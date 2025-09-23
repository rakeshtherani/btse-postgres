#!/bin/bash

# ProxySQL Advanced Connection Pooling Configuration
# Handles 800-900 client connections with 500 backend PostgreSQL limit
# Version: 1.0

set -e

# Configuration
PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"
PRIMARY_HOST="10.40.0.24"
STANDBY_HOST="10.40.0.27"
MAX_BACKEND_CONNECTIONS="500"
MAX_CLIENT_CONNECTIONS="1000"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Function to configure PostgreSQL for connection pooling
configure_postgresql() {
    log "Configuring PostgreSQL servers for connection pooling..."

    # Configure primary server
    info "Disabling parallel workers on primary to prevent shared memory errors..."
    ssh root@$PRIMARY_HOST << 'EOF'
    sudo -u postgres psql << 'EOSQL'
    -- Disable parallel workers to prevent shared memory errors during high load
    ALTER SYSTEM SET max_parallel_workers_per_gather = 0;
    ALTER SYSTEM SET max_parallel_workers = 0;
    ALTER SYSTEM SET max_parallel_maintenance_workers = 0;

    -- Increase max_connections if needed (ensure it's at least 500)
    ALTER SYSTEM SET max_connections = 550;

    -- Reload configuration
    SELECT pg_reload_conf();

    -- Show current settings
    SELECT name, setting FROM pg_settings
    WHERE name IN ('max_connections', 'max_parallel_workers_per_gather',
                   'max_parallel_workers', 'max_parallel_maintenance_workers');
EOSQL

    # Restart PostgreSQL for max_connections change to take effect
    sudo systemctl restart postgresql-13
    sleep 5
EOF

    # Configure standby server
    info "Configuring standby server..."
    ssh root@$STANDBY_HOST << 'EOF'
    sudo -u postgres psql << 'EOSQL'
    -- Same settings for standby
    ALTER SYSTEM SET max_parallel_workers_per_gather = 0;
    ALTER SYSTEM SET max_parallel_workers = 0;
    ALTER SYSTEM SET max_parallel_maintenance_workers = 0;
    ALTER SYSTEM SET max_connections = 550;

    SELECT pg_reload_conf();
EOSQL

    sudo systemctl restart postgresql-13
    sleep 5
EOF

    log "PostgreSQL configuration completed"
}

# Function to configure ProxySQL connection pooling
configure_proxysql_pooling() {
    log "Configuring ProxySQL advanced connection pooling..."

    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main << EOF

    -- ========================================
    -- 1. BACKEND SERVER CONNECTION LIMITS
    -- ========================================

    -- Set primary server to handle max 500 backend connections
    UPDATE pgsql_servers
    SET max_connections = $MAX_BACKEND_CONNECTIONS
    WHERE hostname = '$PRIMARY_HOST' AND hostgroup_id = 1;

    -- Keep standby server at low connections (since we're not using it for reads)
    UPDATE pgsql_servers
    SET max_connections = 50
    WHERE hostname = '$STANDBY_HOST' AND hostgroup_id = 2;

    -- ========================================
    -- 2. GLOBAL CONNECTION POOLING VARIABLES
    -- ========================================

    -- Allow ProxySQL to accept up to 1000 client connections
    UPDATE global_variables
    SET variable_value = '$MAX_CLIENT_CONNECTIONS'
    WHERE variable_name = 'pgsql-max_connections';

    -- Enable connection multiplexing (CRITICAL for pooling)
    UPDATE global_variables
    SET variable_value = 'true'
    WHERE variable_name = 'pgsql-multiplexing';

    -- Set 10-minute timeouts for queued connections during spikes
    UPDATE global_variables
    SET variable_value = '600000'
    WHERE variable_name = 'pgsql-connect_timeout_server';

    UPDATE global_variables
    SET variable_value = '600000'
    WHERE variable_name = 'pgsql-connect_timeout_client';

    UPDATE global_variables
    SET variable_value = '600000'
    WHERE variable_name = 'pgsql-connect_timeout_server_max';

    -- Optimize connection pool utilization
    UPDATE global_variables
    SET variable_value = '10'
    WHERE variable_name = 'pgsql-free_connections_pct';

    -- Fast session recycling (500ms idle before reuse)
    UPDATE global_variables
    SET variable_value = '500'
    WHERE variable_name = 'pgsql-session_idle_ms';

    -- No delay for connection multiplexing
    UPDATE global_variables
    SET variable_value = '0'
    WHERE variable_name = 'pgsql-connection_delay_multiplex_ms';

    -- Set connection age (1 hour max age for connections)
    UPDATE global_variables
    SET variable_value = '3600000'
    WHERE variable_name = 'pgsql-connection_max_age_ms';

    -- ========================================
    -- 3. USER CONFIGURATION
    -- ========================================

    -- Ensure app_user routes to primary hostgroup only
    UPDATE pgsql_users
    SET default_hostgroup = 1,
        max_connections = 0  -- 0 means unlimited from client side
    WHERE username = 'app_user';

    -- ========================================
    -- 4. QUERY RULES (Simplified for single primary)
    -- ========================================

    -- Clear existing query rules for simplified routing
    DELETE FROM pgsql_query_rules;

    -- Optional: Add a simple rule to route everything to primary
    INSERT INTO pgsql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply, comment)
    VALUES (1, 1, '.*', 1, 1, 'Route all queries to primary for connection pooling');

    -- ========================================
    -- 5. APPLY ALL CONFIGURATION
    -- ========================================

    LOAD PGSQL SERVERS TO RUNTIME;
    LOAD PGSQL USERS TO RUNTIME;
    LOAD PGSQL QUERY RULES TO RUNTIME;
    LOAD PGSQL VARIABLES TO RUNTIME;

    SAVE PGSQL SERVERS TO DISK;
    SAVE PGSQL USERS TO DISK;
    SAVE PGSQL QUERY RULES TO DISK;
    SAVE PGSQL VARIABLES TO DISK;

    -- ========================================
    -- 6. SHOW CONFIGURATION SUMMARY
    -- ========================================

    \echo ''
    \echo 'Connection Pool Configuration Summary:'
    \echo '======================================'

    SELECT 'Backend Servers:' as config;
    SELECT '  ' || hostname || ' - Max Connections: ' || max_connections
    FROM runtime_pgsql_servers
    ORDER BY hostgroup_id;

    \echo ''
    SELECT 'Key Connection Pool Settings:' as config;
    SELECT '  ' || variable_name || ' = ' || variable_value
    FROM global_variables
    WHERE variable_name IN (
        'pgsql-max_connections',
        'pgsql-multiplexing',
        'pgsql-connect_timeout_server',
        'pgsql-free_connections_pct',
        'pgsql-session_idle_ms',
        'pgsql-connection_max_age_ms'
    )
    ORDER BY variable_name;

EOF

    log "ProxySQL connection pooling configuration completed"
}

# Function to show pool mathematics
show_pool_math() {
    log "Connection Pool Mathematics"
    echo "================================================"
    echo "Configuration:"
    echo "  Max Client Connections: $MAX_CLIENT_CONNECTIONS"
    echo "  Max Backend Connections: $MAX_BACKEND_CONNECTIONS"
    echo "  Free Connections %: 10%"
    echo ""
    echo "Pool Calculations:"
    echo "  Idle connections in pool: $(($MAX_BACKEND_CONNECTIONS * 10 / 100)) connections"
    echo "  Maximum backend connections: $MAX_BACKEND_CONNECTIONS connections"
    echo "  Client connections supported: $MAX_CLIENT_CONNECTIONS connections"
    echo ""
    echo "Traffic Flow Scenarios:"
    echo "  Normal Load (≤500): Direct connection, no queuing"
    echo "  High Load (800): 500 get backend, 300 wait in queue"
    echo "  Peak Load (900): 500 get backend, 400 wait in queue"
    echo "================================================"
}

# Function to create monitoring queries
create_monitoring_script() {
    log "Creating monitoring script..."

    cat > /tmp/monitor_proxysql_pool.sh << 'MONITOR_EOF'
#!/bin/bash

PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"

echo "ProxySQL Connection Pool Status"
echo "================================"

# Connection pool status
echo -e "\n[Connection Pool Status]"
PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
SELECT
    'Server: ' || srv_host || ':' || srv_port ||
    ' | Used: ' || ConnUsed ||
    ' | Free: ' || ConnFree ||
    ' | Total: ' || (ConnUsed + ConnFree) ||
    ' | Queries: ' || Queries
FROM stats_pgsql_connection_pool
ORDER BY srv_host;
EOF

# Backend connection count
echo -e "\n[Backend Connections]"
PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
SELECT 'Total Backend Connections: ' || COUNT(*)
FROM stats_pgsql_processlist;
EOF

# Client connections
echo -e "\n[Client Connections]"
PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
SELECT 'User: ' || username || ' | Frontend Connections: ' || frontend_connections
FROM stats_pgsql_users;
EOF

# Timeout errors
echo -e "\n[Recent Errors]"
PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
SELECT error_msg || ' (Count: ' || count_star || ')'
FROM stats_pgsql_errors
WHERE error_msg LIKE '%timeout%'
ORDER BY last_seen DESC
LIMIT 5;
EOF

# PostgreSQL backend status
echo -e "\n[PostgreSQL Backend Status]"
ssh root@10.40.0.24 "sudo -u postgres psql -t -c \"SELECT 'PostgreSQL Connections by User:'; SELECT usename, count(*) FROM pg_stat_activity WHERE usename IS NOT NULL GROUP BY usename ORDER BY count DESC;\""

MONITOR_EOF

    chmod +x /tmp/monitor_proxysql_pool.sh
    log "Monitoring script created at /tmp/monitor_proxysql_pool.sh"
}

# Function to create test script
create_test_script() {
    log "Creating connection pool test script..."

    cat > /tmp/test_connection_pool.sh << 'TEST_EOF'
#!/bin/bash

# Test queries file
cat > /tmp/test_queries.sql << 'SQL'
SELECT 1;
SELECT pg_sleep(0.1);
SELECT current_timestamp;
SQL

echo "================================================"
echo "Connection Pool Test"
echo "================================================"

# Test parameters
CONNECTIONS=800
TRANSACTIONS=100
HOST="127.0.0.1"
PORT="6133"
USER="app_user"
PASS="app_password_123"
DB="txn"

echo "Test Configuration:"
echo "  Client Connections: $CONNECTIONS"
echo "  Transactions per Client: $TRANSACTIONS"
echo "  Target: ProxySQL at $HOST:$PORT"
echo ""

# Check if pgbench is available
if ! command -v pgbench &> /dev/null; then
    echo "Installing pgbench..."
    yum install -y postgresql13 2>/dev/null || apt-get install -y postgresql-client 2>/dev/null
fi

# Monitor in background
echo "Starting background monitoring..."
watch -n 2 "/tmp/monitor_proxysql_pool.sh" &
WATCH_PID=$!

echo "Running connection pool test..."
echo "This will simulate $CONNECTIONS concurrent connections..."

# Run the test
PGPASSWORD=$PASS pgbench -f /tmp/test_queries.sql \
    -c $CONNECTIONS \
    -t $TRANSACTIONS \
    -h $HOST \
    -p $PORT \
    -U $USER \
    $DB

# Stop monitoring
kill $WATCH_PID 2>/dev/null

echo ""
echo "Test completed. Check monitoring output above."
echo "================================================"

# Final status check
/tmp/monitor_proxysql_pool.sh

TEST_EOF

    chmod +x /tmp/test_connection_pool.sh
    log "Test script created at /tmp/test_connection_pool.sh"
}

# Main execution
main() {
    echo "================================================"
    echo "ProxySQL Advanced Connection Pooling Setup"
    echo "================================================"
    echo "This will configure ProxySQL to handle:"
    echo "  • 800-900 client connections"
    echo "  • Limited to 500 backend PostgreSQL connections"
    echo "  • Connection queuing during traffic spikes"
    echo "================================================"

    read -p "Do you want to proceed? (y/n): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Configuration cancelled."
        exit 0
    fi

    # Step 1: Configure PostgreSQL
    configure_postgresql

    # Step 2: Configure ProxySQL pooling
    configure_proxysql_pooling

    # Step 3: Show pool mathematics
    show_pool_math

    # Step 4: Create monitoring script
    create_monitoring_script

    # Step 5: Create test script
    create_test_script

    log "Advanced connection pooling configuration completed!"
    echo "================================================"
    echo "Next Steps:"
    echo "1. Monitor pool status: /tmp/monitor_proxysql_pool.sh"
    echo "2. Test with high load: /tmp/test_connection_pool.sh"
    echo "3. Watch real-time: watch -n 2 /tmp/monitor_proxysql_pool.sh"
    echo "================================================"
}

# Run main function
main "$@"
