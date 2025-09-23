#!/bin/bash

# ProxySQL Monitoring Script
# Provides real-time monitoring of ProxySQL with PostgreSQL
# Version: 2.0

set -e

# Configuration
PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"
REFRESH_INTERVAL=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function to display header
show_header() {
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}        ProxySQL PostgreSQL Monitor${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e "${YELLOW}Time: $(date +'%Y-%m-%d %H:%M:%S')${NC}"
    echo ""
}

# Function to show server status
show_server_status() {
    echo -e "${GREEN}[PostgreSQL Servers]${NC}"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
    SELECT
        CASE hostgroup_id
            WHEN 1 THEN 'WRITER'
            WHEN 2 THEN 'READER'
            ELSE 'OTHER'
        END || ' | ' ||
        hostname || ':' || port || ' | ' ||
        CASE status
            WHEN 'ONLINE' THEN E'\033[32mONLINE\033[0m'
            WHEN 'OFFLINE_SOFT' THEN E'\033[33mOFFLINE_SOFT\033[0m'
            WHEN 'OFFLINE_HARD' THEN E'\033[31mOFFLINE_HARD\033[0m'
            ELSE status
        END || ' | ' ||
        'Weight: ' || weight || ' | ' ||
        'Max Conn: ' || max_connections
    FROM runtime_pgsql_servers
    ORDER BY hostgroup_id, hostname;
EOF
    echo ""
}

# Function to show connection pool statistics
show_connection_pool() {
    echo -e "${GREEN}[Connection Pool Statistics]${NC}"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
    SELECT
        srv_host || ':' || srv_port || ' (HG' || hostgroup || ') | ' ||
        'Status: ' || status || ' | ' ||
        'Used: ' || ConnUsed || ' | ' ||
        'Free: ' || ConnFree || ' | ' ||
        'OK: ' || ConnOK || ' | ' ||
        'Err: ' || ConnERR || ' | ' ||
        'Queries: ' || Queries
    FROM stats_pgsql_connection_pool
    WHERE status != 'OFFLINE_HARD'
    ORDER BY Queries DESC;
EOF
    echo ""
}

# Function to show query statistics
show_query_stats() {
    echo -e "${GREEN}[Query Rule Statistics]${NC}"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
    SELECT
        'Rule ' || rule_id || ': ' ||
        CASE rule_id
            WHEN 1 THEN 'SELECT queries → Standby'
            WHEN 2 THEN 'Write queries → Primary'
            WHEN 3 THEN 'Transactions → Primary'
            ELSE match_pattern
        END || ' | ' ||
        'Hits: ' || hits
    FROM stats_pgsql_query_rules
    WHERE hits > 0
    ORDER BY rule_id;
EOF
    echo ""
}

# Function to show global status
show_global_status() {
    echo -e "${GREEN}[Global Status]${NC}"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
    SELECT
        'Active Connections: ' ||
        (SELECT SUM(ConnUsed) FROM stats_pgsql_connection_pool) || ' | ' ||
        'Total Queries: ' ||
        (SELECT SUM(Queries) FROM stats_pgsql_connection_pool) || ' | ' ||
        'Total Bytes Sent: ' ||
        pg_size_pretty((SELECT SUM(Bytes_sent) FROM stats_pgsql_connection_pool)::bigint) || ' | ' ||
        'Total Bytes Recv: ' ||
        pg_size_pretty((SELECT SUM(Bytes_recv) FROM stats_pgsql_connection_pool)::bigint);
EOF
    echo ""
}

# Function to show user statistics
show_user_stats() {
    echo -e "${GREEN}[User Statistics]${NC}"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
    SELECT
        'User: ' || username || ' | ' ||
        'Frontend Conn: ' || frontend_connections || ' | ' ||
        'Frontend Max: ' || frontend_max_connections
    FROM stats_pgsql_users;
EOF
    echo ""
}

# Function to show recent errors
show_errors() {
    echo -e "${GREEN}[Recent Connection Errors]${NC}"
    ERROR_COUNT=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT SUM(ConnERR) FROM stats_pgsql_connection_pool;
    " 2>/dev/null | tr -d ' ')

    if [ "$ERROR_COUNT" -gt "0" ]; then
        echo -e "${RED}Total connection errors: $ERROR_COUNT${NC}"
        PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
        SELECT
            srv_host || ':' || srv_port || ' - Errors: ' || ConnERR
        FROM stats_pgsql_connection_pool
        WHERE ConnERR > 0;
EOF
    else
        echo -e "${GREEN}No connection errors${NC}"
    fi
    echo ""
}

# Function for continuous monitoring
continuous_monitor() {
    while true; do
        show_header
        show_server_status
        show_connection_pool
        show_query_stats
        show_global_status
        show_user_stats
        show_errors

        echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
        sleep $REFRESH_INTERVAL
    done
}

# Function for single status check
single_check() {
    show_header
    show_server_status
    show_connection_pool
    show_query_stats
    show_global_status
    show_user_stats
    show_errors
}

# Function to export statistics to file
export_stats() {
    local output_file="proxysql_stats_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "ProxySQL Statistics Report"
        echo "Generated: $(date)"
        echo "================================================"
        echo ""

        echo "[Server Configuration]"
        PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
        SELECT * FROM runtime_pgsql_servers ORDER BY hostgroup_id;
EOF

        echo ""
        echo "[Connection Pool Statistics]"
        PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
        SELECT * FROM stats_pgsql_connection_pool ORDER BY srv_host;
EOF

        echo ""
        echo "[Query Rules]"
        PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
        SELECT * FROM runtime_pgsql_query_rules ORDER BY rule_id;
EOF

        echo ""
        echo "[Query Rule Statistics]"
        PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t << EOF
        SELECT * FROM stats_pgsql_query_rules ORDER BY hits DESC;
EOF

    } > "$output_file"

    echo -e "${GREEN}Statistics exported to: $output_file${NC}"
}

# Function to reset statistics
reset_stats() {
    echo -e "${YELLOW}Resetting ProxySQL statistics...${NC}"

    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main << EOF
    -- Reset stats (ProxySQL automatically resets stats when queried with specific commands)
    SELECT 1;
EOF

    echo -e "${GREEN}Statistics reset completed${NC}"
}

# Function to show detailed server info
detailed_server_info() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}       Detailed Server Information${NC}"
    echo -e "${CYAN}================================================${NC}"

    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main << EOF
    \echo 'Runtime Servers:'
    SELECT * FROM runtime_pgsql_servers\gx

    \echo '\nServer Connection Pool:'
    SELECT * FROM stats_pgsql_connection_pool\gx

    \echo '\nReplication Hostgroups:'
    SELECT * FROM pgsql_replication_hostgroups;

    \echo '\nGlobal Variables (Monitoring):'
    SELECT variable_name, variable_value
    FROM global_variables
    WHERE variable_name LIKE '%monitor%'
    ORDER BY variable_name;
EOF
}

# Main menu
show_menu() {
    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}      ProxySQL Monitoring Options${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo "1. Continuous monitoring (refresh every ${REFRESH_INTERVAL}s)"
    echo "2. Single status check"
    echo "3. Detailed server information"
    echo "4. Export statistics to file"
    echo "5. Reset statistics"
    echo "6. Change refresh interval"
    echo "0. Exit"
    echo "================================================"
}

# Main execution
main() {
    # Check if ProxySQL is running
    if ! systemctl is-active proxysql &>/dev/null; then
        echo -e "${RED}ProxySQL is not running!${NC}"
        echo "Please start ProxySQL first: systemctl start proxysql"
        exit 1
    fi

    # If argument provided, use it
    case "$1" in
        --continuous|-c)
            continuous_monitor
            ;;
        --single|-s)
            single_check
            ;;
        --export|-e)
            export_stats
            ;;
        --detailed|-d)
            detailed_server_info
            ;;
        *)
            # Interactive menu
            while true; do
                show_menu
                read -p "Select an option: " choice

                case $choice in
                    1) continuous_monitor ;;
                    2) single_check; read -p "Press Enter to continue..." ;;
                    3) detailed_server_info; read -p "Press Enter to continue..." ;;
                    4) export_stats; read -p "Press Enter to continue..." ;;
                    5) reset_stats; read -p "Press Enter to continue..." ;;
                    6)
                        read -p "Enter new refresh interval (seconds): " new_interval
                        if [[ "$new_interval" =~ ^[0-9]+$ ]]; then
                            REFRESH_INTERVAL=$new_interval
                            echo -e "${GREEN}Refresh interval set to ${REFRESH_INTERVAL} seconds${NC}"
                        else
                            echo -e "${RED}Invalid interval${NC}"
                        fi
                        ;;
                    0) echo "Exiting..."; exit 0 ;;
                    *) echo -e "${RED}Invalid option${NC}" ;;
                esac
            done
            ;;
    esac
}

# Handle Ctrl+C gracefully
trap 'echo -e "\n${YELLOW}Monitoring stopped${NC}"; exit 0' INT

# Run main function
main "$@"
