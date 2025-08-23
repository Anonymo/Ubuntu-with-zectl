#!/usr/bin/env bash

#############################################################
# Ubuntu ZFS Boot Environment Installer
# 
# A modern, modular installer for Ubuntu with ZFS root,
# boot environments (zectl), and zfsbootmenu support.
#############################################################

set -euo pipefail

# Script metadata
# This installer creates a Ubuntu system with ZFS root and boot environment management
readonly VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly LOG_DIR="/var/log/ubuntu-zfs-installer"
readonly LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

# Source modules if available  
# Note: zectl-manager.sh provides advanced BE management functions
# These are made available to other scripts but not used directly in install.sh
# The main installer focuses on initial setup; post-install management uses the modules
if [[ -f "${MODULES_DIR}/zectl-manager.sh" ]]; then
    source "${MODULES_DIR}/zectl-manager.sh"
fi

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default configuration
UBUNTU_VERSION=""
INSTALL_TYPE="server"  # server, desktop, minimal
DISK=""
POOL_NAME="rpool"
ENCRYPTION="off"  # on, off
SWAP_SIZE="4G"
USERNAME=""
HOSTNAME=""
TIMEZONE="America/Chicago"
LOCALE="en_US.UTF-8"
PASSPHRASE=""

# Installation state
STATE_FILE="/tmp/ubuntu-zfs-installer.state"

#############################################################
# Helper Functions
#############################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Ensure log directory exists before writing
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
    
    case "${level}" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} ${message}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} ${message}"
            ;;
        INFO)
            echo -e "${BLUE}[INFO]${NC} ${message}"
            ;;
        *)
            echo "${message}"
            ;;
    esac
}

die() {
    log ERROR "$@"
    exit 1
}

confirm() {
    local prompt="$1"
    local response
    
    while true; do
        read -rp "${prompt} [y/N]: " response
        case "${response}" in
            [yY][eE][sS]|[yY])
                return 0
                ;;
            [nN][oO]|[nN]|"")
                return 1
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
}

check_uefi() {
    log INFO "Checking UEFI system requirements..."
    
    # Check if system is booted in UEFI mode
    if [[ ! -d /sys/firmware/efi ]]; then
        die "This installer requires a UEFI system. Boot your system in UEFI mode to continue."
    fi
    
    # Check for EFI variables support
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        log WARNING "EFI variables not accessible. Some boot management features may not work."
    fi
    
    log INFO "UEFI system detected"
}

check_dependencies() {
    log INFO "Checking and installing dependencies..."
    
    # Ensure we have a working package manager
    if ! command -v apt-get &> /dev/null; then
        die "apt-get not found. This installer requires Ubuntu or Debian."
    fi
    
    # Update package cache with retry logic
    local retries=3
    while [[ $retries -gt 0 ]]; do
        if apt-get update; then
            break
        else
            retries=$((retries - 1))
            if [[ $retries -eq 0 ]]; then
                die "Failed to update package cache after multiple attempts"
            fi
            log WARNING "Package update failed, retrying in 5 seconds... ($retries attempts left)"
            sleep 5
        fi
    done
    
    # Install required packages with better error handling
    local packages=("debootstrap" "gdisk" "zfsutils-linux" "efibootmgr" "dosfstools")
    
    log INFO "Installing packages: ${packages[*]}"
    if ! apt-get install -y "${packages[@]}"; then
        log ERROR "Failed to install some packages. Checking which ones are missing..."
        local missing=()
        for pkg in "${packages[@]}"; do
            if ! dpkg -l "$pkg" &>/dev/null; then
                missing+=("$pkg")
            fi
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            die "Missing critical packages: ${missing[*]}. Please install them manually and retry."
        fi
    fi
    
    # Load ZFS module if not loaded
    if ! lsmod | grep -q zfs; then
        modprobe zfs || die "Failed to load ZFS module"
    fi
    
    # Check if we're in a live environment and add universe repository safely
    if [[ ! -f /etc/apt/sources.list ]] || ! grep -q "universe" /etc/apt/sources.list; then
        log WARNING "Adding universe repository..."
        
        # Ensure software-properties-common is installed first
        if ! dpkg -l software-properties-common &>/dev/null; then
            apt-get install -y software-properties-common || {
                log WARNING "Failed to install software-properties-common"
            }
        fi
        
        add-apt-repository universe -y 2>/dev/null || {
            log WARNING "Failed to add universe repository, continuing anyway"
        }
        apt-get update 2>/dev/null || {
            log WARNING "Failed to update package cache after adding universe"
        }
    fi
}

detect_ubuntu_version() {
    if [[ -f /etc/os-release ]]; then
        # Read VERSION_ID without sourcing to avoid conflicts with our readonly VERSION
        local version_id
        version_id=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        UBUNTU_VERSION="${version_id}"
        log INFO "Detected Ubuntu version: ${UBUNTU_VERSION}"
    else
        die "Cannot detect Ubuntu version"
    fi
}

save_state() {
    local key="$1"
    local value="$2"
    # Replace existing key or append if missing to avoid unbounded growth
    if [[ -f "${STATE_FILE}" ]] && grep -q "^${key}=" "${STATE_FILE}"; then
        local tmp
        tmp="$(mktemp)"
        awk -v k="${key}" -v v="${value}" 'BEGIN{FS=OFS="="} $1==k {$2=v; print; next} {print}' "${STATE_FILE}" >"${tmp}" && mv "${tmp}" "${STATE_FILE}"
    else
        echo "${key}=${value}" >> "${STATE_FILE}"
    fi
}

load_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        source "${STATE_FILE}"
    fi
}

#############################################################
# Configuration Functions
#############################################################

load_config() {
    local config_file="${SCRIPT_DIR}/installer.conf"
    
    if [[ -f "${config_file}" ]]; then
        log INFO "Loading configuration from ${config_file}"
        source "${config_file}"
    else
        log WARNING "No installer.conf found, will use interactive mode"
    fi
}

validate_username() {
    local username="$1"
    if [[ -z "$username" ]]; then
        return 1
    fi
    # Check valid username format (alphanumeric, underscore, dash, 3-32 chars)
    if [[ "$username" =~ ^[a-z][-a-z0-9_]{2,31}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_hostname() {
    local hostname="$1"
    if [[ -z "$hostname" ]]; then
        return 1
    fi
    # Check valid hostname format
    if [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && [[ ${#hostname} -le 63 ]]; then
        return 0
    else
        return 1
    fi
}

validate_timezone() {
    local timezone="$1"
    if [[ -z "$timezone" ]]; then
        return 1
    fi
    # Check if timezone file exists
    if [[ -f "/usr/share/zoneinfo/$timezone" ]]; then
        return 0
    else
        return 1
    fi
}

interactive_config() {
    log INFO "Starting interactive configuration..."
    
    # Select installation type with validation
    while true; do
        echo "Select installation type:"
        echo "1) Server (minimal)"
        echo "2) Desktop (with GUI)"
        echo "3) Minimal (basic system only)"
        read -rp "Choice [1-3]: " choice
        
        case "${choice}" in
            1) INSTALL_TYPE="server"; break ;;
            2) INSTALL_TYPE="desktop"; break ;;
            3) INSTALL_TYPE="minimal"; break ;;
            *) echo "Invalid choice. Please select 1, 2, or 3." ;;
        esac
    done
    
    # Select disk
    echo -e "\nAvailable disks:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk
    
    while true; do
        read -rp "Enter disk device (e.g., sda, nvme0n1): " disk_input
        
        # Handle different input formats
        if [[ "$disk_input" =~ ^/dev/ ]]; then
            DISK="$disk_input"
        else
            DISK="/dev/${disk_input}"
        fi
        
        if [[ -b "${DISK}" ]]; then
            break
        else
            echo "Error: ${DISK} is not a valid block device. Please try again."
        fi
    done
    
    log INFO "Selected disk: ${DISK}"
    
    # Show disk info
    echo "Disk information:"
    lsblk "${DISK}" || true
    echo
    
    if ! confirm "WARNING: This will ERASE ALL DATA on ${DISK}. Continue?"; then
        die "Installation cancelled by user"
    fi
    
    # Pool name
    read -rp "Enter ZFS pool name [${POOL_NAME}]: " input
    POOL_NAME="${input:-${POOL_NAME}}"
    
    # Encryption
    if confirm "Enable encryption?"; then
        ENCRYPTION="on"
        read -sp "Enter encryption passphrase: " PASSPHRASE
        echo
        read -sp "Confirm passphrase: " PASSPHRASE_CONFIRM
        echo
        
        if [[ "${PASSPHRASE}" != "${PASSPHRASE_CONFIRM}" ]]; then
            die "Passphrases do not match"
        fi
    else
        ENCRYPTION="off"
    fi
    
    # User configuration with validation
    while true; do
        read -rp "Enter username for the new system: " USERNAME
        if validate_username "$USERNAME"; then
            break
        else
            echo "Invalid username. Must start with a letter, be 3-32 characters, and contain only lowercase letters, numbers, hyphens, and underscores."
        fi
    done
    
    # Get password for the user (secure)
    while true; do
        read -rsp "Enter password for $USERNAME: " USER_PASSWORD
        echo
        read -rsp "Confirm password: " USER_PASSWORD_CONFIRM
        echo
        
        if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then
            if [[ ${#USER_PASSWORD} -ge 8 ]]; then
                break
            else
                echo "Password must be at least 8 characters long."
            fi
        else
            echo "Passwords do not match. Please try again."
        fi
    done
    
    # Get root password (optional)
    echo "Set root password (optional - leave empty to disable root login):"
    read -rsp "Root password: " ROOT_PASSWORD
    echo
    
    while true; do
        read -rp "Enter hostname: " HOSTNAME
        if validate_hostname "$HOSTNAME"; then
            break
        else
            echo "Invalid hostname. Must be 1-63 characters, start and end with alphanumeric, and contain only letters, numbers, and hyphens."
        fi
    done
    
    # Timezone with validation
    while true; do
        read -rp "Enter timezone [${TIMEZONE}]: " input
        local tz="${input:-${TIMEZONE}}"
        if validate_timezone "$tz"; then
            TIMEZONE="$tz"
            break
        else
            echo "Invalid timezone. Examples: America/New_York, Europe/London, Asia/Tokyo"
            echo "Run 'timedatectl list-timezones' to see all available timezones."
        fi
    done
    
    # Summary
    echo -e "\n${GREEN}Configuration Summary:${NC}"
    echo "  Installation Type: ${INSTALL_TYPE}"
    echo "  Disk: ${DISK}"
    echo "  Pool Name: ${POOL_NAME}"
    echo "  Encryption: ${ENCRYPTION}"
    echo "  Username: ${USERNAME}"
    echo "  Hostname: ${HOSTNAME}"
    echo "  Timezone: ${TIMEZONE}"
    echo
    
    confirm "Proceed with installation?" || die "Installation cancelled"
}

#############################################################
# Installation Functions
#############################################################

get_partition_name() {
    local disk="$1"
    local partition_num="$2"
    
    # More robust partition naming detection
    # Handle various disk types: NVMe, eMMC, loop devices, etc.
    if [[ "$disk" =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+)$ ]]; then
        echo "${disk}p${partition_num}"
    elif [[ "$disk" =~ (sd[a-z]+|hd[a-z]+|vd[a-z]+|xvd[a-z]+)$ ]]; then
        echo "${disk}${partition_num}"
    else
        # Fallback: try both formats and use the one that exists
        local p_format="${disk}p${partition_num}"
        local direct_format="${disk}${partition_num}"
        
        if [[ -b "$p_format" ]]; then
            echo "$p_format"
        elif [[ -b "$direct_format" ]]; then
            echo "$direct_format"
        else
            # Default to p format for unknown types
            echo "$p_format"
        fi
    fi
}

prepare_disk() {
    log INFO "Preparing disk ${DISK}..."
    
    # Safely unmount any existing filesystems
    log INFO "Unmounting existing filesystems..."
    for mount_point in $(mount | grep "^${DISK}" | awk '{print $3}' | sort -r); do
        umount "$mount_point" 2>/dev/null || {
            log WARNING "Failed to unmount $mount_point, trying lazy unmount"
            umount -l "$mount_point" 2>/dev/null || true
        }
    done
    
    # Stop any swap on the disk
    for swap_dev in $(swapon --show=NAME --noheadings | grep "^${DISK}"); do
        swapoff "$swap_dev" 2>/dev/null || {
            log WARNING "Failed to disable swap on $swap_dev"
        }
    done
    
    # Wipe disk
    log INFO "Wiping disk signatures..."
    wipefs -af "${DISK}" || die "Failed to wipe disk"
    sgdisk --zap-all "${DISK}" || die "Failed to zap disk"
    
    # Create partitions
    log INFO "Creating partitions..."
    sgdisk -n1:1M:+1G -t1:EF00 "${DISK}" || die "Failed to create EFI partition"  # EFI partition
    
    # Create swap partition only if swap is enabled
    if [[ "$SWAP_SIZE" != "0" ]] && [[ "$SWAP_SIZE" != "0G" ]] && [[ "$SWAP_SIZE" != "0M" ]]; then
        sgdisk -n2:0:+${SWAP_SIZE} -t2:8200 "${DISK}" || die "Failed to create swap partition"  # Swap partition
        sgdisk -n3:0:0 -t3:BF00 "${DISK}" || die "Failed to create ZFS partition"  # ZFS partition
    else
        log INFO "Swap disabled, creating ZFS partition as partition 2"
        sgdisk -n2:0:0 -t2:BF00 "${DISK}" || die "Failed to create ZFS partition"  # ZFS partition
    fi
    
    # Wait for devices to settle
    sleep 3
    partprobe "${DISK}" || die "Failed to update partition table"
    udevadm settle || true
    sleep 2
    
    # Get partition names
    local efi_partition=$(get_partition_name "${DISK}" "1")
    local swap_partition=""
    local zfs_partition=""
    
    if [[ "$SWAP_SIZE" != "0" ]] && [[ "$SWAP_SIZE" != "0G" ]] && [[ "$SWAP_SIZE" != "0M" ]]; then
        swap_partition=$(get_partition_name "${DISK}" "2")
        zfs_partition=$(get_partition_name "${DISK}" "3")
        log INFO "Partitions: EFI=${efi_partition}, Swap=${swap_partition}, ZFS=${zfs_partition}"
    else
        zfs_partition=$(get_partition_name "${DISK}" "2")
        log INFO "Partitions: EFI=${efi_partition}, ZFS=${zfs_partition} (no swap)"
    fi
    
    # Wait for partition devices to exist
    local timeout=10
    while [[ $timeout -gt 0 ]] && [[ ! -b "$efi_partition" ]]; do
        sleep 1
        timeout=$((timeout - 1))
    done
    
    if [[ ! -b "$efi_partition" ]]; then
        die "EFI partition $efi_partition not found after partitioning"
    fi
    
    # Format EFI partition
    log INFO "Formatting EFI partition..."
    mkfs.vfat -F32 -n EFI "$efi_partition" || die "Failed to format EFI partition"
    
    # Create swap
    if [[ "$SWAP_SIZE" != "0" ]] && [[ "$SWAP_SIZE" != "0G" ]] && [[ "$SWAP_SIZE" != "0M" ]]; then
        log INFO "Setting up swap..."
        mkswap -L swap "$swap_partition" || die "Failed to create swap"
    fi
    
    # Store partition names for later use
    export EFI_PARTITION="$efi_partition"
    export SWAP_PARTITION="$swap_partition"
    export ZFS_PARTITION="$zfs_partition"
    
    save_state "DISK_PREPARED" "true"
}

create_zfs_pool() {
    log INFO "Creating ZFS pool..."
    
    local zfs_partition="${ZFS_PARTITION}"
    
    if [[ ! -b "$zfs_partition" ]]; then
        die "ZFS partition $zfs_partition not found"
    fi
    
    # Create pool with settings from config
    local pool_opts=(
        -o ashift="${ZFS_ASHIFT:-12}"
        -o autotrim=on
        -O acltype=posixacl
        -O canmount=off
        -O compression="${ZFS_COMPRESSION:-lz4}"
        -O dnodesize=auto
        -O normalization=formD
        -O atime="${ZFS_ATIME:-off}"
        -O xattr=sa
        -O mountpoint=/
        -R /mnt
    )
    
    # Add recordsize if specified
    if [[ -n "${ZFS_RECORDSIZE:-}" ]]; then
        pool_opts+=(-O recordsize="${ZFS_RECORDSIZE}")
    fi
    
    if [[ "${ENCRYPTION}" == "on" ]]; then
        if [[ -n "${PASSPHRASE}" ]]; then
            # Create key file for encryption in the target system
            local key_dir="/mnt/etc/zfs/keys"
            local key_file="${key_dir}/${POOL_NAME}.key"
            local target_key_path="/etc/zfs/keys/${POOL_NAME}.key"
            
            # Ensure key directory exists in target
            mkdir -p "${key_dir}"
            chmod 700 "${key_dir}"
            
            # Write key file to target system
            printf "%s" "${PASSPHRASE}" > "${key_file}"
            chmod 600 "${key_file}"
            
            pool_opts+=(
                -O encryption=aes-256-gcm
                -O keylocation="file://${target_key_path}"
                -O keyformat=passphrase
            )
        else
            die "Encryption enabled but no passphrase provided"
        fi
    fi
    
    log INFO "Creating ZFS pool on ${zfs_partition}..."
    
    # Create pool (encryption handled via keyfile if enabled)
    zpool create -f "${pool_opts[@]}" "${POOL_NAME}" "${zfs_partition}" || die "Failed to create ZFS pool"
    
    # Create datasets
    log INFO "Creating ZFS datasets..."
    
    # Root dataset
    zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT" || die "Failed to create ROOT dataset"
    zfs create -o canmount=noauto -o mountpoint=/ "${POOL_NAME}/ROOT/ubuntu" || die "Failed to create ubuntu dataset"
    
    # Mark as boot environment
    zpool set bootfs="${POOL_NAME}/ROOT/ubuntu" "${POOL_NAME}" || die "Failed to set bootfs"
    
    # Home dataset (separate for snapshots)
    zfs create -o canmount=on -o mountpoint=/home "${POOL_NAME}/home" || die "Failed to create home dataset"
    
    # Other datasets
    zfs create -o canmount=off -o mountpoint=/var "${POOL_NAME}/var" || die "Failed to create var dataset"
    zfs create -o canmount=on "${POOL_NAME}/var/lib" || die "Failed to create var/lib dataset"
    zfs create -o canmount=on "${POOL_NAME}/var/log" || die "Failed to create var/log dataset"
    zfs create -o canmount=on "${POOL_NAME}/var/cache" || die "Failed to create var/cache dataset"
    zfs create -o canmount=on "${POOL_NAME}/var/tmp" || die "Failed to create var/tmp dataset"
    
    # Mount root
    zfs mount "${POOL_NAME}/ROOT/ubuntu" || die "Failed to mount root dataset"
    
    # Create mount points
    mkdir -p /mnt/boot/efi || die "Failed to create boot/efi directory"
    mount "${EFI_PARTITION}" /mnt/boot/efi || die "Failed to mount EFI partition"
    
    # Ensure ZFS cachefile is present in target for reliable imports at boot
    mkdir -p /etc/zfs /mnt/etc/zfs
    if ! zpool set cachefile=/etc/zfs/zpool.cache "${POOL_NAME}" 2>/dev/null; then
        log WARNING "Failed to set ZFS cachefile property; relying on initramfs auto import"
    fi
    if [[ -f /etc/zfs/zpool.cache ]]; then
        cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache 2>/dev/null || log WARNING "Failed to copy zpool.cache to target"
    fi
    
    save_state "ZFS_CREATED" "true"
}

detect_ubuntu_codename() {
    case "${UBUNTU_VERSION}" in
        22.04) echo "jammy" ;;
        24.04) echo "noble" ;;
        24.10) echo "oracular" ;;
        *) 
            # Try to detect from current environment for unknown versions
            if [[ -f /etc/os-release ]]; then
                local version_codename
                version_codename=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
                if [[ -n "${version_codename:-}" ]]; then
                    echo "${version_codename}"
                else
                    log ERROR "Unknown Ubuntu version ${UBUNTU_VERSION} and no codename detected"
                    die "Please specify a known Ubuntu version (22.04, 24.04, 24.10) or update the script"
                fi
            else
                die "Cannot detect Ubuntu version. Please specify UBUNTU_VERSION in config."
            fi
            ;;
    esac
}

mount_chroot_filesystems() {
    log INFO "Mounting filesystems for chroot environment..."
    
    # Mount necessary filesystems for chroot (including /run for systemd/apt)
    mount -t proc proc /mnt/proc || die "Failed to mount proc"
    mount -t sysfs sys /mnt/sys || die "Failed to mount sys"
    mount -B /dev /mnt/dev || die "Failed to mount dev"
    mount -t devpts devpts /mnt/dev/pts || die "Failed to mount devpts"
    mount -B /run /mnt/run || die "Failed to mount run"
}

configure_apt_sources() {
    local codename="$1"
    local mirror="$2"
    
    log INFO "Configuring apt sources..."
    
    # Configure apt sources with dedicated security mirror
    cat > /mnt/etc/apt/sources.list <<EOF
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
EOF
    
    # Copy network configuration
    cp /etc/resolv.conf /mnt/etc/ || log WARNING "Failed to copy resolv.conf"
}

detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        armv7l)
            echo "armhf"
            ;;
        *)
            log WARNING "Unknown architecture: $arch, defaulting to amd64"
            echo "amd64"
            ;;
    esac
}

copy_live_system() {
    log INFO "Copying live system to target (much faster than debootstrap)..."
    
    # Create a basic filesystem structure first
    mkdir -p /mnt/{dev,proc,sys,tmp,var/tmp,var/cache/apt}
    chmod 1777 /mnt/tmp /mnt/var/tmp
    
    # Copy the live filesystem, excluding certain directories we'll handle separately
    log INFO "Copying live system files... (this may take a few minutes)"
    
    rsync -aHAXS --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
          --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' \
          --exclude='/media/*' --exclude='/cdrom/*' --exclude='/var/tmp/*' \
          --exclude='/var/cache/apt/archives/*' \
          / /mnt/ || die "Failed to copy live system"
    
    log INFO "Live system copied successfully"
}

install_missing_packages() {
    local codename="$1" 
    local mirror="$2"
    
    # Only needed if we used live system copy
    if [[ ! -f /usr/lib/live/mount/medium/casper/filesystem.squashfs ]] && [[ ! -f /cdrom/casper/filesystem.squashfs ]]; then
        return  # debootstrap already installed everything
    fi
    
    log INFO "Installing ZFS packages not included in live system..."
    
    # Essential ZFS packages that might not be on Live USB
    local zfs_packages=("zfsutils-linux" "zfs-initramfs" "zfs-dkms")
    
    # Update package cache in target
    chroot /mnt apt-get update || log WARNING "Failed to update package cache in target"
    
    # Install missing packages
    for package in "${zfs_packages[@]}"; do
        if ! chroot /mnt dpkg -l "$package" &>/dev/null; then
            log INFO "Installing missing package: $package"
            chroot /mnt apt-get install -y "$package" || log WARNING "Failed to install $package"
        else
            log INFO "Package $package already installed"
        fi
    done
}

run_debootstrap() {
    local codename="$1"
    local mirror="$2" 
    local all_packages="$3"
    
    # Check if we should use the faster live system copy method
    if [[ -f /usr/lib/live/mount/medium/casper/filesystem.squashfs ]] || [[ -f /cdrom/casper/filesystem.squashfs ]]; then
        log INFO "Live environment detected, using fast copy method instead of debootstrap"
        copy_live_system
        return
    fi
    
    # Fallback to traditional debootstrap for non-live environments
    local target_arch=$(detect_architecture)
    log INFO "Using debootstrap fallback for $target_arch with packages: ${all_packages}"
    
    debootstrap \
        --arch="${target_arch}" \
        --include="${all_packages}" \
        --components=main,restricted,universe,multiverse \
        "${codename}" \
        /mnt \
        "${mirror}" || die "Failed to run debootstrap"
}

detect_live_mirror() {
    local live_mirror=""
    
    # Scan /etc/apt/sources.list and /etc/apt/sources.list.d/*.list
    local sources_files=("/etc/apt/sources.list")
    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r -d '' file; do
            sources_files+=("$file")
        done < <(find /etc/apt/sources.list.d -name "*.list" -print0 2>/dev/null)
    fi
    
    for file in "${sources_files[@]}"; do
        if [[ -f "$file" ]]; then
            # Get first non-security, non-cdrom mirror
            live_mirror=$(grep "^deb " "$file" | grep -v "security.ubuntu.com" | grep -v "deb cdrom:" | head -1 | awk '{print $2}')
            if [[ -n "$live_mirror" ]] && [[ "$live_mirror" != *"archive.ubuntu.com"* ]]; then
                log INFO "Detected optimized mirror from live environment: $live_mirror"
                echo "$live_mirror"
                return
            fi
        fi
    done
}

validate_mirror() {
    local mirror="$1"
    local codename="$2"
    
    if ! command -v curl &> /dev/null; then
        return 0  # Can't validate without curl, assume it works
    fi
    
    # Check if mirror is reachable with Release file validation
    if curl -s --head --connect-timeout 3 --max-time 5 "$mirror/dists/$codename/Release" >/dev/null 2>&1; then
        return 0
    else
        log WARNING "Mirror $mirror appears unreachable or lacks $codename"
        return 1
    fi
}

prefer_https() {
    local mirror="$1"
    local codename="$2"
    
    # If already HTTPS, return as-is
    if [[ "$mirror" == https://* ]]; then
        echo "$mirror"
        return
    fi
    
    # Try HTTPS version
    local https_mirror="${mirror/http:/https:}"
    
    if command -v curl &> /dev/null; then
        if [[ -n "$codename" ]]; then
            # Validate HTTPS with codename
            if curl -s --head --connect-timeout 3 --max-time 5 "$https_mirror/dists/$codename/Release" >/dev/null 2>&1; then
                log INFO "Using HTTPS mirror: $https_mirror"
                echo "$https_mirror"
                return
            fi
        else
            # Simple HTTPS connectivity test
            if curl -s --head --connect-timeout 3 --max-time 5 "$https_mirror" >/dev/null 2>&1; then
                log INFO "Using HTTPS mirror: $https_mirror"
                echo "$https_mirror"
                return
            fi
        fi
    fi
    
    # Fall back to HTTP
    echo "$mirror"
}

get_architecture_base_url() {
    local arch=$(detect_architecture)
    local country_code="$1"
    
    case "$arch" in
        amd64)
            # Standard archive for x86_64
            case "${country_code,,}" in
                us) echo "http://us.archive.ubuntu.com/ubuntu" ;;
                gb|uk) echo "http://gb.archive.ubuntu.com/ubuntu" ;;
                ca) echo "http://ca.archive.ubuntu.com/ubuntu" ;;
                de) echo "http://de.archive.ubuntu.com/ubuntu" ;;
                fr) echo "http://fr.archive.ubuntu.com/ubuntu" ;;
                au) echo "http://au.archive.ubuntu.com/ubuntu" ;;
                jp) echo "http://jp.archive.ubuntu.com/ubuntu" ;;
                kr) echo "http://kr.archive.ubuntu.com/ubuntu" ;;
                cn) echo "http://cn.archive.ubuntu.com/ubuntu" ;;
                in) echo "http://in.archive.ubuntu.com/ubuntu" ;;
                br) echo "http://br.archive.ubuntu.com/ubuntu" ;;
                *) echo "http://archive.ubuntu.com/ubuntu" ;;
            esac
            ;;
        arm64|armhf)
            # Use ports archive for ARM architectures
            log INFO "Using ports archive for $arch architecture"
            echo "http://ports.ubuntu.com/ubuntu-ports"
            ;;
        *)
            # Default to ports for unknown architectures
            log WARNING "Unknown architecture $arch, using ports archive"
            echo "http://ports.ubuntu.com/ubuntu-ports"
            ;;
    esac
}

detect_best_mirror() {
    local codename="${1:-}"
    
    # 1. Prefer user-defined mirror
    if [[ -n "${UBUNTU_MIRROR}" ]]; then
        if [[ -n "$codename" ]] && ! validate_mirror "${UBUNTU_MIRROR}" "$codename"; then
            log WARNING "User-specified mirror failed validation, falling back to auto-detection"
        else
            local user_mirror=$(prefer_https "${UBUNTU_MIRROR}" "$codename")
            echo "$user_mirror"
            return
        fi
    fi
    
    # 2. Try to reuse live environment mirror
    local live_mirror=$(detect_live_mirror)
    if [[ -n "$live_mirror" ]]; then
        if [[ -z "$codename" ]] || validate_mirror "$live_mirror" "$codename"; then
            live_mirror=$(prefer_https "$live_mirror" "$codename")
            echo "$live_mirror"
            return
        fi
    fi
    
    # 3. Geo-IP detection with architecture awareness
    # Note: This is a best-effort attempt via a public geo-IP service
    # and may not be accurate if using a VPN or proxy
    local country_code=""
    if command -v curl &> /dev/null; then
        country_code=$(curl -s --connect-timeout 3 --max-time 5 http://ipinfo.io/country 2>/dev/null || true)
    fi
    
    local geo_mirror=$(get_architecture_base_url "$country_code")
    
    # 4. Validate geo-detected mirror
    if [[ -n "$codename" ]] && ! validate_mirror "$geo_mirror" "$codename"; then
        log WARNING "Geo-detected mirror failed validation, using default"
        # Final fallback
        local arch=$(detect_architecture)
        case "$arch" in
            amd64) geo_mirror="http://archive.ubuntu.com/ubuntu" ;;
            *) geo_mirror="http://ports.ubuntu.com/ubuntu-ports" ;;
        esac
    fi
    
    log INFO "Selected mirror: $geo_mirror (country: ${country_code:-unknown})"
    
    # 5. Try to prefer HTTPS if available
    geo_mirror=$(prefer_https "$geo_mirror" "$codename")
    
    echo "$geo_mirror"
}

install_base_system() {
    log INFO "Installing base system..."
    
    local codename=$(detect_ubuntu_codename)
    local mirror=$(detect_best_mirror "$codename")
    
    log INFO "Using Ubuntu ${UBUNTU_VERSION} (${codename}) from ${mirror}"
    
    # Essential packages for ZFS boot
    local essential_packages="locales,systemd-sysv,zfsutils-linux,zfs-initramfs"
    
    # Base packages (bootctl comes from systemd, no separate systemd-boot package needed)
    local base_packages="linux-image-generic,linux-headers-generic,efibootmgr,systemd"
    
    # Additional packages based on install type
    case "${INSTALL_TYPE}" in
        desktop)
            base_packages="${base_packages},ubuntu-desktop-minimal,network-manager"
            ;;
        server)
            base_packages="${base_packages},ubuntu-server,openssh-server,curl,wget"
            ;;
        minimal)
            base_packages="${base_packages},openssh-server,curl,wget,vim"
            ;;
    esac
    
    # Combine all packages
    local all_packages="${essential_packages},${base_packages}"
    
    # Run the modular installation steps
    run_debootstrap "$codename" "$mirror" "$all_packages"
    configure_apt_sources "$codename" "$mirror"
    mount_chroot_filesystems
    
    # Install missing ZFS packages if we used live system copy
    install_missing_packages "$codename" "$mirror"
    
    save_state "BASE_INSTALLED" "true"
}

configure_system() {
    log INFO "Configuring system..."
    
    # Create fstab
    cat > /mnt/etc/fstab <<EOF
# /etc/fstab: static file system information.
# ZFS filesystems are mounted by ZFS, not fstab
UUID=$(blkid -s UUID -o value "${EFI_PARTITION}") /boot/efi vfat umask=0077 0 1
EOF

    # Add swap if configured
    if [[ "$SWAP_SIZE" != "0" ]] && [[ "$SWAP_SIZE" != "0G" ]] && [[ "$SWAP_SIZE" != "0M" ]]; then
        echo "UUID=$(blkid -s UUID -o value "${SWAP_PARTITION}") none swap sw 0 0" >> /mnt/etc/fstab
    fi
    
    # Set hostname
    echo "${HOSTNAME}" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}

# IPv6
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
    # Configure timezone in chroot
    chroot /mnt ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime || die "Failed to set timezone"
    chroot /mnt dpkg-reconfigure -f noninteractive tzdata || log WARNING "Failed to reconfigure tzdata"
    
    # Configure locale
    echo "${LOCALE} UTF-8" > /mnt/etc/locale.gen
    chroot /mnt locale-gen || log WARNING "Failed to generate locales"
    chroot /mnt update-locale LANG="${LOCALE}" || log WARNING "Failed to update locale"
    
    # Configure machine-id
    chroot /mnt systemd-machine-id-setup || log WARNING "Failed to setup machine-id"
    
    save_state "SYSTEM_CONFIGURED" "true"
}

install_zectl() {
    # This function handles the initial installation of zectl in the target system
    # After this completes, the zectl-manager.sh module functions become available
    # for advanced boot environment management operations
    log INFO "Installing zectl for boot environment management..."
    
    cat > /mnt/tmp/install_zectl.sh <<'SCRIPT'
#!/bin/bash
set -e

# Update package cache
apt-get update

# Install dependencies
apt-get install -y python3 python3-pip python3-setuptools git build-essential

# Install zectl
cd /tmp
if [[ -d zectl ]]; then rm -rf zectl; fi
git clone https://github.com/johnramsden/zectl.git
cd zectl
python3 setup.py install

# Configure zectl
mkdir -p /etc/zectl
echo "bootloader: systemd-boot" > /etc/zectl/config.yaml
echo "esp_path: /boot/efi" >> /etc/zectl/config.yaml

# Create initial snapshot
echo "Creating initial boot environment..."
zectl snapshot initial || true

echo "zectl installed and configured successfully"
SCRIPT
    
    chmod +x /mnt/tmp/install_zectl.sh
    chroot /mnt /tmp/install_zectl.sh || log WARNING "zectl installation failed, but continuing..."
    
    save_state "ZECTL_INSTALLED" "true"
}

install_systemd_boot() {
    log INFO "Installing systemd-boot..."
    
    # Install systemd-boot to ESP
    chroot /mnt bootctl --path=/boot/efi install || die "Failed to install systemd-boot"
    
    # Configure loader
    cat > /mnt/boot/efi/loader/loader.conf <<EOF
default ubuntu
timeout 5
console-mode max
editor no
EOF
    
    # Get latest kernel version (sorted properly)
    local kernel_version
    kernel_version=$(chroot /mnt bash -c 'ls -1 /boot/vmlinuz-* 2>/dev/null | sed "s#.*/vmlinuz-##" | sort -V | tail -1')
    if [[ -z "$kernel_version" ]]; then
        die "No kernel found in /boot"
    fi
    
    log INFO "Using kernel version: $kernel_version"
    
    # Create boot entry
    cat > /mnt/boot/efi/loader/entries/ubuntu.conf <<EOF
title   Ubuntu Linux
linux   /vmlinuz-${kernel_version}
initrd  /initrd.img-${kernel_version}
options root=ZFS=${POOL_NAME}/ROOT/ubuntu rw quiet splash
EOF
    
    # Copy kernel and initrd to ESP
    log INFO "Copying kernel and initrd to ESP..."
    cp "/mnt/boot/vmlinuz-${kernel_version}" /mnt/boot/efi/ || die "Failed to copy kernel"
    cp "/mnt/boot/initrd.img-${kernel_version}" /mnt/boot/efi/ || die "Failed to copy initrd"
    
    save_state "SYSTEMD_BOOT_INSTALLED" "true"
}

finalize_installation() {
    log INFO "Finalizing installation..."
    
    # Create user and configure system in chroot
    cat > /mnt/tmp/finalize.sh <<'SCRIPT'
#!/bin/bash
set -e

# Set non-interactive frontend for apt
export DEBIAN_FRONTEND=noninteractive

# Create user
if ! id "${USERNAME}" &>/dev/null; then
    useradd -m -G sudo,adm,cdrom,plugdev,lpadmin -s /bin/bash "${USERNAME}"
fi

# Set user password from interactive input
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Set root password or disable root login
if [[ -n "${ROOT_PASSWORD}" ]]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd
else
    # Disable root login if no password set
    passwd -l root
fi

# Configure sudo with timeout (more secure than NOPASSWD:ALL)
echo "${USERNAME} ALL=(ALL) PASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
echo "Defaults:${USERNAME} timestamp_timeout=15" >> "/etc/sudoers.d/${USERNAME}"
chmod 440 "/etc/sudoers.d/${USERNAME}"

# Enable services
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

if systemctl list-unit-files | grep -q ssh; then
    systemctl enable ssh
fi

if systemctl list-unit-files | grep -q NetworkManager; then
    systemctl enable NetworkManager
fi

# Note: No forced password change since user set password during installation

# Ensure CA certificates are updated
apt-get update -y
apt-get install -y ca-certificates

# Update initramfs
# Set up automatic kernel syncing to ESP
cat > /etc/apt/apt.conf.d/99-sync-kernels-to-esp <<'HOOK'
// Automatically sync kernel and initrd to ESP after apt operations
DPkg::Post-Invoke {
    "if [ -d /boot/efi ] && [ -x /usr/local/bin/sync-kernels-to-esp ]; then /usr/local/bin/sync-kernels-to-esp; fi";
};
HOOK

# Create the kernel sync script
cat > /usr/local/bin/sync-kernels-to-esp <<'SYNCSCRIPT'
#!/bin/bash
# Sync latest kernel and initrd to ESP for systemd-boot

set -euo pipefail

ESP="/boot/efi"
LOG_FACILITY="local0.info"

# Function to log messages
log_message() {
    logger -p "$LOG_FACILITY" -t "kernel-sync" "$1" 2>/dev/null || true
    echo "[$(date)] $1" >&2
}

# Check if ESP is mounted
if ! mountpoint -q "$ESP"; then
    log_message "ESP not mounted at $ESP, skipping kernel sync"
    exit 0
fi

# Get latest kernel version
KERNEL_VERSION=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed "s#.*/vmlinuz-##" | sort -V | tail -1)

if [[ -z "$KERNEL_VERSION" ]]; then
    log_message "No kernel found in /boot"
    exit 1
fi

log_message "Syncing kernel $KERNEL_VERSION to ESP"

# Copy kernel and initrd to ESP
if [[ -f "/boot/vmlinuz-$KERNEL_VERSION" ]]; then
    cp "/boot/vmlinuz-$KERNEL_VERSION" "$ESP/" || {
        log_message "Failed to copy kernel to ESP"
        exit 1
    }
fi

if [[ -f "/boot/initrd.img-$KERNEL_VERSION" ]]; then
    cp "/boot/initrd.img-$KERNEL_VERSION" "$ESP/" || {
        log_message "Failed to copy initrd to ESP"
        exit 1
    }
fi

# Update systemd-boot entry if it exists
if [[ -f "$ESP/loader/entries/ubuntu.conf" ]]; then
    sed -i "s/vmlinuz-.*/vmlinuz-$KERNEL_VERSION/" "$ESP/loader/entries/ubuntu.conf"
    sed -i "s/initrd.img-.*/initrd.img-$KERNEL_VERSION/" "$ESP/loader/entries/ubuntu.conf"
    log_message "Updated systemd-boot entry for kernel $KERNEL_VERSION"
fi

log_message "Kernel sync completed successfully"
SYNCSCRIPT

# Make the sync script executable
chmod +x /usr/local/bin/sync-kernels-to-esp

# Update initramfs
update-initramfs -c -k all

# Run initial kernel sync
/usr/local/bin/sync-kernels-to-esp || true

# Optional: run post-install script if provided
if [[ -x /tmp/post-install.sh ]]; then
    echo "Running post-install script..."
    /tmp/post-install.sh || echo "Post-install script exited with non-zero status"
fi

echo "Finalization complete"
SCRIPT
    
    chmod +x /mnt/tmp/finalize.sh
    
    # Optionally copy post-install script into chroot
    if [[ -n "${POST_INSTALL_SCRIPT:-}" ]] && [[ -f "${POST_INSTALL_SCRIPT}" ]]; then
        cp "${POST_INSTALL_SCRIPT}" /mnt/tmp/post-install.sh || log WARNING "Failed to copy post-install script"
        chroot /mnt chmod +x /tmp/post-install.sh || true
    fi

    # Set variables in chroot environment
    export USERNAME USER_PASSWORD ROOT_PASSWORD
    chroot /mnt /bin/bash -c "USERNAME='${USERNAME}' USER_PASSWORD='${USER_PASSWORD}' ROOT_PASSWORD='${ROOT_PASSWORD}' /tmp/finalize.sh" || die "Failed to finalize installation"
    
    # Clean up
    rm -f /mnt/tmp/*.sh
    
    # Comprehensive cleanup with error handling
    log INFO "Cleaning up installation environment..."
    
    # Unmount filesystems in proper reverse order
    local mounts_to_unmount=(
        "/mnt/dev/pts"
        "/mnt/dev"
        "/mnt/run"
        "/mnt/sys" 
        "/mnt/proc"
        "/mnt/boot/efi"
    )
    
    for mount_point in "${mounts_to_unmount[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            if ! umount "$mount_point" 2>/dev/null; then
                log WARNING "Failed to unmount $mount_point, trying lazy unmount"
                umount -l "$mount_point" 2>/dev/null || log WARNING "Lazy unmount also failed for $mount_point"
            fi
        fi
    done
    
    # Export pool cleanly with verification
    if zpool list "${POOL_NAME}" &>/dev/null; then
        if ! zpool export "${POOL_NAME}" 2>/dev/null; then
            log WARNING "Failed to export ZFS pool cleanly, forcing export"
            zpool export -f "${POOL_NAME}" 2>/dev/null || log ERROR "Failed to force export ZFS pool"
        fi
    fi
    
    save_state "INSTALLATION_COMPLETE" "true"
    
    log SUCCESS "Installation complete!"
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo
    echo "System Information:"
    echo "  Username: ${USERNAME}"
    echo "  Hostname: ${HOSTNAME}"
    echo "  ZFS Pool: ${POOL_NAME}"
    echo "  Encryption: ${ENCRYPTION}"
    echo
    if [[ -n "${ROOT_PASSWORD}" ]]; then
        echo "You can log in as '${USERNAME}' or 'root' with the passwords you set during installation."
    else
        echo "You can log in as '${USERNAME}' with the password you set during installation."
        echo "Root login is disabled for security."
    fi
    echo
    echo "Boot environments are managed with 'zectl' - see README.md for usage examples."
    echo
    if confirm "Reboot now?"; then
        reboot
    else
        echo "You can manually reboot when ready: sudo reboot"
    fi
}

#############################################################
# Main Function
#############################################################

main() {
    # Setup logging
    mkdir -p "${LOG_DIR}"
    
    log INFO "Ubuntu ZFS Boot Environment Installer v${VERSION}"
    log INFO "Starting installation process..."
    
    # Check prerequisites
    check_root
    check_uefi
    check_dependencies
    detect_ubuntu_version
    
    # Load any existing configuration
    load_config
    load_state
    
    # Interactive configuration if needed (skip if non-interactive)
    if [[ "$NON_INTERACTIVE" != true ]]; then
        if [[ -z "${DISK}" ]] || [[ -z "${USERNAME}" ]]; then
            interactive_config
        fi
    fi
    
    # Installation steps
    if [[ "${DISK_PREPARED:-false}" != "true" ]]; then
        prepare_disk
    fi
    
    if [[ "${ZFS_CREATED:-false}" != "true" ]]; then
        create_zfs_pool
    fi
    
    if [[ "${BASE_INSTALLED:-false}" != "true" ]]; then
        install_base_system
    fi
    
    if [[ "${SYSTEM_CONFIGURED:-false}" != "true" ]]; then
        configure_system
    fi
    
    if [[ "${ZECTL_INSTALLED:-false}" != "true" ]]; then
        install_zectl
    fi
    
    if [[ "${SYSTEMD_BOOT_INSTALLED:-false}" != "true" ]]; then
        install_systemd_boot
    fi
    
    if [[ "${INSTALLATION_COMPLETE:-false}" != "true" ]]; then
        finalize_installation
    fi
}

# Handle arguments
case "${1:-}" in
    --help|-h)
        echo "Ubuntu ZFS Boot Environment Installer"
        echo "Usage: $0 [options]"
        echo
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --version, -v  Show version information"
        echo "  --resume       Resume interrupted installation"
        echo "  --reset        Reset installation state"
        exit 0
        ;;
    --version|-v)
        echo "Ubuntu ZFS Boot Environment Installer v${VERSION}"
        exit 0
        ;;
    --resume)
        log INFO "Resuming installation..."
        ;;
    --reset)
        rm -f "${STATE_FILE}"
        log INFO "Installation state reset"
        exit 0
        ;;
esac

# Run main installation
# Additional CLI flags
NON_INTERACTIVE=false
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --non-interactive)
            NON_INTERACTIVE=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
    esac
done

# Non-interactive mode validation
if [[ "$NON_INTERACTIVE" == true ]]; then
    if [[ -z "${DISK}" || -z "${USERNAME}" || -z "${HOSTNAME}" ]]; then
        echo "Missing required config (DISK, USERNAME, HOSTNAME) for --non-interactive"
        exit 1
    fi
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run: no changes will be made"
    echo "Configuration Summary:"
    echo "  Disk: ${DISK:-<unset>}"
    echo "  Pool: ${POOL_NAME}"
    echo "  Swap: ${SWAP_SIZE}"
    echo "  Encryption: ${ENCRYPTION}"
    echo "  User: ${USERNAME:-<unset>}"
    echo "  Hostname: ${HOSTNAME:-<unset>}"
    echo "  Timezone: ${TIMEZONE}"
    echo "Planned steps: prepare_disk, create_zfs_pool, install_base_system, configure_system, install_zectl, install_systemd_boot, finalize_installation"
    exit 0
fi

main "$@"
