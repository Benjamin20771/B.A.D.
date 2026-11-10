#!/bin/bash
# linux-onboard.sh
# Ben Deyot - SYS-265
# Interactive Linux system onboarding script
# Supports Ubuntu and Rocky/CentOS systems

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOGFILE="/var/log/linux-onboard.log"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO: $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS: $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING: $1"
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Function to detect Linux distribution
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        print_info "Detected OS: $NAME $VERSION"
        
        case $OS in
            ubuntu|debian)
                OS_FAMILY="debian"
                ;;
            rocky|centos|rhel|fedora)
                OS_FAMILY="rhel"
                ;;
            *)
                print_warning "Unknown OS: $OS. Attempting Debian-based configuration."
                OS_FAMILY="debian"
                ;;
        esac
    else
        print_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [ "$i" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Function to validate hostname
validate_hostname() {
    local hostname=$1
    if [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to get input (no defaults)
get_input() {
    local prompt=$1
    local var_name=$2
    local input
    
    while true; do
        read -p "$prompt: " input
        if [ -n "$input" ]; then
            eval $var_name="'$input'"
            break
        else
            print_error "Input cannot be empty. Please try again."
        fi
    done
}

# Function to get input with optional default (only used for optional fields)
get_input_optional() {
    local prompt=$1
    local default=$2
    local var_name=$3
    
    if [ -n "$default" ]; then
        read -p "$prompt (default: $default): " input
        if [ -z "$input" ]; then
            eval $var_name="$default"
        else
            eval $var_name="$input"
        fi
    else
        read -p "$prompt: " input
        eval $var_name="$input"
    fi
}

# Function to get password input
get_password() {
    local prompt=$1
    local var_name=$2
    local password
    local password_confirm
    
    while true; do
        read -s -p "$prompt: " password
        echo
        read -s -p "Confirm password: " password_confirm
        echo
        
        if [ "$password" = "$password_confirm" ]; then
            if [ -z "$password" ]; then
                print_error "Password cannot be empty"
                continue
            fi
            eval $var_name="'$password'"
            break
        else
            print_error "Passwords do not match. Try again."
        fi
    done
}

# Function to get yes/no input
get_yes_no() {
    local prompt=$1
    local default=$2
    local var_name=$3
    local response
    
    if [ "$default" = "y" ]; then
        read -p "$prompt (Y/n): " response
        response=${response:-y}
    else
        read -p "$prompt (y/N): " response
        response=${response:-n}
    fi
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        eval $var_name="true"
    else
        eval $var_name="false"
    fi
}

# Function to detect network interface
detect_interface() {
    local interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$interface" ]; then
        interface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
    fi
    echo "$interface"
}

# Function to configure network on Ubuntu (netplan)
configure_network_ubuntu() {
    print_info "Configuring network using Netplan..."
    
    local netplan_file="/etc/netplan/00-installer-config.yaml"
    
    # Backup existing config
    if [ -f "$netplan_file" ]; then
        cp "$netplan_file" "${netplan_file}.backup.$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Create netplan configuration based on DHCP or Static
    if [ "$IP_ADDRESS" = "DHCP" ]; then
        # DHCP Configuration
        if [ -n "$DNS_SECONDARY" ]; then
            cat > "$netplan_file" << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: yes
      dhcp6: no
      nameservers:
        addresses:
          - $DNS_PRIMARY
          - $DNS_SECONDARY
        search:
          - $DOMAIN
EOF
        else
            cat > "$netplan_file" << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: yes
      dhcp6: no
      nameservers:
        addresses:
          - $DNS_PRIMARY
        search:
          - $DOMAIN
EOF
        fi
    else
        # Static IP Configuration
        if [ -n "$DNS_SECONDARY" ]; then
            cat > "$netplan_file" << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: no
      dhcp6: no
      addresses:
        - $IP_ADDRESS/$NETMASK_CIDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS_PRIMARY
          - $DNS_SECONDARY
        search:
          - $DOMAIN
EOF
        else
            cat > "$netplan_file" << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: no
      dhcp6: no
      addresses:
        - $IP_ADDRESS/$NETMASK_CIDR
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS_PRIMARY
        search:
          - $DOMAIN
EOF
        fi
    fi
    
    # Set correct permissions
    chmod 600 "$netplan_file"
    
    # Apply netplan configuration
    netplan apply
    
    if [ $? -eq 0 ]; then
        print_success "Network configured successfully"
    else
        print_error "Failed to apply netplan configuration"
        return 1
    fi
    
    # Update resolv.conf
    if [ -n "$DNS_SECONDARY" ]; then
        cat > /etc/resolv.conf << EOF
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY
search $DOMAIN
EOF
    else
        cat > /etc/resolv.conf << EOF
nameserver $DNS_PRIMARY
search $DOMAIN
EOF
    fi
    
    # Handle cloud-init if present
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg
    fi
}

# Function to configure network on Rocky/CentOS
configure_network_rocky() {
    print_info "Configuring network using nmcli..."
    
    # Build DNS string
    if [ -n "$DNS_SECONDARY" ]; then
        DNS_SERVERS="$DNS_PRIMARY $DNS_SECONDARY"
    else
        DNS_SERVERS="$DNS_PRIMARY"
    fi
    
    # Set connection to manual
    nmcli con mod "$INTERFACE" ipv4.method manual \
        ipv4.addresses "$IP_ADDRESS/$NETMASK_CIDR" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$DNS_SERVERS" \
        ipv4.dns-search "$DOMAIN"
    
    # Restart connection
    nmcli con down "$INTERFACE" && nmcli con up "$INTERFACE"
    
    if [ $? -eq 0 ]; then
        print_success "Network configured successfully"
    else
        print_error "Failed to configure network"
        return 1
    fi
}

# Function to configure hostname
configure_hostname() {
    print_info "Setting hostname to $HOSTNAME..."
    
    # Set hostname
    hostnamectl set-hostname "$HOSTNAME"
    
    # Update /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME.$DOMAIN $HOSTNAME
$IP_ADDRESS $HOSTNAME.$DOMAIN $HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
    print_success "Hostname configured: $HOSTNAME"
}

# Function to create user
create_user() {
    local username=$1
    local password=$2
    local add_sudo=$3
    
    print_info "Creating user: $username"
    
    # Check if user already exists
    if id "$username" &>/dev/null; then
        print_warning "User $username already exists. Skipping creation."
        
        # Update password
        echo "$username:$password" | chpasswd
        print_info "Password updated for $username"
    else
        # Create user
        useradd -m -s /bin/bash "$username"
        
        # Set password
        echo "$username:$password" | chpasswd
        
        print_success "User $username created"
    fi
    
    # Add to sudo group if requested
    if [ "$add_sudo" = "true" ]; then
        if [ "$OS_FAMILY" = "debian" ]; then
            usermod -aG sudo "$username"
            print_success "Added $username to sudo group"
        else
            usermod -aG wheel "$username"
            print_success "Added $username to wheel group"
        fi
    fi
    
    # Add to other useful groups
    if [ "$OS_FAMILY" = "debian" ]; then
        usermod -aG adm,systemd-journal "$username" 2>/dev/null
    fi
}

# Function to configure passwordless sudo
configure_passwordless_sudo() {
    print_info "Configuring passwordless sudo..."
    
    cat > /etc/sudoers.d/sys265 << EOF
# SYS-265 - Passwordless sudo for deployer
deployer ALL=(ALL) NOPASSWD: ALL
EOF
    
    chmod 440 /etc/sudoers.d/sys265
    print_success "Passwordless sudo configured for deployer"
}

# Function to configure SSH
configure_ssh() {
    print_info "Configuring SSH..."
    
    # Install SSH if not present
    if [ "$OS_FAMILY" = "debian" ]; then
        if ! command -v sshd &> /dev/null; then
            apt install -y openssh-server
        fi
    else
        if ! command -v sshd &> /dev/null; then
            dnf install -y openssh-server
        fi
    fi
    
    # Enable and start SSH
    systemctl enable sshd
    systemctl start sshd
    
    # Configure SSH settings
    if [ "$DISABLE_ROOT_SSH" = "true" ]; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        print_success "Root SSH login disabled"
    fi
    
    # Restart SSH
    systemctl restart sshd
    
    print_success "SSH configured and running"
}

# Function to configure firewall
configure_firewall() {
    print_info "Configuring firewall..."
    
    if [ "$OS_FAMILY" = "debian" ]; then
        # Ubuntu uses UFW
        if ! command -v ufw &> /dev/null; then
            apt install -y ufw
        fi
        
        # Allow SSH
        ufw allow 22/tcp comment 'SSH'
        
        # Enable firewall
        ufw --force enable
        print_success "UFW configured and enabled"
    else
        # Rocky uses firewalld
        if ! systemctl is-active --quiet firewalld; then
            systemctl enable firewalld
            systemctl start firewalld
        fi
        
        # Allow SSH
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --reload
        print_success "Firewalld configured and enabled"
    fi
}

# Function to update system
update_system() {
    print_info "Updating system packages..."
    
    if [ "$OS_FAMILY" = "debian" ]; then
        apt update
        apt upgrade -y
    else
        dnf update -y
    fi
    
    print_success "System updated"
}

# Function to test connectivity
test_connectivity() {
    print_info "Testing connectivity..."
    
    # Test gateway
    if ping -c 2 "$GATEWAY" &> /dev/null; then
        print_success "Gateway reachable: $GATEWAY"
    else
        print_error "Cannot reach gateway: $GATEWAY"
    fi
    
    # Test DNS
    if ping -c 2 "$DNS_PRIMARY" &> /dev/null; then
        print_success "Primary DNS reachable: $DNS_PRIMARY"
    else
        print_warning "Cannot reach primary DNS: $DNS_PRIMARY"
    fi
    
    # Test external connectivity
    if ping -c 2 8.8.8.8 &> /dev/null; then
        print_success "External connectivity working"
    else
        print_warning "Cannot reach external network"
    fi
    
    # Test DNS resolution
    if nslookup google.com &> /dev/null; then
        print_success "DNS resolution working"
    else
        print_warning "DNS resolution not working"
    fi
}

# Function to display summary
display_summary() {
    echo
    echo "======================================"
    echo "  Configuration Summary"
    echo "======================================"
    echo "Hostname:        $HOSTNAME"
    if [ "$IP_ADDRESS" = "DHCP" ]; then
        echo "IP Address:      DHCP (automatic)"
        echo "Gateway:         DHCP (automatic)"
    else
        echo "IP Address:      $IP_ADDRESS/$NETMASK_CIDR"
        echo "Gateway:         $GATEWAY"
    fi
    echo "DNS Primary:     $DNS_PRIMARY"
    if [ -n "$DNS_SECONDARY" ]; then
        echo "DNS Secondary:   $DNS_SECONDARY"
    else
        echo "DNS Secondary:   (none)"
    fi
    echo "Domain:          $DOMAIN"
    echo "Interface:       $INTERFACE"
    echo ""
    echo "Users created:"
    for user in "${USERS[@]}"; do
        echo "  - $user"
    done
    echo ""
    echo "SSH:             Enabled"
    echo "Root SSH:        $([ "$DISABLE_ROOT_SSH" = "true" ] && echo "Disabled" || echo "Enabled")"
    echo "Firewall:        Configured"
    echo "======================================"
    echo
}

# Main script execution
main() {
    clear
    echo "======================================"
    echo "  Linux System Onboarding Script"
    echo "  Ben Deyot - SYS-265"
    echo "======================================"
    echo
    
    # Check if running as root
    check_root
    
    # Detect OS
    detect_os
    
    echo
    print_info "Starting interactive configuration..."
    echo
    
    # Gather network information
    echo "=== Network Configuration ==="
    echo
    
    # Detect interface
    DEFAULT_INTERFACE=$(detect_interface)
    print_info "Detected network interface: $DEFAULT_INTERFACE"
    get_yes_no "Use detected interface ($DEFAULT_INTERFACE)?" "y" USE_DETECTED
    
    if [ "$USE_DETECTED" = "true" ]; then
        INTERFACE="$DEFAULT_INTERFACE"
    else
        get_input "Enter network interface name" INTERFACE
    fi
    
    echo
    print_info "Network interface set to: $INTERFACE"
    echo
    
    # Ask if user wants DHCP or Static IP
    get_yes_no "Do you want to use DHCP (automatic IP)?" "n" USE_DHCP
    
    if [ "$USE_DHCP" = "true" ]; then
        # User wants DHCP
        print_info "Network will be configured for DHCP"
        IP_ADDRESS="DHCP"
        NETMASK_CIDR="DHCP"
        GATEWAY="DHCP"
        
        # Still need DNS info
        echo
        while true; do
            get_input "What is the PRIMARY DNS server IP?" DNS_PRIMARY
            if validate_ip "$DNS_PRIMARY"; then
                break
            else
                print_error "Invalid DNS IP address"
            fi
        done
        
        echo
        get_yes_no "Do you want to configure a secondary DNS server?" "n" USE_SECONDARY_DNS
        
        if [ "$USE_SECONDARY_DNS" = "true" ]; then
            while true; do
                get_input "What is the SECONDARY DNS server IP?" DNS_SECONDARY
                if validate_ip "$DNS_SECONDARY"; then
                    break
                else
                    print_error "Invalid DNS IP address"
                fi
            done
        else
            DNS_SECONDARY=""
        fi
        
        echo
        get_input "What is the domain name?" DOMAIN
        
    else
        # User wants Static IP
        # Disable DHCP if active
        print_info "Disabling DHCP on $INTERFACE..."
        if [ "$OS_FAMILY" = "debian" ]; then
            # Ubuntu 22.04+ uses netplan, older uses dhclient
            if command -v dhclient &> /dev/null; then
                # Release DHCP lease (older Ubuntu)
                dhclient -r $INTERFACE 2>/dev/null || true
                pkill dhclient 2>/dev/null || true
            fi
            # Flush any DHCP addresses
            ip addr flush dev $INTERFACE 2>/dev/null || true
        else
            # Rocky/CentOS
            nmcli con mod $INTERFACE ipv4.method manual 2>/dev/null || true
        fi
        print_success "DHCP will be disabled when static IP is applied"
        
        echo
        # Get IP configuration
        print_info "Configure static IP address for this system"
        while true; do
            get_input "What is the IP address for this system?" IP_ADDRESS
            if validate_ip "$IP_ADDRESS"; then
                break
            else
                print_error "Invalid IP address format. Use format: xxx.xxx.xxx.xxx"
            fi
        done
        
        echo "You entered: $IP_ADDRESS"
        get_yes_no "Is this correct?" "y" IP_CONFIRM
        if [ "$IP_CONFIRM" = "false" ]; then
            while true; do
                get_input "Enter IP address again" IP_ADDRESS
                if validate_ip "$IP_ADDRESS"; then
                    break
                fi
            done
        fi
        
        echo
        get_input "What is the subnet mask in CIDR notation?" NETMASK_INPUT
        # Convert subnet mask to CIDR if needed
        case $NETMASK_INPUT in
            255.255.255.0)
                NETMASK_CIDR="24"
                ;;
            255.255.0.0)
                NETMASK_CIDR="16"
                ;;
            255.0.0.0)
                NETMASK_CIDR="8"
                ;;
            *)
                NETMASK_CIDR="$NETMASK_INPUT"
                ;;
        esac
        print_info "Using subnet mask: /$NETMASK_CIDR"
        
        echo
        while true; do
            get_input "What is the gateway IP address?" GATEWAY
            if validate_ip "$GATEWAY"; then
                break
            else
                print_error "Invalid gateway IP address"
            fi
        done
        
        echo
        while true; do
            get_input "What is the PRIMARY DNS server IP?" DNS_PRIMARY
            if validate_ip "$DNS_PRIMARY"; then
                break
            else
                print_error "Invalid DNS IP address"
            fi
        done
        
        echo
        get_yes_no "Do you want to configure a secondary DNS server?" "n" USE_SECONDARY_DNS
        
        if [ "$USE_SECONDARY_DNS" = "true" ]; then
            while true; do
                get_input "What is the SECONDARY DNS server IP?" DNS_SECONDARY
                if validate_ip "$DNS_SECONDARY"; then
                    break
                else
                    print_error "Invalid DNS IP address"
                fi
            done
        else
            DNS_SECONDARY=""
        fi
        
        echo
        get_input "What is the domain name?" DOMAIN
    fi
    
    echo
    echo "=== System Identity ==="
    echo
    
    while true; do
        get_input "What should the hostname be? " HOSTNAME
        if validate_hostname "$HOSTNAME"; then
            print_info "Hostname will be set to: $HOSTNAME"
            break
        else
            print_error "Invalid hostname format. Use only letters, numbers, and hyphens."
        fi
    done
    
    echo
    echo "=== User Configuration ==="
    echo
    
    USERS=()
    
    print_info "Let's create user accounts for this system"
    echo
    
    # First user
    get_input "What is the username for the first user? " NAMED_USER
    get_password "Set password for $NAMED_USER" NAMED_PASSWORD
    get_yes_no "Should $NAMED_USER have sudo (administrator) privileges?" "y" NAMED_SUDO
    USERS+=("$NAMED_USER")
    
    echo
    # Additional users
    while true; do
        get_yes_no "Do you want to create another user account?" "n" CREATE_ANOTHER
        if [ "$CREATE_ANOTHER" = "false" ]; then
            break
        fi
        
        echo
        get_input "What is the username for this user? " ADDITIONAL_USER
        get_password "Set password for $ADDITIONAL_USER" ADDITIONAL_PASSWORD
        get_yes_no "Should $ADDITIONAL_USER have sudo privileges?" "y" ADDITIONAL_SUDO
        
        # Store user info
        USERS+=("$ADDITIONAL_USER")
        eval "USER_${#USERS[@]}_NAME=$ADDITIONAL_USER"
        eval "USER_${#USERS[@]}_PASS=$ADDITIONAL_PASSWORD"
        eval "USER_${#USERS[@]}_SUDO=$ADDITIONAL_SUDO"
    done
    
    echo
    echo "=== Service Configuration ==="
    echo
    
    # Check if deployer user exists
    DEPLOYER_EXISTS=false
    for user in "${USERS[@]}"; do
        if [ "$user" = "deployer" ]; then
            DEPLOYER_EXISTS=true
            break
        fi
    done
    
    if [ "$DEPLOYER_EXISTS" = "true" ]; then
        get_yes_no "Configure passwordless sudo for deployer user?" "y" PASSWORDLESS_SUDO
    else
        PASSWORDLESS_SUDO="false"
    fi
    
    echo
    get_yes_no "Do you want to configure SSH (remote access)?" "y" CONFIGURE_SSH
    
    if [ "$CONFIGURE_SSH" = "true" ]; then
        echo
        get_yes_no "Should root SSH login be disabled? (Recommended for security)" "y" DISABLE_ROOT_SSH
    fi
    
    echo
    get_yes_no "Do you want to configure the firewall?" "y" CONFIGURE_FIREWALL
    
    echo
    get_yes_no "Do you want to update all system packages now? (This may take several minutes)" "y" UPDATE_SYSTEM
    
    echo
    display_summary
    
    get_yes_no "Proceed with configuration?" "y" PROCEED
    
    if [ "$PROCEED" = "false" ]; then
        print_warning "Configuration cancelled by user"
        exit 0
    fi
    
    echo
    print_info "Starting system configuration..."
    echo
    
    # Configure network
    if [ "$OS_FAMILY" = "debian" ]; then
        configure_network_ubuntu
    else
        configure_network_rocky
    fi
    
    # Configure hostname
    configure_hostname
    
    # Create users
    create_user "$NAMED_USER" "$NAMED_PASSWORD" "$NAMED_SUDO"
    
    # Create additional users
    for i in $(seq 2 ${#USERS[@]}); do
        eval "username=\$USER_${i}_NAME"
        eval "password=\$USER_${i}_PASS"
        eval "sudo_access=\$USER_${i}_SUDO"
        create_user "$username" "$password" "$sudo_access"
    done
    
    # Configure passwordless sudo
    if [ "$PASSWORDLESS_SUDO" = "true" ]; then
        configure_passwordless_sudo
    fi
    
    # Configure SSH
    if [ "$CONFIGURE_SSH" = "true" ]; then
        configure_ssh
    fi
    
    # Configure firewall
    if [ "$CONFIGURE_FIREWALL" = "true" ]; then
        configure_firewall
    fi
    
    # Update system
    if [ "$UPDATE_SYSTEM" = "true" ]; then
        update_system
    fi
    
    # Test connectivity
    test_connectivity
    
    echo
    print_success "======================================"
    print_success "  Configuration Complete!"
    print_success "======================================"
    echo
    display_summary
    echo
    print_info "Log file saved to: $LOGFILE"
    print_info "It is recommended to reboot the system: sudo reboot"
    echo
}

# Run main function
main "$@"
