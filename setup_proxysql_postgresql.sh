#!/bin/bash

# ProxySQL Setup Script for PostgreSQL with repmgr
# Designed for CentOS/RHEL/Rocky Linux with PostgreSQL 13 and repmgr
# Version: 2.0
# Date: 2025

set -e

# Configuration Variables
PRIMARY_HOST="10.40.0.24"
STANDBY_HOST="10.40.0.27"
PROXYSQL_HOST="10.40.0.17"  # Change this to your ProxySQL server IP
PROXYSQL_VERSION="3.0.2"
PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_PGSQL_PORT="6133"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"
MONITOR_USER="proxysql_monitor"
MONITOR_PASS="monitor_password_123"
APP_USER="app_user"
APP_PASS="app_password_123"
DB_NAME="txn"
REPMGR_DB="repmgr"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check connectivity to PostgreSQL servers
    ping -c 1 $PRIMARY_HOST &>/dev/null || error "Cannot reach primary server: $PRIMARY_HOST"
    ping -c 1 $STANDBY_HOST &>/dev/null || error "Cannot reach standby server: $STANDBY_HOST"

    # Check if PostgreSQL is running on both servers
    ssh root@$PRIMARY_HOST "systemctl is-active postgresql-13" &>/dev/null || error "PostgreSQL not running on primary"
    ssh root@$STANDBY_HOST "systemctl is-active postgresql-13" &>/dev/null || error "PostgreSQL not running on standby"

    # Check repmgr status
    ssh root@$PRIMARY_HOST "sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf node check" &>/dev/null || warning "repmgr check failed on primary"

    log "Prerequisites check completed successfully"
}

# Function to install ProxySQL
install_proxysql() {
    log "Installing ProxySQL on $HOSTNAME..."

    # Check if ProxySQL is already installed
    if command -v proxysql &>/dev/null; then
        warning "ProxySQL is already installed"
        systemctl stop proxysql 2>/dev/null || true
    else
        # Download and install ProxySQL 3.0
        log "Downloading ProxySQL 3.0.2..."
        cd /tmp

        # Use AlmaLinux 9 build for Amazon Linux 2023 compatibility
        curl -OL https://github.com/sysown/proxysql/releases/download/v3.0.2/proxysql-3.0.2-1-almalinux9.x86_64.rpm

        log "Installing ProxySQL 3.0.2 package..."
        # Install with dependencies
        yum install -y gnutls perl-DBI perl-DBD-mysql || true
        yum install -y proxysql-3.0.2-1-almalinux9.x86_64.rpm || \
        yum install -y --nogpgcheck proxysql-3.0.2-1-almalinux9.x86_64.rpm || \
        rpm -ivh --nodeps proxysql-3.0.2-1-almalinux9.x86_64.rpm

        # Clean up
        rm -f /tmp/proxysql-3.0.2-1-almalinux9.x86_64.rpm
    fi

    # Verify installation
    proxysql --version || error "ProxySQL installation failed"
    log "ProxySQL installed successfully"
}

# Function to configure ProxySQL
configure_proxysql() {
    log "Configuring ProxySQL..."

    # Backup original configuration
    cp /etc/proxysql.cnf /etc/proxysql.cnf.bak.$(date +%Y%m%d_%H%M%S)

    # Create ProxySQL configuration
    cat > /etc/proxysql.cnf << EOF
datadir="/var/lib/proxysql"
errorlog="/var/log/proxysql/proxysql.log"

admin_variables=
{
    admin_credentials="$PROXYSQL_ADMIN_USER:$PROXYSQL_ADMIN_PASS"
    pgsql_ifaces="0.0.0.0:$PROXYSQL_ADMIN_PORT"
}

pgsql_variables=
{
    threads=4
    max_connections=2048
    default_query_delay=0
    default_query_timeout=36000000
    have_compress=true
    poll_timeout=2000
    interfaces="0.0.0.0:$PROXYSQL_PGSQL_PORT"
    default_schema="information_schema"
    stacksize=1048576
    server_version="13.0"
    connect_timeout_server=3000
    monitor_username="$MONITOR_USER"
    monitor_password="$MONITOR_PASS"
    monitor_history=600000
    monitor_connect_interval=60000
    monitor_ping_interval=10000
    ping_interval_server_msec=120000
    ping_timeout_server=500
    commands_stats=true
    sessions_sort=true
    monitor_enabled=true
}

# ProxySQL 3.0 configuration will be done via SQL commands in runtime
EOF

    log "ProxySQL configuration created"
}

# Function to start ProxySQL
start_proxysql() {
    log "Starting ProxySQL service..."

    # Create log directory if it doesn't exist
    mkdir -p /var/log/proxysql
    chown proxysql:proxysql /var/log/proxysql

    # Start and enable ProxySQL
    systemctl start proxysql
    systemctl enable proxysql

    # Wait for ProxySQL to start
    sleep 5

    # Check if ProxySQL is running
    if systemctl is-active proxysql &>/dev/null; then
        log "ProxySQL started successfully"
    else
        error "Failed to start ProxySQL"
    fi

    # Check ports
    ss -tlnp | grep $PROXYSQL_ADMIN_PORT &>/dev/null || error "Admin port $PROXYSQL_ADMIN_PORT not listening"
    ss -tlnp | grep $PROXYSQL_PGSQL_PORT &>/dev/null || error "PostgreSQL port $PROXYSQL_PGSQL_PORT not listening"

    log "ProxySQL ports verified: Admin=$PROXYSQL_ADMIN_PORT, PostgreSQL=$PROXYSQL_PGSQL_PORT"
}

# Function to create PostgreSQL users
create_postgresql_users() {
    log "Creating PostgreSQL users on primary server..."

    ssh root@$PRIMARY_HOST << EOF
    sudo -u postgres psql << 'EOSQL'

    -- Check and create monitoring user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$MONITOR_USER') THEN
            CREATE USER $MONITOR_USER WITH PASSWORD '$MONITOR_PASS';
            RAISE NOTICE 'User $MONITOR_USER created';
        ELSE
            ALTER USER $MONITOR_USER WITH PASSWORD '$MONITOR_PASS';
            RAISE NOTICE 'User $MONITOR_USER password updated';
        END IF;
    END
    \$\$;

    -- Grant permissions for monitoring
    GRANT CONNECT ON DATABASE postgres TO $MONITOR_USER;
    GRANT CONNECT ON DATABASE $REPMGR_DB TO $MONITOR_USER;
    GRANT pg_monitor TO $MONITOR_USER;

    -- Connect to repmgr database
    \c $REPMGR_DB
    GRANT USAGE ON SCHEMA repmgr TO $MONITOR_USER;
    GRANT SELECT ON ALL TABLES IN SCHEMA repmgr TO $MONITOR_USER;

    -- Check and create application database
    \c postgres
    SELECT 'CREATE DATABASE $DB_NAME' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec

    -- Check and create application user
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$APP_USER') THEN
            CREATE USER $APP_USER WITH PASSWORD '$APP_PASS';
            RAISE NOTICE 'User $APP_USER created';
        ELSE
            ALTER USER $APP_USER WITH PASSWORD '$APP_PASS';
            RAISE NOTICE 'User $APP_USER password updated';
        END IF;
    END
    \$\$;

    -- Grant privileges on application database
    GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $APP_USER;

    -- Connect to application database and grant schema permissions
    \c $DB_NAME
    GRANT ALL PRIVILEGES ON SCHEMA public TO $APP_USER;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $APP_USER;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $APP_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $APP_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $APP_USER;

EOSQL
EOF

    log "PostgreSQL users created/updated successfully"
}

# Function to update pg_hba.conf
update_pg_hba() {
    log "Updating pg_hba.conf on PostgreSQL servers..."

    # Update primary server
    log "Updating pg_hba.conf on primary server..."
    ssh root@$PRIMARY_HOST << 'EOF'
    PG_HBA="/var/lib/pgsql/13/data/pg_hba.conf"

    # Backup pg_hba.conf
    cp $PG_HBA ${PG_HBA}.bak.$(date +%Y%m%d_%H%M%S)

    # Check if ProxySQL rules already exist
    if ! grep -q "ProxySQL connections" $PG_HBA; then
        # Add ProxySQL rules before the first general host rule
        cat >> $PG_HBA << 'EOHBA'

# ProxySQL connections
host    all             proxysql_monitor    10.0.0.0/8              md5
host    all             app_user            10.0.0.0/8              md5
host    repmgr          proxysql_monitor    10.0.0.0/8              md5
host    txn             app_user            10.0.0.0/8              md5
EOHBA
    fi

    # Reload PostgreSQL
    systemctl reload postgresql-13
EOF

    # Update standby server
    log "Updating pg_hba.conf on standby server..."
    ssh root@$STANDBY_HOST << 'EOF'
    PG_HBA="/var/lib/pgsql/13/data/pg_hba.conf"

    # Backup pg_hba.conf
    cp $PG_HBA ${PG_HBA}.bak.$(date +%Y%m%d_%H%M%S)

    # Check if ProxySQL rules already exist
    if ! grep -q "ProxySQL connections" $PG_HBA; then
        # Add ProxySQL rules
        cat >> $PG_HBA << 'EOHBA'

# ProxySQL connections
host    all             proxysql_monitor    10.0.0.0/8              md5
host    all             app_user            10.0.0.0/8              md5
host    repmgr          proxysql_monitor    10.0.0.0/8              md5
host    txn             app_user            10.0.0.0/8              md5
EOHBA
    fi

    # Reload PostgreSQL
    systemctl reload postgresql-13
EOF

    log "pg_hba.conf updated successfully on both servers"
}

# Function to configure ProxySQL runtime settings
configure_proxysql_runtime() {
    log "Configuring ProxySQL runtime settings..."

    # Wait for ProxySQL to be ready
    sleep 5

    # Configure through admin interface - ProxySQL 3.0 specific
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main << EOF

    -- First, clear any existing configuration
    DELETE FROM pgsql_servers;
    DELETE FROM pgsql_users;
    DELETE FROM pgsql_query_rules;
    DELETE FROM pgsql_replication_hostgroups;

    -- Add PostgreSQL servers
    INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, comment)
    VALUES (1, '$PRIMARY_HOST', 5432, 1000, 'Primary PostgreSQL Server');

    INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, comment)
    VALUES (2, '$STANDBY_HOST', 5432, 1000, 'Standby PostgreSQL Server');

    -- Add application user
    INSERT INTO pgsql_users (username, password, default_hostgroup, active, comment)
    VALUES ('$APP_USER', '$APP_PASS', 1, 1, 'Application User');

    -- Add query routing rules
    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (1, 1, '^SELECT.*', 2, 1, 'Route SELECT to standby server');

    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (2, 1, '^(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TRUNCATE).*', 1, 1, 'Route writes to primary server');

    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (3, 1, '^(BEGIN|START|COMMIT|ROLLBACK).*', 1, 1, 'Route transactions to primary');

    -- Configure replication hostgroups
    INSERT INTO pgsql_replication_hostgroups (writer_hostgroup, reader_hostgroup, comment)
    VALUES (1, 2, 'Primary-Standby replication setup');

    -- Update monitoring settings
    UPDATE global_variables SET variable_value = '$MONITOR_USER'
    WHERE variable_name = 'pgsql-monitor_username';

    UPDATE global_variables SET variable_value = '$MONITOR_PASS'
    WHERE variable_name = 'pgsql-monitor_password';

    UPDATE global_variables SET variable_value = 'true'
    WHERE variable_name = 'pgsql-monitor_enabled';

    -- Load all configuration to runtime
    LOAD PGSQL SERVERS TO RUNTIME;
    LOAD PGSQL USERS TO RUNTIME;
    LOAD PGSQL QUERY RULES TO RUNTIME;
    LOAD PGSQL VARIABLES TO RUNTIME;

    -- Save all configuration to disk
    SAVE PGSQL SERVERS TO DISK;
    SAVE PGSQL USERS TO DISK;
    SAVE PGSQL QUERY RULES TO DISK;
    SAVE PGSQL VARIABLES TO DISK;

    -- Verify configuration
    SELECT 'Servers configured: ' || COUNT(*) FROM runtime_pgsql_servers;
    SELECT 'Users configured: ' || COUNT(*) FROM runtime_pgsql_users;
    SELECT 'Query rules configured: ' || COUNT(*) FROM runtime_pgsql_query_rules;

EOF

    log "ProxySQL runtime configuration completed"
}

# Function to test ProxySQL connectivity
test_proxysql() {
    log "Testing ProxySQL connectivity..."

    # Test admin interface
    info "Testing admin interface..."
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -c "SELECT version();" || error "Admin interface connection failed"

    # Test application connectivity
    info "Testing application connectivity..."
    PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME -c "SELECT 'ProxySQL connection successful' as status;" || error "Application connection failed"

    # Create test table
    info "Creating test table..."
    PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME << EOF
    CREATE TABLE IF NOT EXISTS proxysql_test (
        id serial PRIMARY KEY,
        name varchar(50),
        created_at timestamp DEFAULT now()
    );
    INSERT INTO proxysql_test (name) VALUES ('Test from ProxySQL');
EOF

    # Test read operations
    info "Testing read operations (should go to standby)..."
    for i in {1..3}; do
        echo -n "Read test $i - Server: "
        PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME -t -c "SELECT inet_server_addr();" 2>/dev/null | tr -d ' '
    done

    log "ProxySQL connectivity tests completed successfully"
}

# Function to show ProxySQL status
show_status() {
    log "ProxySQL Status Summary"
    echo "================================================"

    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main << EOF

    -- Server status
    \echo 'PostgreSQL Servers:'
    SELECT hostgroup_id, hostname, port, status, weight
    FROM runtime_pgsql_servers
    ORDER BY hostgroup_id;

    -- Connection pool stats
    \echo '\nConnection Pool Statistics:'
    SELECT hostgroup, srv_host, srv_port, status, ConnUsed, ConnFree, ConnOK, ConnERR
    FROM stats_pgsql_connection_pool;

    -- Query rules
    \echo '\nQuery Rules:'
    SELECT rule_id, hits, match_pattern, destination_hostgroup
    FROM stats_pgsql_query_rules
    WHERE hits > 0
    ORDER BY rule_id;

    -- Replication hostgroups
    \echo '\nReplication Hostgroups:'
    SELECT * FROM pgsql_replication_hostgroups;

EOF

    echo "================================================"
    log "Configuration Summary:"
    echo "  Primary Server: $PRIMARY_HOST:5432 (Hostgroup 1 - Writes)"
    echo "  Standby Server: $STANDBY_HOST:5432 (Hostgroup 2 - Reads)"
    echo "  ProxySQL Admin: $PROXYSQL_HOST:$PROXYSQL_ADMIN_PORT"
    echo "  ProxySQL PostgreSQL: $PROXYSQL_HOST:$PROXYSQL_PGSQL_PORT"
    echo "  Application User: $APP_USER"
    echo "  Monitor User: $MONITOR_USER"
    echo "================================================"
}

# Main execution
main() {
    echo "================================================"
    echo "ProxySQL Setup for PostgreSQL with repmgr"
    echo "================================================"

    check_root
    check_prerequisites
    install_proxysql
    configure_proxysql
    start_proxysql
    create_postgresql_users
    update_pg_hba
    configure_proxysql_runtime
    test_proxysql
    show_status

    log "ProxySQL setup completed successfully!"
    echo "================================================"
    echo "Next steps:"
    echo "1. Test failover: Use test_proxysql_failover.sh"
    echo "2. Monitor ProxySQL: tail -f /var/log/proxysql/proxysql.log"
    echo "3. Access admin: psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U admin"
    echo "4. Connect apps: psql -h $PROXYSQL_HOST -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME"
    echo "================================================"
}

# Run main function
main "$@"
