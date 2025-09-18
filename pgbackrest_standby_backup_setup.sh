#!/bin/bash
#===============================================================================
# pgBackRest Standby Backup Setup Script (Unified)
#
# This script handles:
# 1. Setting up pgBackRest on a STANDBY server for taking backups
# 2. Taking backups from standby (reduces primary load)
# 3. Creating EBS snapshots for quick standby creation
# 4. Works with existing repmgr cluster setup
# 5. Can be used for both initial setup and scheduled backups
#
# Usage:
#   Initial setup: ./pgbackrest_standby_backup_setup.sh
#   Scheduled run: ./pgbackrest_standby_backup_setup.sh --scheduled
#
# The snapshots created by this script can be used with pgbackrest_standby_setup.sh
# to create new standby servers
#
# Author: Unified Standby Backup Script
# Version: 2.0
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
readonly DEFAULT_STANDBY_IP="10.40.0.17"  # The standby where backups will run
readonly DEFAULT_PG_VERSION="13"
readonly DEFAULT_STANZA_NAME="txn_cluster_new"
readonly DEFAULT_BACKUP_VOLUME_SIZE="100"
readonly DEFAULT_AWS_REGION="ap-northeast-1"
readonly DEFAULT_AVAILABILITY_ZONE="ap-northeast-1a"

# Configuration variables
PRIMARY_IP="${PRIMARY_IP:-$DEFAULT_PRIMARY_IP}"
STANDBY_IP="${STANDBY_IP:-$DEFAULT_STANDBY_IP}"
PG_VERSION="${PG_VERSION:-$DEFAULT_PG_VERSION}"
STANZA_NAME="${STANZA_NAME:-$DEFAULT_STANZA_NAME}"
BACKUP_VOLUME_SIZE="${BACKUP_VOLUME_SIZE:-$DEFAULT_BACKUP_VOLUME_SIZE}"
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-$DEFAULT_AVAILABILITY_ZONE}"
SETUP_PERIODIC_SNAPSHOTS="${SETUP_PERIODIC_SNAPSHOTS:-true}"

# Backup scheduling configuration
BACKUP_MODE="${BACKUP_MODE:-auto}"  # auto, setup, full, incr, skip
FORCE_FULL_BACKUP="${FORCE_FULL_BACKUP:-false}"
SKIP_SNAPSHOT="${SKIP_SNAPSHOT:-false}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"
CLEANUP_OLD_SNAPSHOTS="${CLEANUP_OLD_SNAPSHOTS:-true}"

# Derived configuration
readonly PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
readonly PG_BIN_DIR="/usr/pgsql-${PG_VERSION}/bin"
readonly BACKUP_MOUNT_POINT="/backup/pgbackrest"
readonly BACKUP_DEVICE="/dev/xvdb"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/pgbackrest_standby_backup_$(date +%Y%m%d_%H%M%S).log"
readonly STATE_FILE="${SCRIPT_DIR}/pgbackrest_standby_backup_state.env"

# Check if we have local repmgr binary path
REPMGR_BIN="/usr/local/pgsql/bin/repmgr"
if [ ! -f "$REPMGR_BIN" ]; then
    REPMGR_BIN="/usr/pgsql-${PG_VERSION}/bin/repmgr"
fi

# Global variables
BACKUP_VOLUME_ID=""
SNAPSHOT_ID=""
SCHEDULED_MODE=false

#===============================================================================
# Utility Functions
#===============================================================================

get_current_server_ip() {
    # Get the IP address of the current server
    # Try multiple methods to ensure we get the correct IP

    # Method 1: Get IP from hostname -I (most reliable for internal IPs)
    local ip_list=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^10\.|^172\.|^192\.168\.' | head -1)

    if [[ -n "$ip_list" ]]; then
        echo "$ip_list"
        return
    fi

    # Method 2: Get IP from ip command
    local ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -E '^10\.|^172\.|^192\.168\.' | head -1)

    if [[ -n "$ip_addr" ]]; then
        echo "$ip_addr"
        return
    fi

    # Method 3: Get IP that can reach the primary
    local primary_ip="${PRIMARY_IP:-$DEFAULT_PRIMARY_IP}"
    local route_ip=$(ip route get "$primary_ip" 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -1)

    if [[ -n "$route_ip" ]]; then
        echo "$route_ip"
        return
    fi

    # If all methods fail, return empty
    echo ""
}

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

save_state() {
    local key="$1"
    local value="$2"

    # Create or update state file
    if [ -f "$STATE_FILE" ]; then
        # Remove existing key if present
        grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || touch "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    # Add new key-value pair
    echo "${key}=${value}" >> "$STATE_FILE"
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

#===============================================================================
# Smart Backup Type Detection
#===============================================================================

determine_backup_type() {
    # If backup is explicitly skipped
    if [[ "$SKIP_BACKUP" == "true" ]] || [[ "$BACKUP_MODE" == "skip" ]]; then
        echo "skip"
        return
    fi

    # If explicitly set, use that
    if [[ "$BACKUP_MODE" == "full" ]]; then
        echo "full"
        return
    elif [[ "$BACKUP_MODE" == "incr" ]]; then
        echo "incr"
        return
    elif [[ "$BACKUP_MODE" == "setup" ]]; then
        echo "full"
        return
    fi

    # Auto mode: determine based on day of week and existing backups
    local day_of_week=$(date +%u)  # 1=Monday, 7=Sunday

    if [[ "$day_of_week" == "7" ]] || [[ "$FORCE_FULL_BACKUP" == "true" ]]; then
        # Sunday or forced full backup
        echo "full"
    else
        # Monday-Saturday: check if we have a recent full backup
        local has_recent_full
        has_recent_full=$(sudo -u postgres pgbackrest --stanza=$STANZA_NAME info --output=json 2>/dev/null | grep -q '"type":"full"' && echo 'true' || echo 'false')

        if [[ "$has_recent_full" == "true" ]]; then
            echo "incr"
        else
            log_warning "No recent full backup found, taking full backup instead of incremental"
            echo "full"
        fi
    fi
}

should_run_setup() {
    # Check if this is the first run (setup mode)
    if [[ "$BACKUP_MODE" == "setup" ]]; then
        return 0
    fi

    # In scheduled mode, never run setup
    if [[ "$SCHEDULED_MODE" == "true" ]]; then
        return 1
    fi

    # Check if already configured
    if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        if [[ "${PGBACKREST_CONFIGURED:-false}" == "true" ]] && [[ "${INITIAL_BACKUP_COMPLETED:-false}" == "true" ]]; then
            return 1  # Setup already completed
        fi
    fi

    return 0  # Needs setup
}

#===============================================================================
# Prerequisites Check - Standby Specific
#===============================================================================

check_prerequisites() {
    log "Checking prerequisites for standby backup setup..."

    # Check required commands
    check_command "aws"
    check_command "nc"

    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &>/dev/null; then
        log_error "AWS CLI not configured properly"
        exit 1
    fi

    # Verify this server's IP matches the configured standby IP
    log_info "Verifying server IP configuration..."
    local current_ip=$(get_current_server_ip)

    if [[ -z "$current_ip" ]]; then
        log_error "Could not determine current server's IP address"
        exit 1
    fi

    log_info "Current server IP: $current_ip"
    log_info "Expected standby IP: $STANDBY_IP"

    if [[ "$current_ip" != "$STANDBY_IP" ]]; then
        log_error "This script is configured to run on $STANDBY_IP but is running on $current_ip"
        log_error "Please either:"
        log_error "  1. Run this script on server $STANDBY_IP"
        log_error "  2. Or set STANDBY_IP environment variable:"
        log_error "     export STANDBY_IP='$current_ip'"
        log_error "     ./pgbackrest_standby_backup_setup.sh"
        exit 1
    fi

    log_success "Server IP verified: running on correct standby server ($current_ip)"

    # Verify this is actually a standby server
    log_info "Verifying this server is a standby in the repmgr cluster..."

    # First check if PostgreSQL is in recovery mode
    local in_recovery=$(sudo -u postgres psql -t -c 'SELECT pg_is_in_recovery();' 2>/dev/null | xargs)
    if [[ "$in_recovery" != "t" ]]; then
        log_error "Server is not in recovery mode. This script is only for standby servers."
        log_error "For primary servers, use pgbackrest_primary_setup.sh instead."
        exit 1
    fi

    # Check repmgr status if available
    if [ -f "$REPMGR_BIN" ]; then
        local node_role=$(sudo -u postgres $REPMGR_BIN -f /var/lib/pgsql/repmgr.conf node status 2>/dev/null | grep "Role:" | awk '{print $NF}')
        if [[ "$node_role" != "standby" ]]; then
            log_error "This server is not a standby according to repmgr (role: $node_role)"
            exit 1
        fi
    fi

    # Check SSH connectivity to primary for pgBackRest
    log_info "Checking SSH connectivity to primary server..."
    if ! sudo -u postgres ssh -o BatchMode=yes -o ConnectTimeout=5 postgres@$PRIMARY_IP 'exit 0' 2>/dev/null; then
        log_error "Cannot SSH to primary server as postgres user"
        log_error "Please ensure passwordless SSH is configured from standby to primary"
        log_error "Run: sudo -u postgres ssh-copy-id postgres@$PRIMARY_IP"
        exit 1
    fi

    log_success "Prerequisites check completed - server confirmed as standby"
}

#===============================================================================
# Step 1: Setup Backup Volume on Standby
#===============================================================================

setup_backup_volume() {
    log "=== STEP 1: Setting up backup volume on standby ==="

    # Check if mount point already exists and is mounted
    if mount | grep -q "$BACKUP_MOUNT_POINT"; then
        log_info "Backup mount point already exists"

        # Check if it has the required structure
        if [ -d "$BACKUP_MOUNT_POINT/repo" ] && [ -d "$BACKUP_MOUNT_POINT/logs" ]; then
            log_info "Existing backup directory structure found - using existing setup"
        else
            log_info "Creating missing directory structure"
            sudo -u postgres mkdir -p $BACKUP_MOUNT_POINT/{repo,logs,archive}
        fi
    else
        log_info "No backup mount point found - checking for available devices"

        # Check if backup device exists but is not mounted
        if lsblk | grep -q "${BACKUP_DEVICE##*/}"; then
            log_info "Backup device ${BACKUP_DEVICE##*/} found - mounting it"

            # Check if volume needs formatting
            if ! sudo file -s $BACKUP_DEVICE | grep -q 'ext4'; then
                log_info "Formatting backup device..."
                sudo mkfs.ext4 $BACKUP_DEVICE
            fi

            # Create mount point and mount
            sudo mkdir -p $BACKUP_MOUNT_POINT
            sudo mount $BACKUP_DEVICE $BACKUP_MOUNT_POINT

            # Add to fstab for persistence
            if ! grep -q "$BACKUP_DEVICE" /etc/fstab; then
                echo "$BACKUP_DEVICE $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
            fi
        else
            # No device found - create and attach EBS volume if AWS credentials available
            log_warning "No dedicated backup device found"

            if aws sts get-caller-identity &>/dev/null; then
                log_info "AWS credentials available - creating EBS volume for backups"

                # Get instance details
                local instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
                local az=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

                if [[ -n "$instance_id" ]] && [[ -n "$az" ]]; then
                    log_info "Creating ${DEFAULT_BACKUP_VOLUME_SIZE}GB EBS volume in $az..."

                    # Create volume
                    local volume_id=$(aws ec2 create-volume \
                        --size "$DEFAULT_BACKUP_VOLUME_SIZE" \
                        --volume-type "gp3" \
                        --availability-zone "$az" \
                        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=pgbackrest-backup-$instance_id},{Key=Purpose,Value=pgbackrest-backup}]" \
                        --query 'VolumeId' \
                        --output text \
                        --region "$AWS_REGION" 2>/dev/null)

                    if [[ -n "$volume_id" ]] && [[ "$volume_id" != "None" ]]; then
                        log_success "Created volume: $volume_id"

                        # Wait for volume
                        aws ec2 wait volume-available --volume-ids "$volume_id" --region "$AWS_REGION"

                        # Attach volume
                        aws ec2 attach-volume \
                            --volume-id "$volume_id" \
                            --instance-id "$instance_id" \
                            --device "$BACKUP_DEVICE" \
                            --region "$AWS_REGION"

                        # Wait for attachment
                        log_info "Waiting for volume to attach..."
                        aws ec2 wait volume-in-use --volume-ids "$volume_id" --region "$AWS_REGION"

                        # Wait for device to appear
                        local device_path=""
                        for i in {1..30}; do
                            if [[ -b "$BACKUP_DEVICE" ]]; then
                                device_path="$BACKUP_DEVICE"
                                break
                            elif [[ -b "/dev/nvme1n1" ]]; then
                                device_path="/dev/nvme1n1"
                                BACKUP_DEVICE="/dev/nvme1n1"
                                break
                            fi
                            sleep 2
                        done

                        if [[ -n "$device_path" ]]; then
                            log_success "Device available at: $device_path"

                            # Format and mount
                            sudo mkfs.ext4 "$device_path"
                            sudo mkdir -p $BACKUP_MOUNT_POINT
                            sudo mount "$device_path" $BACKUP_MOUNT_POINT

                            # Add to fstab
                            local uuid=$(sudo blkid -s UUID -o value "$device_path")
                            echo "UUID=$uuid $BACKUP_MOUNT_POINT ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
                        else
                            log_error "Device did not appear after 60 seconds"
                            log_info "Using root filesystem as fallback"
                            sudo mkdir -p $BACKUP_MOUNT_POINT
                        fi
                    else
                        log_error "Failed to create EBS volume"
                        log_info "Using root filesystem as fallback"
                        sudo mkdir -p $BACKUP_MOUNT_POINT
                    fi
                else
                    log_error "Could not get instance metadata"
                    log_info "Using root filesystem as fallback"
                    sudo mkdir -p $BACKUP_MOUNT_POINT
                fi
            else
                log_warning "No AWS credentials available to create EBS volume"
                log_info "Using root filesystem for backup (not recommended for production)"
                log_info "To create a dedicated backup volume, either:"
                log_info "1. Set AWS credentials and re-run this script"
                log_info "2. Manually attach an EBS volume and mount at $BACKUP_MOUNT_POINT"
                sudo mkdir -p $BACKUP_MOUNT_POINT
            fi
        fi

        # Set permissions and create directory structure
        sudo chown -R postgres:postgres $BACKUP_MOUNT_POINT
        sudo chmod 750 $BACKUP_MOUNT_POINT
        sudo -u postgres mkdir -p $BACKUP_MOUNT_POINT/{repo,logs,archive}
    fi

    # Verify setup
    df -h $BACKUP_MOUNT_POINT
    ls -la $BACKUP_MOUNT_POINT/

    save_state "BACKUP_VOLUME_CONFIGURED" "true"
    log_success "Backup volume setup completed"
}

#===============================================================================
# Primary Server Configuration Management
#===============================================================================

get_next_available_repo_number() {
    # Check primary's pgBackRest config to find next available repo number
    local primary_ip="$1"
    local max_repo=0

    # Get existing repo configurations from primary
    local primary_config=$(ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 postgres@$primary_ip "cat /etc/pgbackrest/pgbackrest.conf 2>/dev/null" 2>/dev/null || echo "")

    if [[ -n "$primary_config" ]]; then
        # Find all repo configurations (repo1, repo2, etc.)
        local repo_nums=$(echo "$primary_config" | grep -oE '^repo[0-9]+-' | grep -oE '[0-9]+' | sort -n | uniq)

        if [[ -n "$repo_nums" ]]; then
            max_repo=$(echo "$repo_nums" | tail -1)
        fi
    fi

    # Return next available number
    echo $((max_repo + 1))
}

find_repo_for_standby() {
    # Check if this standby already has a repo configured on primary
    local primary_ip="$1"
    local standby_ip="$2"

    local primary_config=$(ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 postgres@$primary_ip "cat /etc/pgbackrest/pgbackrest.conf 2>/dev/null" 2>/dev/null || echo "")

    if [[ -n "$primary_config" ]]; then
        # Check each repo to see if it points to our standby
        for i in {1..10}; do
            if echo "$primary_config" | grep -q "repo${i}-host=$standby_ip"; then
                echo "$i"
                return
            fi
        done
    fi

    echo "0"  # Not found
}

configure_primary_for_multi_repo() {
    log_info "Configuring primary server for multi-repository setup..."

    local standby_ip=$(get_current_server_ip)
    local existing_repo=$(find_repo_for_standby "$PRIMARY_IP" "$standby_ip")

    if [[ "$existing_repo" != "0" ]]; then
        log_info "This standby already configured as repo$existing_repo on primary"
        save_state "STANDBY_REPO_NUMBER" "$existing_repo"
        return 0
    fi

    # Get next available repo number
    local repo_num=$(get_next_available_repo_number "$PRIMARY_IP")
    log_info "Configuring this standby as repo$repo_num on primary"

    # Get current primary config
    local primary_config=$(ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 postgres@$PRIMARY_IP "cat /etc/pgbackrest/pgbackrest.conf 2>/dev/null" || echo "")

    # Check if we need to create a new config or append to existing
    if [[ -z "$primary_config" ]] || ! echo "$primary_config" | grep -q "\[global\]"; then
        # Create new configuration
        log_info "Creating new pgBackRest configuration on primary"
        ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "cat > /etc/pgbackrest/pgbackrest.conf" << EOF
[$STANZA_NAME]
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

[global]
# Repository $repo_num - Standby at $standby_ip
repo${repo_num}-host-user=postgres
repo${repo_num}-host=$standby_ip
repo${repo_num}-path=$BACKUP_MOUNT_POINT/repo${repo_num}
repo${repo_num}-retention-full=4
repo${repo_num}-retention-diff=3
repo${repo_num}-retention-archive=10

process-max=12
start-fast=y
stop-auto=y
delta=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=/backup/pgbackrest/logs
EOF
    else
        # Append new repository to existing config
        log_info "Adding repository configuration to existing primary config"

        # Create a temporary file with the new repo config
        local new_repo_config="
# Repository $repo_num - Standby at $standby_ip
repo${repo_num}-host-user=postgres
repo${repo_num}-host=$standby_ip
repo${repo_num}-path=$BACKUP_MOUNT_POINT/repo${repo_num}
repo${repo_num}-retention-full=4
repo${repo_num}-retention-diff=3
repo${repo_num}-retention-archive=10"

        # Insert the new repo config into the [global] section
        ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "cp /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf.bak && \
            awk '/^\[global\]/ {print; print \"$new_repo_config\"; next} {print}' /etc/pgbackrest/pgbackrest.conf.bak > /etc/pgbackrest/pgbackrest.conf"
    fi

    # Verify configuration
    log_info "Verifying primary configuration..."
    ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "pgbackrest --stanza=$STANZA_NAME --repo=$repo_num check 2>&1" || true

    save_state "STANDBY_REPO_NUMBER" "$repo_num"
    log_success "Primary configured with repo$repo_num for this standby"

    # Reload PostgreSQL configuration if archive_command needs updating
    local current_archive_cmd=$(ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -t -c 'show archive_command;' 2>/dev/null" | xargs)
    if [[ ! "$current_archive_cmd" =~ "pgbackrest" ]]; then
        log_info "Updating PostgreSQL archive_command on primary"
        ssh -i /home/postgres/.ssh/id_rsa -o StrictHostKeyChecking=no postgres@$PRIMARY_IP "psql -c \"ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=$STANZA_NAME archive-push %p';\" && \
                                   psql -c 'SELECT pg_reload_conf();'"
    fi
}

#===============================================================================
# Step 2: Install and Configure pgBackRest on Standby
#===============================================================================

configure_pgbackrest_standby() {
    log "=== STEP 2: Configuring pgBackRest on standby ==="

    # Install pgBackRest if not already installed
    if ! command -v pgbackrest &> /dev/null; then
        log_info "Installing pgBackRest..."

        # Install build dependencies
        sudo yum install -y gcc postgresql${PG_VERSION}-devel openssl-devel \
            libxml2-devel lz4-devel libzstd-devel bzip2-devel libyaml-devel \
            python3-pip wget

        # Install meson and ninja
        sudo pip3 install meson ninja

        # Download and build pgBackRest
        cd /tmp
        wget -O - https://github.com/pgbackrest/pgbackrest/archive/release/2.55.1.tar.gz | tar zx
        cd pgbackrest-release-2.55.1
        meson setup build
        ninja -C build
        sudo cp build/src/pgbackrest /usr/bin/
        sudo chmod 755 /usr/bin/pgbackrest
        pgbackrest version

        # Cleanup
        cd /
        rm -rf /tmp/pgbackrest-release-2.55.1
    else
        log_info "pgBackRest already installed"
        pgbackrest version
    fi

    # Create pgBackRest directories
    sudo mkdir -p /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
    sudo chown postgres:postgres /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest

    # Configure primary server for multi-repository setup
    configure_primary_for_multi_repo

    # Get the repository number assigned to this standby
    local repo_num="${STANDBY_REPO_NUMBER:-1}"

    # Create the repo directory for this standby
    sudo -u postgres mkdir -p $BACKUP_MOUNT_POINT/repo${repo_num}

    # Configure pgBackRest for standby backup
    log_info "Creating pgBackRest configuration for standby backup (using repo$repo_num)..."
    sudo -u postgres tee /etc/pgbackrest/pgbackrest.conf << EOF
[$STANZA_NAME]
# Local standby server
pg1-path=$PG_DATA_DIR
pg1-port=5432
pg1-socket-path=/tmp

# Primary server (required for standby backups)
pg2-host=$PRIMARY_IP
pg2-path=$PG_DATA_DIR
pg2-port=5432
pg2-host-user=postgres
pg2-socket-path=/tmp

# Standby-specific settings
backup-standby=y
delta=y

[global]
# This standby's repository (local repo1, mapped to repo$repo_num on primary)
repo1-path=$BACKUP_MOUNT_POINT/repo${repo_num}
repo1-retention-full=4
repo1-retention-diff=3
repo1-retention-archive=10

process-max=8
start-fast=y
stop-auto=y
compress-type=zst
compress-level=3
log-level-console=info
log-level-file=detail
log-path=$BACKUP_MOUNT_POINT/logs

# Archive settings
archive-get-queue-max=128MB
archive-push-queue-max=128MB
EOF

    save_state "PGBACKREST_CONFIGURED" "true"
    log_success "pgBackRest configuration completed"
}

#===============================================================================
# Step 3: Create Stanza and Take Backup from Standby
#===============================================================================

create_stanza_and_backup() {
    local backup_type=$(determine_backup_type)

    if [[ "$backup_type" == "skip" ]]; then
        log "=== STEP 3: Skipping backup creation (SKIP_BACKUP=true) ==="
        log_info "Using existing backups"

        # Show current backup information
        sudo -u postgres pgbackrest --stanza=$STANZA_NAME info 2>/dev/null || true

        save_state "INITIAL_BACKUP_COMPLETED" "true"
        return
    fi

    log "=== STEP 3: Creating stanza and taking $backup_type backup from standby ==="

    # Get the repository number for this standby
    local repo_num="${STANDBY_REPO_NUMBER:-1}"

    # Create stanza if it doesn't exist
    log_info "Creating pgBackRest stanza for repo$repo_num..."
    if ! sudo -u postgres pgbackrest --stanza=$STANZA_NAME stanza-create 2>/dev/null; then
        log_info "Stanza already exists or creation skipped"
    fi

    # Get the repository number for this standby
    local repo_num="${STANDBY_REPO_NUMBER:-1}"

    # Take backup from standby
    log_info "Taking $backup_type backup from standby server (repo$repo_num on primary)..."
    log_warning "Note: Standby backups may take longer than primary backups"

    if sudo -u postgres pgbackrest --stanza=$STANZA_NAME --type=$backup_type backup; then
        log_success "$backup_type backup completed from standby"
    else
        log_error "Backup failed - check pgBackRest logs in $BACKUP_MOUNT_POINT/logs"
        log_error "You may need to check:"
        log_error "  1. WAL archiving is working from primary to this standby"
        log_error "  2. SSH connectivity between primary and standby"
        log_error "  3. Repository permissions on this standby"
        return 1
    fi

    # Verify backup
    log_info "Verifying backup..."
    sudo -u postgres pgbackrest --stanza=$STANZA_NAME info

    save_state "INITIAL_BACKUP_COMPLETED" "true"
    save_state "LAST_BACKUP_TYPE" "$backup_type"
    save_state "LAST_BACKUP_DATE" "\"$(date '+%Y-%m-%d %H:%M:%S')\""
    save_state "BACKUP_FROM_STANDBY" "true"
}

#===============================================================================
# Step 4: Create EBS Snapshot of Standby Backup Volume
#===============================================================================

create_ebs_snapshot() {
    if [[ "$SKIP_SNAPSHOT" == "true" ]]; then
        log_info "Snapshot creation skipped (SKIP_SNAPSHOT=true)"
        return 0
    fi

    log "=== STEP 4: Creating EBS snapshot of standby backup volume ==="

    # Check if we're using a dedicated backup device
    local mount_source=$(mount | grep "$BACKUP_MOUNT_POINT" | awk '{print $1}')

    if [[ -z "$mount_source" ]] || [[ ! "$mount_source" =~ ^/dev/ ]]; then
        log_warning "Backup is on root filesystem - cannot create EBS snapshot"
        log_info "Attach a dedicated EBS volume for snapshot capability"
        save_state "SNAPSHOT_AVAILABLE" "false"
        return 0
    fi

    # Get instance ID using IMDSv2
    local token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    local instance_id=$(curl -H "X-aws-ec2-metadata-token: $token" -s http://169.254.169.254/latest/meta-data/instance-id)

    if [[ -z "$instance_id" ]]; then
        log_error "Could not retrieve instance ID"
        return 1
    fi

    log_info "Instance ID: $instance_id"

    # Check if volume ID is manually provided (for cases with limited IAM permissions)
    if [[ -n "${MANUAL_BACKUP_VOLUME_ID:-}" ]]; then
        BACKUP_VOLUME_ID="$MANUAL_BACKUP_VOLUME_ID"
        log_info "Using manually provided volume ID: $BACKUP_VOLUME_ID"
    else
        # Get volume ID for the backup device
        BACKUP_VOLUME_ID=$(aws ec2 describe-volumes \
        --filters "Name=attachment.instance-id,Values=$instance_id" \
        --query "Volumes[?Attachments[?Device=='$mount_source']].VolumeId | [0]" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)

    # Try alternative device mappings if not found
    if [[ "$BACKUP_VOLUME_ID" == "None" ]] || [[ -z "$BACKUP_VOLUME_ID" ]] || [[ "$BACKUP_VOLUME_ID" == "null" ]]; then
        log_info "Direct device lookup failed for $mount_source, trying alternative mappings..."
        for alt_device in "/dev/xvdb" "/dev/sdb" "/dev/nvme1n1"; do
            log_info "Trying AWS device mapping: $alt_device"
            BACKUP_VOLUME_ID=$(aws ec2 describe-volumes \
                --filters "Name=attachment.device,Values=$alt_device" \
                          "Name=attachment.instance-id,Values=$instance_id" \
                --query 'Volumes[0].VolumeId' \
                --output text \
                --region "$AWS_REGION" 2>/dev/null)

            if [[ "$BACKUP_VOLUME_ID" != "None" ]] && [[ -n "$BACKUP_VOLUME_ID" ]] && [[ "$BACKUP_VOLUME_ID" != "null" ]]; then
                log_info "Found backup volume using alternative device mapping: $alt_device -> $BACKUP_VOLUME_ID"
                break
            fi
        done
    fi
    fi

    if [[ "$BACKUP_VOLUME_ID" == "None" ]] || [[ -z "$BACKUP_VOLUME_ID" ]]; then
        log_error "Could not determine backup volume ID"
        return 1
    fi

    log_info "Backup Volume ID: $BACKUP_VOLUME_ID"

    # Create snapshot with standby-specific tags
    local backup_type="${LAST_BACKUP_TYPE:-full}"
    local day_name=$(date +%A)
    local snapshot_desc="pgbackrest-standby-$STANZA_NAME-$backup_type-$(date +%Y%m%d-%H%M%S)"

    SNAPSHOT_ID=$(aws ec2 create-snapshot \
        --volume-id "$BACKUP_VOLUME_ID" \
        --description "$snapshot_desc" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$snapshot_desc},{Key=BackupType,Value=$backup_type},{Key=Stanza,Value=$STANZA_NAME},{Key=Source,Value=standby},{Key=SourceIP,Value=$STANDBY_IP},{Key=Day,Value=$day_name}]" \
        --query 'SnapshotId' \
        --output text \
        --region "$AWS_REGION")

    if [[ -z "$SNAPSHOT_ID" ]] || [[ "$SNAPSHOT_ID" == "None" ]]; then
        log_error "Failed to create snapshot"
        return 1
    fi

    log_info "Snapshot created: $SNAPSHOT_ID"

    # Save snapshot info to state file
    save_state "BACKUP_VOLUME_ID" "$BACKUP_VOLUME_ID"
    save_state "LATEST_SNAPSHOT_ID" "$SNAPSHOT_ID"
    save_state "LAST_SNAPSHOT_DATE" "\"$(date '+%Y-%m-%d %H:%M:%S')\""
    save_state "SNAPSHOT_AVAILABLE" "true"

    # In setup mode, wait for completion
    if [[ "$BACKUP_MODE" == "setup" ]] || [[ "$SCHEDULED_MODE" == "false" ]]; then
        log "Waiting for snapshot to complete..."
        aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID" --region "$AWS_REGION"
        log_success "Snapshot completed: $SNAPSHOT_ID"
    else
        log_info "Snapshot creation initiated: $SNAPSHOT_ID (completion in background)"
    fi

    # Cleanup old snapshots if enabled
    if [[ "$CLEANUP_OLD_SNAPSHOTS" == "true" ]]; then
        cleanup_old_snapshots
    fi
}

#===============================================================================
# Step 5: Cleanup Old Snapshots
#===============================================================================

cleanup_old_snapshots() {
    if [[ "$CLEANUP_OLD_SNAPSHOTS" != "true" ]]; then
        return 0
    fi

    log "=== Cleaning up old standby snapshots ==="

    # Keep only last 7 days of daily snapshots
    local retention_days=7
    local cutoff_date=$(date -d "${retention_days} days ago" '+%Y-%m-%d')

    local old_snapshots=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Source,Values=standby" \
                  "Name=tag:Stanza,Values=${STANZA_NAME}" \
        --query "Snapshots[?StartTime<='${cutoff_date}'].SnapshotId" \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)

    local deleted_count=0
    for snapshot in $old_snapshots; do
        if [ -n "$snapshot" ] && [ "$snapshot" != "None" ]; then
            log_info "Deleting old snapshot: $snapshot"
            if aws ec2 delete-snapshot --snapshot-id "$snapshot" --region "$AWS_REGION" 2>/dev/null; then
                ((deleted_count++))
            fi
        fi
    done

    # Keep only last 4 weekly full backups
    if [[ "$(date +%u)" == "7" ]]; then  # Sunday
        local old_weekly=$(aws ec2 describe-snapshots \
            --owner-ids self \
            --filters "Name=tag:Source,Values=standby" \
                      "Name=tag:BackupType,Values=full" \
                      "Name=tag:Stanza,Values=${STANZA_NAME}" \
            --query "Snapshots | sort_by(@, &StartTime) | [:-4].SnapshotId" \
            --output text \
            --region "$AWS_REGION" 2>/dev/null)

        for snapshot in $old_weekly; do
            if [ -n "$snapshot" ] && [ "$snapshot" != "None" ]; then
                log_info "Deleting old weekly snapshot: $snapshot"
                if aws ec2 delete-snapshot --snapshot-id "$snapshot" --region "$AWS_REGION" 2>/dev/null; then
                    ((deleted_count++))
                fi
            fi
        done
    fi

    if [ $deleted_count -gt 0 ]; then
        log_success "Cleaned up $deleted_count old snapshots"
    else
        log_info "No old snapshots to clean up"
    fi
}

#===============================================================================
# Setup Periodic Snapshots
#===============================================================================

setup_periodic_snapshots() {
    log "=== Setting up periodic snapshots from standby ==="

    if [[ "$SETUP_PERIODIC_SNAPSHOTS" != "true" ]]; then
        log_info "Periodic snapshots disabled"
        return 0
    fi

    # Create scheduled backup script
    cat > "${SCRIPT_DIR}/scheduled_standby_backup.sh" << 'EOF'
#!/bin/bash
# Scheduled standby backup wrapper script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/pgbackrest_standby_backup_state.env"

# Source the state file to get configuration
if [ -f "${STATE_FILE}" ]; then
    source "${STATE_FILE}"
fi

# Set environment variables for scheduled execution
export BACKUP_MODE="auto"
export CLEANUP_OLD_SNAPSHOTS="true"

# Log file with date
LOG_FILE="/var/log/pgbackrest_standby_scheduled_$(date +%Y%m%d_%H%M%S).log"

echo "$(date): Starting scheduled standby backup execution" | tee -a "$LOG_FILE"

# Execute the main script
"${SCRIPT_DIR}/pgbackrest_standby_backup_setup.sh" --scheduled >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "$(date): Scheduled standby backup completed successfully" | tee -a "$LOG_FILE"
else
    echo "$(date): Scheduled standby backup failed with exit code $EXIT_CODE" | tee -a "$LOG_FILE"
fi

exit $EXIT_CODE
EOF

    chmod +x "${SCRIPT_DIR}/scheduled_standby_backup.sh"

    log_info "Scheduled backup script created: ${SCRIPT_DIR}/scheduled_standby_backup.sh"
    log_info ""
    log_info "To enable automatic backups from standby, add to crontab:"
    log_info "  # Daily backup from standby at 3 AM (full on Sunday, incremental Mon-Sat)"
    log_info "  0 3 * * * ${SCRIPT_DIR}/scheduled_standby_backup.sh"

    save_state "PERIODIC_SNAPSHOTS_CONFIGURED" "true"
    log_success "Periodic snapshot setup completed"
}

#===============================================================================
# Summary
#===============================================================================

show_summary() {
    log "=== STANDBY BACKUP SETUP COMPLETED SUCCESSFULLY! ==="
    echo
    log_info "=== CONFIGURATION SUMMARY ==="
    log_info "Primary Server: $PRIMARY_IP"
    log_info "Standby Server: $STANDBY_IP (this server)"
    log_info "PostgreSQL Version: $PG_VERSION"
    log_info "Stanza Name: $STANZA_NAME"
    log_info "Backup Location: $BACKUP_MOUNT_POINT"

    if [ -n "${BACKUP_VOLUME_ID:-}" ]; then
        log_info "Backup Volume: $BACKUP_VOLUME_ID"
    fi

    if [ -n "${SNAPSHOT_ID:-}" ]; then
        log_info "Latest Snapshot: $SNAPSHOT_ID"
    fi

    echo
    log_info "=== REPMGR CLUSTER STATUS ==="
    if [ -f "$REPMGR_BIN" ]; then
        sudo -u postgres $REPMGR_BIN -f /var/lib/pgsql/repmgr.conf cluster show
    else
        log_info "repmgr not available for cluster status"
    fi

    echo
    log_info "=== STATE FILE ==="
    log_info "Configuration saved to: $STATE_FILE"
    log_info "This file is needed for pgbackrest_standby_setup.sh"
    echo
    log_info "=== NEXT STEPS ==="
    log_info "1. Use this snapshot to create new standbys:"
    log_info "   ./pgbackrest_standby_setup.sh --state-file $STATE_FILE"
    echo
    log_info "2. Enable scheduled backups (optional):"
    log_info "   echo '0 3 * * * ${SCRIPT_DIR}/scheduled_standby_backup.sh' | crontab -"
    echo
    local repo_num="${STANDBY_REPO_NUMBER:-1}"
    log_info "3. Monitor backup status:"
    log_info "   sudo -u postgres pgbackrest --stanza=$STANZA_NAME info"
    echo
    log_info "=== IMPORTANT NOTES ==="
    log_info "- Backups are taken from standby to reduce primary load"
    log_info "- Standby backups may take longer than primary backups"
    log_info "- EBS snapshots are tagged with 'Source=standby' for identification"
    log_info "- Snapshots can be used to quickly create new standby servers"
    echo
    log_success "Log saved to: $LOG_FILE"
}

#===============================================================================
# Usage Information
#===============================================================================

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "This script sets up pgBackRest backups on a STANDBY server and creates"
    echo "EBS snapshots that can be used to launch new standby servers."
    echo
    echo "Options:"
    echo "  --scheduled         Run in scheduled/cron mode (non-interactive)"
    echo "  --help              Show this help message"
    echo
    echo "Environment Variables:"
    echo "  PRIMARY_IP          Primary server IP (default: $DEFAULT_PRIMARY_IP)"
    echo "  STANDBY_IP          Standby IP where backups run (default: $DEFAULT_STANDBY_IP)"
    echo "  PG_VERSION          PostgreSQL version (default: $DEFAULT_PG_VERSION)"
    echo "  STANZA_NAME         pgBackRest stanza name (default: $DEFAULT_STANZA_NAME)"
    echo "  AWS_REGION          AWS region (default: $DEFAULT_AWS_REGION)"
    echo
    echo "Backup Control:"
    echo "  BACKUP_MODE         auto, full, incr, skip (default: auto)"
    echo "  FORCE_FULL_BACKUP   Force full backup (default: false)"
    echo "  SKIP_BACKUP         Skip backup, only snapshot (default: false)"
    echo "  SKIP_SNAPSHOT       Skip snapshot creation (default: false)"
    echo
    echo "Examples:"
    echo "  # Initial setup on standby"
    echo "  $0"
    echo
    echo "  # Scheduled execution (for cron)"
    echo "  $0 --scheduled"
    echo
    echo "  # Force full backup"
    echo "  FORCE_FULL_BACKUP=true $0"
    echo
    echo "After running this script, use the created snapshots with:"
    echo "  ./pgbackrest_standby_setup.sh --state-file $STATE_FILE"
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    local scheduled_mode=false
    local interactive_mode=true

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --scheduled)
                scheduled_mode=true
                interactive_mode=false
                SCHEDULED_MODE=true
                BACKUP_MODE="${BACKUP_MODE:-auto}"
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Print header
    if [[ "$interactive_mode" == "true" ]]; then
        echo -e "${CYAN}"
        echo "==============================================================================="
        echo "  pgBackRest Standby Backup Setup Script"
        echo "==============================================================================="
        echo -e "${NC}"
    fi

    # Load existing state
    load_state

    # Show configuration
    if [[ "$interactive_mode" == "true" ]]; then
        log_info "Configuration:"
        log_info "  Primary IP: $PRIMARY_IP"
        log_info "  Standby IP: $STANDBY_IP (this server)"
        log_info "  PostgreSQL Version: $PG_VERSION"
        log_info "  Stanza Name: $STANZA_NAME"
        log_info "  AWS Region: $AWS_REGION"
        log_info "  Backup Mode: $BACKUP_MODE"
        echo

        # Confirmation
        read -p "Do you want to proceed with standby backup setup? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log_info "Setup cancelled"
            exit 0
        fi
    else
        log_info "=== SCHEDULED STANDBY BACKUP EXECUTION ==="
        log_info "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        log_info "Backup Mode: $BACKUP_MODE"
    fi

    # Execute setup steps
    check_prerequisites

    # Run setup or just backup based on state
    if should_run_setup; then
        # Full setup mode
        setup_backup_volume
        configure_pgbackrest_standby
        create_stanza_and_backup
        create_ebs_snapshot

        if [[ "$interactive_mode" == "true" ]]; then
            setup_periodic_snapshots
            show_summary
        fi
    else
        # Scheduled backup mode - only run backup and snapshot
        log_info "=== SCHEDULED BACKUP EXECUTION ==="
        create_stanza_and_backup
        create_ebs_snapshot

        if [[ "$interactive_mode" == "true" ]]; then
            show_summary
        else
            log_success "Scheduled standby backup completed"
            log_info "Snapshot: ${SNAPSHOT_ID:-none}"
        fi
    fi

    log_success "Execution completed successfully!"
}

# Execute main function
main "$@"
