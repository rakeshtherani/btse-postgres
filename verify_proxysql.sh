#!/bin/bash

# ProxySQL Verification and Health Check Script
# Comprehensive verification of ProxySQL setup with PostgreSQL
# Version: 2.0

set -e

# Configuration
PRIMARY_HOST="10.40.0.24"
STANDBY_HOST="10.40.0.27"
PROXYSQL_HOST="10.40.0.17"
PROXYSQL_ADMIN_PORT="6132"
PROXYSQL_PGSQL_PORT="6133"
PROXYSQL_ADMIN_USER="admin"
PROXYSQL_ADMIN_PASS="admin"
MONITOR_USER="proxysql_monitor"
MONITOR_PASS="monitor_password_123"
APP_USER="app_user"
APP_PASS="app_password_123"
DB_NAME="txn"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Status tracking
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Function to print section header
print_section() {
    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}================================================${NC}"
}

# Function to check and report status
check_status() {
    local check_name="$1"
    local command="$2"
    local expected="$3"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    echo -n "Checking $check_name... "

    if eval "$command" 2>/dev/null; then
        echo -e "${GREEN}✓ PASSED${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
}

# Function to show warning
show_warning() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
    WARNINGS=$((WARNINGS + 1))
}

# 1. Check PostgreSQL Servers
check_postgresql_servers() {
    print_section "1. PostgreSQL Server Verification"

    # Check Primary Server
    echo -n "Primary Server ($PRIMARY_HOST): "
    if ssh root@$PRIMARY_HOST "systemctl is-active postgresql-13" &>/dev/null; then
        IS_PRIMARY=$(ssh root@$PRIMARY_HOST "sudo -u postgres psql -t -c \"SELECT NOT pg_is_in_recovery();\"" 2>/dev/null | tr -d ' ')
        if [ "$IS_PRIMARY" = "t" ]; then
            echo -e "${GREEN}✓ Running as PRIMARY${NC}"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            echo -e "${YELLOW}⚠ Running as STANDBY (role switched)${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo -e "${RED}✗ PostgreSQL not running${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check Standby Server
    echo -n "Standby Server ($STANDBY_HOST): "
    if ssh root@$STANDBY_HOST "systemctl is-active postgresql-13" &>/dev/null; then
        IS_STANDBY=$(ssh root@$STANDBY_HOST "sudo -u postgres psql -t -c \"SELECT pg_is_in_recovery();\"" 2>/dev/null | tr -d ' ')
        if [ "$IS_STANDBY" = "t" ]; then
            echo -e "${GREEN}✓ Running as STANDBY${NC}"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            echo -e "${YELLOW}⚠ Running as PRIMARY (role switched)${NC}"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        echo -e "${RED}✗ PostgreSQL not running${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check replication status
    echo -n "Replication Status: "
    REP_STATUS=$(ssh root@$PRIMARY_HOST "sudo -u postgres psql -t -c \"SELECT COUNT(*) FROM pg_stat_replication;\"" 2>/dev/null | tr -d ' ') || \
                 $(ssh root@$STANDBY_HOST "sudo -u postgres psql -t -c \"SELECT COUNT(*) FROM pg_stat_replication;\"" 2>/dev/null | tr -d ' ')

    if [ "$REP_STATUS" -gt "0" ] 2>/dev/null; then
        echo -e "${GREEN}✓ Replication active ($REP_STATUS standby connected)${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${RED}✗ No replication detected${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

# 2. Check ProxySQL Service
check_proxysql_service() {
    print_section "2. ProxySQL Service Verification"

    check_status "ProxySQL service status" "systemctl is-active proxysql | grep -q active"
    check_status "ProxySQL process" "pgrep proxysql > /dev/null"
    check_status "Admin port ($PROXYSQL_ADMIN_PORT)" "ss -tlnp | grep -q :$PROXYSQL_ADMIN_PORT"
    check_status "PostgreSQL port ($PROXYSQL_PGSQL_PORT)" "ss -tlnp | grep -q :$PROXYSQL_PGSQL_PORT"

    # Check ProxySQL version
    echo -n "ProxySQL Version: "
    VERSION=$(proxysql --version 2>/dev/null | head -1)
    if [ -n "$VERSION" ]; then
        echo -e "${GREEN}$VERSION${NC}"
    else
        echo -e "${RED}Unable to determine version${NC}"
    fi
}

# 3. Check ProxySQL Configuration
check_proxysql_config() {
    print_section "3. ProxySQL Configuration Verification"

    # Check backend servers
    echo "Backend Servers Configuration:"
    SERVERS=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT COUNT(*) FROM runtime_pgsql_servers;
    " 2>/dev/null | tr -d ' ')

    if [ "$SERVERS" -eq "2" ] 2>/dev/null; then
        echo -e "  ${GREEN}✓ 2 servers configured${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))

        # Show server details
        PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << 'EOF'
        SELECT '  - HG' || hostgroup_id || ': ' || hostname || ':' || port || ' (' || status || ', weight=' || weight || ')'
        FROM runtime_pgsql_servers
        ORDER BY hostgroup_id;
EOF
    else
        echo -e "  ${RED}✗ Expected 2 servers, found $SERVERS${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check users
    echo -n "ProxySQL Users: "
    USERS=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT COUNT(*) FROM runtime_pgsql_users;
    " 2>/dev/null | tr -d ' ')

    if [ "$USERS" -gt "0" ] 2>/dev/null; then
        echo -e "${GREEN}✓ $USERS user(s) configured${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${RED}✗ No users configured${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check query rules
    echo -n "Query Rules: "
    RULES=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT COUNT(*) FROM runtime_pgsql_query_rules WHERE active = 1;
    " 2>/dev/null | tr -d ' ')

    if [ "$RULES" -ge "3" ] 2>/dev/null; then
        echo -e "${GREEN}✓ $RULES active rule(s)${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${YELLOW}⚠ Only $RULES active rule(s) (expected at least 3)${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check replication hostgroups
    echo -n "Replication Hostgroups: "
    REP_HG=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT COUNT(*) FROM pgsql_replication_hostgroups;
    " 2>/dev/null | tr -d ' ')

    if [ "$REP_HG" -ge "1" ] 2>/dev/null; then
        echo -e "${GREEN}✓ Configured${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${RED}✗ Not configured${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

# 4. Check Connectivity
check_connectivity() {
    print_section "4. Connectivity Verification"

    # Admin interface connectivity
    check_status "Admin interface connectivity" \
        "PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -c 'SELECT 1' > /dev/null"

    # Application connectivity through ProxySQL
    check_status "Application connectivity" \
        "PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME -c 'SELECT 1' > /dev/null"

    # Direct connectivity to backends from ProxySQL
    echo -n "Backend connectivity from ProxySQL: "
    BACKEND_OK=0
    BACKEND_FAIL=0

    for host in $PRIMARY_HOST $STANDBY_HOST; do
        if PGPASSWORD=$MONITOR_PASS psql -h $host -p 5432 -U $MONITOR_USER -d postgres -c "SELECT 1" &>/dev/null; then
            BACKEND_OK=$((BACKEND_OK + 1))
        else
            BACKEND_FAIL=$((BACKEND_FAIL + 1))
        fi
    done

    if [ "$BACKEND_OK" -eq "2" ]; then
        echo -e "${GREEN}✓ All backends reachable${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${RED}✗ $BACKEND_FAIL backend(s) unreachable${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

# 5. Check Read/Write Splitting
check_read_write_splitting() {
    print_section "5. Read/Write Splitting Verification"

    # Create test table if not exists
    PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME -c "
        CREATE TABLE IF NOT EXISTS verify_test (
            id serial PRIMARY KEY,
            test_type varchar(20),
            server_addr inet,
            created_at timestamp DEFAULT now()
        );
    " 2>/dev/null

    # Test write operation
    echo -n "Write operations routing: "
    WRITE_SERVER=$(PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME -t -c "
        INSERT INTO verify_test (test_type, server_addr)
        VALUES ('write', inet_server_addr())
        RETURNING server_addr;
    " 2>/dev/null | tr -d ' ')

    if [ -n "$WRITE_SERVER" ]; then
        echo -e "${GREEN}✓ Routed to $WRITE_SERVER${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${RED}✗ Write operation failed${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Test read operations
    echo -n "Read operations routing: "
    READ_SERVERS=""
    for i in {1..5}; do
        SERVER=$(PGPASSWORD=$APP_PASS psql -h 127.0.0.1 -p $PROXYSQL_PGSQL_PORT -U $APP_USER -d $DB_NAME -t -c "
            SELECT inet_server_addr() FROM verify_test LIMIT 1;
        " 2>/dev/null | tr -d ' ')
        READ_SERVERS="$READ_SERVERS $SERVER"
    done

    UNIQUE_SERVERS=$(echo $READ_SERVERS | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo -e "${GREEN}✓ Routed to: $UNIQUE_SERVERS${NC}"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

# 6. Check Performance Metrics
check_performance() {
    print_section "6. Performance Metrics"

    # Get connection pool metrics
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << EOF
    SELECT
        'Total Queries: ' || SUM(Queries) || ' | ' ||
        'Active Connections: ' || SUM(ConnUsed) || ' | ' ||
        'Free Connections: ' || SUM(ConnFree) || ' | ' ||
        'Connection Errors: ' || SUM(ConnERR)
    FROM stats_pgsql_connection_pool;
EOF

    # Check for connection errors
    echo -n "Connection Health: "
    CONN_ERRORS=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT COALESCE(SUM(ConnERR), 0) FROM stats_pgsql_connection_pool;
    " 2>/dev/null | tr -d ' ')

    if [ "$CONN_ERRORS" -eq "0" ] 2>/dev/null; then
        echo -e "${GREEN}✓ No connection errors${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    elif [ "$CONN_ERRORS" -lt "10" ] 2>/dev/null; then
        echo -e "${YELLOW}⚠ $CONN_ERRORS connection error(s)${NC}"
        WARNINGS=$((WARNINGS + 1))
    else
        echo -e "${RED}✗ High error count: $CONN_ERRORS${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Query rule efficiency
    echo "Query Rule Efficiency:"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << 'EOF'
    SELECT
        'Rule ' || rule_id || ': ' ||
        hits || ' hits - ' ||
        CASE rule_id
            WHEN 1 THEN 'SELECTs to standby'
            WHEN 2 THEN 'Writes to primary'
            WHEN 3 THEN 'Transactions to primary'
            ELSE 'Custom rule'
        END
    FROM stats_pgsql_query_rules
    WHERE hits > 0
    ORDER BY rule_id;
EOF
}

# 7. Check Monitoring Configuration
check_monitoring() {
    print_section "7. Monitoring Configuration"

    # Check monitor user connectivity
    echo -n "Monitor user connectivity: "
    MONITOR_OK=true
    for host in $PRIMARY_HOST $STANDBY_HOST; do
        if ! PGPASSWORD=$MONITOR_PASS psql -h $host -p 5432 -U $MONITOR_USER -d postgres -c "SELECT 1" &>/dev/null; then
            MONITOR_OK=false
        fi
    done

    if [ "$MONITOR_OK" = true ]; then
        echo -e "${GREEN}✓ Monitor user can connect to all backends${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "${RED}✗ Monitor user connectivity issues${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check monitoring settings
    echo "Monitoring Settings:"
    PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t 2>/dev/null << 'EOF'
    SELECT
        CASE variable_name
            WHEN 'pgsql-monitor_enabled' THEN 'Monitoring Enabled: '
            WHEN 'pgsql-monitor_connect_interval' THEN 'Connect Interval: '
            WHEN 'pgsql-monitor_ping_interval' THEN 'Ping Interval: '
            WHEN 'pgsql-monitor_username' THEN 'Monitor User: '
        END || variable_value
    FROM global_variables
    WHERE variable_name IN (
        'pgsql-monitor_enabled',
        'pgsql-monitor_connect_interval',
        'pgsql-monitor_ping_interval',
        'pgsql-monitor_username'
    )
    ORDER BY variable_name;
EOF
}

# 8. Security Check
check_security() {
    print_section "8. Security Verification"

    # Check default admin password
    echo -n "Admin password changed: "
    if [ "$PROXYSQL_ADMIN_PASS" = "admin" ]; then
        show_warning "Using default admin password - should be changed in production"
    else
        echo -e "${GREEN}✓ Non-default password${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check SSL/TLS configuration
    echo -n "SSL/TLS Configuration: "
    SSL_ENABLED=$(PGPASSWORD=$PROXYSQL_ADMIN_PASS psql -h 127.0.0.1 -p $PROXYSQL_ADMIN_PORT -U $PROXYSQL_ADMIN_USER -d main -t -c "
        SELECT variable_value FROM global_variables WHERE variable_name = 'pgsql-have_ssl';
    " 2>/dev/null | tr -d ' ')

    if [ "$SSL_ENABLED" = "true" ]; then
        echo -e "${GREEN}✓ SSL enabled${NC}"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        show_warning "SSL not enabled - consider enabling for production"
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    # Check firewall rules
    echo -n "Firewall status: "
    if command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q "$PROXYSQL_PGSQL_PORT"; then
            echo -e "${GREEN}✓ Port $PROXYSQL_PGSQL_PORT open in firewall${NC}"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            show_warning "Port $PROXYSQL_PGSQL_PORT may not be open in firewall"
        fi
    else
        echo -e "${YELLOW}⚠ Firewall not detected${NC}"
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

# Generate summary report
generate_summary() {
    print_section "Verification Summary"

    # Calculate percentage
    if [ $TOTAL_CHECKS -gt 0 ]; then
        SUCCESS_RATE=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    else
        SUCCESS_RATE=0
    fi

    echo "Total Checks: $TOTAL_CHECKS"
    echo -e "Passed: ${GREEN}$PASSED_CHECKS${NC}"
    echo -e "Failed: ${RED}$FAILED_CHECKS${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    echo ""

    # Overall status
    echo -n "Overall Status: "
    if [ $FAILED_CHECKS -eq 0 ]; then
        if [ $WARNINGS -eq 0 ]; then
            echo -e "${GREEN}✓ HEALTHY - All checks passed (${SUCCESS_RATE}%)${NC}"
        else
            echo -e "${YELLOW}⚠ HEALTHY WITH WARNINGS - ${SUCCESS_RATE}% passed, $WARNINGS warning(s)${NC}"
        fi
    elif [ $FAILED_CHECKS -le 2 ]; then
        echo -e "${YELLOW}⚠ DEGRADED - ${SUCCESS_RATE}% passed, $FAILED_CHECKS check(s) failed${NC}"
    else
        echo -e "${RED}✗ UNHEALTHY - ${SUCCESS_RATE}% passed, $FAILED_CHECKS check(s) failed${NC}"
    fi

    echo ""
    echo -e "${CYAN}================================================${NC}"

    # Configuration details
    echo ""
    echo "Configuration Details:"
    echo "  Primary Server: $PRIMARY_HOST:5432"
    echo "  Standby Server: $STANDBY_HOST:5432"
    echo "  ProxySQL Host: $PROXYSQL_HOST"
    echo "  Admin Interface: $PROXYSQL_HOST:$PROXYSQL_ADMIN_PORT"
    echo "  PostgreSQL Interface: $PROXYSQL_HOST:$PROXYSQL_PGSQL_PORT"

    # Recommendations
    if [ $WARNINGS -gt 0 ] || [ $FAILED_CHECKS -gt 0 ]; then
        echo ""
        echo "Recommendations:"
        if [ "$PROXYSQL_ADMIN_PASS" = "admin" ]; then
            echo "  • Change default admin password"
        fi
        if [ "$SSL_ENABLED" != "true" ]; then
            echo "  • Enable SSL for secure connections"
        fi
        if [ $CONN_ERRORS -gt 0 ]; then
            echo "  • Investigate connection errors"
        fi
        if [ $FAILED_CHECKS -gt 0 ]; then
            echo "  • Review and fix failed checks"
        fi
    fi
}

# Export report to file
export_report() {
    local report_file="proxysql_verification_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "ProxySQL Verification Report"
        echo "Generated: $(date)"
        echo "================================================"
        echo ""

        # Run all checks and capture output
        check_postgresql_servers
        check_proxysql_service
        check_proxysql_config
        check_connectivity
        check_read_write_splitting
        check_performance
        check_monitoring
        check_security
        generate_summary

    } > "$report_file" 2>&1

    echo ""
    echo -e "${GREEN}Report exported to: $report_file${NC}"
}

# Main execution
main() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}     ProxySQL PostgreSQL Verification${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo "Starting verification at $(date)"

    # Run all checks
    check_postgresql_servers
    check_proxysql_service
    check_proxysql_config
    check_connectivity
    check_read_write_splitting
    check_performance
    check_monitoring
    check_security

    # Generate summary
    generate_summary

    # Ask if user wants to export report
    echo ""
    read -p "Export detailed report to file? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        export_report
    fi
}

# Run main function
main "$@"
