# Ubuntu ZFS Installer Error Codes

## How to Report Errors

When an error occurs, the installer will display:
1. **Error Code** (e.g., E030)
2. **Description** of what failed
3. **Context** information if available
4. **Log file** location

To report an issue, please provide:
- The error code
- Last 50 lines of the log: `tail -50 /var/log/ubuntu-zfs-installer/install-*.log`
- System info: `lsblk && uname -a`

## Error Code Reference

### System Requirements (E001-E019)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E001 | Not running as root | Script run without sudo | Run with: `sudo ./install.sh` |
| E002 | Not a UEFI system | Legacy BIOS boot | Reboot in UEFI mode |
| E003 | EFI variables not accessible | Secure Boot or permissions | Check UEFI settings |
| E004 | Missing required dependency | Package not installed | Install missing package |
| E005 | Ubuntu version not supported | Incompatible Ubuntu release | Use Ubuntu 20.04+ |

### Disk Operations (E020-E029)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E020 | Failed to prepare disk | Disk in use | Unmount partitions, stop processes |
| E021 | Failed to partition disk | Disk locked or bad | Check disk health, retry |
| E022 | Failed to format ESP | Partition issues | Check partition table |
| E023 | Disk too small | <20GB disk | Use larger disk |
| E024 | Disk device not found | Wrong path or disconnected | Verify disk path with `lsblk` |
| E025 | Failed to wipe disk | Protected or failing disk | Check write protection |
| E026 | Partition creation failed | GPT issues | Check with `gdisk` |

### ZFS Operations (E030-E039)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E030 | Failed to create ZFS pool | Disk issues or ZFS module | Load ZFS module: `modprobe zfs` |
| E031 | Failed to create ROOT dataset | Pool creation issue | Check pool status |
| E032 | Failed to mount dataset | Dataset or mount issues | Check `zfs list` |
| E033 | ZFS module not loaded | Module missing | Install zfs-dkms |
| E034 | Pool import failed | Pool busy or corrupt | Check `zpool status` |
| E035 | Dataset creation failed | Parent dataset issue | Verify pool exists |
| E036 | Property setting failed | Invalid property | Check property name |

### Installation (E040-E049)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E040 | Debootstrap failed | Network or mirror issues | Check internet connection |
| E041 | Base system install failed | Package conflicts | Check apt logs |
| E042 | Package installation failed | Broken dependencies | Fix with `apt -f install` |
| E043 | Network unreachable | No internet | Configure network |
| E044 | Mirror validation failed | Mirror down | Use different mirror |
| E045 | Local repository not found | Not on live USB | Use network install |
| E046 | APT update failed | Sources issue | Check sources.list |

### Configuration (E050-E059)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E050 | Configuration failed | Script error | Check log for details |
| E051 | Locale generation failed | Invalid locale | Check locale name |
| E052 | Timezone config failed | Invalid timezone | Use valid timezone |
| E053 | Network config failed | Interface issues | Check network setup |
| E054 | User creation failed | Invalid username | Use valid username |
| E055 | Password setting failed | Invalid password | Meet password requirements |

### Boot Management (E060-E069)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E060 | systemd-boot install failed | ESP not mounted | Check /boot/efi mount |
| E061 | Boot entry creation failed | Config error | Check boot config |
| E062 | ESP mount failed | Partition issues | Verify ESP partition |
| E063 | Kernel copy failed | No space on ESP | Clear ESP space |
| E064 | Initramfs generation failed | Kernel issues | Check kernel install |
| E065 | Boot config failed | Invalid config | Review boot settings |

### zectl/BE Management (E070-E079)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E070 | zectl installation failed | Network or build error | Check internet, retry |
| E071 | zectl not functional | Installation incomplete | Reinstall zectl |
| E072 | BE creation failed | ZFS dataset issues | Check pool status |
| E073 | Git clone failed | Network issues | Check GitHub access |
| E074 | Python setup failed | Missing python deps | Install python3-dev |
| E075 | zectl command not found | PATH issue | Check installation |

### Finalization (E080-E089)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E080 | Finalization failed | Script error | Check finalize.sh log |
| E081 | Cleanup failed | Mount issues | Manual cleanup needed |
| E082 | Unmount failed | Busy filesystem | Stop using processes |
| E083 | Pool export failed | Pool in use | Close pool operations |
| E084 | State save failed | Write permissions | Check state file perms |

### User Errors (E090-E099)

| Code | Description | Common Causes | Solutions |
|------|-------------|---------------|-----------|
| E090 | User cancelled | User choice | Restart if desired |
| E091 | Invalid configuration | Config syntax | Fix configuration file |
| E092 | Config file not found | Missing file | Create installer.conf |
| E093 | Invalid disk selection | Wrong disk chosen | Select correct disk |
| E094 | Installation media selected | Selected USB/DVD as target | Choose different disk |

## Common Recovery Steps

### If installation fails mid-way:

1. **Clean up mounts:**
   ```bash
   umount -R /mnt 2>/dev/null || true
   zpool export -f rpool 2>/dev/null || true
   ```

2. **Restart installer with cleanup:**
   ```bash
   ./install.sh --restart
   ```

3. **Check system state:**
   ```bash
   # Check mounts
   mount | grep /mnt
   
   # Check ZFS pools
   zpool list
   
   # Check disk status
   lsblk
   ```

### For network issues:

1. **Test connectivity:**
   ```bash
   ping -c 3 archive.ubuntu.com
   ```

2. **Check DNS:**
   ```bash
   nslookup archive.ubuntu.com
   ```

3. **Use different mirror:**
   ```bash
   UBUNTU_MIRROR=http://us.archive.ubuntu.com/ubuntu ./install.sh
   ```

## Debug Mode

Run installer with debug output:
```bash
DEBUG=true ./install.sh 2>&1 | tee install.log
```

This will create a detailed log file for troubleshooting.