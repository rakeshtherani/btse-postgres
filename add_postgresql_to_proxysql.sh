#!/bin/bash

#############################################################################
# Script: add_postgresql_to_proxysql.sh
# Description: Add a PostgreSQL server as a backend to ProxySQL for load balancing
# Usage: ./add_postgresql_to_proxysql.sh <server_ip> <hostgroup> [weight]
# Example: ./add_postgresql_to_proxysql.sh 10.40.0.17 2 1000
#############################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ProxySQL connection details
PROXYSQL_ADMIN_HOST="127.0.0.1"
PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to execute ProxySQL admin commands
execute_proxysql_cmd() {
    local cmd="$1"
    export PGPASSWORD=$PROXYSQL_ADMIN_PASS
    psql -h $PROXYSQL_ADMIN_HOST -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -c "$cmd"
    unset PGPASSWORD
}

# Check if required parameters are provided
if [ $# -lt 2 ]; then
    echo "Usage: $0 <server_ip> <hostgroup> [weight] [max_connections]"
    echo ""
    echo "Parameters:"
    echo "  server_ip       - IP address of PostgreSQL server to add"
    echo "  hostgroup       - Hostgroup ID (1 for primary/writes, 2 for standby/reads)"
    echo "  weight          - Server weight for load balancing (default: 1000)"
    echo "  max_connections - Maximum connections to this server (default: 200)"
    echo ""
    echo "Example:"
    echo "  $0 10.40.0.17 2              # Add as read replica with defaults"
    echo "  $0 10.40.0.18 2 1500 300     # Add with custom weight and connections"
    echo "  $0 10.40.0.20 1 1000 500     # Add as primary server"
    exit 1
fi

# Parse parameters
SERVER_IP="$1"
HOSTGROUP="$2"
WEIGHT="${3:-1000}"
MAX_CONNECTIONS="${4:-200}"
SERVER_PORT="5432"

print_status "Adding PostgreSQL server $SERVER_IP to ProxySQL"
echo "Configuration:"
echo "  - Server: $SERVER_IP:$SERVER_PORT"
echo "  - Hostgroup: $HOSTGROUP"
echo "  - Weight: $WEIGHT"
echo "  - Max Connections: $MAX_CONNECTIONS"
echo ""

# Step 1: Check if server is already configured
print_status "Checking if server already exists in ProxySQL..."
EXISTS=$(execute_proxysql_cmd "SELECT COUNT(*) FROM pgsql_servers WHERE hostname='$SERVER_IP' AND hostgroup_id=$HOSTGROUP;" | grep -E '^\s*[0-9]+' | tr -d ' ')

if [ "$EXISTS" -gt 0 ]; then
    print_warning "Server $SERVER_IP already exists in hostgroup $HOSTGROUP"
    read -p "Do you want to update the configuration? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Exiting without changes"
        exit 0
    fi

    # Update existing server
    print_status "Updating server configuration..."
    execute_proxysql_cmd "UPDATE pgsql_servers SET weight=$WEIGHT, max_connections=$MAX_CONNECTIONS WHERE hostname='$SERVER_IP' AND hostgroup_id=$HOSTGROUP;"
else
    # Step 2: Test connectivity to the PostgreSQL server
    print_status "Testing connectivity to PostgreSQL server $SERVER_IP..."
    export PGPASSWORD=app_password_123
    if psql -h $SERVER_IP -p $SERVER_PORT -U app_user -d postgres -c "SELECT version();" > /dev/null 2>&1; then
        print_status "Successfully connected to PostgreSQL server"
    else
        print_warning "Could not connect with app_user, trying with repmgr..."
        export PGPASSWORD=repmgr_password
        if psql -h $SERVER_IP -p $SERVER_PORT -U repmgr -d repmgr -c "SELECT version();" > /dev/null 2>&1; then
            print_status "Successfully connected to PostgreSQL server with repmgr user"
        else
            print_error "Cannot connect to PostgreSQL server at $SERVER_IP:$SERVER_PORT"
            print_error "Please ensure PostgreSQL is running and accessible"
            exit 1
        fi
    fi
    unset PGPASSWORD

    # Step 3: Add server to ProxySQL
    print_status "Adding server to ProxySQL..."

    # Determine comment based on hostgroup
    if [ "$HOSTGROUP" = "1" ]; then
        COMMENT="Primary PostgreSQL server"
    elif [ "$HOSTGROUP" = "2" ]; then
        COMMENT="Standby PostgreSQL server for read queries"
    else
        COMMENT="PostgreSQL server in hostgroup $HOSTGROUP"
    fi

    execute_proxysql_cmd "INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight, status, max_connections, comment)
                          VALUES ($HOSTGROUP, '$SERVER_IP', $SERVER_PORT, $WEIGHT, 'ONLINE', $MAX_CONNECTIONS, '$COMMENT');"
fi

# Step 4: Load configuration to runtime
print_status "Loading configuration to runtime..."
execute_proxysql_cmd "LOAD PGSQL SERVERS TO RUNTIME;"

# Step 5: Save configuration to disk
print_status "Saving configuration to disk..."
execute_proxysql_cmd "SAVE PGSQL SERVERS TO DISK;"

# Step 6: Verify the server was added
print_status "Verifying server configuration..."
execute_proxysql_cmd "SELECT hostgroup_id, hostname, port, weight, status, max_connections
                      FROM runtime_pgsql_servers
                      WHERE hostname='$SERVER_IP' AND hostgroup_id=$HOSTGROUP;"

# Step 7: Check server status in connection pool
print_status "Checking server status in connection pool..."
sleep 2  # Give ProxySQL time to establish connections
execute_proxysql_cmd "SELECT hostgroup, srv_host, srv_port, status, ConnUsed, ConnFree, Queries
                      FROM stats_pgsql_connection_pool
                      WHERE srv_host='$SERVER_IP';"

# Step 8: Test load balancing if adding to read hostgroup
if [ "$HOSTGROUP" = "2" ]; then
    print_status "Testing read query routing to new server..."

    echo ""
    echo "Running 10 test queries to check load distribution..."
    export PGPASSWORD=app_password_123

    for i in {1..10}; do
        SERVER=$(psql -h $PROXYSQL_ADMIN_HOST -p 6133 -U app_user -d txn -t -c "SELECT inet_server_addr()" 2>/dev/null | tr -d ' ')
        if [ "$SERVER" = "$SERVER_IP" ]; then
            echo "  Query $i routed to NEW server: $SERVER"
        else
            echo "  Query $i routed to: $SERVER"
        fi
    done

    unset PGPASSWORD
fi

# Step 9: Show final statistics
print_status "Final server configuration:"
execute_proxysql_cmd "SELECT hostgroup_id, hostname, port, weight, status, max_connections, comment
                      FROM runtime_pgsql_servers
                      ORDER BY hostgroup_id, hostname;"

echo ""
print_status "Successfully added PostgreSQL server $SERVER_IP to ProxySQL hostgroup $HOSTGROUP"
echo ""
echo "Next steps:"
echo "1. Monitor the server performance using: ./monitor_proxysql.sh"
echo "2. Adjust weight if needed for load distribution"
echo "3. Configure query rules if specific routing is required"
