#!/usr/bin/env bash

#############################################################
# zectl Manager Module
# 
# Provides boot environment management functionality
# using zectl for ZFS-based Ubuntu systems
#############################################################

set -euo pipefail

# Boot environment configuration
readonly BE_ROOT_DATASET="${POOL_NAME}/ROOT"
readonly BE_SNAPSHOT_PREFIX="auto"
readonly BE_MAX_SNAPSHOTS=10

#############################################################
# Boot Environment Functions
#############################################################

setup_zectl() {
    local chroot_path="${1:-/mnt}"
    
    log INFO "Setting up zectl boot environment management..."
    
    cat > "${chroot_path}/tmp/setup_zectl.sh" <<'SCRIPT'
#!/bin/bash
set -e

# Install dependencies
apt-get update
apt-get install -y python3 python3-pip python3-setuptools git

# Clone and install zectl
cd /tmp
git clone https://github.com/johnramsden/zectl
cd zectl
python3 setup.py install

# Configure zectl for systemd-boot
zectl set bootloader=systemd-boot

# Set default properties
zectl set org.zectl:bootloader=systemd-boot
zectl set org.zectl:ESP=/boot/efi

echo "zectl setup complete"
SCRIPT
    
    chmod +x "${chroot_path}/tmp/setup_zectl.sh"
    chroot "${chroot_path}" /tmp/setup_zectl.sh
    rm -f "${chroot_path}/tmp/setup_zectl.sh"
}

create_boot_environment() {
    local be_name="$1"
    local description="${2:-}"
    
    log INFO "Creating boot environment: ${be_name}"
    
    if [[ -n "${description}" ]]; then
        zectl create -d "${description}" "${be_name}"
    else
        zectl create "${be_name}"
    fi
}

activate_boot_environment() {
    local be_name="$1"
    
    log INFO "Activating boot environment: ${be_name}"
    zectl activate "${be_name}"
}

list_boot_environments() {
    log INFO "Listing boot environments:"
    zectl list
}

delete_boot_environment() {
    local be_name="$1"
    local force="${2:-false}"
    
    log INFO "Deleting boot environment: ${be_name}"
    
    if [[ "${force}" == "true" ]]; then
        zectl destroy -F "${be_name}"
    else
        zectl destroy "${be_name}"
    fi
}

snapshot_boot_environment() {
    local be_name="${1:-}"
    local snapshot_name="${2:-}"
    
    if [[ -z "${be_name}" ]]; then
        # Snapshot current BE
        be_name=$(zectl list -H | grep -E '^\s*N\s+R' | awk '{print $1}')
    fi
    
    if [[ -z "${snapshot_name}" ]]; then
        snapshot_name="${BE_SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    fi
    
    log INFO "Creating snapshot: ${be_name}@${snapshot_name}"
    zectl snapshot "${be_name}@${snapshot_name}"
}

clone_boot_environment() {
    local source_be="$1"
    local target_be="$2"
    local description="${3:-Cloned from ${source_be}}"
    
    log INFO "Cloning ${source_be} to ${target_be}"
    zectl create -e "${source_be}" -d "${description}" "${target_be}"
}

rename_boot_environment() {
    local old_name="$1"
    local new_name="$2"
    
    log INFO "Renaming boot environment from ${old_name} to ${new_name}"
    zectl rename "${old_name}" "${new_name}"
}

mount_boot_environment() {
    local be_name="$1"
    local mount_point="${2:-/mnt/be}"
    
    log INFO "Mounting boot environment ${be_name} at ${mount_point}"
    mkdir -p "${mount_point}"
    zectl mount "${be_name}" "${mount_point}"
}

umount_boot_environment() {
    local be_name="$1"
    
    log INFO "Unmounting boot environment ${be_name}"
    zectl umount "${be_name}"
}

#############################################################
# Systemd-boot Integration
#############################################################

update_systemd_boot_entries() {
    log INFO "Updating systemd-boot entries for boot environments..."
    
    local esp="/boot/efi"
    local loader_dir="${esp}/loader"
    local entries_dir="${loader_dir}/entries"
    
    # Clear old entries
    rm -f "${entries_dir}"/zectl-*.conf
    
    # Generate entries for each boot environment
    while IFS= read -r line; do
        local be_name=$(echo "$line" | awk '{print $1}')
        local active=$(echo "$line" | awk '{print $2}')
        local mountpoint=$(echo "$line" | awk '{print $3}')
        local creation=$(echo "$line" | awk '{print $4, $5}')
        
        if [[ "${be_name}" == "Name" ]]; then
            continue  # Skip header
        fi
        
        local entry_file="${entries_dir}/zectl-${be_name}.conf"
        local kernel_version=$(ls "${esp}"/vmlinuz-* 2>/dev/null | head -1 | xargs basename | sed 's/vmlinuz-//')
        
        cat > "${entry_file}" <<EOF
title   Ubuntu - ${be_name}
version ${creation}
linux   /vmlinuz-${kernel_version}
initrd  /initrd.img-${kernel_version}
options root=ZFS=${BE_ROOT_DATASET}/${be_name} rw quiet splash
EOF
        
        # Set default if active
        if [[ "${active}" == "NR" ]]; then
            echo "default zectl-${be_name}" > "${loader_dir}/loader.conf"
            echo "timeout 5" >> "${loader_dir}/loader.conf"
            echo "console-mode max" >> "${loader_dir}/loader.conf"
            echo "editor no" >> "${loader_dir}/loader.conf"
        fi
    done < <(zectl list)
}

#############################################################
# Automated Snapshot Management
#############################################################

setup_auto_snapshots() {
    log INFO "Setting up automated snapshot management..."
    
    # Create systemd service for auto snapshots
    cat > /etc/systemd/system/zectl-auto-snapshot.service <<EOF
[Unit]
Description=Automatic ZFS Boot Environment Snapshots
After=zfs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zectl-auto-snapshot.sh

[Install]
WantedBy=multi-user.target
EOF
    
    # Create snapshot script
    cat > /usr/local/bin/zectl-auto-snapshot.sh <<'SCRIPT'
#!/bin/bash
set -e

# Configuration
MAX_SNAPSHOTS=10
SNAPSHOT_PREFIX="auto"

# Get current boot environment
CURRENT_BE=$(zectl list -H | grep -E '^\s*N\s+R' | awk '{print $1}')

if [[ -n "${CURRENT_BE}" ]]; then
    # Create snapshot
    SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    zectl snapshot "${CURRENT_BE}@${SNAPSHOT_NAME}"
    
    # Clean old snapshots
    SNAPSHOTS=$(zfs list -t snapshot -o name -H | grep "${CURRENT_BE}@${SNAPSHOT_PREFIX}" | sort -r)
    COUNT=0
    
    while IFS= read -r snapshot; do
        COUNT=$((COUNT + 1))
        if [[ ${COUNT} -gt ${MAX_SNAPSHOTS} ]]; then
            zfs destroy "${snapshot}"
        fi
    done <<< "${SNAPSHOTS}"
fi
SCRIPT
    
    chmod +x /usr/local/bin/zectl-auto-snapshot.sh
    
    # Create timer for daily snapshots
    cat > /etc/systemd/system/zectl-auto-snapshot.timer <<EOF
[Unit]
Description=Daily Automatic ZFS Boot Environment Snapshots
Requires=zectl-auto-snapshot.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Enable services
    systemctl daemon-reload
    systemctl enable zectl-auto-snapshot.timer
    systemctl start zectl-auto-snapshot.timer
}

#############################################################
# Hooks for Package Management
#############################################################

setup_apt_hooks() {
    log INFO "Setting up APT hooks for automatic snapshots..."
    
    # Pre-upgrade hook
    cat > /etc/apt/apt.conf.d/80-zectl-snapshot <<'CONF'
// Automatically create boot environment snapshots before package operations
DPkg::Pre-Invoke {
    "if [ -x /usr/local/bin/zectl ] && [ -f /usr/local/bin/zectl-apt-snapshot ]; then /usr/local/bin/zectl-apt-snapshot pre; fi";
};

DPkg::Post-Invoke {
    "if [ -x /usr/local/bin/zectl ] && [ -f /usr/local/bin/zectl-apt-snapshot ]; then /usr/local/bin/zectl-apt-snapshot post; fi";
};
CONF
    
    # Create APT snapshot script
    cat > /usr/local/bin/zectl-apt-snapshot <<'SCRIPT'
#!/bin/bash
set -e

ACTION="${1:-pre}"
SNAPSHOT_PREFIX="apt"

# Get current boot environment
CURRENT_BE=$(zectl list -H | grep -E '^\s*N\s+R' | awk '{print $1}')

if [[ -n "${CURRENT_BE}" ]]; then
    case "${ACTION}" in
        pre)
            # Create snapshot before package operation
            SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-pre-$(date +%Y%m%d-%H%M%S)"
            zectl snapshot "${CURRENT_BE}@${SNAPSHOT_NAME}"
            echo "Created pre-upgrade snapshot: ${CURRENT_BE}@${SNAPSHOT_NAME}"
            ;;
        post)
            # Optional: Create post-upgrade snapshot
            if [[ "${CREATE_POST_SNAPSHOT:-false}" == "true" ]]; then
                SNAPSHOT_NAME="${SNAPSHOT_PREFIX}-post-$(date +%Y%m%d-%H%M%S)"
                zectl snapshot "${CURRENT_BE}@${SNAPSHOT_NAME}"
                echo "Created post-upgrade snapshot: ${CURRENT_BE}@${SNAPSHOT_NAME}"
            fi
            ;;
    esac
fi
SCRIPT
    
    chmod +x /usr/local/bin/zectl-apt-snapshot
}

#############################################################
# Recovery Functions
#############################################################

create_recovery_environment() {
    log INFO "Creating recovery boot environment..."
    
    local recovery_be="recovery-$(date +%Y%m%d)"
    
    # Create minimal recovery BE
    create_boot_environment "${recovery_be}" "Recovery Environment"
    
    # Mount and configure
    mount_boot_environment "${recovery_be}" "/mnt/recovery"
    
    # Install recovery tools
    chroot /mnt/recovery apt-get update
    chroot /mnt/recovery apt-get install -y \
        zfsutils-linux \
        mdadm \
        cryptsetup \
        gdisk \
        testdisk \
        gddrescue \
        network-manager \
        openssh-server
    
    # Configure for recovery
    echo "PermitRootLogin yes" >> /mnt/recovery/etc/ssh/sshd_config
    
    umount_boot_environment "${recovery_be}"
    
    log SUCCESS "Recovery environment created: ${recovery_be}"
}

rollback_to_snapshot() {
    local snapshot="$1"
    
    log INFO "Rolling back to snapshot: ${snapshot}"
    
    # Create new BE from snapshot
    local rollback_be="rollback-$(date +%Y%m%d-%H%M%S)"
    zectl create -e "${snapshot}" "${rollback_be}"
    
    # Activate the rollback BE
    activate_boot_environment "${rollback_be}"
    
    log SUCCESS "Rolled back to ${snapshot} as ${rollback_be}"
    log INFO "Reboot to activate the rollback environment"
}

#############################################################
# Export Functions
#############################################################

# Make functions available to other scripts
export -f setup_zectl
export -f create_boot_environment
export -f activate_boot_environment
export -f list_boot_environments
export -f delete_boot_environment
export -f snapshot_boot_environment
export -f clone_boot_environment
export -f rename_boot_environment
export -f mount_boot_environment
export -f umount_boot_environment
export -f update_systemd_boot_entries
export -f setup_auto_snapshots
export -f setup_apt_hooks
export -f create_recovery_environment
export -f rollback_to_snapshot