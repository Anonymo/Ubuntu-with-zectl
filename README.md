# Ubuntu with zectl

ZFS boot environment management for Ubuntu - never break your system again!

## What is this?

This installer gives you:
- **Boot Environments** - Multiple versions of your system you can switch between
- **Automatic Snapshots** - Backup before every update
- **Easy Rollback** - Boot into a previous working state if something breaks
- **ZFS Benefits** - Compression, checksums, and data integrity

## Quick Install

Boot from Ubuntu Live USB, then:

```bash
# Download and run
wget https://raw.githubusercontent.com/Anonymo/Ubuntu-with-zectl/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## Requirements

- Ubuntu 22.04, 24.04, or 25.04 Live USB
- UEFI system
- 8GB+ RAM
- 20GB+ storage

## Basic Usage

After installation, manage your system with these commands:

```bash
# List boot environments
zectl list

# Create backup before updates
zectl create pre-update
apt upgrade

# Something broke? Rollback!
zectl activate pre-update
reboot
```

## Configuration

Edit `installer.conf` before running the installer to customize your installation:

```bash
# Edit the configuration
nano installer.conf

# Run with your settings
sudo ./install.sh
```

Key settings:
- `DISK` - Target drive (e.g., `/dev/sda` or `/dev/nvme0n1`)
- `USERNAME` - Your login name
- `HOSTNAME` - Computer name
- `ENCRYPTION` - Enable disk encryption (`on` or `off`)
- `INSTALL_TYPE` - `server`, `desktop`, or `minimal`

Advanced flags:
- `--dry-run` prints a summary of planned actions and exits without making changes.
- `--non-interactive` runs without prompts; requires `DISK`, `USERNAME`, and `HOSTNAME` to be set in `installer.conf`.

## Helper Scripts

We include a helper script for common tasks:

```bash
# System upgrade with automatic backup
./scripts/zectl-helper.sh upgrade

# Quick rollback to previous state
./scripts/zectl-helper.sh rollback

# Check system status
./scripts/zectl-helper.sh status
```

## Common Tasks

### Before Major Updates
```bash
zectl create pre-update
apt upgrade
# If it breaks: zectl activate pre-update && reboot
```

### Regular Backups
```bash
# Automatic daily snapshots are enabled by default
# Manual snapshot:
zectl snapshot
```

### Clean Up Old Environments
```bash
zectl list                    # See what you have
zectl destroy old-environment  # Remove old ones
```

## Troubleshooting

### System Won't Boot?

1. Reboot and select an older environment from the boot menu
2. Once booted, make it permanent:
   ```bash
   zectl activate working-environment
   ```

### Need to Access Your Data from Live USB?

```bash
# Import your pool
zpool import -f rpool

# Mount it
zfs mount rpool/ROOT/ubuntu

# Your files are in /mnt
```

## Project Structure

```
.
├── install.sh                 # Main installer
├── installer.conf             # Configuration (edit this!)
├── README.md                  # This file
├── modules/
│   └── zectl-manager.sh      # Boot environment functions
├── scripts/
│   └── zectl-helper.sh       # Convenience commands
└── config/
    └── installer.conf.example # Example configuration
```

## Advanced Topics

See the [Wiki](https://github.com/Anonymo/Ubuntu-with-zectl/wiki) for:
- Encryption setup
- Remote backups
- Performance tuning
- Custom configurations

## Secure Boot

If Secure Boot is enabled, unsigned kernels loaded via systemd-boot will not boot. Either disable Secure Boot in firmware or enroll your own keys/sign the kernel and initrd. This installer does not configure Secure Boot key management.

## ⚠️ Warning

This installer will **ERASE** the target disk. Backup your data first!

## Support

- [Report Issues](https://github.com/Anonymo/Ubuntu-with-zectl/issues)
- [Documentation Wiki](https://github.com/Anonymo/Ubuntu-with-zectl/wiki)

## License

MIT License - See LICENSE file

---

*Never fear updates again with ZFS boot environments!*
