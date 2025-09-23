# ProxySQL Complete Deployment and Management Guide

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Initial Setup Script](#initial-setup-script)
4. [Verification Script](#verification-script)
5. [Monitoring Script](#monitoring-script)
6. [Adding Backend Servers Script](#adding-backend-servers-script)
7. [Connection Pooling Configuration](#connection-pooling-configuration)
8. [Operational Procedures](#operational-procedures)
9. [Troubleshooting](#troubleshooting)
10. [Best Practices](#best-practices)

---

## Overview

ProxySQL is a high-performance SQL proxy that provides:
- **Connection Pooling**: Reduce database connection overhead
- **Load Balancing**: Distribute reads across multiple replicas
- **Query Routing**: Route reads/writes to appropriate servers
- **High Availability**: Automatic failover handling
- **Query Caching**: Cache frequently accessed data

### Environment Details
- **ProxySQL Version**: 3.0.2
- **PostgreSQL Version**: 13.x
- **Replication**: repmgr-based streaming replication
- **Operating System**: Amazon Linux 2023/RHEL/CentOS

### Current Infrastructure
```
ProxySQL Server: 10.40.0.17 (Port 6133 for app, 6132 for admin)
    |
    ├── Primary PostgreSQL: 10.40.0.24 (Hostgroup 1 - Writes)
    ├── Standby PostgreSQL: 10.40.0.27 (Hostgroup 2 - Reads)
    └── Local PostgreSQL:   10.40.0.17 (Hostgroup 2 - Reads)
```

---

## Architecture

### Connection Flow
```
Application (800-900 connections)
         ↓
ProxySQL (Connection Pooling)
         ↓
Backend PostgreSQL (500 max connections)
```

### Hostgroup Configuration
- **Hostgroup 1**: Write operations (Primary server)
- **Hostgroup 2**: Read operations (Standby servers)

---

## Initial Setup Script

### Script: `setup_proxysql_postgresql.sh`

**Purpose**: Complete installation and initial configuration of ProxySQL for PostgreSQL

**Location**: `/opt/test-ansible/setup_proxysql_postgresql.sh`

**Features**:
- Installs ProxySQL 3.0.2
- Configures PostgreSQL backend servers
- Sets up users and authentication
- Creates query routing rules
- Implements connection pooling
- Configures monitoring

**Usage**:
```bash
chmod +x /opt/test-ansible/setup_proxysql_postgresql.sh
./setup_proxysql_postgresql.sh
```

**Key Configuration Steps**:

1. **Install ProxySQL**
   - Downloads and installs ProxySQL 3.0.2
   - Configures systemd service
   - Sets up logging directories

2. **Configure Backend Servers**
   ```sql
   -- Primary server for writes
   INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight)
   VALUES (1, '10.40.0.24', 5432, 1000);

   -- Standby servers for reads
   INSERT INTO pgsql_servers (hostgroup_id, hostname, port, weight)
   VALUES (2, '10.40.0.27', 5432, 1000);
   ```

3. **Create Users**
   ```sql
   -- Application user
   INSERT INTO pgsql_users (username, password, active, default_hostgroup, max_connections)
   VALUES ('app_user', 'app_password_123', 1, 2, 1000);

   -- Monitoring user
   UPDATE global_variables SET variable_value = 'proxysql_monitor'
   WHERE variable_name = 'pgsql-monitor_username';
   ```

4. **Setup Query Rules**
   ```sql
   -- Route writes to primary
   INSERT INTO pgsql_query_rules (rule_id, match_pattern, destination_hostgroup)
   VALUES (1, '^(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)', 1);

   -- Route reads to standbys
   INSERT INTO pgsql_query_rules (rule_id, match_pattern, destination_hostgroup)
   VALUES (2, '^SELECT', 2);
   ```

**Expected Output**:
```
[INFO] Installing ProxySQL 3.0.2...
[SUCCESS] ProxySQL installed successfully
[INFO] Configuring PostgreSQL backends...
[SUCCESS] Backend servers configured
[INFO] Setting up query routing rules...
[SUCCESS] Query rules configured
[INFO] ProxySQL is ready at 127.0.0.1:6133
```

---

## Verification Script

### Script: `verify_proxysql.sh`

**Purpose**: Comprehensive health check and validation of ProxySQL setup

**Location**: `/opt/test-ansible/verify_proxysql.sh`

**Features**:
- Checks ProxySQL service status
- Validates backend server connectivity
- Tests query routing
- Verifies connection pooling
- Checks user authentication
- Validates monitoring setup

**Usage**:
```bash
chmod +x /opt/test-ansible/verify_proxysql.sh
./verify_proxysql.sh
```

**Verification Steps**:

1. **Service Status Check**
   - ProxySQL process running
   - Listening on ports 6132 (admin) and 6133 (app)

2. **Backend Server Health**
   - All servers ONLINE status
   - Connectivity to each PostgreSQL instance
   - Replication lag check

3. **Query Routing Test**
   - Writes go to primary (10.40.0.24)
   - Reads distributed across standbys

4. **Connection Pool Status**
   - Active connections
   - Connection errors
   - Pool efficiency

**Sample Output**:
```
=================================
ProxySQL Verification Report
=================================
[✓] ProxySQL Service: Running
[✓] Admin Interface: Accessible (127.0.0.1:6132)
[✓] App Interface: Accessible (127.0.0.1:6133)

Backend Servers Status:
[✓] Primary (10.40.0.24): ONLINE - 0 errors
[✓] Standby (10.40.0.27): ONLINE - 0 errors
[✓] Standby (10.40.0.17): ONLINE - 0 errors

Query Routing:
[✓] Write queries → Primary (10.40.0.24)
[✓] Read queries → Load balanced across standbys

Connection Pool:
- Total Connections: 3
- Used: 0
- Free: 3
- Errors: 0

Overall Status: HEALTHY
```

---

## Monitoring Script

### Script: `monitor_proxysql.sh`

**Purpose**: Real-time monitoring of ProxySQL performance and health

**Location**: `/opt/test-ansible/monitor_proxysql.sh`

**Features**:
- Live connection statistics
- Query performance metrics
- Server load distribution
- Error tracking
- Connection pool efficiency
- Automatic alerting for issues

**Usage**:
```bash
chmod +x /opt/test-ansible/monitor_proxysql.sh
./monitor_proxysql.sh              # One-time check
./monitor_proxysql.sh --continuous # Continuous monitoring
./monitor_proxysql.sh --interval 5 # Custom interval (seconds)
```

**Monitoring Metrics**:

1. **Connection Metrics**
   - Active connections per server
   - Connection pool utilization
   - Failed connection attempts

2. **Query Metrics**
   - Queries per second
   - Query distribution across servers
   - Query response times

3. **Server Metrics**
   - Server status (ONLINE/OFFLINE)
   - Data sent/received
   - Latency measurements

4. **Load Distribution**
   - Read/write ratio
   - Server weight effectiveness
   - Query routing accuracy

**Sample Output**:
```
========================================
ProxySQL Monitoring - 2025-01-19 10:30:45
========================================

CONNECTION POOL STATUS:
┌─────────────┬────────┬──────────┬──────────┬────────┬─────────┐
│ Server      │ HG     │ Status   │ ConnUsed │ ConnFree│ Queries │
├─────────────┼────────┼──────────┼──────────┼────────┼─────────┤
│ 10.40.0.24  │ 1      │ ONLINE   │ 2        │ 8      │ 1250    │
│ 10.40.0.27  │ 2      │ ONLINE   │ 5        │ 15     │ 3420    │
│ 10.40.0.17  │ 2      │ ONLINE   │ 3        │ 17     │ 2180    │
└─────────────┴────────┴──────────┴──────────┴────────┴─────────┘

QUERY DISTRIBUTION (Last 60 seconds):
- Writes (HG1): 125 queries → 10.40.0.24 (100%)
- Reads (HG2):  564 queries → Load balanced
  • 10.40.0.27: 312 queries (55.3%)
  • 10.40.0.17: 252 queries (44.7%)

PERFORMANCE METRICS:
- Avg Query Time: 1.2ms
- Connection Pool Hit Rate: 98.5%
- Error Rate: 0.01%

ALERTS: None
```

---

## Adding Backend Servers Script

### Script: `add_postgresql_to_proxysql.sh`

**Purpose**: Add new PostgreSQL servers as backend to ProxySQL

**Location**: `/opt/test-ansible/add_postgresql_to_proxysql.sh`

**Features**:
- Add servers to specific hostgroups
- Configure weight and connection limits
- Test connectivity before adding
- Verify load balancing after addition
- Update or replace existing configurations

**Usage**:
```bash
chmod +x /opt/test-ansible/add_postgresql_to_proxysql.sh

# Add read replica with defaults
./add_postgresql_to_proxysql.sh 10.40.0.17 2

# Add with custom weight and connections
./add_postgresql_to_proxysql.sh 10.40.0.18 2 1500 300

# Add primary server
./add_postgresql_to_proxysql.sh 10.40.0.20 1 1000 500
```

**Parameters**:
- `server_ip`: IP address of PostgreSQL server
- `hostgroup`: 1 for primary (writes), 2 for standby (reads)
- `weight`: Load balancing weight (default: 1000)
- `max_connections`: Maximum connections (default: 200)

**Process Flow**:

1. **Pre-checks**
   - Validate parameters
   - Check if server already exists
   - Test PostgreSQL connectivity

2. **Configuration**
   ```sql
   INSERT INTO pgsql_servers (
       hostgroup_id, hostname, port, weight,
       status, max_connections, comment
   ) VALUES (
       2, '10.40.0.17', 5432, 1000,
       'ONLINE', 200, 'Standby PostgreSQL server'
   );
   ```

3. **Activation**
   ```sql
   LOAD PGSQL SERVERS TO RUNTIME;
   SAVE PGSQL SERVERS TO DISK;
   ```

4. **Verification**
   - Check server appears in runtime configuration
   - Test query routing to new server
   - Verify load distribution

**Expected Output**:
```
[INFO] Adding PostgreSQL server 10.40.0.17 to ProxySQL
Configuration:
  - Server: 10.40.0.17:5432
  - Hostgroup: 2
  - Weight: 1000
  - Max Connections: 200

[INFO] Testing connectivity to PostgreSQL server...
[INFO] Successfully connected to PostgreSQL server
[INFO] Adding server to ProxySQL...
[INFO] Loading configuration to runtime...
[INFO] Saving configuration to disk...
[INFO] Verifying server configuration...

Testing read query routing to new server...
  Query 1 routed to NEW server: 10.40.0.17
  Query 2 routed to: 10.40.0.27
  Query 3 routed to NEW server: 10.40.0.17

[INFO] Successfully added PostgreSQL server 10.40.0.17
```

---

## Connection Pooling Configuration

### Script: `configure_proxysql_connection_pooling.sh`

**Purpose**: Advanced connection pooling optimization

**Location**: `/opt/test-ansible/configure_proxysql_connection_pooling.sh`

**Features**:
- Configure pool size limits
- Set up multiplexing
- Optimize connection reuse
- Configure idle timeouts
- Set transaction pooling modes

**Key Configurations**:

```sql
-- Global connection limits
UPDATE global_variables SET variable_value = '1000'
WHERE variable_name = 'pgsql-max_connections';

-- Enable multiplexing
UPDATE global_variables SET variable_value = 'true'
WHERE variable_name = 'pgsql-multiplexing';

-- Connection timeout
UPDATE global_variables SET variable_value = '10000'
WHERE variable_name = 'pgsql-connect_timeout_server';

-- Idle connection timeout
UPDATE global_variables SET variable_value = '60000'
WHERE variable_name = 'pgsql-connection_max_age_ms';

-- Per-server limits
UPDATE pgsql_servers SET max_connections = 500
WHERE hostname = '10.40.0.24' AND hostgroup_id = 1;
```

---

## Operational Procedures

### Daily Operations

#### 1. Morning Health Check
```bash
# Run comprehensive verification
./verify_proxysql.sh

# Check overnight query statistics
./monitor_proxysql.sh --report daily
```

#### 2. Adding New Application Users
```sql
-- Connect to ProxySQL admin
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main

-- Add new user
INSERT INTO pgsql_users (username, password, active, default_hostgroup, max_connections)
VALUES ('new_app_user', 'secure_password', 1, 2, 500);

-- Apply changes
LOAD PGSQL USERS TO RUNTIME;
SAVE PGSQL USERS TO DISK;
```

#### 3. Adjusting Load Distribution
```sql
-- Increase weight for better performing server
UPDATE pgsql_servers SET weight = 1500
WHERE hostname = '10.40.0.27' AND hostgroup_id = 2;

-- Apply changes
LOAD PGSQL SERVERS TO RUNTIME;
```

### Maintenance Procedures

#### 1. Planned PostgreSQL Maintenance
```bash
# Step 1: Set server to OFFLINE_SOFT (graceful)
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
UPDATE pgsql_servers SET status = 'OFFLINE_SOFT'
WHERE hostname = '10.40.0.27';
LOAD PGSQL SERVERS TO RUNTIME;"

# Step 2: Wait for active connections to complete
./monitor_proxysql.sh --server 10.40.0.27 --wait-drain

# Step 3: Perform PostgreSQL maintenance
# ... maintenance tasks ...

# Step 4: Bring server back online
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
UPDATE pgsql_servers SET status = 'ONLINE'
WHERE hostname = '10.40.0.27';
LOAD PGSQL SERVERS TO RUNTIME;"
```

#### 2. ProxySQL Configuration Backup
```bash
# Backup current configuration
PGPASSWORD=admin pg_dump -h 127.0.0.1 -p 6132 -U admin main > \
    /backup/proxysql_config_$(date +%Y%m%d_%H%M%S).sql

# Restore configuration
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin main < \
    /backup/proxysql_config_20250119_103045.sql
```

### Emergency Procedures

#### 1. Server Failure Response
```bash
# Automatic handling by ProxySQL
# Manual intervention if needed:

# Check server status
./monitor_proxysql.sh --alert-check

# Remove failed server
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
UPDATE pgsql_servers SET status = 'OFFLINE_HARD'
WHERE hostname = 'FAILED_SERVER_IP';
LOAD PGSQL SERVERS TO RUNTIME;"
```

#### 2. Connection Pool Exhaustion
```bash
# Increase connection limits temporarily
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
UPDATE global_variables SET variable_value = '1500'
WHERE variable_name = 'pgsql-max_connections';
LOAD PGSQL VARIABLES TO RUNTIME;"

# Identify connection consumers
./monitor_proxysql.sh --top-connections
```

---

## Troubleshooting

### Common Issues and Solutions

#### Issue 1: High Connection Errors
**Symptoms**: Connection pool showing errors
**Solution**:
```bash
# Check PostgreSQL server status
ssh 10.40.0.24 "systemctl status postgresql-13"

# Verify max_connections on PostgreSQL
ssh 10.40.0.24 "psql -c 'SHOW max_connections;'"

# Adjust ProxySQL limits
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
UPDATE pgsql_servers SET max_connections = 400
WHERE hostname = '10.40.0.24';
LOAD PGSQL SERVERS TO RUNTIME;"
```

#### Issue 2: Uneven Load Distribution
**Symptoms**: One server handling most queries
**Solution**:
```bash
# Check current weights
./monitor_proxysql.sh --load-distribution

# Adjust weights
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
UPDATE pgsql_servers SET weight = 2000
WHERE hostname = 'UNDERUTILIZED_SERVER';
LOAD PGSQL SERVERS TO RUNTIME;"

# Force connection redistribution
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
PROXYSQL FLUSH PGSQL_CONNECTION_POOL;"
```

#### Issue 3: Slow Query Performance
**Symptoms**: Increased query latency
**Solution**:
```bash
# Check query rules
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT * FROM stats_pgsql_query_rules ORDER BY hits DESC LIMIT 10;"

# Monitor slow queries
./monitor_proxysql.sh --slow-queries --threshold 1000

# Enable query caching for frequent reads
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
INSERT INTO pgsql_query_rules (
    rule_id, match_pattern, cache_ttl, destination_hostgroup
) VALUES (
    100, '^SELECT .* FROM frequent_table', 60000, 2
);
LOAD PGSQL QUERY RULES TO RUNTIME;"
```

### Diagnostic Commands

```bash
# Check ProxySQL logs
tail -f /var/log/proxysql/proxysql.log

# Monitor connections in real-time
watch -n 1 "PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c \
'SELECT hostgroup, srv_host, status, ConnUsed, ConnFree, Queries \
FROM stats_pgsql_connection_pool ORDER BY hostgroup, srv_host;'"

# Check memory usage
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT * FROM stats_memory_metrics;"

# View current configuration
PGPASSWORD=admin psql -h 127.0.0.1 -p 6132 -U admin -d main -c "
SELECT * FROM runtime_global_variables
WHERE variable_name LIKE 'pgsql%'
ORDER BY variable_name;"
```

---

## Best Practices

### 1. Configuration Management
- Always test changes on a single server first
- Use OFFLINE_SOFT for graceful maintenance
- Keep configuration backups before major changes
- Document all custom query rules

### 2. Monitoring
- Set up automated monitoring alerts
- Track connection pool efficiency (aim for >95% hit rate)
- Monitor query distribution patterns
- Watch for connection errors

### 3. Security
- Use strong passwords for all users
- Limit admin interface access (bind to localhost)
- Regularly rotate passwords
- Enable SSL/TLS for client connections

### 4. Performance
- Size connection pools appropriately (not too large)
- Enable multiplexing for better connection reuse
- Use query caching for frequently accessed data
- Balance load based on server capacity

### 5. High Availability
- Configure multiple ProxySQL instances
- Use automatic failover for backend servers
- Test disaster recovery procedures
- Keep ProxySQL version updated

---

## Script Execution Order

For a complete ProxySQL deployment, execute scripts in this order:

1. **Initial Setup**
   ```bash
   ./setup_proxysql_postgresql.sh
   ```

2. **Configure Connection Pooling**
   ```bash
   ./configure_proxysql_connection_pooling.sh
   ```

3. **Verify Installation**
   ```bash
   ./verify_proxysql.sh
   ```

4. **Add Additional Servers** (if needed)
   ```bash
   ./add_postgresql_to_proxysql.sh 10.40.0.17 2
   ```

5. **Start Monitoring**
   ```bash
   ./monitor_proxysql.sh --continuous
   ```

---

## Summary

This guide provides complete documentation for:
- Installing and configuring ProxySQL for PostgreSQL
- Verifying the setup is working correctly
- Monitoring performance and health
- Adding new backend servers dynamically
- Optimizing connection pooling
- Troubleshooting common issues
- Following operational best practices

All scripts are located in `/opt/test-ansible/` and are designed to work together for a complete ProxySQL deployment and management solution.

---

*Document Version: 2.0*
*ProxySQL Version: 3.0.2*
*PostgreSQL Version: 13.x*
