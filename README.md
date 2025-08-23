# Ubuntu with zectl - ZFS Boot Environment Management

A modern, streamlined installer for Ubuntu with ZFS root filesystem and boot environment management using `zectl` and `systemd-boot`.

## Features

- **ZFS Root Filesystem**: Full system installed on ZFS with optimal settings
- **Boot Environments**: Manage multiple bootable system states with `zectl`
- **Automatic Snapshots**: Automated snapshots before system updates
- **Easy Rollback**: Quickly revert to previous system states
- **systemd-boot Integration**: Modern UEFI boot management
- **Encryption Support**: Optional native ZFS encryption
- **Multiple Installation Types**: Server, Desktop, or Custom configurations

## Requirements

- Ubuntu 22.04, 24.04, or 25.04 installation media (Live USB/DVD)
- UEFI-capable system
- Minimum 8GB RAM (16GB recommended for desktop)
- Minimum 20GB storage (50GB+ recommended)
- Internet connection during installation

## Quick Start

1. Boot from Ubuntu Live media
2. Open a terminal and run:

```bash
# Download the installer
wget https://raw.githubusercontent.com/Anonymo/Ubuntu-with-zectl/main/install.sh
chmod +x install.sh

# Run the installer
sudo ./install.sh
```

3. Follow the interactive prompts to configure your system

## Installation Options

### Interactive Mode (Recommended)
```bash
sudo ./install.sh
```
The installer will guide you through all configuration options.

### Automated Mode
Create a configuration file first:
```bash
cat > installer.conf <<EOF
INSTALL_TYPE="server"
DISK="/dev/sda"
POOL_NAME="rpool"
ENCRYPTION="on"
USERNAME="myuser"
HOSTNAME="myserver"
TIMEZONE="America/New_York"
EOF

sudo ./install.sh --config installer.conf
```

### Resume Interrupted Installation
```bash
sudo ./install.sh --resume
```

## Boot Environment Management

After installation, you can manage boot environments using `zectl`:

### List Boot Environments
```bash
zectl list
```

### Create a New Boot Environment
```bash
# Create BE before major updates
zectl create pre-update

# Create BE with description
zectl create -d "Before kernel upgrade" kernel-update
```

### Activate a Boot Environment
```bash
zectl activate previous-be
# Reboot to use the activated BE
```

### Delete a Boot Environment
```bash
zectl destroy old-be
```

### Create and Manage Snapshots
```bash
# Snapshot current BE
zectl snapshot

# Snapshot specific BE
zectl snapshot myenv@before-changes

# Rollback to snapshot
zectl rollback myenv@before-changes
```

## System Layout

### ZFS Dataset Structure
```
rpool                       # Root pool
├── ROOT                    # Container for boot environments
│   └── ubuntu             # Default boot environment
├── home                   # User home directories
└── var                    # System state
    ├── lib                # Variable libraries
    ├── log                # System logs
    ├── cache              # Application caches
    └── tmp                # Temporary files
```

### Boot Configuration
- **Bootloader**: systemd-boot (UEFI)
- **ESP Mount**: `/boot/efi`
- **Boot Entries**: Automatically managed by zectl

## Advanced Features

### Automatic Snapshots

The system automatically creates snapshots:
- Daily snapshots (kept for 10 days)
- Pre/post package installation snapshots
- Manual snapshots via `zectl snapshot`

### APT Integration

Snapshots are automatically created before package operations:
```bash
# Automatic snapshot before upgrade
apt upgrade
# If something breaks, rollback:
zectl activate <previous-be>
```

### Recovery Environment

Create a dedicated recovery environment:
```bash
zectl create recovery
zectl mount recovery /mnt
# Install recovery tools in /mnt
zectl umount recovery
```

## Troubleshooting

### Boot Issues

1. **System won't boot after update**:
   - Reboot and select previous BE from boot menu
   - Make previous BE permanent: `zectl activate working-be`

2. **Missing boot entries**:
   ```bash
   # Regenerate systemd-boot entries
   bootctl update
   ```

3. **ZFS modules not loading**:
   ```bash
   # In recovery/live environment
   zpool import -f rpool
   zfs mount rpool/ROOT/ubuntu
   # Chroot and rebuild initramfs
   ```

### ZFS Pool Issues

1. **Import pool in live environment**:
   ```bash
   zpool import -f -R /mnt rpool
   ```

2. **Check pool status**:
   ```bash
   zpool status rpool
   ```

3. **Repair filesystem**:
   ```bash
   zpool scrub rpool
   ```

## Configuration Files

### Main Configuration
- `/etc/zectl.conf` - zectl configuration
- `/boot/efi/loader/loader.conf` - systemd-boot configuration

### Dataset Properties
View current dataset properties:
```bash
zfs get all rpool/ROOT/ubuntu
```

## Performance Tuning

### ZFS Tuning
```bash
# Set ARC max (example: 8GB)
echo "options zfs zfs_arc_max=8589934592" >> /etc/modprobe.d/zfs.conf

# Enable TRIM for SSDs
zpool set autotrim=on rpool
```

### Compression
All datasets use LZ4 compression by default. To change:
```bash
zfs set compression=zstd rpool/home
```

## Backup and Restore

### Send/Receive Backups
```bash
# Backup BE to file
zfs send rpool/ROOT/ubuntu@snapshot | gzip > backup.zfs.gz

# Restore from backup
gunzip -c backup.zfs.gz | zfs receive rpool/ROOT/restored
```

### Remote Backups
```bash
# Send to remote system
zfs send rpool/ROOT/ubuntu@snapshot | ssh remote "zfs receive tank/backups/ubuntu"
```

## Security Considerations

- Encryption keys are stored in the initramfs (if encryption enabled)
- Regular snapshots protect against ransomware
- Boot environments isolate system changes
- systemd-boot secure boot compatible

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## Support

- **Issues**: [GitHub Issues](https://github.com/Anonymo/Ubuntu-with-zectl/issues)
- **Documentation**: [Wiki](https://github.com/Anonymo/Ubuntu-with-zectl/wiki)

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Credits

- [zectl](https://github.com/johnramsden/zectl) - ZFS Boot Environment manager
- Ubuntu ZFS community
- systemd-boot developers

## Disclaimer

This installer modifies system partitions and can result in data loss. Always backup important data before proceeding. Use at your own risk.