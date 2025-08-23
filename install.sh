#!/usr/bin/env bash

#############################################################
# Ubuntu ZFS Boot Environment Installer
# 
# A modern, modular installer for Ubuntu with ZFS root,
# boot environments (zectl), and zfsbootmenu support.
#############################################################

set -euo pipefail

# Script metadata
readonly VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly LOG_DIR="/var/log/ubuntu-zfs-installer"
readonly LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"

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

check_dependencies() {
    log INFO "Checking and installing dependencies..."
    
    # Update package cache
    apt-get update || die "Failed to update package cache"
    
    # Install required packages
    local packages=("debootstrap" "gdisk" "zfsutils-linux" "efibootmgr" "arch-install-scripts" "dosfstools")
    
    apt-get install -y "${packages[@]}" || die "Failed to install dependencies"
    
    # Load ZFS module if not loaded
    if ! lsmod | grep -q zfs; then
        modprobe zfs || die "Failed to load ZFS module"
    fi
    
    # Check if we're in a live environment
    if [[ ! -f /etc/apt/sources.list ]] || ! grep -q "universe" /etc/apt/sources.list; then
        log WARNING "Adding universe repository..."
        add-apt-repository universe -y || true
        apt-get update || true
    fi
}

detect_ubuntu_version() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        UBUNTU_VERSION="${VERSION_ID}"
        log INFO "Detected Ubuntu version: ${UBUNTU_VERSION}"
    else
        die "Cannot detect Ubuntu version"
    fi
}

save_state() {
    local key="$1"
    local value="$2"
    
    echo "${key}=${value}" >> "${STATE_FILE}"
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

interactive_config() {
    log INFO "Starting interactive configuration..."
    
    # Select installation type
    echo "Select installation type:"
    echo "1) Server (minimal)"
    echo "2) Desktop (with GUI)"
    echo "3) Custom"
    read -rp "Choice [1-3]: " choice
    
    case "${choice}" in
        1) INSTALL_TYPE="server" ;;
        2) INSTALL_TYPE="desktop" ;;
        3) INSTALL_TYPE="custom" ;;
        *) INSTALL_TYPE="server" ;;
    esac
    
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
    
    # User configuration
    read -rp "Enter username for the new system: " USERNAME
    read -rp "Enter hostname: " HOSTNAME
    
    # Timezone
    read -rp "Enter timezone [${TIMEZONE}]: " input
    TIMEZONE="${input:-${TIMEZONE}}"
    
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
    
    # Handle NVMe drives (nvme0n1p1) vs SATA drives (sda1)
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]] || [[ "$disk" =~ mmcblk[0-9]+$ ]]; then
        echo "${disk}p${partition_num}"
    else
        echo "${disk}${partition_num}"
    fi
}

prepare_disk() {
    log INFO "Preparing disk ${DISK}..."
    
    # Unmount any existing filesystems
    log INFO "Unmounting existing filesystems..."
    umount "${DISK}"* 2>/dev/null || true
    
    # Stop any swap on the disk
    swapoff "${DISK}"* 2>/dev/null || true
    
    # Wipe disk
    log INFO "Wiping disk signatures..."
    wipefs -af "${DISK}" || die "Failed to wipe disk"
    sgdisk --zap-all "${DISK}" || die "Failed to zap disk"
    
    # Create partitions
    log INFO "Creating partitions..."
    sgdisk -n1:1M:+1G -t1:EF00 "${DISK}" || die "Failed to create EFI partition"  # EFI partition
    sgdisk -n2:0:+${SWAP_SIZE} -t2:8200 "${DISK}" || die "Failed to create swap partition"  # Swap partition  
    sgdisk -n3:0:0 -t3:BF00 "${DISK}" || die "Failed to create ZFS partition"  # ZFS partition
    
    # Wait for devices to settle
    sleep 3
    partprobe "${DISK}" || die "Failed to update partition table"
    udevadm settle || true
    sleep 2
    
    # Get partition names
    local efi_partition=$(get_partition_name "${DISK}" "1")
    local swap_partition=$(get_partition_name "${DISK}" "2")
    local zfs_partition=$(get_partition_name "${DISK}" "3")
    
    log INFO "Partitions: EFI=${efi_partition}, Swap=${swap_partition}, ZFS=${zfs_partition}"
    
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
    if [[ "$SWAP_SIZE" != "0" ]] && [[ "$SWAP_SIZE" != "0G" ]]; then
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
    
    # Create pool with optimal settings
    local pool_opts=(
        -o ashift=12
        -o autotrim=on
        -O acltype=posixacl
        -O canmount=off
        -O compression=lz4
        -O dnodesize=auto
        -O normalization=formD
        -O relatime=on
        -O xattr=sa
        -O mountpoint=/
        -R /mnt
    )
    
    if [[ "${ENCRYPTION}" == "on" ]]; then
        if [[ -n "${PASSPHRASE}" ]]; then
            pool_opts+=(
                -O encryption=aes-256-gcm
                -O keylocation=prompt
                -O keyformat=passphrase
            )
        else
            die "Encryption enabled but no passphrase provided"
        fi
    fi
    
    log INFO "Creating ZFS pool on ${zfs_partition}..."
    
    if [[ "${ENCRYPTION}" == "on" ]]; then
        echo "$PASSPHRASE" | zpool create -f "${pool_opts[@]}" "${POOL_NAME}" "${zfs_partition}" || die "Failed to create encrypted ZFS pool"
    else
        zpool create -f "${pool_opts[@]}" "${POOL_NAME}" "${zfs_partition}" || die "Failed to create ZFS pool"
    fi
    
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
    
    save_state "ZFS_CREATED" "true"
}

detect_ubuntu_codename() {
    case "${UBUNTU_VERSION}" in
        22.04) echo "jammy" ;;
        24.04) echo "noble" ;;
        25.04) echo "plucky" ;;
        *) 
            # Try to detect from current environment
            if [[ -f /etc/os-release ]]; then
                . /etc/os-release
                echo "${VERSION_CODENAME:-jammy}"
            else
                echo "jammy"
            fi
            ;;
    esac
}

install_base_system() {
    log INFO "Installing base system..."
    
    local codename=$(detect_ubuntu_codename)
    local mirror="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
    
    log INFO "Using Ubuntu ${UBUNTU_VERSION} (${codename}) from ${mirror}"
    
    # Essential packages for ZFS boot
    local essential_packages="locales,systemd-sysv,zfsutils-linux,zfs-initramfs"
    
    # Base packages
    local base_packages="linux-image-generic,linux-headers-generic,grub-efi-amd64,efibootmgr,systemd-boot"
    
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
    
    # Run debootstrap
    log INFO "Running debootstrap with packages: ${all_packages}"
    debootstrap \
        --arch=amd64 \
        --include="${all_packages}" \
        --components=main,restricted,universe,multiverse \
        "${codename}" \
        /mnt \
        "${mirror}" || die "Failed to run debootstrap"
    
    # Configure apt sources
    log INFO "Configuring apt sources..."
    cat > /mnt/etc/apt/sources.list <<EOF
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb ${mirror} ${codename}-security main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
EOF
    
    # Copy network configuration
    cp /etc/resolv.conf /mnt/etc/ || log WARNING "Failed to copy resolv.conf"
    
    # Mount necessary filesystems for chroot
    mount -t proc proc /mnt/proc || die "Failed to mount proc"
    mount -t sysfs sys /mnt/sys || die "Failed to mount sys"
    mount -B /dev /mnt/dev || die "Failed to mount dev"
    mount -t devpts devpts /mnt/dev/pts || die "Failed to mount devpts"
    
    save_state "BASE_INSTALLED" "true"
}

configure_system() {
    log INFO "Configuring system..."
    
    # Create fstab
    cat > /mnt/etc/fstab <<EOF
# /etc/fstab: static file system information.
# ZFS filesystems are mounted by ZFS, not fstab
UUID=$(blkid -s UUID -o value "${EFI_PARTITION}") /boot/efi vfat defaults 0 1
EOF

    # Add swap if configured
    if [[ "$SWAP_SIZE" != "0" ]] && [[ "$SWAP_SIZE" != "0G" ]]; then
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
    echo "LANG=${LOCALE}" > /mnt/etc/locale.conf
    echo "${LOCALE} UTF-8" > /mnt/etc/locale.gen
    chroot /mnt locale-gen || log WARNING "Failed to generate locales"
    chroot /mnt update-locale LANG="${LOCALE}" || log WARNING "Failed to update locale"
    
    # Configure machine-id
    chroot /mnt systemd-machine-id-setup || log WARNING "Failed to setup machine-id"
    
    save_state "SYSTEM_CONFIGURED" "true"
}

install_zectl() {
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
    
    # Get kernel version
    local kernel_version=$(chroot /mnt ls /boot/vmlinuz-* | sed 's/.*vmlinuz-//' | head -n1)
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

# Create user
if ! id "${USERNAME}" &>/dev/null; then
    useradd -m -G sudo,adm,cdrom,plugdev,lpadmin -s /bin/bash "${USERNAME}"
fi

# Set passwords
echo "${USERNAME}:changeme" | chpasswd
echo "root:changeme" | chpasswd

# Configure sudo
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
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

# Update initramfs
update-initramfs -c -k all

echo "Finalization complete"
SCRIPT
    
    chmod +x /mnt/tmp/finalize.sh
    
    # Set USERNAME in chroot environment
    export USERNAME
    chroot /mnt /bin/bash -c "USERNAME='${USERNAME}' /tmp/finalize.sh" || die "Failed to finalize installation"
    
    # Install zectl after system is ready
    install_zectl
    
    # Clean up
    rm -f /mnt/tmp/*.sh
    
    # Unmount filesystems in reverse order
    umount /mnt/dev/pts 2>/dev/null || true
    umount /mnt/dev 2>/dev/null || true  
    umount /mnt/sys 2>/dev/null || true
    umount /mnt/proc 2>/dev/null || true
    umount /mnt/boot/efi || log WARNING "Failed to unmount EFI partition"
    
    # Export pool cleanly
    zpool export "${POOL_NAME}" || log WARNING "Failed to export ZFS pool"
    
    save_state "INSTALLATION_COMPLETE" "true"
    
    log SUCCESS "Installation complete!"
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo
    echo "Default login credentials:"
    echo "  Username: ${USERNAME}"
    echo "  Password: changeme"
    echo "  Root password: changeme"
    echo
    echo "IMPORTANT: Change these passwords after first login!"
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
    check_dependencies
    detect_ubuntu_version
    
    # Load any existing configuration
    load_config
    load_state
    
    # Interactive configuration if needed
    if [[ -z "${DISK}" ]] || [[ -z "${USERNAME}" ]]; then
        interactive_config
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
main "$@"