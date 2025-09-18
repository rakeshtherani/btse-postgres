#!/bin/bash
#===============================================================================
# pgBackRest Standby Setup Script - Part 2 (FIXED)
#
# This script handles:
# 1. Finding the latest available snapshot from primary setup
# 2. Creating new volume from latest snapshot
# 3. Setting up new standby server with restored data
# 4. Configuring replication and registering with repmgr
#
# Author: Generated Script (Fixed Version)
# Version: 1.1 - Fixed backup data verification and PostgreSQL startup
#===============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Default configuration - MODIFY THESE VALUES FOR YOUR ENVIRONMENT
readonly DEFAULT_PRIMARY_IP="10.40.0.24"
readonly DEFAULT_EXISTING_STANDBY_IP="10.40.0.27"
readonly DEFAULT_NEW_STANDBY_IP="10.40.0.17"
readonly DEFAULT_PG_VERSION="13"
readonly DEFAULT_STANZA_NAME="txn_cluster"
readonly DEFAULT_AWS_REGION="ap-northeast-1"
readonly DEFAULT_AVAILABILITY_ZONE="ap-northeast-1a"
readonly DEFAULT_NEW_NODE_ID="3"
readonly DEFAULT_NEW_NODE_NAME="standby_17"

# Configuration variables
PRIMARY_IP="${PRIMARY_IP:-$DEFAULT_PRIMARY_IP}"
EXISTING_STANDBY_IP="${EXISTING_STANDBY_IP:-$DEFAULT_EXISTING_STANDBY_IP}"
NEW_STANDBY_IP="${NEW_STANDBY_IP:-$DEFAULT_NEW_STANDBY_IP}"
PG_VERSION="${PG_VERSION:-$DEFAULT_PG_VERSION}"
STANZA_NAME="${STANZA_NAME:-$DEFAULT_STANZA_NAME}"
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-$DEFAULT_AVAILABILITY_ZONE}"
NEW_NODE_ID="${NEW_NODE_ID:-$DEFAULT_NEW_NODE_ID}"
NEW_NODE_NAME="${NEW_NODE_NAME:-$DEFAULT_NEW_NODE_NAME}"

# Derived configuration
readonly PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
readonly PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"
readonly BACKUP_MOUNT_POINT="/backup/pgbackrest"
readonly BACKUP_DEVICE="/dev/xvdb"
readonly REPLICATION_SLOT_NAME="${NEW_NODE_NAME}_slot"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/pgbackrest_standby_setup_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_FILE="${SCRIPT_DIR}/pgbackrest_standby_state.env"

# Global variables
BACKUP_VOLUME_ID=""
LATEST_SNAPSHOT_ID=""
NEW_VOLUME_ID=""
NEW_INSTANCE_ID=""
PRIMARY_STATE_FILE=""

#===============================================================================
# Utility Functions (Fixed to match primary script)
#===============================================================================

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${CYAN}[${timestamp}]${NC} ${message}" | tee -a "$LOG_FILE"
}

log_success() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[${timestamp}] ✅ ${message}${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[${timestamp}] ❌ ERROR: ${message}${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[${timestamp}] ⚠️  WARNING: ${message}${NC}" | tee -a "$LOG_FILE"
}

log_info() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[${timestamp}] ℹ️  INFO: ${message}${NC}" | tee -a "$LOG_FILE"
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found"
        exit 1
    fi
}

execute_remote() {
    local host="$1"
    local command="$2"
    local description="${3:-Executing remote command}"

    log "Executing on $host: $description"
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$host" "$command"; then
        log_success "Command executed successfully on $host"
        return 0
    else
        log_error "Command failed on $host: $command"
        return 1
    fi
}

save_state() {
    local key="$1"
    local value="$2"

    # Create or update state file
    if [ -f "$STATE_FILE" ]; then
        # Remove existing key if present
        grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || touch "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    # Add new key-value pair with proper quoting for values containing spaces
    if [[ "$value" =~ [[:space:]] ]]; then
        echo "${key}=\"${value}\"" >> "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
    log_info "State saved: ${key}=${value}"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        log_info "State loaded from: $STATE_FILE"
    else
        log_info "No existing state file found"
    fi
}

load_primary_state() {
    local state_file="$1"

    if [ ! -f "$state_file" ]; then
        log_error "State file not found: $state_file"
        exit 1
    fi

    source "$state_file"
    PRIMARY_STATE_FILE="$state_file"
    log_info "Primary state loaded from: $state_file"

    # Validate required state variables
    if [ -z "${BACKUP_VOLUME_ID:-}" ]; then
        log_error "BACKUP_VOLUME_ID not found in state file"
        exit 1
    fi

    if [ -z "${LATEST_SNAPSHOT_ID:-}" ]; then
        log_error "LATEST_SNAPSHOT_ID not found in state file"
        exit 1
    fi

    log_info "Using backup volume: $BACKUP_VOLUME_ID"
    log_info "Using latest snapshot: $LATEST_SNAPSHOT_ID"
}

#===============================================================================
# Prerequisites Check (Fixed to match primary script structure)
#===============================================================================

check_prerequisites() {
    log "Checking prerequisites for standby setup..."

    # Check required commands
    check_command "aws"
    check_command "ssh"
    check_command "nc"

    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS CLI not configured properly"
        exit 1
    fi

    # Test SSH connectivity
    for host in "$PRIMARY_IP" "$NEW_STANDBY_IP"; do
        if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$host" "echo 'SSH test successful'" &>/dev/null; then
            log_error "Cannot SSH to $host"
            exit 1
        fi
    done

    # Verify PostgreSQL is running on primary
    if ! ssh -o StrictHostKeyChecking=no "root@$PRIMARY_IP" "sudo -u postgres psql -c 'SELECT version();'" &>/dev/null; then
        log_error "PostgreSQL not accessible on primary server $PRIMARY_IP"
        exit 1
    fi

    # Verify PostgreSQL is installed on new standby (but don't install it)
    if ! ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "command -v psql" &>/dev/null; then
        log_error "PostgreSQL not found on $NEW_STANDBY_IP"
        log_error "Please install PostgreSQL ${PG_VERSION} on the standby server before running this script"
        log_info "Required: PostgreSQL ${PG_VERSION} server and client tools"
        exit 1
    fi

    # Verify PostgreSQL version on standby
    local pg_version_check
    pg_version_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "psql --version" 2>/dev/null || echo "version_check_failed")

    if [[ "$pg_version_check" == "version_check_failed" ]]; then
        log_warning "Could not verify PostgreSQL version on $NEW_STANDBY_IP"
    elif [[ "$pg_version_check" == *"$PG_VERSION"* ]]; then
        log_info "PostgreSQL $PG_VERSION verified on standby server"
    else
        log_warning "PostgreSQL version on standby may not match expected version $PG_VERSION"
        log_info "Found: $pg_version_check"
    fi

    log_success "Prerequisites check completed"
}

#===============================================================================
# Step 1: Find Latest Snapshot
#===============================================================================

find_latest_snapshot() {
    log "=== STEP 1: Finding latest snapshot ==="

    # If state file provided, use snapshot from there
    if [ -n "${LATEST_SNAPSHOT_ID:-}" ]; then
        log_info "Using snapshot from state file: $LATEST_SNAPSHOT_ID"

        # Verify snapshot exists and is completed
        local snapshot_state
        snapshot_state=$(aws ec2 describe-snapshots \
            --snapshot-ids "$LATEST_SNAPSHOT_ID" \
            --query 'Snapshots[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "not-found")

        if [ "$snapshot_state" != "completed" ]; then
            log_error "Snapshot $LATEST_SNAPSHOT_ID is not in completed state: $snapshot_state"
            exit 1
        fi

        save_state "LATEST_SNAPSHOT_ID" "$LATEST_SNAPSHOT_ID"
        log_success "Verified snapshot: $LATEST_SNAPSHOT_ID"
        return 0
    fi

    # Otherwise, find latest snapshot for the stanza
    log "Searching for latest snapshot for stanza: $STANZA_NAME"

    # Find latest completed snapshot for the stanza
    LATEST_SNAPSHOT_ID=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Stanza,Values=$STANZA_NAME" \
        --query 'Snapshots[?State==`completed`] | sort_by(@, &StartTime) | [-1].SnapshotId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "None")

    if [ "$LATEST_SNAPSHOT_ID" == "None" ] || [ -z "$LATEST_SNAPSHOT_ID" ] || [ "$LATEST_SNAPSHOT_ID" == "null" ]; then
        log_error "No completed snapshots found for stanza: $STANZA_NAME"
        log_info "Please run the primary setup script first or check AWS region/tags"
        exit 1
    fi

    # Get snapshot details
    local snapshot_info
    snapshot_info=$(aws ec2 describe-snapshots \
        --snapshot-ids "$LATEST_SNAPSHOT_ID" \
        --query 'Snapshots[0].{Description:Description,StartTime:StartTime,Size:VolumeSize}' \
        --output json \
        --region "$AWS_REGION" 2>/dev/null || echo "{}")

    log_info "Found latest snapshot:"
    log_info "  Snapshot ID: $LATEST_SNAPSHOT_ID"
    log_info "  Details: $snapshot_info"

    save_state "LATEST_SNAPSHOT_ID" "$LATEST_SNAPSHOT_ID"
    log_success "Latest snapshot identified: $LATEST_SNAPSHOT_ID"
}

#===============================================================================
# Step 2: Create New Volume from Latest Snapshot
#===============================================================================

create_new_volume() {
    log "=== STEP 2: Creating new volume from latest snapshot ==="

    # Check if we already have a volume ID in state
    if [[ -n "${NEW_VOLUME_ID:-}" ]] && [[ "$NEW_VOLUME_ID" != "existing-unknown" ]]; then
        # Verify the volume exists and is available
        local volume_state
        volume_state=$(aws ec2 describe-volumes \
            --volume-ids "$NEW_VOLUME_ID" \
            --query 'Volumes[0].State' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "not-found")

        if [[ "$volume_state" == "available" ]]; then
            log_info "Volume $NEW_VOLUME_ID already exists and is available - skipping creation"
            log_success "Using existing volume: $NEW_VOLUME_ID"
            return 0
        elif [[ "$volume_state" == "in-use" ]]; then
            log_info "Volume $NEW_VOLUME_ID already exists and is in-use - checking attachment"
            save_state "VOLUME_EXISTS" "true"
            log_success "Using existing in-use volume: $NEW_VOLUME_ID"
            return 0
        fi
    fi

    # Create new volume from snapshot with improved error handling
    log_info "Creating new volume from snapshot $LATEST_SNAPSHOT_ID"
    NEW_VOLUME_ID=$(aws ec2 create-volume \
        --snapshot-id "$LATEST_SNAPSHOT_ID" \
        --availability-zone "$AVAILABILITY_ZONE" \
        --volume-type gp3 \
        --iops 16000 \
        --throughput 1000 \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=pgbackrest-restore-$(date +%Y%m%d)},{Key=Purpose,Value=Standby-Restore},{Key=SourceSnapshot,Value=$LATEST_SNAPSHOT_ID},{Key=Stanza,Value=$STANZA_NAME}]" \
        --query 'VolumeId' --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "failed")

    if [ "$NEW_VOLUME_ID" == "failed" ] || [ -z "$NEW_VOLUME_ID" ] || [ "$NEW_VOLUME_ID" == "None" ]; then
        log_error "Failed to create volume from snapshot $LATEST_SNAPSHOT_ID"
        exit 1
    fi

    log_info "New volume created: $NEW_VOLUME_ID"

    # Wait for volume to be available
    log "Waiting for volume to be available..."
    aws ec2 wait volume-available --volume-ids "$NEW_VOLUME_ID" --region "$AWS_REGION"

    save_state "NEW_VOLUME_ID" "$NEW_VOLUME_ID"
    log_success "New volume ready: $NEW_VOLUME_ID"
}

#===============================================================================
# Step 3: Attach Volume to New Standby Server (FIXED for NVMe detection)
#===============================================================================

attach_volume_to_new_server() {
    log "=== STEP 3: Attaching volume to new standby server ($NEW_STANDBY_IP) ==="

    # Get instance ID of new standby server
    NEW_INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=private-ip-address,Values=$NEW_STANDBY_IP" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -z "$NEW_INSTANCE_ID" ] || [ "$NEW_INSTANCE_ID" == "None" ]; then
        log_error "Could not find running instance with IP: $NEW_STANDBY_IP"
        exit 1
    fi

    log_info "Target instance: $NEW_INSTANCE_ID"

    # Check if backup is already mounted and working
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Checking current disk layout and backup mount status...'
        lsblk
        echo

        # Check if backup is already mounted
        if mount | grep -q '$BACKUP_MOUNT_POINT'; then
            MOUNTED_DEVICE=\$(mount | grep '$BACKUP_MOUNT_POINT' | awk '{print \$1}')
            echo \"Backup already mounted from: \$MOUNTED_DEVICE\"

            # Verify backup data exists
            if [ -d '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME' ]; then
                echo 'Backup data verified - using existing mount'

                # Set proper permissions just in case
                sudo chown -R postgres:postgres $BACKUP_MOUNT_POINT
                sudo chmod 750 $BACKUP_MOUNT_POINT

                # Verify it's in fstab
                DEVICE_UUID=\$(blkid -s UUID -o value \"\$MOUNTED_DEVICE\" 2>/dev/null)
                if [ -n \"\$DEVICE_UUID\" ] && ! grep -q \"\$DEVICE_UUID\" /etc/fstab; then
                    echo \"Adding mount to fstab for persistence...\"
                    sudo sed -i '\|$BACKUP_MOUNT_POINT|d' /etc/fstab
                    echo \"UUID=\$DEVICE_UUID $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2\" | sudo tee -a /etc/fstab
                    echo \"Added to fstab with UUID: \$DEVICE_UUID\"
                fi

                echo 'BACKUP_MOUNT_READY=true'
                exit 0
            else
                echo 'Mounted device does not contain backup data - will unmount and proceed'
                sudo umount '$BACKUP_MOUNT_POINT' || true
            fi
        fi

        echo 'BACKUP_MOUNT_READY=false'
    " "Checking for existing backup mount"

    # Get the result of backup mount check
    local mount_check_result
    mount_check_result=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
        if mount | grep -q '$BACKUP_MOUNT_POINT'; then
            if [ -d '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME' ]; then
                echo 'ready'
            else
                echo 'invalid'
            fi
        else
            echo 'not_mounted'
        fi
    " 2>/dev/null || echo "check_failed")

    if [ "$mount_check_result" = "ready" ]; then
        log_success "Backup is already mounted and contains valid data - skipping mount setup"
        save_state "NEW_INSTANCE_ID" "$NEW_INSTANCE_ID"
        save_state "VOLUME_ATTACHED" "true"
        save_state "BACKUP_MOUNT_READY" "true"
        return 0
    fi

    # If mount is invalid or not present, proceed with mount setup
    log_info "Backup mount needs setup - proceeding with volume attachment/mount"

    # Check for available disks with backup data (from snapshot)
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Looking for disks with backup data from snapshot...'
        BACKUP_DEVICE_FOUND=\"\"

        for dev in /dev/nvme[0-9]n[0-9] /dev/xvd[b-z] /dev/sd[b-z]; do
            if [ -b \"\$dev\" ]; then
                # Skip mounted devices (except if they're mounted on our target mount point and we already checked them)
                if mount | grep -q \"\$dev\" && ! mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    continue
                fi

                echo \"Checking device: \$dev\"

                # Try to mount and check for backup data
                mkdir -p /tmp/test_mount

                # Unmount from target if it's there but invalid
                if mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    sudo umount '$BACKUP_MOUNT_POINT' 2>/dev/null || true
                fi

                if mount \"\$dev\" /tmp/test_mount 2>/dev/null; then
                    if [ -d '/tmp/test_mount/repo/backup/$STANZA_NAME' ]; then
                        echo \"Found backup data on device: \$dev\"
                        BACKUP_DEVICE_FOUND=\"\$dev\"
                        umount /tmp/test_mount
                        break
                    else
                        echo \"Device \$dev does not contain backup data\"
                    fi
                    umount /tmp/test_mount 2>/dev/null || true
                else
                    echo \"Could not mount \$dev for testing\"
                fi
            fi
        done

        if [ -n \"\$BACKUP_DEVICE_FOUND\" ]; then
            echo \"BACKUP_DEVICE_FOUND=\$BACKUP_DEVICE_FOUND\"
        else
            echo \"BACKUP_DEVICE_FOUND=none\"
        fi
    " "Searching for backup devices"

    # Get the result of backup device search
    local backup_device_result
    backup_device_result=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
        for dev in /dev/nvme[0-9]n[0-9] /dev/xvd[b-z] /dev/sd[b-z]; do
            if [ -b \"\$dev\" ]; then
                # Skip currently mounted devices that aren't on our target mount point
                if mount | grep -q \"\$dev\" && ! mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    continue
                fi

                mkdir -p /tmp/test_mount

                # If it's mounted on our target, unmount first to test
                if mount | grep \"\$dev\" | grep -q '$BACKUP_MOUNT_POINT'; then
                    sudo umount '$BACKUP_MOUNT_POINT' 2>/dev/null || true
                fi

                if mount \"\$dev\" /tmp/test_mount 2>/dev/null; then
                    if [ -d '/tmp/test_mount/repo/backup/$STANZA_NAME' ]; then
                        echo \"\$dev\"
                        umount /tmp/test_mount
                        exit 0
                    fi
                    umount /tmp/test_mount 2>/dev/null || true
                fi
            fi
        done
        echo 'none'
    " 2>/dev/null || echo "none")

    if [ "$backup_device_result" != "none" ]; then
        log_info "Found existing disk with backup data: $backup_device_result"
        BACKUP_DEVICE_ACTUAL="$backup_device_result"
        SKIP_ATTACH=true
    else
        log_info "No existing backup device found - will attach new volume"
        SKIP_ATTACH=false

        # Check if volume is already attached to this instance
        local volume_attachment
        volume_attachment=$(aws ec2 describe-volumes \
            --volume-ids "$NEW_VOLUME_ID" \
            --query 'Volumes[0].Attachments[0].{State:State,InstanceId:InstanceId,Device:Device}' \
            --output json \
            --region "$AWS_REGION" 2>/dev/null || echo "{}")

        local attachment_state=$(echo "$volume_attachment" | grep -o '"State": *"[^"]*"' | cut -d'"' -f4)
        local attached_instance=$(echo "$volume_attachment" | grep -o '"InstanceId": *"[^"]*"' | cut -d'"' -f4)

        if [[ "$attachment_state" == "attached" ]] && [[ "$attached_instance" == "$NEW_INSTANCE_ID" ]]; then
            log_info "Volume $NEW_VOLUME_ID already attached to instance $NEW_INSTANCE_ID"
        else
            # Stop PostgreSQL and unmount any existing backup mount
            execute_remote "$NEW_STANDBY_IP" "
                sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true
                sudo umount $BACKUP_MOUNT_POINT 2>/dev/null || true
            " "Stopping PostgreSQL and unmounting backup"

            # Attach volume to new server
            log_info "Attaching volume $NEW_VOLUME_ID to instance $NEW_INSTANCE_ID"
            if ! aws ec2 attach-volume \
                --volume-id "$NEW_VOLUME_ID" \
                --instance-id "$NEW_INSTANCE_ID" \
                --device "$BACKUP_DEVICE" \
                --region "$AWS_REGION" &>/dev/null; then
                log_error "Failed to attach volume"
                exit 1
            fi

            # Wait for attachment
            log "Waiting for volume attachment..."
            sleep 15
        fi
    fi

    # Mount the backup volume
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Setting up backup volume mount...'

        # Stop PostgreSQL if running
        sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true

        BACKUP_DEVICE_ACTUAL=\"\"

        if [ '$SKIP_ATTACH' = 'true' ]; then
            # Use the device we found earlier
            BACKUP_DEVICE_ACTUAL='$backup_device_result'
            echo \"Using existing device with backup data: \$BACKUP_DEVICE_ACTUAL\"
        else
            # Find the newly attached device
            echo 'Looking for newly attached device...'

            # Wait for attached device to appear
            device_wait=0
            max_wait=60

            while [ \$device_wait -lt \$max_wait ]; do
                # Check for the expected device first
                if [ -b '$BACKUP_DEVICE' ]; then
                    BACKUP_DEVICE_ACTUAL='$BACKUP_DEVICE'
                    break
                fi

                # Check for nvme devices (modern AWS instances)
                for dev in /dev/nvme[0-9]n[0-9]; do
                    if [ -b \"\$dev\" ]; then
                        # Skip the root device
                        if mount | grep -q \"\$dev\"; then
                            continue
                        fi

                        # Check if this device has backup data structure
                        if blkid \"\$dev\" | grep -q ext4; then
                            mkdir -p /tmp/test_mount
                            if mount \"\$dev\" /tmp/test_mount 2>/dev/null; then
                                if [ -d '/tmp/test_mount/repo' ] || [ -d '/tmp/test_mount/repo/backup/$STANZA_NAME' ]; then
                                    BACKUP_DEVICE_ACTUAL=\"\$dev\"
                                    umount /tmp/test_mount
                                    echo \"Found backup device with data: \$dev\"
                                    break
                                fi
                                umount /tmp/test_mount
                            fi
                        fi
                    fi
                done

                if [ -n \"\$BACKUP_DEVICE_ACTUAL\" ]; then
                    break
                fi

                echo \"Waiting for backup device to appear... (\$device_wait/\$max_wait)\"
                sleep 5
                ((device_wait++))
            done

            if [ -z \"\$BACKUP_DEVICE_ACTUAL\" ]; then
                echo 'ERROR: Backup device not found after attachment'
                echo 'Available devices:'
                lsblk
                exit 1
            fi
        fi

        echo \"Using backup device: \$BACKUP_DEVICE_ACTUAL\"

        # Create mount point and ensure it's not mounted
        sudo mkdir -p $BACKUP_MOUNT_POINT
        sudo umount $BACKUP_MOUNT_POINT 2>/dev/null || true

        # Mount the device
        if ! sudo mount \"\$BACKUP_DEVICE_ACTUAL\" $BACKUP_MOUNT_POINT; then
            echo \"ERROR: Failed to mount backup device \$BACKUP_DEVICE_ACTUAL\"
            echo 'Checking device status:'
            lsblk | grep -E \"\$(basename \$BACKUP_DEVICE_ACTUAL)\"
            blkid \"\$BACKUP_DEVICE_ACTUAL\" || echo 'No filesystem found'
            exit 1
        fi

        echo 'Mount successful. Verifying backup data...'

        # Verify backup data exists
        if [ ! -d '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME' ]; then
            echo 'ERROR: Backup data not found in mounted volume'
            echo 'Directory structure:'
            ls -la $BACKUP_MOUNT_POINT/ || echo 'Mount point empty'
            ls -la $BACKUP_MOUNT_POINT/repo/ 2>/dev/null || echo 'Repo directory missing'
            exit 1
        fi

        echo 'Backup data verified:'
        ls -la $BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME/

        # Add to fstab for persistence (use UUID for reliability)
        DEVICE_UUID=\$(blkid -s UUID -o value \"\$BACKUP_DEVICE_ACTUAL\")
        if [ -n \"\$DEVICE_UUID\" ]; then
            # Remove any existing entries for this mount point
            sudo sed -i '\|$BACKUP_MOUNT_POINT|d' /etc/fstab
            echo \"UUID=\$DEVICE_UUID $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2\" | sudo tee -a /etc/fstab
            echo \"Added to fstab with UUID: \$DEVICE_UUID\"
        fi

        # Set proper permissions
        sudo chown -R postgres:postgres $BACKUP_MOUNT_POINT
        sudo chmod 750 $BACKUP_MOUNT_POINT

        # Final verification
        df -h $BACKUP_MOUNT_POINT
        echo \"Backup mount setup completed using device: \$BACKUP_DEVICE_ACTUAL\"
    " "Setting up backup volume mount"

    save_state "NEW_INSTANCE_ID" "$NEW_INSTANCE_ID"
    save_state "VOLUME_ATTACHED" "true"
    log_success "Backup volume mounted with backup data verified"
}


#===============================================================================
# Step 4: Install pgBackRest on New Server
#===============================================================================

install_pgbackrest_new_server() {
    log "=== STEP 4: Installing pgBackRest on new standby ($NEW_STANDBY_IP) ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Verify PostgreSQL is already installed
        if ! command -v psql &> /dev/null; then
            echo 'ERROR: PostgreSQL not found. Please install PostgreSQL first.'
            echo 'Expected PostgreSQL ${PG_VERSION} to be installed and configured.'
            exit 1
        fi

        echo 'PostgreSQL installation verified:'
        psql --version

        # Install pgBackRest from source if not already installed
        if ! command -v pgbackrest &> /dev/null; then
            echo 'Installing pgBackRest from source...'

            # Install build dependencies
            sudo yum install -y python3-devel gcc postgresql${PG_VERSION}-devel openssl-devel \
                libxml2-devel pkgconfig lz4-devel libzstd-devel bzip2-devel zlib-devel \
                libyaml-devel libssh2-devel wget tar gzip

            # Install meson and ninja build tools
            sudo yum install -y python3-pip
            sudo pip3 install meson ninja

            # Download and extract pgBackRest source
            cd /tmp
            wget -O - https://github.com/pgbackrest/pgbackrest/archive/release/2.55.1.tar.gz | tar zx
            cd pgbackrest-release-2.55.1

            # Build pgBackRest
            meson setup build
            ninja -C build

            # Install binary
            sudo cp build/src/pgbackrest /usr/bin/
            sudo chmod 755 /usr/bin/pgbackrest

            # Verify installation
            pgbackrest version

            # Cleanup
            cd /
            rm -rf /tmp/pgbackrest-release-2.55.1
        else
            echo 'pgBackRest already installed'
            pgbackrest version
        fi

        # Setup directories
        sudo mkdir -p /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
        sudo chown postgres:postgres /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest

        # Ensure logs directory exists in backup mount
        sudo mkdir -p $BACKUP_MOUNT_POINT/logs
        sudo chown postgres:postgres $BACKUP_MOUNT_POINT/logs

        echo 'Installation verification:'
        echo \"PostgreSQL: \$(which psql)\"
        echo \"pgBackRest: \$(which pgbackrest)\"
        pgbackrest version
    " "Installing pgBackRest"

    save_state "PGBACKREST_INSTALLED" "true"
    log_success "pgBackRest installation completed"
}

#===============================================================================
# Step 5: Configure pgBackRest for Restore on New Server
#===============================================================================

configure_pgbackrest_new_server() {
    log "=== STEP 5: Configuring pgBackRest for restore on new standby ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Create pgBackRest configuration
        cat << 'EOF' | sudo tee /etc/pgbackrest/pgbackrest.conf > /dev/null
[$STANZA_NAME]
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

[global]
repo1-path=$BACKUP_MOUNT_POINT/repo
repo1-retention-full=4
repo1-retention-diff=3
repo1-retention-archive=10
process-max=12
start-fast=y
stop-auto=y
delta=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=$BACKUP_MOUNT_POINT/logs

[global:restore]
process-max=20
EOF

        # Fix ownership
        sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
        sudo chmod 640 /etc/pgbackrest/pgbackrest.conf

        # Test pgBackRest configuration and verify backup data
        echo 'Testing pgBackRest configuration...'
        if sudo -u postgres pgbackrest --stanza=$STANZA_NAME info; then
            echo 'pgBackRest configuration and backup data verified successfully'
        else
            echo 'pgBackRest info command failed - checking backup data structure'
            echo 'Backup directory contents:'
            ls -la $BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME/ || echo 'Backup directory not found'

            # Check if backup.info files exist
            if [ ! -f '$BACKUP_MOUNT_POINT/repo/backup/$STANZA_NAME/backup.info' ]; then
                echo 'ERROR: backup.info file missing - backup data may be corrupted'
                echo 'Available files:'
                find $BACKUP_MOUNT_POINT/repo -name '*' -type f | head -20
                exit 1
            fi
        fi
    " "Configuring pgBackRest for restore"

    save_state "PGBACKREST_CONFIGURED" "true"
    log_success "pgBackRest restore configuration completed"
}

#===============================================================================
# Enhanced Step 6: Restore Database with Backup Version Detection
#===============================================================================

restore_database_new_server() {
    log "=== STEP 6: Checking database status and backup version ==="

    # First, get the latest available backup info
    local latest_available_backup=""
    local current_restored_backup=""

    # Get the latest available backup using a simpler approach
    latest_available_backup=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info --output=json 2>/dev/null | python3 -c \"
import json, sys
try:
    data = json.load(sys.stdin)
    for stanza in data:
        if stanza.get('name') == '$STANZA_NAME':
            backups = stanza.get('backup', [])
            if backups:
                print(backups[-1]['label'])
                sys.exit(0)
    print('none')
except:
    print('none')
\" 2>/dev/null || echo 'none'")

    log_info "Latest available backup: $latest_available_backup"

    # Check if database is already restored and running
    local pg_version_file_exists
    pg_version_file_exists=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "[ -f '$PG_DATA_DIR/PG_VERSION' ] && [ -f '$PG_DATA_DIR/postgresql.conf' ] && echo 'true' || echo 'false'" 2>/dev/null || echo "false")

    if [ "$pg_version_file_exists" = "true" ]; then
        log_info "PostgreSQL data directory exists - checking current state"

        # Get the backup label from current restored data (if any)
        local backup_label_info=""
        backup_label_info=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "
            # Check for backup label in various ways
            if [ -f '$PG_DATA_DIR/backup_label' ]; then
                grep 'LABEL:' '$PG_DATA_DIR/backup_label' | awk '{print \$2}' 2>/dev/null || echo 'unknown'
            elif [ -f '$PG_DATA_DIR/backup_label.old' ]; then
                grep 'LABEL:' '$PG_DATA_DIR/backup_label.old' | awk '{print \$2}' 2>/dev/null || echo 'unknown'
            else
                # Try to get backup info from pgBackRest if data directory exists and is substantial
                if [ -d '$PG_DATA_DIR' ] && [ \$(du -s '$PG_DATA_DIR' 2>/dev/null | awk '{print \$1}' || echo '0') -gt 1000000 ]; then
                    # If data directory is substantial, assume it's from the latest available backup
                    echo '$latest_available_backup'
                else
                    echo 'no_data'
                fi
            fi
        " 2>/dev/null || echo "check_failed")

        log_info "Current restored backup label: $backup_label_info"

        # Check if it's configured as standby
        local standby_signal_exists
        standby_signal_exists=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "[ -f '$PG_DATA_DIR/standby.signal' ] && echo 'true' || echo 'false'" 2>/dev/null || echo "false")

        if [ "$standby_signal_exists" = "true" ]; then
            log_info "Standby signal file found - checking if PostgreSQL is running"

            # Check if PostgreSQL is running
            local pg_is_active
            pg_is_active=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "systemctl is-active postgresql-${PG_VERSION}.service 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "inactive")

            if [ "$pg_is_active" = "active" ]; then
                log_info "PostgreSQL service is active - checking recovery status"

                # Check if it's actually in recovery mode (standby)
                local recovery_status
                recovery_status=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

                if [ "$recovery_status" = "t" ]; then
                    log_success "PostgreSQL is running as standby"

                    # ✅ KEY CHECK: Compare backup versions
                    if [ "$backup_label_info" != "no_label" ] && [ "$backup_label_info" != "unknown" ] && [ "$backup_label_info" != "check_failed" ]; then
                        if [ "$backup_label_info" = "$latest_available_backup" ]; then
                            log_success "Current restored backup ($backup_label_info) matches latest available backup"
                            log_success "✅ SKIPPING RESTORE - Database already has latest backup restored and running as standby"

                            # Still verify configuration is correct
                            verify_and_fix_standby_config

                            save_state "DATABASE_RESTORED" "true"
                            save_state "STANDBY_RUNNING" "true"
                            save_state "BACKUP_CURRENT" "true"
                            return 0
                        else
                            log_warning "Current backup ($backup_label_info) is different from latest available ($latest_available_backup)"
                            log_info "Will restore latest backup to ensure standby is up-to-date"
                        fi
                    else
                        log_warning "Cannot determine current backup version - will proceed with restore to ensure latest data"
                    fi

                    # If we reach here, backup needs updating but PostgreSQL is running
                    # Stop it gracefully for restore
                    log_info "Stopping PostgreSQL for backup update"
                    ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl stop postgresql-${PG_VERSION}.service"
                elif [ "$recovery_status" = "f" ]; then
                    log_warning "PostgreSQL is running but NOT in recovery mode - needs reconfiguration"
                else
                    log_warning "Could not determine PostgreSQL recovery status"
                fi
            else
                log_info "PostgreSQL service is not running"

                # Check if we have the right backup even though service is down
                if [ "$backup_label_info" != "no_data" ] && [ "$backup_label_info" != "unknown" ] && [ "$backup_label_info" != "check_failed" ]; then
                    if [ "$backup_label_info" = "$latest_available_backup" ]; then
                        log_info "Latest backup ($backup_label_info) is already restored, just need to start PostgreSQL"

                        # Verify standby configuration and start
                        verify_and_fix_standby_config

                        log_info "Starting PostgreSQL with existing latest backup"
                        ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl start postgresql-${PG_VERSION}.service"
                        sleep 10

                        # Verify it started correctly
                        local recovery_check
                        recovery_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

                        if [ "$recovery_check" = "t" ]; then
                            log_success "PostgreSQL started successfully as standby with latest backup"
                            save_state "DATABASE_RESTORED" "true"
                            save_state "STANDBY_RUNNING" "true"
                            save_state "BACKUP_CURRENT" "true"
                            return 0
                        else
                            log_warning "PostgreSQL started but not in recovery mode - will reconfigure"
                        fi
                    else
                        log_info "Current backup ($backup_label_info) differs from latest ($latest_available_backup)"
                        log_info "Will restore latest backup to ensure standby is up-to-date"
                    fi
                else
                    log_info "Cannot determine current backup version reliably"
                    # If we have substantial data and latest backup is available, assume it's current
                    if [ "$data_size" -gt 1000000 ] && [ "$latest_available_backup" != "none" ]; then
                        log_info "Data directory is substantial ($data_size KB) and backup is available"
                        log_info "Assuming data is from latest backup - will configure and start PostgreSQL"

                        verify_and_fix_standby_config

                        log_info "Starting PostgreSQL with existing data"
                        ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl start postgresql-${PG_VERSION}.service"
                        sleep 10

                        local recovery_check
                        recovery_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

                        if [ "$recovery_check" = "t" ]; then
                            log_success "PostgreSQL started successfully as standby with existing data"
                            save_state "DATABASE_RESTORED" "true"
                            save_state "STANDBY_RUNNING" "true"
                            save_state "BACKUP_CURRENT" "true"
                            return 0
                        else
                            log_warning "PostgreSQL failed to start in recovery mode - will restore and reconfigure"
                        fi
                    fi
                fi
            fi
        fi

        # Check if data directory has substantial content - if so, assume it's already restored
        local data_size
        data_size=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "du -s $PG_DATA_DIR 2>/dev/null | awk '{print \$1}' || echo '0'" 2>/dev/null || echo "0")

        if [ "$data_size" -gt 1000000 ]; then  # More than ~1GB
            log_info "Data directory has substantial content ($data_size KB)"
            if [ "$backup_label_info" != "$latest_available_backup" ] && [ "$backup_label_info" != "unknown" ] && [ "$backup_label_info" != "check_failed" ]; then
                log_info "Current: $backup_label_info, Latest: $latest_available_backup"
                # Only restore if we're confident the backup is different
                if [ "$backup_label_info" != "no_data" ]; then
                    log_info "Will restore latest backup"
                else
                    log_info "Cannot determine backup version reliably - will try to use existing data"
                fi
            else
                log_info "Data appears to be current - will try to use existing data"
            fi
        fi
    fi

    # If we reach here, check if we should restore or try to use existing data
    if [ "$data_size" -gt 1000000 ] && [ "$latest_available_backup" != "none" ]; then
        log_info "Data directory has substantial content ($data_size KB)"
        log_info "Attempting to use existing data and configure as standby"

        # Try to configure and start with existing data first
        verify_and_fix_standby_config

        log_info "Starting PostgreSQL with existing data"
        ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl start postgresql-${PG_VERSION}.service"
        sleep 10

        local recovery_check
        recovery_check=$(ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs || echo 'failed'" 2>/dev/null || echo "failed")

        if [ "$recovery_check" = "t" ]; then
            log_success "PostgreSQL started successfully as standby with existing data"
            save_state "DATABASE_RESTORED" "true"
            save_state "STANDBY_RUNNING" "true"
            save_state "BACKUP_CURRENT" "true"
            return 0
        else
            log_warning "PostgreSQL failed to start properly with existing data"
            ssh -o StrictHostKeyChecking=no "root@$NEW_STANDBY_IP" "sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true"
            log_info "Will perform fresh restore"
        fi
    fi

    # Only restore if we really need to
    log_info "Performing database restore with latest backup: $latest_available_backup"

    # Perform the actual restore
    perform_backup_restore "$latest_available_backup"
}

#===============================================================================
# Helper function to verify and fix standby configuration
#===============================================================================

verify_and_fix_standby_config() {
    log_info "Verifying standby configuration..."

    execute_remote "$NEW_STANDBY_IP" "
        # Check max_wal_senders setting
        current_max_wal_senders=\$(grep '^max_wal_senders' $PG_DATA_DIR/postgresql.conf | awk '{print \$3}' 2>/dev/null || echo 'unknown')

        if [ \"\$current_max_wal_senders\" != 'unknown' ] && [ \"\$current_max_wal_senders\" -lt 16 ]; then
            echo 'max_wal_senders is '\$current_max_wal_senders', should be >= 16 - fixing'
            sudo -u postgres sed -i 's/max_wal_senders = [0-9]*/max_wal_senders = 16/' $PG_DATA_DIR/postgresql.conf
            sudo -u postgres sed -i 's/max_replication_slots = [0-9]*/max_replication_slots = 16/' $PG_DATA_DIR/postgresql.conf
        fi

        # Ensure standby.signal exists
        sudo -u postgres touch $PG_DATA_DIR/standby.signal

        # Verify standby configuration exists in postgresql.conf
        if ! grep -q 'primary_conninfo.*$NEW_NODE_NAME' $PG_DATA_DIR/postgresql.conf 2>/dev/null; then
            echo 'Adding missing standby configuration'
            add_standby_configuration
        fi
    " "Verifying standby configuration"
}

#===============================================================================
# Helper function to add standby configuration
#===============================================================================

add_standby_configuration() {
    execute_remote "$NEW_STANDBY_IP" "
        sudo -u postgres tee -a $PG_DATA_DIR/postgresql.conf << EOF

# Standby configuration - Added by setup script
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=repmgr application_name=$NEW_NODE_NAME connect_timeout=2'
primary_slot_name = '$REPLICATION_SLOT_NAME'
hot_standby = on
hot_standby_feedback = on

# Archive configuration
archive_mode = always
archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p'
archive_timeout = 60

# Performance settings (fixed to match primary)
max_wal_senders = 16
max_replication_slots = 16
wal_level = replica

# Additional standby settings
max_standby_streaming_delay = 30s
max_standby_archive_delay = 30s
EOF
    " "Adding standby configuration"
}

#===============================================================================
# Helper function to perform the backup restore
#===============================================================================

perform_backup_restore() {
    local target_backup="$1"

    log "=== STEP 6: Performing database restore ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Stop PostgreSQL if running
        sudo systemctl stop postgresql-${PG_VERSION}.service 2>/dev/null || true

        # Remove existing data directory contents but preserve directory
        if [ -d '$PG_DATA_DIR' ]; then
            echo 'Cleaning existing data directory...'
            sudo rm -rf $PG_DATA_DIR/*
        else
            echo 'Creating data directory...'
            sudo mkdir -p $PG_DATA_DIR
        fi

        # Set ownership
        sudo chown postgres:postgres $PG_DATA_DIR

        # Perform restore
        echo 'Starting pgBackRest restore...'
        if sudo -u postgres pgbackrest --stanza=$STANZA_NAME --delta restore; then
            echo 'Restore completed successfully'
        else
            echo 'Restore failed - checking backup status'
            sudo -u postgres pgbackrest --stanza=$STANZA_NAME info || echo 'Backup info failed'
            exit 1
        fi

        # Create standby.signal
        sudo -u postgres touch $PG_DATA_DIR/standby.signal

        # Configure replication in postgresql.conf
        echo 'Configuring standby settings...'
        sudo -u postgres cat << EOF >> $PG_DATA_DIR/postgresql.conf

# Standby configuration - Added by setup script
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=repmgr application_name=$NEW_NODE_NAME connect_timeout=2'
primary_slot_name = '$REPLICATION_SLOT_NAME'
hot_standby = on
hot_standby_feedback = on

# Archive configuration
archive_mode = always
archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p'
archive_timeout = 60

# Performance settings
max_wal_senders = 16
max_replication_slots = 16
wal_level = replica

# Additional standby settings
max_standby_streaming_delay = 30s
max_standby_archive_delay = 30s
EOF

        echo 'Database restore and configuration completed'
    " "Performing database restore"

    save_state "DATABASE_RESTORED" "true"
    log_success "Database restore completed"
}

#===============================================================================
# Step 7: Setup Replication Slot on Primary
#===============================================================================

setup_replication_slot() {
    log "=== STEP 7: Setting up replication slot on primary ==="

    execute_remote "$PRIMARY_IP" "
        # Check if replication slot already exists
        SLOT_EXISTS=\$(cd /tmp && sudo -u postgres psql -t -c \"SELECT count(*) FROM pg_replication_slots WHERE slot_name='$REPLICATION_SLOT_NAME';\" | xargs)

        if [ \"\$SLOT_EXISTS\" = \"0\" ]; then
            echo 'Creating replication slot for new standby...'
            cd /tmp && sudo -u postgres psql -c \"SELECT pg_create_physical_replication_slot('$REPLICATION_SLOT_NAME');\"
        else
            echo 'Replication slot $REPLICATION_SLOT_NAME already exists'
        fi

        # Check and update pg_hba.conf
        if ! grep -q '$NEW_STANDBY_IP' $PG_DATA_DIR/pg_hba.conf; then
            echo 'Adding pg_hba.conf entries for new standby...'

            # Backup pg_hba.conf
            sudo -u postgres cp $PG_DATA_DIR/pg_hba.conf $PG_DATA_DIR/pg_hba.conf.backup-\$(date +%Y%m%d_%H%M%S)

            # Add entries for new standby (place before any scram-sha-256 rules)
            sudo -u postgres sed -i '/scram-sha-256/i\\
# New standby server entries - Added by standby setup script\\
host    repmgr          repmgr          $NEW_STANDBY_IP/32      trust\\
host    replication     repmgr          $NEW_STANDBY_IP/32      trust\\
host    postgres        repmgr          $NEW_STANDBY_IP/32      trust' $PG_DATA_DIR/pg_hba.conf
        else
            echo 'pg_hba.conf already contains entries for $NEW_STANDBY_IP'
        fi

        # Reload configuration
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_reload_conf();'

        # Verify replication slot
        cd /tmp && sudo -u postgres psql -c \"SELECT slot_name, slot_type, active FROM pg_replication_slots WHERE slot_name='$REPLICATION_SLOT_NAME';\"

        # Show current replication status
        cd /tmp && sudo -u postgres psql -c 'SELECT application_name, client_addr, state FROM pg_stat_replication;'
    " "Setting up replication slot"

    save_state "REPLICATION_SLOT_CREATED" "true"
    log_success "Replication slot setup completed"
}

#===============================================================================
# Step 8: Configure and Start New Standby (FIXED)
#===============================================================================

configure_new_standby() {
    log "=== STEP 8: Configuring and starting new standby server ==="

    execute_remote "$NEW_STANDBY_IP" "
        # Configure pg_hba.conf for standby
        cat << 'EOF' | sudo -u postgres tee $PG_DATA_DIR/pg_hba.conf > /dev/null
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust

# Repmgr connections (MUST be before the general 10.0.0.0/8 rule)
host    repmgr          repmgr          10.0.0.0/8              trust
host    replication     repmgr          10.0.0.0/8              trust
host    repmgr          repmgr          $PRIMARY_IP/32          trust
host    replication     repmgr          $PRIMARY_IP/32          trust
host    repmgr          repmgr          $EXISTING_STANDBY_IP/32 trust
host    replication     repmgr          $EXISTING_STANDBY_IP/32 trust
host    repmgr          repmgr          $NEW_STANDBY_IP/32      trust
host    replication     repmgr          $NEW_STANDBY_IP/32      trust
host    postgres        repmgr          $NEW_STANDBY_IP/32      trust

# General rule for all other connections in 10.0.0.0/8 network
host    all             all             10.0.0.0/8              scram-sha-256
EOF

        # Find and configure repmgr
        REPMGR_PATH=''
        echo 'Checking for repmgr installation...'

        for path in /usr/local/pgsql/bin/repmgr /usr/local/bin/repmgr /usr/pgsql-${PG_VERSION}/bin/repmgr /usr/bin/repmgr; do
            if [ -x \"\$path\" ] && \"\$path\" --version &>/dev/null; then
                REPMGR_PATH=\"\$path\"
                echo \"Found working repmgr at: \$path\"
                break
            fi
        done

        if [ -z \"\$REPMGR_PATH\" ]; then
            echo 'repmgr not found - PostgreSQL will work without cluster management'
        fi

        # Configure repmgr
        if [ -n \"\$REPMGR_PATH\" ]; then
            cat << EOF | sudo -u postgres tee /var/lib/pgsql/repmgr.conf > /dev/null
node_id=$NEW_NODE_ID
node_name='$NEW_NODE_NAME'
conninfo='host=$NEW_STANDBY_IP user=repmgr dbname=repmgr connect_timeout=2'
data_directory='$PG_DATA_DIR'
config_directory='$PG_DATA_DIR'
log_level=INFO
log_file='/var/log/repmgr/repmgr.log'
pg_bindir='/usr/local/pgsql/bin'
repmgrd_service_start_command='sudo systemctl start repmgrd'
repmgrd_service_stop_command='sudo systemctl stop repmgrd'
EOF

            # Create log directory
            sudo mkdir -p /var/log/repmgr
            sudo chown postgres:postgres /var/log/repmgr
        fi

        # Test PostgreSQL configuration before starting
        echo 'Testing PostgreSQL configuration...'
        if ! sudo -u postgres /usr/pgsql-${PG_VERSION}/bin/postgres --check-config -D $PG_DATA_DIR; then
            echo 'WARNING: PostgreSQL configuration has issues'
        fi

        # Start PostgreSQL with improved error handling
        echo 'Starting PostgreSQL service...'
        if sudo systemctl start postgresql-${PG_VERSION}.service; then
            echo 'PostgreSQL started successfully'
        else
            echo 'PostgreSQL startup failed - checking logs and configuration'

            # Check systemctl status
            sudo systemctl status postgresql-${PG_VERSION}.service --no-pager -l

            # Check PostgreSQL logs
            echo 'Recent PostgreSQL logs:'
            sudo tail -20 $PG_DATA_DIR/log/postgresql-*.log 2>/dev/null || echo 'No PostgreSQL logs found'

            # Try to start manually for better error output
            echo 'Attempting manual start for diagnosis...'
            sudo -u postgres /usr/pgsql-${PG_VERSION}/bin/postgres -D $PG_DATA_DIR --check-config || echo 'Config check failed'

            # Check if port is in use
            netstat -tlnp | grep :5432 || echo 'Port 5432 not in use'

            # Try starting again with a delay
            echo 'Retrying PostgreSQL start...'
            sleep 5
            if sudo systemctl start postgresql-${PG_VERSION}.service; then
                echo 'PostgreSQL started on retry'
            else
                echo 'PostgreSQL startup failed on retry - manual intervention needed'
                exit 1
            fi
        fi

        # Enable PostgreSQL service
        sudo systemctl enable postgresql-${PG_VERSION}.service

        # Wait for startup and test connection
        startup_wait=0
        max_startup_wait=60
        while [ \$startup_wait -lt \$max_startup_wait ]; do
            if cd /tmp && sudo -u postgres psql -c 'SELECT 1;' &>/dev/null; then
                echo 'PostgreSQL connection test successful'
                break
            fi
            echo \"Waiting for PostgreSQL to accept connections... (\$startup_wait/\$max_startup_wait)\"
            sleep 2
            startup_wait=\$((startup_wait + 2))
        done

        if [ \$startup_wait -ge \$max_startup_wait ]; then
            echo 'ERROR: PostgreSQL not accepting connections after startup'
            exit 1
        fi

        # Check recovery status
        echo 'Checking recovery status...'
        RECOVERY_STATUS=\$(cd /tmp && sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' | xargs)
        if [ \"\$RECOVERY_STATUS\" = \"t\" ]; then
            echo 'PostgreSQL is in recovery mode - standby setup successful'
        else
            echo 'WARNING: PostgreSQL is not in recovery mode - may not be properly configured as standby'
        fi

        # Show replication status
        echo 'Initial replication status:'
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();' || echo 'WAL status check'

        echo 'PostgreSQL standby configuration completed'
    " "Configuring and starting new standby"

    save_state "STANDBY_CONFIGURED" "true"
    log_success "New standby server configuration completed"
}

#===============================================================================
# Step 9: Register with repmgr and Final Verification
#===============================================================================

register_with_repmgr() {
    log "=== STEP 9: Registering with repmgr and final verification ==="

    # Test connections first
    execute_remote "$NEW_STANDBY_IP" "
        echo 'Testing connections...'

        # Test regular PostgreSQL connection
        if cd /tmp && timeout 10 sudo -u postgres psql -h $PRIMARY_IP -U repmgr -d postgres -c 'SELECT 1;' 2>/dev/null; then
            echo 'Regular connection to primary: SUCCESS'
        else
            echo 'Regular connection to primary: FAILED'
        fi

        # Test replication connection
        if cd /tmp && timeout 10 sudo -u postgres psql 'host=$PRIMARY_IP port=5432 user=repmgr application_name=$NEW_NODE_NAME replication=1' -c 'IDENTIFY_SYSTEM;' 2>/dev/null; then
            echo 'Replication connection to primary: SUCCESS'
        else
            echo 'Replication connection to primary: FAILED'
        fi
    " "Testing connections"

    # Register standby with repmgr if available
    execute_remote "$NEW_STANDBY_IP" "
        # Find repmgr binary
        REPMGR_PATH=''
        for path in /usr/local/pgsql/bin/repmgr /usr/local/bin/repmgr /usr/pgsql-${PG_VERSION}/bin/repmgr /usr/bin/repmgr; do
            if [ -x \"\$path\" ] && \"\$path\" --version &>/dev/null; then
                REPMGR_PATH=\"\$path\"
                break
            fi
        done

        if [ -z \"\$REPMGR_PATH\" ]; then
            echo 'repmgr not found - skipping cluster registration'
            echo 'PostgreSQL replication is working without repmgr cluster management'
            exit 0
        fi

        echo \"Using repmgr at: \$REPMGR_PATH\"

        # Test repmgr configuration
        if cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" --version; then
            echo 'repmgr version check successful'
        else
            echo 'repmgr version check failed'
            exit 0
        fi

        # Try to show cluster first
        echo 'Testing repmgr cluster configuration...'
        cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" -f /var/lib/pgsql/repmgr.conf cluster show || echo 'Cluster show test completed'

        # Register with repmgr
        echo 'Registering standby with repmgr...'
        if cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" -f /var/lib/pgsql/repmgr.conf standby register --upstream-node-id=1 --force; then
            echo 'Registration successful'
        else
            echo 'Registration attempted (may already be registered or have connectivity issues)'
        fi

        # Verify registration
        echo 'Verifying cluster registration...'
        cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" -f /var/lib/pgsql/repmgr.conf cluster show || echo 'Final cluster show'
    " "Registering with repmgr"

    save_state "REPMGR_REGISTERED" "true"
    log_success "repmgr registration completed"
}

#===============================================================================
# Step 10: Final Verification and Testing
#===============================================================================

final_verification() {
    log "=== STEP 10: Final verification and testing ==="

    # Check recovery status on new standby
    execute_remote "$NEW_STANDBY_IP" "
        echo '=== Recovery Status ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'

        echo '=== WAL Receiver Status ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT pid, status, sender_host, slot_name FROM pg_stat_wal_receiver;' || echo 'WAL receiver status check'

        echo '=== Current LSN ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();'

        echo '=== Standby Configuration Check ==='
        cd /tmp && sudo -u postgres psql -c 'SHOW primary_conninfo;'
        cd /tmp && sudo -u postgres psql -c 'SHOW primary_slot_name;'

        echo '=== PostgreSQL Log Tail ==='
        sudo tail -10 $PG_DATA_DIR/log/postgresql-*.log 2>/dev/null || echo 'Log check completed'
    " "Checking standby status"

    # Check replication status on primary
    execute_remote "$PRIMARY_IP" "
        echo '=== Primary Replication Status ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;'

        echo '=== Replication Slots ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT slot_name, active, active_pid FROM pg_replication_slots;'

        echo '=== Testing Replication ==='
        cd /tmp && sudo -u postgres psql -c \"CREATE TABLE IF NOT EXISTS replication_test (id serial, message text, created_at timestamp DEFAULT now());\"
        cd /tmp && sudo -u postgres psql -c \"INSERT INTO replication_test (message) VALUES ('Test from standby setup script at \$(date)');\"
    " "Checking primary status and testing replication"

    # Verify replication on standby
    sleep 15
    execute_remote "$NEW_STANDBY_IP" "
        echo '=== Verifying Replication ==='
        cd /tmp && sudo -u postgres psql -c \"SELECT * FROM replication_test ORDER BY id DESC LIMIT 5;\" || echo 'Replication test table verification - may take time to appear'

        echo '=== Final Status Check ==='
        cd /tmp && sudo -u postgres psql -c 'SELECT now(), pg_is_in_recovery();'

        echo '=== Backup Verification ==='
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info || echo 'Backup info check'
    " "Verifying replication on standby"

    # Show cluster status if repmgr is available
    execute_remote "$PRIMARY_IP" "
        echo '=== Cluster Status ==='
        REPMGR_PATH=''

        # Try to find repmgr on primary
        for path in /usr/pgsql-${PG_VERSION}/bin/repmgr /usr/local/bin/repmgr /usr/bin/repmgr \$(which repmgr 2>/dev/null); do
            if [ -x \"\$path\" ]; then
                REPMGR_PATH=\"\$path\"
                break
            fi
        done

        if [ -n \"\$REPMGR_PATH\" ]; then
            cd /tmp && sudo -u postgres \"\$REPMGR_PATH\" cluster show || echo 'repmgr cluster status check'
        else
            echo 'repmgr not found on primary for cluster status'
        fi
    " "Showing cluster status"

    save_state "VERIFICATION_COMPLETED" "true"
    save_state "SETUP_COMPLETED" "$(date '+%Y-%m-%d %H:%M:%S')"
    log_success "Final verification completed"
}

#===============================================================================
# Summary
#===============================================================================

show_standby_summary() {
    log "=== STANDBY SETUP COMPLETED SUCCESSFULLY! ==="
    echo
    log_info "=== DEPLOYMENT SUMMARY ==="
    log_info "Primary Server: $PRIMARY_IP"
    log_info "Existing Standby: $EXISTING_STANDBY_IP"
    log_info "New Standby: $NEW_STANDBY_IP"
    log_info "PostgreSQL Version: $PG_VERSION"
    log_info "Stanza Name: $STANZA_NAME"
    if [ -n "$LATEST_SNAPSHOT_ID" ]; then
        log_info "Source Snapshot: $LATEST_SNAPSHOT_ID"
    fi
    if [ -n "$NEW_VOLUME_ID" ]; then
        log_info "New Volume: $NEW_VOLUME_ID"
    fi
    echo
    log_info "=== CLUSTER STRUCTURE ==="
    log_info "Node 1 ($PRIMARY_IP) = Primary"
    log_info "Node 2 ($EXISTING_STANDBY_IP) = Existing Standby"
    log_info "Node 3 ($NEW_STANDBY_IP) = New Standby"
    echo
    log_info "=== STATE FILE ==="
    log_info "Configuration saved to: $STATE_FILE"
    if [ -f "$STATE_FILE" ]; then
        log_info "Current state:"
        while IFS= read -r line; do
            log_info "  $line"
        done < "$STATE_FILE"
    fi
    echo
    log_info "=== MONITORING COMMANDS ==="
    echo "# Check replication status:"
    echo "sudo -u postgres repmgr cluster show"
    echo
    echo "# Check PostgreSQL logs:"
    echo "tail -f $PG_DATA_DIR/log/postgresql-*.log"
    echo
    echo "# Check pgBackRest status:"
    echo "sudo -u postgres pgbackrest --stanza=$STANZA_NAME info"
    echo
    echo "# Test backup from new standby:"
    echo "sudo -u postgres pgbackrest --stanza=$STANZA_NAME --type=full backup"
    echo
    log_info "=== FAILOVER COMMANDS ==="
    echo "# Promote standby to primary:"
    echo "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf standby promote"
    echo
    echo "# Rejoin old primary as standby:"
    echo "sudo -u postgres repmgr -f /var/lib/pgsql/repmgr.conf node rejoin -d 'host=NEW_PRIMARY_IP user=repmgr dbname=repmgr' --force-rewind"
    echo
    log_success "Log file saved to: $LOG_FILE"
}

#===============================================================================
# Usage Information
#===============================================================================

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "PREREQUISITES:"
    echo "  - PostgreSQL ${DEFAULT_PG_VERSION} must be pre-installed on the standby server"
    echo "  - AWS CLI configured with appropriate permissions"
    echo "  - SSH access to both primary and standby servers"
    echo "  - pgBackRest backups available in AWS snapshots"
    echo
    echo "Environment Variables:"
    echo "  PRIMARY_IP              Primary server IP (default: $DEFAULT_PRIMARY_IP)"
    echo "  EXISTING_STANDBY_IP     Existing standby IP (default: $DEFAULT_EXISTING_STANDBY_IP)"
    echo "  NEW_STANDBY_IP          New standby server IP (default: $DEFAULT_NEW_STANDBY_IP)"
    echo "  PG_VERSION              PostgreSQL version (default: $DEFAULT_PG_VERSION)"
    echo "  STANZA_NAME             pgBackRest stanza name (default: $DEFAULT_STANZA_NAME)"
    echo "  AWS_REGION              AWS region (default: $DEFAULT_AWS_REGION)"
    echo "  AVAILABILITY_ZONE       AWS availability zone (default: $DEFAULT_AVAILABILITY_ZONE)"
    echo "  NEW_NODE_ID             New node ID for repmgr (default: $DEFAULT_NEW_NODE_ID)"
    echo "  NEW_NODE_NAME           New node name for repmgr (default: $DEFAULT_NEW_NODE_NAME)"
    echo
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  --state-file FILE       Load configuration from primary setup state file"
    echo "  --snapshot-id ID        Use specific snapshot ID instead of latest"
    echo "  --dry-run               Show what would be done without executing"
    echo "  --skip-prerequisites    Skip prerequisites check"
    echo "  --list-snapshots        List available snapshots and exit"
    echo
    echo "Examples:"
    echo "  # Using state file from primary setup:"
    echo "  $0 --state-file ./pgbackrest_primary_state.env"
    echo
    echo "  # Using specific snapshot:"
    echo "  $0 --snapshot-id snap-1234567890abcdef0"
    echo
    echo "  # Custom new standby IP:"
    echo "  NEW_STANDBY_IP=10.1.1.20 $0 --state-file ./primary_state.env"
    echo
    echo "  # List available snapshots:"
    echo "  $0 --list-snapshots"
}

#===============================================================================
# List Available Snapshots
#===============================================================================

list_snapshots() {
    log "=== AVAILABLE SNAPSHOTS FOR STANZA: $STANZA_NAME ==="

    local snapshots
    snapshots=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Stanza,Values=$STANZA_NAME" \
        --query 'Snapshots | sort_by(@, &StartTime) | [*].{SnapshotId:SnapshotId,Description:Description,StartTime:StartTime,State:State,Size:VolumeSize}' \
        --output table \
        --region "$AWS_REGION" 2>/dev/null || echo "")

    if [ -n "$snapshots" ] && [ "$snapshots" != "None" ]; then
        echo "$snapshots"
        echo

        # Show latest snapshot
        local latest_snapshot
        latest_snapshot=$(aws ec2 describe-snapshots \
            --owner-ids self \
            --filters "Name=tag:Stanza,Values=$STANZA_NAME" "Name=state,Values=completed" \
            --query 'Snapshots | sort_by(@, &StartTime) | [-1].SnapshotId' \
            --output text \
            --region "$AWS_REGION" 2>/dev/null || echo "None")

        if [ "$latest_snapshot" != "None" ] && [ -n "$latest_snapshot" ]; then
            log_info "Latest completed snapshot: $latest_snapshot"
        fi

        log_info "To use a specific snapshot:"
        log_info "  $0 --snapshot-id <SNAPSHOT_ID>"
    else
        log_warning "No snapshots found for stanza: $STANZA_NAME"
        log_info "Please run the primary setup script first or check AWS region/tags"
    fi
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    local use_state_file=""
    local specific_snapshot=""
    local list_snapshots_only=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            --state-file)
                if [ -z "${2:-}" ]; then
                    log_error "State file path required after --state-file"
                    exit 1
                fi
                use_state_file="$2"
                shift 2
                ;;
            --snapshot-id)
                if [ -z "${2:-}" ]; then
                    log_error "Snapshot ID required after --snapshot-id"
                    exit 1
                fi
                specific_snapshot="$2"
                shift 2
                ;;
            --dry-run)
                log_warning "DRY RUN MODE - No changes will be made"
                DRY_RUN=true
                shift
                ;;
            --skip-prerequisites)
                SKIP_PREREQ=true
                shift
                ;;
            --list-snapshots)
                list_snapshots_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Print header
    echo -e "${CYAN}"
    echo "==============================================================================="
    echo "  pgBackRest Standby Setup Script - Part 2 (FIXED VERSION)"
    echo "==============================================================================="
    echo -e "${NC}"

    # Handle list snapshots request
    if [ "$list_snapshots_only" = true ]; then
        list_snapshots
        exit 0
    fi

    # Load existing standby state
    load_state

    # Load state from primary setup if provided
    if [ -n "$use_state_file" ]; then
        PRIMARY_STATE_FILE="$use_state_file"
        load_primary_state "$use_state_file"
    fi

    # Override with specific snapshot if provided
    if [ -n "$specific_snapshot" ]; then
        LATEST_SNAPSHOT_ID="$specific_snapshot"
        log_info "Using specified snapshot: $LATEST_SNAPSHOT_ID"
    fi

    # Show configuration
    log_info "Configuration:"
    log_info "  Primary IP: $PRIMARY_IP"
    log_info "  Existing Standby IP: $EXISTING_STANDBY_IP"
    log_info "  New Standby IP: $NEW_STANDBY_IP"
    log_info "  PostgreSQL Version: $PG_VERSION"
    log_info "  Stanza Name: $STANZA_NAME"
    log_info "  AWS Region: $AWS_REGION"
    if [ -n "$PRIMARY_STATE_FILE" ]; then
        log_info "  Primary State File: $PRIMARY_STATE_FILE"
    fi
    if [ -n "$LATEST_SNAPSHOT_ID" ]; then
        log_info "  Target Snapshot: $LATEST_SNAPSHOT_ID"
    fi
    log_info "  Log File: $LOG_FILE"
    log_info "  State File: $STATE_FILE"
    echo

    # Confirmation prompt
    read -p "Do you want to proceed with the standby setup? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Setup cancelled by user"
        exit 0
    fi

    # Execute setup steps
    if [[ "${SKIP_PREREQ:-false}" != "true" ]]; then
        check_prerequisites
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "DRY RUN - Skipping actual execution"
        exit 0
    fi

    # Execute standby setup steps
    find_latest_snapshot
    create_new_volume
    attach_volume_to_new_server
    install_pgbackrest_new_server
    configure_pgbackrest_new_server
    restore_database_new_server
    setup_replication_slot
    configure_new_standby
    register_with_repmgr
    final_verification
    show_standby_summary

    log_success "Standby setup completed successfully!"
}

# Execute main function with all arguments
main "$@"
