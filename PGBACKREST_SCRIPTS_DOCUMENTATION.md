# pgBackRest Standby Scripts Documentation

## Overview
This documentation covers two critical scripts for managing PostgreSQL standby servers with pgBackRest backup and recovery capabilities:

1. **pgbackrest_standby_backup_setup.sh** - Configures backups FROM a standby server
2. **pgbackrest_standby_setup.sh** - Creates a NEW standby server from backup snapshots

---

## Script 1: pgbackrest_standby_backup_setup.sh

### Purpose
This script sets up pgBackRest backups to run from a standby server instead of the primary, reducing load on the primary database. It also creates EBS snapshots for disaster recovery.

### Key Features
- Configures pgBackRest on standby servers to take backups
- Sets up multi-repository support for multiple standbys
- Creates and manages EBS volumes for backup storage
- Automates EBS snapshot creation for point-in-time recovery
- Configures WAL archiving from primary to standby

### Prerequisites
- PostgreSQL standby server already running
- repmgr configured for replication management
- AWS CLI configured with appropriate permissions
- SSH access between postgres users on primary and standby

### What the Script Does

#### 1. **Server Detection and Validation**
```bash
get_current_server_ip()
```
- Automatically detects the current server's IP address
- Validates that the script is running on the intended standby server
- Prevents accidental execution on wrong servers

#### 2. **Multi-Repository Configuration**
```bash
determine_repository_number()
```
- Checks existing repositories on the primary
- Assigns unique repository numbers (repo1, repo2, repo3, etc.)
- Prevents conflicts when multiple standbys take backups

#### 3. **EBS Volume Management**
- Creates a new 200GB EBS volume for backup storage
- Attaches volume to the standby instance
- Formats as ext4 filesystem
- Mounts at `/backup/pgbackrest`
- Adds to `/etc/fstab` for persistent mounting

#### 4. **pgBackRest Installation and Configuration**
- Installs pgBackRest if not present
- Creates configuration file at `/etc/pgbackrest/pgbackrest.conf`
- Sets up:
  - Compression (zstd level 3)
  - Retention policies (4 full, 3 differential, 10 archives)
  - Parallel processing (12 processes)
  - Delta restore support

#### 5. **Primary Server Configuration**
- Connects to primary via SSH
- Adds new repository to primary's pgBackRest config
- Updates PostgreSQL `archive_command` to push WALs to standby
- Creates replication slot for standby (if needed)

#### 6. **Stanza Creation and Backup**
- Creates pgBackRest stanza
- Performs initial full backup from standby
- Verifies backup integrity
- Performs incremental backup

#### 7. **EBS Snapshot Creation**
- Creates snapshot of backup volume
- Tags snapshot with metadata
- Configures automated snapshots via cron (optional)

#### 8. **State Management**
Creates state file: `pgbackrest_standby_backup_state.env`
```bash
PRIMARY_IP=10.40.0.24
STANDBY_IP=10.40.0.17
BACKUP_VOLUME_CONFIGURED=true
STANDBY_REPO_NUMBER=1
PGBACKREST_CONFIGURED=true
INITIAL_BACKUP_COMPLETED=true
LAST_BACKUP_TYPE=incr
LAST_BACKUP_DATE="2025-09-16 16:02:52"
BACKUP_FROM_STANDBY=true
BACKUP_VOLUME_ID=vol-00d3a4960ff4cfc8d
LATEST_SNAPSHOT_ID=snap-07100add756c1533e
LAST_SNAPSHOT_DATE="2025-09-16 16:02:55"
SNAPSHOT_AVAILABLE=true
PERIODIC_SNAPSHOTS_CONFIGURED=true
```

### Usage Examples

#### Basic Usage
```bash
./pgbackrest_standby_backup_setup.sh
```

#### With Custom Configuration
```bash
PRIMARY_IP=10.40.0.24 \
STANDBY_IP=10.40.0.27 \
BACKUP_VOLUME_SIZE=500 \
./pgbackrest_standby_backup_setup.sh
```

#### Resume After Interruption
```bash
./pgbackrest_standby_backup_setup.sh --resume
```

### Error Handling
- Validates each step before proceeding
- Saves state after each major step
- Can resume from last successful step
- Provides detailed error messages
- Rolls back on critical failures

---

## Script 2: pgbackrest_standby_setup.sh

### Purpose
This script creates a new PostgreSQL standby server by restoring from pgBackRest backups stored in EBS snapshots. It automates the entire process of building a replica from a backup.

### Key Features
- Creates new EBS volume from backup snapshot
- Restores PostgreSQL data using pgBackRest
- Configures streaming replication
- Registers with repmgr cluster
- Handles both full and incremental restores

### Prerequisites
- Target server with PostgreSQL installed (but not initialized)
- Backup snapshot created by pgbackrest_standby_backup_setup.sh
- Network connectivity to primary server
- AWS credentials with EC2 and EBS permissions

### What the Script Does

#### 1. **Configuration Loading**
- Loads state from backup setup (if provided)
- Accepts parameters:
  - `--state-file` - Path to backup state file
  - `--snapshot-id` - Specific snapshot to use
  - `--list-snapshots` - Show available snapshots

#### 2. **Snapshot Discovery**
```bash
find_latest_snapshot()
```
- Finds snapshots by volume ID or tags
- Verifies snapshot is in 'completed' state
- Selects most recent snapshot by default

#### 3. **Volume Creation and Attachment**
```bash
create_new_volume()
attach_volume_to_new_server()
```
- Creates new EBS volume from snapshot
- Attaches to target instance as `/dev/xvdb`
- Waits for volume to be available
- Handles device naming variations

#### 4. **Filesystem Setup**
```bash
mount_backup_volume()
```
- Creates mount point at `/backup/pgbackrest`
- Mounts restored volume
- Adds to `/etc/fstab` for persistence
- Sets proper ownership (postgres:postgres)

#### 5. **pgBackRest Installation**
```bash
install_pgbackrest_new_server()
```
- Installs pgBackRest package
- Creates configuration directory
- Sets up logging paths

#### 6. **pgBackRest Configuration**
```bash
configure_pgbackrest_new_server()
```
- Creates `/etc/pgbackrest/pgbackrest.conf`
- Points to restored backup repository
- Configures restore parameters
- Sets up archive retrieval

#### 7. **Database Restoration**
```bash
restore_database_new_server()
```
- Stops PostgreSQL if running
- Clears existing data directory
- Performs pgBackRest restore with `--type=standby`
- Creates `standby.signal` file
- Restores as standby in recovery mode

#### 8. **Replication Configuration**
```bash
configure_replication_new_server()
```
Updates `postgresql.auto.conf`:
```bash
primary_conninfo = 'host=10.40.0.24 port=5432 user=repmgr application_name=standby'
primary_slot_name = 'standby_27'
restore_command = 'pgbackrest --stanza=txn_cluster archive-get %f "%p"'
archive_cleanup_command = 'pgbackrest --stanza=txn_cluster archive-cleanup %r'
```

#### 9. **repmgr Registration**
```bash
register_with_repmgr()
```
- Creates repmgr.conf
- Registers node with cluster
- Verifies cluster membership

#### 10. **Service Startup**
```bash
start_postgresql_service()
```
- Starts PostgreSQL service
- Verifies streaming replication
- Checks recovery status
- Confirms WAL receiving

### State File Management
Creates/updates: `pgbackrest_standby_state.env`
```bash
NEW_VOLUME_ID=vol-0cea9411f7f3e8af6
LATEST_SNAPSHOT_ID=snap-07100add756c1533e
NEW_INSTANCE_ID=i-09b6a3782d4866085
VOLUME_ATTACHED=true
BACKUP_MOUNT_READY=true
PGBACKREST_INSTALLED=true
PGBACKREST_CONFIGURED=true
POSTGRESQL_RESTORED=true
REPLICATION_CONFIGURED=true
SERVICE_STARTED=true
REPMGR_REGISTERED=true
```

### Usage Examples

#### Using State File from Backup Setup
```bash
./pgbackrest_standby_setup.sh --state-file /opt/setup_new_standby/pgbackrest_standby_backup_state.env
```

#### Using Specific Snapshot
```bash
./pgbackrest_standby_setup.sh --snapshot-id snap-07100add756c1533e
```

#### List Available Snapshots
```bash
./pgbackrest_standby_setup.sh --list-snapshots
```

#### With Custom Configuration
```bash
PRIMARY_IP=10.40.0.24 \
NEW_STANDBY_IP=10.40.0.27 \
EXISTING_STANDBY_IP=10.40.0.17 \
./pgbackrest_standby_setup.sh --snapshot-id snap-07100add756c1533e
```

### Verification Steps
The script performs these checks:
1. Verifies snapshot exists and is complete
2. Confirms volume attachment
3. Validates backup data integrity
4. Checks PostgreSQL starts in recovery mode
5. Verifies streaming replication is active
6. Confirms repmgr cluster membership

### Error Recovery
- Can resume from last successful step
- Handles partial configurations
- Cleans up on failure
- Provides detailed error logs

---

## Workflow: Complete Standby Setup Process

### Step 1: Initial Standby Setup (Manual or Automated)
Create initial standby using PostgreSQL streaming replication or pg_basebackup

### Step 2: Configure Backups on Standby
```bash
# On standby server (e.g., 10.40.0.17)
./pgbackrest_standby_backup_setup.sh
```
This:
- Sets up backup infrastructure
- Takes initial backup
- Creates EBS snapshot
- Configures scheduled backups

### Step 3: Create New Standby from Snapshot
```bash
# On new server (e.g., 10.40.0.27)
./pgbackrest_standby_setup.sh --state-file pgbackrest_standby_backup_state.env
```
This:
- Restores from snapshot
- Configures replication
- Joins repmgr cluster

### Step 4: Verify Cluster Status
```bash
repmgr cluster show
```
Expected output:
```
ID | Name     | Role    | Status    | Upstream | Location | Priority | Timeline
---+----------+---------+-----------+----------+----------+----------+---------
1  | primary  | primary | * running |          | default  | 100      | 1
2  | standby  | standby |   running | primary  | default  | 100      | 1
3  | standby3 | standby |   running | primary  | default  | 100      | 1
```

---

## Troubleshooting Guide

### Common Issues and Solutions

#### 1. SSH Connection Failures
**Problem**: Cannot SSH to primary from standby
**Solution**:
```bash
# Set up SSH keys between postgres users
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
ssh-copy-id postgres@primary_ip
```

#### 2. Permission Denied on Log Files
**Problem**: tee: Permission denied errors
**Solution**: Run as root or modify script to use /tmp for logs

#### 3. WAL Archive Timeout
**Problem**: WAL segment not archived before timeout
**Solution**:
- Check network connectivity
- Verify archive_command on primary
- Ensure all repositories are accessible

#### 4. Stanza Already Exists
**Problem**: pgBackRest stanza creation fails
**Solution**:
```bash
pgbackrest --stanza=txn_cluster stanza-upgrade
```

#### 5. Snapshot Not Found
**Problem**: AWS cannot find snapshot
**Solution**:
- Verify AWS credentials
- Check correct region
- Ensure snapshot ID is valid

#### 6. Replication Slot Issues
**Problem**: Replication slot does not exist
**Solution**:
```bash
# On primary
psql -c "SELECT pg_create_physical_replication_slot('slot_name');"
```

#### 7. Application Name Mismatch
**Problem**: repmgr shows standby not attached
**Solution**: Update application_name in postgresql.auto.conf to match repmgr node name

---

## Best Practices

### Security
1. Use encrypted EBS volumes
2. Restrict SSH access with keys only
3. Implement AWS IAM roles with minimal permissions
4. Secure pgBackRest repository with proper permissions

### Performance
1. Schedule backups during low-traffic periods
2. Use compression to reduce storage costs
3. Implement parallel processing for faster backups
4. Monitor backup duration and adjust process-max

### Reliability
1. Test restore procedures regularly
2. Verify backups with pgbackrest verify
3. Monitor replication lag
4. Set up alerts for backup failures

### Maintenance
1. Rotate snapshots based on retention policy
2. Monitor EBS volume usage
3. Clean up old WAL archives
4. Update scripts with infrastructure changes

---

## Configuration Parameters

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| PRIMARY_IP | Primary server IP address | 10.40.0.24 |
| STANDBY_IP | Standby server IP address | Auto-detected |
| BACKUP_VOLUME_SIZE | EBS volume size in GB | 200 |
| STANZA_NAME | pgBackRest stanza name | txn_cluster |
| PG_VERSION | PostgreSQL version | 13 |
| AWS_REGION | AWS region | ap-northeast-1 |
| REPO_PATH | Repository base path | /backup/pgbackrest/repo |
| RETENTION_FULL | Full backup retention | 4 |
| RETENTION_DIFF | Differential retention | 3 |
| RETENTION_ARCHIVE | Archive retention days | 10 |

### File Locations

| File | Purpose |
|------|---------|
| /etc/pgbackrest/pgbackrest.conf | pgBackRest configuration |
| /backup/pgbackrest/repo | Backup repository |
| /backup/pgbackrest/logs | pgBackRest logs |
| /var/lib/pgsql/repmgr.conf | repmgr configuration |
| /opt/setup_new_standby/*.env | State files |

---

## Monitoring and Validation

### Check Backup Status
```bash
pgbackrest --stanza=txn_cluster info
```

### Verify Latest Backup
```bash
pgbackrest --stanza=txn_cluster verify
```

### Monitor Replication Lag
```bash
psql -c "SELECT pg_last_wal_receive_lsn() - pg_last_wal_replay_lsn() AS lag;"
```

### View Snapshot Details
```bash
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[*].[SnapshotId,StartTime,State]'
```

### Check Repository Size
```bash
du -sh /backup/pgbackrest/repo/
```

---

## Recovery Scenarios

### Scenario 1: Primary Failure
1. Promote standby using repmgr
2. Reconfigure backups on new primary
3. Update application connection strings

### Scenario 2: Standby Failure
1. Use pgbackrest_standby_setup.sh to rebuild
2. Or create new standby from latest snapshot
3. Re-register with repmgr

### Scenario 3: Point-in-Time Recovery
1. Restore from pgBackRest to specific time
2. Configure as standalone or new primary
3. Rebuild standbys from new primary

### Scenario 4: Disaster Recovery
1. Launch new instances in DR region
2. Restore from replicated snapshots
3. Reconfigure replication topology

---

## Version History

### Current Version Features
- Multi-repository support for multiple standbys
- Automatic IP detection
- SSH connectivity fixes
- State management and resume capability
- EBS snapshot automation
- repmgr integration

### Known Limitations
- Requires root or sudo access for some operations
- Scripts must run on target servers (not remote)
- AWS credentials must be configured
- Maximum 4 repositories per primary

---

## Support and Maintenance

### Log Locations
- Script logs: `/opt/setup_new_standby/pgbackrest_*.log`
- pgBackRest logs: `/backup/pgbackrest/logs/`
- PostgreSQL logs: `/var/lib/pgsql/13/data/log/`
- System logs: `/var/log/messages`

### Getting Help
1. Check script output for error messages
2. Review log files for detailed errors
3. Verify prerequisites are met
4. Test individual components separately
5. Consult pgBackRest documentation

### Regular Maintenance Tasks
- Weekly: Verify backups
- Monthly: Test restore procedure
- Quarterly: Review retention policies
- Annually: Update documentation

---

This documentation provides a comprehensive guide for using both scripts to implement a robust PostgreSQL backup and standby management system using pgBackRest and AWS EBS snapshots.
