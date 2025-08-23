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
ENCRYPTION="on"  # on, off
SWAP_SIZE="4G"
USERNAME=""
HOSTNAME=""
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"

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
    local deps=("debootstrap" "gdisk" "zfsutils-linux" "efibootmgr")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log WARNING "Missing dependencies: ${missing[*]}"
        log INFO "Installing missing dependencies..."
        apt-get update
        apt-get install -y "${missing[@]}"
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
    local config_file="${CONFIG_DIR}/installer.conf"
    
    if [[ -f "${config_file}" ]]; then
        log INFO "Loading configuration from ${config_file}"
        source "${config_file}"
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
    lsblk -d -o NAME,SIZE,TYPE | grep disk
    
    read -rp "Enter disk device (e.g., sda, nvme0n1): " DISK
    DISK="/dev/${DISK}"
    
    if [[ ! -b "${DISK}" ]]; then
        die "Invalid disk device: ${DISK}"
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

prepare_disk() {
    log INFO "Preparing disk ${DISK}..."
    
    # Wipe disk
    log INFO "Wiping disk signatures..."
    wipefs -af "${DISK}"
    sgdisk --zap-all "${DISK}"
    
    # Create partitions
    log INFO "Creating partitions..."
    sgdisk -n1:1M:+1G -t1:EF00 "${DISK}"  # EFI partition
    sgdisk -n2:0:+4G -t2:8200 "${DISK}"    # Swap partition  
    sgdisk -n3:0:0 -t3:BF00 "${DISK}"      # ZFS partition
    
    # Wait for devices to settle
    sleep 2
    partprobe "${DISK}"
    sleep 2
    
    # Format EFI partition
    log INFO "Formatting EFI partition..."
    mkfs.vfat -F32 -n EFI "${DISK}1" || mkfs.vfat -F32 -n EFI "${DISK}p1"
    
    # Create swap
    log INFO "Setting up swap..."
    mkswap -L swap "${DISK}2" || mkswap -L swap "${DISK}p2"
    
    save_state "DISK_PREPARED" "true"
}

create_zfs_pool() {
    log INFO "Creating ZFS pool..."
    
    local zfs_partition="${DISK}3"
    [[ ! -b "${zfs_partition}" ]] && zfs_partition="${DISK}p3"
    
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
        pool_opts+=(
            -O encryption=aes-256-gcm
            -O keylocation=prompt
            -O keyformat=passphrase
        )
    fi
    
    zpool create -f "${pool_opts[@]}" "${POOL_NAME}" "${zfs_partition}"
    
    # Create datasets
    log INFO "Creating ZFS datasets..."
    
    # Root dataset
    zfs create -o canmount=off -o mountpoint=none "${POOL_NAME}/ROOT"
    zfs create -o canmount=noauto -o mountpoint=/ "${POOL_NAME}/ROOT/ubuntu"
    
    # Mark as boot environment
    zpool set bootfs="${POOL_NAME}/ROOT/ubuntu" "${POOL_NAME}"
    
    # Home dataset (separate for snapshots)
    zfs create -o canmount=on -o mountpoint=/home "${POOL_NAME}/home"
    
    # Other datasets
    zfs create -o canmount=off -o mountpoint=/var "${POOL_NAME}/var"
    zfs create -o canmount=on "${POOL_NAME}/var/lib"
    zfs create -o canmount=on "${POOL_NAME}/var/log"
    zfs create -o canmount=on "${POOL_NAME}/var/cache"
    zfs create -o canmount=on "${POOL_NAME}/var/tmp"
    
    # Mount root
    zfs mount "${POOL_NAME}/ROOT/ubuntu"
    
    # Create mount points
    mkdir -p /mnt/boot/efi
    mount "${DISK}1" /mnt/boot/efi || mount "${DISK}p1" /mnt/boot/efi
    
    save_state "ZFS_CREATED" "true"
}

install_base_system() {
    log INFO "Installing base system..."
    
    # Determine packages based on install type
    local packages="linux-image-generic linux-headers-generic grub-efi-amd64 zfs-initramfs zfsutils-linux"
    
    case "${INSTALL_TYPE}" in
        desktop)
            packages="${packages} ubuntu-desktop"
            ;;
        server)
            packages="${packages} ubuntu-server"
            ;;
    esac
    
    # Run debootstrap
    debootstrap --arch=amd64 --include="${packages}" "${UBUNTU_VERSION}" /mnt
    
    # Copy network configuration
    cp /etc/resolv.conf /mnt/etc/
    
    save_state "BASE_INSTALLED" "true"
}

configure_system() {
    log INFO "Configuring system..."
    
    # Create fstab
    cat > /mnt/etc/fstab <<EOF
# /etc/fstab: static file system information.
UUID=$(blkid -s UUID -o value "${DISK}1" || blkid -s UUID -o value "${DISK}p1") /boot/efi vfat defaults 0 1
UUID=$(blkid -s UUID -o value "${DISK}2" || blkid -s UUID -o value "${DISK}p2") none swap sw 0 0
EOF
    
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
    
    # Configure timezone
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /mnt/etc/localtime
    
    # Configure locale
    echo "LANG=${LOCALE}" > /mnt/etc/locale.conf
    echo "${LOCALE} UTF-8" > /mnt/etc/locale.gen
    
    save_state "SYSTEM_CONFIGURED" "true"
}

install_zectl() {
    log INFO "Installing zectl for boot environment management..."
    
    cat > /mnt/tmp/install_zectl.sh <<'SCRIPT'
#!/bin/bash
set -e

# Install dependencies
apt-get update
apt-get install -y python3 python3-pip git

# Install zectl
git clone https://github.com/johnramsden/zectl /tmp/zectl
cd /tmp/zectl
python3 setup.py install

# Configure zectl
zectl set bootloader=systemd-boot

# Create initial boot environment
zectl snapshot initial

echo "zectl installed successfully"
SCRIPT
    
    chmod +x /mnt/tmp/install_zectl.sh
    chroot /mnt /tmp/install_zectl.sh
    
    save_state "ZECTL_INSTALLED" "true"
}

install_systemd_boot() {
    log INFO "Installing systemd-boot..."
    
    cat > /mnt/tmp/install_systemd_boot.sh <<'SCRIPT'
#!/bin/bash
set -e

# Install systemd-boot
apt-get update
apt-get install -y systemd-boot efibootmgr

# Install systemd-boot to ESP
bootctl --path=/boot/efi install

# Configure loader
cat > /boot/efi/loader/loader.conf <<EOF
default ubuntu
timeout 5
console-mode max
editor no
EOF

# Create entry for current boot environment
KERNEL_VERSION=$(ls /boot/vmlinuz-* | sed 's/.*vmlinuz-//' | head -n1)
ROOT_DATASET=$(df / | tail -1 | awk '{print $1}')

cat > /boot/efi/loader/entries/ubuntu.conf <<EOF
title   Ubuntu Linux
linux   /vmlinuz-${KERNEL_VERSION}
initrd  /initrd.img-${KERNEL_VERSION}
options root=ZFS=${ROOT_DATASET} rw quiet splash
EOF

# Copy kernel and initrd to ESP
cp /boot/vmlinuz-${KERNEL_VERSION} /boot/efi/
cp /boot/initrd.img-${KERNEL_VERSION} /boot/efi/

echo "systemd-boot installed successfully"
SCRIPT
    
    chmod +x /mnt/tmp/install_systemd_boot.sh
    chroot /mnt /tmp/install_systemd_boot.sh
    
    save_state "SYSTEMD_BOOT_INSTALLED" "true"
}

finalize_installation() {
    log INFO "Finalizing installation..."
    
    # Create user
    cat > /mnt/tmp/create_user.sh <<SCRIPT
#!/bin/bash
set -e

# Create user
useradd -m -G sudo,adm,cdrom,plugdev -s /bin/bash ${USERNAME}
echo "${USERNAME}:changeme" | chpasswd
echo "root:changeme" | chpasswd

# Configure sudo
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}

# Update initramfs
update-initramfs -c -k all

# Configure GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub

echo "User created and bootloader configured"
SCRIPT
    
    chmod +x /mnt/tmp/create_user.sh
    chroot /mnt /tmp/create_user.sh
    
    # Clean up
    rm -f /mnt/tmp/*.sh
    
    # Export pool
    umount /mnt/boot/efi
    zpool export "${POOL_NAME}"
    
    save_state "INSTALLATION_COMPLETE" "true"
    
    log SUCCESS "Installation complete!"
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo "Default passwords have been set to 'changeme'"
    echo "Please change them after first login."
    echo
    echo "You can now reboot into your new system."
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