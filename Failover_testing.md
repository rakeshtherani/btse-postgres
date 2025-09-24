# Repmgr Switchover Checklist

## BEFORE SWITCHOVER

### 1. Check cluster health
```bash
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf cluster show
```
- Ensure all nodes show "running" status
- Note current primary and standby nodes

### 2. Check replication slots on current primary
```bash
sudo -u postgres psql -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;"
```
- Note slot names for each standby

### 3. Verify repmgrd is running on all nodes (if using automatic failover)
```bash
systemctl status repmgrd
```

## EXECUTE SWITCHOVER

### 4. Run switchover command from the standby that will become primary
```bash
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf standby switchover --siblings-follow
```

## AFTER SWITCHOVER

### 5. Immediately check cluster status
```bash
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf cluster show
```

### 6. Create missing replication slots on new primary
```bash
# On new primary, for each standby:
sudo -u postgres psql -c "SELECT pg_create_physical_replication_slot('slot_name_here');"
```

### 7. For standbys not following new primary
```bash
# On problematic standby:
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf standby follow --upstream-node-id=NEW_PRIMARY_ID

# If that fails, use pg_rewind:
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf node rejoin -d 'host=NEW_PRIMARY_IP user=repmgr dbname=repmgr' --force-rewind
```

### 8. Re-register nodes if metadata is incorrect
```bash
# On new primary:
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf primary register --force

# On each standby:
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf standby register --force
```

### 9. Final verification
```bash
# Check from new primary:
sudo -u postgres /usr/local/pgsql/bin/repmgr -f /var/lib/pgsql/repmgr.conf cluster show

# Verify replication:
sudo -u postgres psql -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

## COMMON ISSUES

- **"standby not found in pg_stat_replication"** - Missing replication slot on new primary
- **"reports different upstream"** - Standby needs to be repointed with `standby follow`
- **"wrong timeline"** - Standby needs rejoin with `--force-rewind`
- **Metadata mismatch** - Re-register nodes with `--force`

## Connection Test Analysis

Based on your connection test output:

```bash
[root@txn-testing-0002-slave repmgr]# psql -h 127.0.0.1 -p 6133 -U app_user --password txn
Password:
psql (13.9, server 13.0)
Type "help" for help.

txn=> select inet_server_addr();
 inet_server_addr
------------------
 10.40.0.27        -- First connection (standby)
(1 row)

txn=> select inet_server_addr();
 inet_server_addr
------------------
 10.40.0.24        -- Second connection (primary)
(1 row)
```

This shows that your connection is **switching between servers**, which indicates:

1. **Load balancer or connection pooler** is distributing connections on port 6133
2. **HAProxy/pgpool** is routing traffic between nodes (10.40.0.27 and 10.40.0.24)
3. **Round-robin or health-based routing** is occurring

### Key Observations:
- **Port 6133**: Not standard PostgreSQL port (5432) - indicates load balancer/proxy
- **Connection switching**: Each query hits a different server
- **Servers involved**: 10.40.0.27 (standby) and 10.40.0.24 (primary)

### Before Switchover - Identify Current Primary:
```bash
# Connect directly to each server to identify roles:
psql -h 10.40.0.24 -p 5432 -U postgres -c "SELECT pg_is_in_recovery();"
psql -h 10.40.0.27 -p 5432 -U postgres -c "SELECT pg_is_in_recovery();"

# False = Primary, True = Standby
```

**Keep this checklist handy for future switchovers!**
