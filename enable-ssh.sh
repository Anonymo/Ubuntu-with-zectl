#!/usr/bin/env bash

#############################################################
# SSH Enabler for Ubuntu Live Environment
# 
# This script enables SSH access in a Ubuntu live environment
# allowing remote installation via the main installer script.
#############################################################

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  Ubuntu Live SSH Enabler${NC}"
echo -e "${CYAN}============================================${NC}\n"

# Function to get network interfaces and IPs
show_network_info() {
    echo -e "${BLUE}Network Interfaces:${NC}"
    echo -e "${YELLOW}-------------------${NC}"
    
    # Get all interfaces except lo
    for interface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        # Get IP address if available
        ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        
        if [[ -n "$ip_addr" ]]; then
            echo -e "${GREEN}✓${NC} $interface: ${GREEN}$ip_addr${NC}"
        else
            echo -e "${YELLOW}○${NC} $interface: ${YELLOW}no IP address${NC}"
        fi
    done
    echo
}

# Function to ensure network is up
ensure_network() {
    echo -e "${BLUE}Checking network connectivity...${NC}"
    
    # Check if NetworkManager is running
    if systemctl is-active --quiet NetworkManager; then
        echo -e "${GREEN}✓${NC} NetworkManager is running"
    else
        echo -e "${YELLOW}Starting NetworkManager...${NC}"
        systemctl start NetworkManager || true
        sleep 2
    fi
    
    # Try to bring up all ethernet interfaces
    for interface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)'); do
        if ! ip link show "$interface" | grep -q "UP"; then
            echo -e "${YELLOW}Bringing up $interface...${NC}"
            ip link set "$interface" up 2>/dev/null || true
        fi
    done
    
    # Wait a moment for DHCP
    sleep 3
    
    # Check for any IP addresses
    if ip -4 addr show | grep -q "inet "; then
        echo -e "${GREEN}✓${NC} Network is configured"
    else
        echo -e "${YELLOW}⚠${NC} No IP addresses found. You may need to configure network manually."
        echo -e "   Try: ${CYAN}sudo dhclient${NC} or configure WiFi via GUI"
    fi
    echo
}

# Install and configure SSH
setup_ssh() {
    echo -e "${BLUE}Setting up SSH server...${NC}"
    
    # Update package cache if needed
    if [[ ! -f /var/lib/apt/lists/lock ]]; then
        echo -e "${YELLOW}Updating package cache...${NC}"
        apt-get update -qq || true
    fi
    
    # Install OpenSSH server
    if ! command -v sshd &> /dev/null; then
        echo -e "${YELLOW}Installing OpenSSH server...${NC}"
        apt-get install -y -qq openssh-server || {
            echo -e "${RED}Failed to install OpenSSH server${NC}"
            echo -e "You may need to configure apt sources or network first"
            exit 1
        }
    else
        echo -e "${GREEN}✓${NC} OpenSSH server is already installed"
    fi
    
    # Configure SSH
    echo -e "${BLUE}Configuring SSH...${NC}"
    
    # Backup original config if it exists
    if [[ -f /etc/ssh/sshd_config ]] && [[ ! -f /etc/ssh/sshd_config.backup ]]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    fi
    
    # Enable root login and password authentication for live environment
    cat > /etc/ssh/sshd_config.d/99-live-installer.conf <<EOF
# Temporary SSH configuration for live installer
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
    
    echo -e "${GREEN}✓${NC} SSH configured for installation"
}

# Set up user access
setup_user_access() {
    echo -e "${BLUE}Setting up user access...${NC}"
    
    # Check if ubuntu user exists (common in live environments)
    if id ubuntu &>/dev/null; then
        echo -e "${YELLOW}Setting password for 'ubuntu' user...${NC}"
        echo -e "${CYAN}Enter password for 'ubuntu' user:${NC}"
        if passwd ubuntu; then
            echo -e "${GREEN}✓${NC} Password set for 'ubuntu' user"
        else
            echo -e "${RED}Failed to set password for 'ubuntu' user${NC}"
        fi
        
        # Add ubuntu to sudo group if not already
        usermod -aG sudo ubuntu 2>/dev/null || true
    fi
    
    # Enable root access
    echo -e "\n${YELLOW}Setting password for 'root' user...${NC}"
    echo -e "${CYAN}Enter password for 'root' user:${NC}"
    if passwd root; then
        echo -e "${GREEN}✓${NC} Password set for 'root' user"
    else
        echo -e "${RED}Failed to set password for 'root' user${NC}"
    fi
}

# Start SSH service
start_ssh_service() {
    echo -e "\n${BLUE}Starting SSH service...${NC}"
    
    # Generate host keys if they don't exist
    if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
        echo -e "${YELLOW}Generating SSH host keys...${NC}"
        ssh-keygen -A
    fi
    
    # Start SSH service
    if systemctl start ssh || systemctl start sshd; then
        echo -e "${GREEN}✓${NC} SSH service started successfully"
        
        # Enable SSH service
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    else
        echo -e "${RED}Failed to start SSH service${NC}"
        exit 1
    fi
    
    # Verify SSH is running
    if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
        echo -e "${GREEN}✓${NC} SSH service is running"
    else
        echo -e "${RED}SSH service is not running${NC}"
        exit 1
    fi
}

# Download installer if needed
setup_installer() {
    echo -e "\n${BLUE}Setting up installer...${NC}"
    
    local installer_dir="/root/Ubuntu-with-zectl"
    
    if [[ -d "$installer_dir" ]]; then
        echo -e "${GREEN}✓${NC} Installer already present at $installer_dir"
        
        # Make sure it's executable
        chmod +x "$installer_dir/install.sh" 2>/dev/null || true
    else
        echo -e "${YELLOW}Downloading installer...${NC}"
        
        # Install git if needed
        if ! command -v git &> /dev/null; then
            apt-get install -y -qq git || {
                echo -e "${RED}Failed to install git${NC}"
                exit 1
            }
        fi
        
        # Clone the repository
        cd /root
        if git clone https://github.com/Anonymo/Ubuntu-with-zectl.git; then
            echo -e "${GREEN}✓${NC} Installer downloaded to $installer_dir"
            chmod +x "$installer_dir/install.sh"
        else
            echo -e "${YELLOW}⚠${NC} Failed to download installer automatically"
            echo -e "   You can manually clone it after connecting via SSH:"
            echo -e "   ${CYAN}git clone https://github.com/Anonymo/Ubuntu-with-zectl.git${NC}"
        fi
    fi
}

# Show connection information
show_connection_info() {
    echo -e "\n${GREEN}============================================${NC}"
    echo -e "${GREEN}  SSH Access Enabled Successfully!${NC}"
    echo -e "${GREEN}============================================${NC}\n"
    
    echo -e "${CYAN}Connection Information:${NC}"
    echo -e "${YELLOW}----------------------${NC}"
    
    # Get primary IP address
    primary_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || \
                 ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    
    if [[ -n "$primary_ip" ]]; then
        echo -e "${GREEN}Primary IP:${NC} $primary_ip\n"
        
        echo -e "${CYAN}Connect from your main machine using:${NC}"
        echo -e "${YELLOW}--------------------------------------${NC}"
        
        # Show connection commands
        if id ubuntu &>/dev/null 2>&1; then
            echo -e "As ubuntu user:"
            echo -e "  ${GREEN}ssh ubuntu@$primary_ip${NC}"
            echo
        fi
        
        echo -e "As root user:"
        echo -e "  ${GREEN}ssh root@$primary_ip${NC}"
        echo
        
        echo -e "${CYAN}After connecting, run the installer:${NC}"
        echo -e "${YELLOW}------------------------------------${NC}"
        echo -e "  ${GREEN}cd /root/Ubuntu-with-zectl${NC}"
        echo -e "  ${GREEN}sudo ./install.sh${NC}"
        echo
        
        # Show all IPs
        echo -e "${CYAN}All Network Interfaces:${NC}"
        echo -e "${YELLOW}----------------------${NC}"
        show_network_info
    else
        echo -e "${RED}No IP address found!${NC}"
        echo -e "Please configure network manually and check with:"
        echo -e "  ${CYAN}ip addr show${NC}"
    fi
    
    # Show SSH status
    echo -e "${CYAN}SSH Service Status:${NC}"
    echo -e "${YELLOW}------------------${NC}"
    systemctl status ssh --no-pager 2>/dev/null || systemctl status sshd --no-pager 2>/dev/null || true
}

# Main execution
main() {
    # Ensure network is up
    ensure_network
    
    # Show current network info
    show_network_info
    
    # Set up SSH
    setup_ssh
    
    # Set up user access
    setup_user_access
    
    # Start SSH service
    start_ssh_service
    
    # Set up installer
    setup_installer
    
    # Show connection info
    show_connection_info
}

# Run main function
main "$@"