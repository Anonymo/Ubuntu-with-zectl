#!/usr/bin/env bash

#############################################################
# zectl Helper Script
# 
# Convenient wrapper for common zectl operations
#############################################################

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Script version
readonly VERSION="1.0.0"

usage() {
    cat <<EOF
zectl Helper Script v${VERSION}

Usage: $(basename "$0") [command] [options]

Commands:
    create-safe <name>      Create BE with automatic snapshot
    upgrade                 System upgrade with automatic BE creation
    rollback [name]        Rollback to previous BE or specified BE
    cleanup [days]         Remove BEs older than N days (default: 30)
    backup <be> [file]     Backup a BE to file
    restore <file> [name]  Restore BE from backup file
    status                 Show BE status and disk usage
    history                Show BE creation history
    
Options:
    -h, --help            Show this help message
    -v, --version         Show version information
    -y, --yes             Skip confirmation prompts

Examples:
    $(basename "$0") create-safe pre-update
    $(basename "$0") upgrade
    $(basename "$0") rollback
    $(basename "$0") cleanup 7
    $(basename "$0") backup current /backup/current-be.zfs
    
EOF
}

error() {
    echo -e "${RED}Error: $*${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}✓ $*${NC}"
}

warning() {
    echo -e "${YELLOW}⚠ $*${NC}"
}

confirm() {
    if [[ "${SKIP_CONFIRM:-false}" == "true" ]]; then
        return 0
    fi
    
    local prompt="$1"
    read -rp "${prompt} [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This operation requires root privileges. Please run with sudo."
    fi
}

check_zectl() {
    if ! command -v zectl &> /dev/null; then
        error "zectl is not installed or not in PATH"
    fi
}

# Detect root pool name (env override or smart detection)
get_pool_name() {
    if [[ -n "${POOL_NAME:-}" ]]; then
        echo "${POOL_NAME}"
        return
    fi
    
    # Smart detection: prefer pool containing ROOT datasets
    local pools root_pool
    pools=$(zpool list -H -o name 2>/dev/null)
    
    for pool in $pools; do
        if zfs list -H -o name "${pool}/ROOT" 2>/dev/null | grep -q "^${pool}/ROOT$"; then
            root_pool="$pool"
            break
        fi
    done
    
    # Fallback to first pool if no ROOT dataset found
    echo "${root_pool:-$(echo "$pools" | head -1)}"
}

# Root dataset path helper
dataset_root() {
    local pool
    pool=$(get_pool_name)
    [[ -n "$pool" ]] && echo "$pool/ROOT"
}

get_current_be() {
    check_zectl
    zectl list -p 2>/dev/null | grep -E '^NR' | cut -d$'\t' -f1 | head -1
}

create_safe() {
    local be_name="${1:-}"
    check_zectl
    
    if [[ -z "$be_name" ]]; then
        be_name="manual-$(date +%Y%m%d-%H%M%S)"
    fi
    
    echo "Creating new boot environment: $be_name"
    
    # Validate BE name
    if [[ ! "$be_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        error "Invalid boot environment name. Use only letters, numbers, dots, underscores, and hyphens."
    fi
    
    # Create snapshot of current BE first
    local current_be=$(get_current_be)
    if [[ -n "$current_be" ]]; then
        local snapshot_name="backup-$(date +%Y%m%d-%H%M%S)"
        if zectl snapshot "${current_be}@${snapshot_name}" 2>/dev/null; then
            success "Created backup snapshot: ${current_be}@${snapshot_name}"
        else
            warning "Failed to create backup snapshot, but continuing..."
        fi
    fi
    
    # Create new BE
    if zectl create "$be_name" 2>/dev/null; then
        success "Created boot environment: $be_name"
    else
        error "Failed to create boot environment: $be_name"
    fi
    
    # Show current BEs
    echo -e "\nCurrent boot environments:"
    zectl list 2>/dev/null || warning "Failed to list boot environments"
}

system_upgrade() {
    check_root
    check_zectl
    echo "Preparing for system upgrade..."
    
    # Create pre-upgrade BE
    local be_name="pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    local current_be=$(get_current_be)
    
    if [[ -z "$current_be" ]]; then
        error "Cannot determine current boot environment"
    fi
    
    # Create snapshot
    if zectl snapshot "${current_be}@${be_name}" 2>/dev/null; then
        success "Created snapshot: ${current_be}@${be_name}"
    else
        error "Failed to create pre-upgrade snapshot"
    fi
    
    # Create new BE for upgrade
    local upgrade_be="upgrade-$(date +%Y%m%d-%H%M%S)"
    if zectl create -e "$current_be" "$upgrade_be" 2>/dev/null; then
        success "Created upgrade environment: $upgrade_be"
    else
        error "Failed to create upgrade environment"
    fi
    
    # Activate new BE
    if zectl activate "$upgrade_be" 2>/dev/null; then
        success "Activated: $upgrade_be"
    else
        error "Failed to activate upgrade environment"
    fi
    
    echo -e "\n${GREEN}Ready for upgrade!${NC}"
    echo "The new boot environment '$upgrade_be' is active."
    echo "Run your system upgrade commands now."
    echo "If upgrade fails, you can rollback with: $0 rollback $current_be"
    
    if confirm "Proceed with system upgrade (apt upgrade)?"; then
        if apt update && apt upgrade -y; then
            success "System upgrade completed"
            echo "Reboot to use the upgraded environment"
        else
            warning "System upgrade encountered issues. You may want to rollback."
        fi
    fi
}

rollback_be() {
    local target_be="${1:-}"
    check_zectl
    
    if [[ -z "$target_be" ]]; then
        # Get previous BE (more robust method)
        local be_list
        if ! be_list=$(zectl list -p 2>/dev/null); then
            error "Failed to get boot environments list"
        fi
        
        target_be=$(echo "$be_list" | grep -v -E '^\s*N' | head -1 | awk '{print $1}')
        
        if [[ -z "$target_be" ]]; then
            error "No previous boot environment found"
        fi
        
        echo "Auto-selected previous BE: $target_be"
    fi
    
    echo "Rolling back to: $target_be"
    
    # Verify BE exists
    if ! zectl list -p 2>/dev/null | grep -q "^${target_be}\s"; then
        error "Boot environment '$target_be' not found"
    fi
    
    if confirm "Activate '$target_be' and reboot?"; then
        if zectl activate "$target_be" 2>/dev/null; then
            success "Activated: $target_be"
            
            if confirm "Reboot now?"; then
                systemctl reboot
            else
                echo "Remember to reboot to complete the rollback"
            fi
        else
            error "Failed to activate boot environment: $target_be"
        fi
    fi
}

cleanup_old_bes() {
    local days="${1:-30}"
    check_root
    check_zectl
    
    local current_be=$(get_current_be)
    local current_date=$(date +%s)
    
    echo "Cleaning up boot environments older than $days days..."
    
    # Get BE list with machine-readable parsing (much more reliable)
    local be_list
    if ! be_list=$(zectl list -p 2>/dev/null); then
        warning "Failed to get machine-readable BE list, falling back to regular format"
        if ! be_list=$(zectl list -p 2>/dev/null); then
            error "Failed to get boot environments list"
        fi
    fi
    
    while IFS= read -r line; do
        # Skip empty lines and header
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^Name ]] && continue
        
        local be_name=$(echo "$line" | awk '{print $1}')
        
        # Skip current BE and invalid names
        if [[ "$be_name" == "$current_be" ]] || [[ -z "$be_name" ]]; then
            continue
        fi
        
        # Try to get creation time from ZFS properties (more reliable)
        local be_date=0
        local ds_root
        ds_root=$(dataset_root)
        local zfs_dataset="${ds_root}/${be_name}"
        
        if zfs list "$zfs_dataset" &>/dev/null; then
            # Get creation property from ZFS (Unix timestamp)
            local creation_prop=$(zfs get -H -o value creation "$zfs_dataset" 2>/dev/null || echo "")
            
            if [[ -n "$creation_prop" ]]; then
                # Convert ZFS creation time to epoch seconds
                be_date=$(date -d "$creation_prop" +%s 2>/dev/null || echo 0)
            fi
        fi
        
        # Fallback to parsing zectl output if ZFS method failed
        if [[ $be_date -eq 0 ]]; then
            local creation_str=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}')
            be_date=$(date -d "$creation_str" +%s 2>/dev/null || echo 0)
        fi
        
        if [[ $be_date -gt 0 ]]; then
            local age_days=$(( (current_date - be_date) / 86400 ))
            
            if [[ $age_days -gt $days ]]; then
                if confirm "Delete '$be_name' (${age_days} days old)?"; then
                    if zectl destroy "$be_name" 2>/dev/null; then
                        success "Deleted: $be_name"
                    else
                        warning "Failed to delete: $be_name"
                    fi
                fi
            fi
        else
            warning "Could not determine creation date for: $be_name (skipping)"
        fi
    done <<< "$be_list"
    
    success "Cleanup completed"
}

backup_be() {
    local be_name="${1:-}"
    local backup_file="${2:-}"
    
    if [[ -z "$be_name" ]]; then
        be_name=$(get_current_be)
    fi
    
    if [[ -z "$backup_file" ]]; then
        backup_file="${be_name}-$(date +%Y%m%d-%H%M%S).zfs.gz"
    fi
    
    echo "Backing up '$be_name' to '$backup_file'..."
    
    # Get the dataset path
    local ds_root
    ds_root=$(dataset_root)
    local dataset="${ds_root}/${be_name}"
    
    # Create snapshot for backup
    local snapshot="${dataset}@backup-$(date +%Y%m%d-%H%M%S)"
    zfs snapshot "$snapshot"
    
    # Send to file
    zfs send "$snapshot" | gzip > "$backup_file"
    
    # Remove temporary snapshot
    zfs destroy "$snapshot"
    
    success "Backup saved to: $backup_file"
    echo "Size: $(du -h "$backup_file" | cut -f1)"
}

restore_be() {
    local backup_file="$1"
    local be_name="${2:-restored-$(date +%Y%m%d-%H%M%S)}"
    
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
    fi
    
    echo "Restoring from '$backup_file' as '$be_name'..."
    
    # Receive the backup
    gunzip -c "$backup_file" | zfs receive -F "rpool/ROOT/${be_name}"
    
    success "Restored boot environment: $be_name"
    
    if confirm "Activate restored environment?"; then
        zectl activate "$be_name"
        success "Activated: $be_name"
        echo "Reboot to use the restored environment"
    fi
}

show_status() {
    echo -e "${GREEN}Boot Environment Status${NC}"
    echo "========================"
    
    # Show current BE
    local current_be=$(get_current_be)
    echo -e "Current BE: ${GREEN}${current_be}${NC}\n"
    
    # Show all BEs
    echo "All Boot Environments:"
    zectl list
    
    # Show disk usage
    echo -e "\n${GREEN}Disk Usage${NC}"
    echo "==========="
    local ds_root
    ds_root=$(dataset_root)
    zfs list -o name,used,avail,refer,mountpoint -t filesystem -r "$ds_root"
    
    # Show snapshots
    echo -e "\n${GREEN}Snapshots${NC}"
    echo "=========="
    zfs list -t snapshot -o name,used,creation -r "$ds_root" | head -20
    
    local snapshot_count=$(zfs list -t snapshot -r "$ds_root" | wc -l)
    if [[ $snapshot_count -gt 20 ]]; then
        echo "... and $((snapshot_count - 20)) more snapshots"
    fi
}

show_history() {
    echo -e "${GREEN}Boot Environment History${NC}"
    echo "========================"
    
    # Show BE creation times
    while IFS= read -r line; do
        local be_name=$(echo "$line" | awk '{print $1}')
        local active=$(echo "$line" | awk '{print $2}')
        local creation=$(echo "$line" | awk '{print $4, $5, $6, $7}')
        
        if [[ "$active" == "NR" ]]; then
            echo -e "${GREEN}* ${be_name}${NC} - ${creation} [ACTIVE]"
        elif [[ "$active" == "R" ]]; then
            echo -e "  ${be_name} - ${creation} [NEXT BOOT]"
        else
            echo -e "  ${be_name} - ${creation}"
        fi
    done < <(zectl list -p | tail -n +2)
    
    # Show recent snapshots
    echo -e "\n${GREEN}Recent Snapshots${NC}"
    echo "================"
    local ds_root
    ds_root=$(dataset_root)
    zfs list -t snapshot -o name,creation -r "$ds_root" -s creation | tail -10
}

# Parse arguments
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
            echo "zectl Helper Script v${VERSION}"
            exit 0
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        create-safe)
            shift
            create_safe "$@"
            exit 0
            ;;
        upgrade)
            shift
            system_upgrade
            exit 0
            ;;
        rollback)
            shift
            rollback_be "$@"
            exit 0
            ;;
        cleanup)
            shift
            cleanup_old_bes "$@"
            exit 0
            ;;
        backup)
            shift
            backup_be "$@"
            exit 0
            ;;
        restore)
            shift
            restore_be "$@"
            exit 0
            ;;
        status)
            show_status
            exit 0
            ;;
        history)
            show_history
            exit 0
            ;;
        *)
            error "Unknown command: $1"
            ;;
    esac
done

# If no arguments, show usage
usage
