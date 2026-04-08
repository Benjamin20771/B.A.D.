#Requires -RunAsAdministrator
# windows-onboard.ps1
# Ben Deyot - SYS-265
# Interactive Windows system onboarding script
# Supports Windows 10, Windows Server 2019 (Core and GUI)

# =============================================
# Color Output Functions
# =============================================

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
    Write-Log "INFO: $Message"
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
    Write-Log "SUCCESS: $Message"
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Write-Log "ERROR: $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
    Write-Log "WARNING: $Message"
}

# =============================================
# Logging
# =============================================

$LogFile = "C:\windows-onboard.log"

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$Timestamp] $Message" -ErrorAction SilentlyContinue
}

# =============================================
# Input Helper Functions
# =============================================

function Get-Input {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    while ($true) {
        if ($Default -ne "") {
            $input = Read-Host "$Prompt (default: $Default)"
            if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
            return $input
        } else {
            $input = Read-Host $Prompt
            if (-not [string]::IsNullOrWhiteSpace($input)) { return $input }
            Write-Err "Input cannot be empty. Please try again."
        }
    }
}

function Get-SecureInput {
    param([string]$Prompt)
    while ($true) {
        $pass1 = Read-Host $Prompt -AsSecureString
        $pass2 = Read-Host "Confirm password" -AsSecureString

        # Convert to plain text for comparison
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass2))

        if ($plain1 -eq $plain2) {
            if ([string]::IsNullOrWhiteSpace($plain1)) {
                Write-Err "Password cannot be empty."
                continue
            }
            return $pass1
        }
        Write-Err "Passwords do not match. Try again."
    }
}

function Get-YesNo {
    param(
        [string]$Prompt,
        [string]$Default = "y"
    )
    if ($Default -eq "y") {
        $choice = Read-Host "$Prompt (Y/n)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "y" }
    } else {
        $choice = Read-Host "$Prompt (y/N)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "n" }
    }
    return ($choice -match '^[Yy]$')
}

# =============================================
# Validation Functions
# =============================================

function Test-ValidIP {
    param([string]$IP)
    if ($IP -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { return $false }
    $octets = $IP.Split('.')
    foreach ($octet in $octets) {
        if ([int]$octet -gt 255) { return $false }
    }
    return $true
}

function Test-ValidHostname {
    param([string]$Hostname)
    return $Hostname -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$'
}

function Convert-MaskToCIDR {
    param([string]$Mask)
    switch ($Mask) {
        "255.255.255.0"   { return 24 }
        "255.255.0.0"     { return 16 }
        "255.0.0.0"       { return 8  }
        "255.255.255.128" { return 25 }
        "255.255.255.192" { return 26 }
        default {
            # Try to parse as CIDR directly
            if ($Mask -match '^\d+$' -and [int]$Mask -le 32) { return [int]$Mask }
            Write-Warn "Unrecognized mask format, defaulting to /24"
            return 24
        }
    }
}

# =============================================
# OS Detection
# =============================================

function Get-OSInfo {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    $caption = $os.Caption
    $productType = $os.ProductType  # 1 = Workstation, 2 = DC, 3 = Server

    Write-Info "Detected OS: $caption"

    $osInfo = @{
        Caption     = $caption
        Type        = ""
        IsCore      = $false
        IsServer    = $false
        IsWorkstation = $false
    }

    # Detect Server Core (no Explorer shell)
    $explorerRunning = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
    if ($productType -eq 1) {
        $osInfo.Type = "Workstation"
        $osInfo.IsWorkstation = $true
        Write-Info "System type: Windows Workstation"
    } elseif ($productType -ge 2) {
        $osInfo.IsServer = $true
        if (-not $explorerRunning) {
            $osInfo.Type = "ServerCore"
            $osInfo.IsCore = $true
            Write-Info "System type: Windows Server Core"
        } else {
            $osInfo.Type = "ServerGUI"
            Write-Info "System type: Windows Server (Desktop Experience)"
        }
    }

    return $osInfo
}

# =============================================
# Network Configuration
# =============================================

function Get-ActiveAdapter {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    return $adapter
}

function Set-NetworkConfig {
    param(
        [string]$AdapterName,
        [bool]$UseDHCP,
        [string]$IPAddress,
        [nullable[int]]$PrefixLength,
        [string]$Gateway,
        [string]$DNSPrimary,
        [string]$DNSSecondary,
        [string]$Domain
    )

    Write-Info "Configuring network adapter: $AdapterName"

    if ($UseDHCP) {
        # Set to DHCP
        Set-NetIPInterface -InterfaceAlias $AdapterName -Dhcp Enabled -ErrorAction SilentlyContinue
        Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ResetServerAddresses
        Write-Info "DHCP enabled on $AdapterName"
    } else {
        # Remove existing IP config
        $existing = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        }

        $existingGW = Get-NetRoute -InterfaceAlias $AdapterName -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
        if ($existingGW) {
            Remove-NetRoute -InterfaceAlias $AdapterName -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Set static IP
        New-NetIPAddress -InterfaceAlias $AdapterName `
            -IPAddress $IPAddress `
            -PrefixLength $PrefixLength `
            -DefaultGateway $Gateway `
            -ErrorAction Stop | Out-Null

        Write-Success "Static IP set: $IPAddress/$PrefixLength via $Gateway"
    }

    # Set DNS
    $dnsServers = @($DNSPrimary)
    if (-not [string]::IsNullOrWhiteSpace($DNSSecondary)) {
        $dnsServers += $DNSSecondary
    }
    Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses $dnsServers
    Write-Success "DNS configured: $($dnsServers -join ', ')"

    # Set DNS search suffix
    if (-not [string]::IsNullOrWhiteSpace($Domain)) {
        Set-DnsClient -InterfaceAlias $AdapterName -ConnectionSpecificSuffix $Domain -ErrorAction SilentlyContinue
        Write-Success "DNS suffix set: $Domain"
    }
}

# =============================================
# Hostname Configuration
# =============================================

function Set-SystemHostname {
    param([string]$NewHostname)

    $current = $env:COMPUTERNAME
    if ($current -eq $NewHostname) {
        Write-Warn "Hostname is already $NewHostname. No change needed."
        return $false
    }

    Write-Info "Renaming computer from '$current' to '$NewHostname'..."
    Rename-Computer -NewName $NewHostname -Force -ErrorAction Stop
    Write-Success "Hostname set to: $NewHostname (will apply after reboot)"
    return $true  # Flag that reboot is needed
}

# =============================================
# Local User Creation
# =============================================

function New-LocalSystemUser {
    param(
        [string]$Username,
        [System.Security.SecureString]$Password,
        [bool]$IsAdmin
    )

    $existing = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warn "User '$Username' already exists. Updating password."
        Set-LocalUser -Name $Username -Password $Password
    } else {
        New-LocalUser -Name $Username `
            -Password $Password `
            -FullName $Username `
            -Description "Created by windows-onboard.ps1 - SYS-265" `
            -PasswordNeverExpires:$true `
            -ErrorAction Stop | Out-Null
        Write-Success "User '$Username' created."
    }

    if ($IsAdmin) {
        Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue
        Write-Success "Added '$Username' to local Administrators group."
    } else {
        Add-LocalGroupMember -Group "Users" -Member $Username -ErrorAction SilentlyContinue
        Write-Info "Added '$Username' to local Users group."
    }
}

# =============================================
# Domain Join
# =============================================

function Join-ADDomain {
    param(
        [string]$DomainName,
        [string]$DomainUser,
        [System.Security.SecureString]$DomainPassword,
        [string]$OUPath = ""
    )

    Write-Info "Joining domain: $DomainName"

    $credential = New-Object System.Management.Automation.PSCredential("$DomainName\$DomainUser", $DomainPassword)

    $params = @{
        DomainName  = $DomainName
        Credential  = $credential
        Force       = $true
        ErrorAction = "Stop"
    }

    if (-not [string]::IsNullOrWhiteSpace($OUPath)) {
        $params["OUPath"] = $OUPath
    }

    Add-Computer @params
    Write-Success "Successfully joined domain: $DomainName (will apply after reboot)"
    return $true  # reboot needed
}

# =============================================
# Windows Firewall Configuration
# =============================================

function Set-FirewallConfig {
    Write-Info "Configuring Windows Firewall..."

    # Enable firewall on all profiles
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
    Write-Success "Firewall enabled on all profiles."

    # Allow RDP (TCP 3389)
    $rdpRule = Get-NetFirewallRule -DisplayName "Remote Desktop*" -ErrorAction SilentlyContinue
    if (-not $rdpRule) {
        New-NetFirewallRule -DisplayName "Allow RDP" `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 3389 `
            -Action Allow `
            -Profile Any | Out-Null
    } else {
        Enable-NetFirewallRule -DisplayName "Remote Desktop*"
    }
    Write-Success "RDP (3389) allowed through firewall."

    # Allow WinRM (for remote management / Ansible)
    New-NetFirewallRule -DisplayName "Allow WinRM HTTP" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 5985 `
        -Action Allow `
        -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Success "WinRM HTTP (5985) allowed through firewall."

    # Allow ICMP ping
    New-NetFirewallRule -DisplayName "Allow ICMPv4 Echo" `
        -Direction Inbound `
        -Protocol ICMPv4 `
        -IcmpType 8 `
        -Action Allow `
        -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Success "ICMP (ping) allowed through firewall."
}

# =============================================
# Enable WinRM (for Ansible/MGMT2)
# =============================================

function Enable-WinRMAccess {
    Write-Info "Enabling WinRM for remote management..."
    Enable-PSRemoting -Force -ErrorAction SilentlyContinue
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM -ErrorAction SilentlyContinue
    Write-Success "WinRM enabled and configured."
}

# =============================================
# Enable RDP
# =============================================

function Enable-RDPAccess {
    Write-Info "Enabling Remote Desktop..."
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name "fDenyTSConnections" -Value 0
    Write-Success "Remote Desktop enabled."
}

# =============================================
# RSAT Installation (Server GUI only)
# =============================================

function Install-RSATTools {
    Write-Info "Installing Remote Server Administration Tools (RSAT)..."

    $features = @(
        "RSAT-AD-Tools",           # AD Users and Computers, AD Domains and Trusts
        "RSAT-AD-PowerShell",      # Active Directory PowerShell module
        "RSAT-DNS-Server",         # DNS Manager
        "RSAT-DHCP",               # DHCP Manager
        "RSAT-File-Services",      # DFS Management (needed for M3 DFS profiles)
        "RSAT-Role-Tools",         # General role management tools
        "GPMC"                     # Group Policy Management Console (needed for M3 GPO)
    )

    foreach ($feature in $features) {
        $f = Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue
        if ($f -and -not $f.Installed) {
            Write-Info "Installing: $feature"
            Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction SilentlyContinue | Out-Null
            Write-Success "Installed: $feature"
        } elseif ($f -and $f.Installed) {
            Write-Warn "$feature is already installed. Skipping."
        } else {
            Write-Warn "Feature not found on this system: $feature"
        }
    }

    Write-Success "RSAT tools installation complete."
    Write-Info "You can now manage AD, DNS, DHCP, DFS, and Group Policy from this machine."
}

# =============================================
# Connectivity Test
# =============================================

function Test-Connectivity {
    param(
        [string]$Gateway,
        [string]$DNSPrimary,
        [string]$Domain
    )

    Write-Info "Testing connectivity..."

    # Test gateway
    if (Test-Connection -ComputerName $Gateway -Count 2 -Quiet) {
        Write-Success "Gateway reachable: $Gateway"
    } else {
        Write-Warn "Cannot reach gateway: $Gateway"
    }

    # Test DNS
    if (Test-Connection -ComputerName $DNSPrimary -Count 2 -Quiet) {
        Write-Success "Primary DNS reachable: $DNSPrimary"
    } else {
        Write-Warn "Cannot reach primary DNS: $DNSPrimary"
    }

    # Test external
    if (Test-Connection -ComputerName "8.8.8.8" -Count 2 -Quiet) {
        Write-Success "External connectivity working."
    } else {
        Write-Warn "Cannot reach external network."
    }

    # Test DNS resolution
    try {
        Resolve-DnsName "google.com" -ErrorAction Stop | Out-Null
        Write-Success "DNS resolution working."
    } catch {
        Write-Warn "DNS resolution not working."
    }
}

# =============================================
# Summary Display
# =============================================

function Show-Summary {
    param(
        [hashtable]$Config
    )

    Write-Host ""
    Write-Host "======================================" -ForegroundColor White
    Write-Host "  Configuration Summary" -ForegroundColor White
    Write-Host "======================================" -ForegroundColor White
    Write-Host "Hostname:        $($Config.Hostname)"
    Write-Host "OS Type:         $($Config.OSType)"
    if ($Config.UseDHCP) {
        Write-Host "IP Address:      DHCP (automatic)"
        Write-Host "Gateway:         DHCP (automatic)"
    } else {
        Write-Host "IP Address:      $($Config.IPAddress)/$($Config.PrefixLength)"
        Write-Host "Gateway:         $($Config.Gateway)"
    }
    Write-Host "DNS Primary:     $($Config.DNSPrimary)"
    if ($Config.DNSSecondary) {
        Write-Host "DNS Secondary:   $($Config.DNSSecondary)"
    } else {
        Write-Host "DNS Secondary:   (none)"
    }
    Write-Host "Domain:          $($Config.Domain)"
    Write-Host "Adapter:         $($Config.AdapterName)"
    Write-Host ""
    Write-Host "Users to create:"
    foreach ($u in $Config.Users) {
        $adminTag = if ($u.IsAdmin) { " [Admin]" } else { "" }
        Write-Host "  - $($u.Username)$adminTag"
    }
    Write-Host ""
    Write-Host "Domain Join:     $(if ($Config.DoDomainJoin) { 'Yes - ' + $Config.DomainJoinTarget } else { 'No' })"
    Write-Host "Firewall:        $(if ($Config.DoFirewall) { 'Configure' } else { 'Skip' })"
    Write-Host "WinRM:           $(if ($Config.DoWinRM) { 'Enable' } else { 'Skip' })"
    Write-Host "RDP:             $(if ($Config.DoRDP) { 'Enable' } else { 'Skip' })"
    Write-Host "RSAT Tools:      $(if ($Config.DoRSAT -eq $true) { 'Install' } else { 'Skip' })"
    Write-Host "======================================" -ForegroundColor White
    Write-Host ""
}

# =============================================
# Main Script
# =============================================

function Main {
    Clear-Host
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  Windows System Onboarding Script" -ForegroundColor Cyan
    Write-Host "  Ben Deyot - SYS-265" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Log "=== Onboarding script started ==="

    # Detect OS
    $osInfo = Get-OSInfo
    Write-Host ""

    # Config hashtable to collect all settings
    $config = @{
        OSType        = $osInfo.Type
        Users         = @()
        RebootNeeded  = $false
    }

    # ---- Network Configuration ----
    Write-Host "=== Network Configuration ===" -ForegroundColor White
    Write-Host ""

    $adapter = Get-ActiveAdapter
    if ($adapter) {
        Write-Info "Detected active adapter: $($adapter.Name) [$($adapter.InterfaceDescription)]"
        $useDetected = Get-YesNo "Use this adapter?" "y"
        if ($useDetected) {
            $config.AdapterName = $adapter.Name
        } else {
            $config.AdapterName = Get-Input "Enter adapter name"
        }
    } else {
        Write-Warn "Could not auto-detect adapter."
        $config.AdapterName = Get-Input "Enter adapter name"
    }

    Write-Host ""
    $useDHCP = Get-YesNo "Use DHCP (automatic IP)?" "n"
    $config.UseDHCP = $useDHCP

    if ($useDHCP) {
        Write-Info "Network will be configured for DHCP."
        $config.IPAddress    = "DHCP"
        $config.PrefixLength = $null
        $config.Gateway      = "DHCP"
    } else {
        Write-Host ""
        do {
            $ip = Get-Input "IP address for this system"
        } while (-not (Test-ValidIP $ip) -and (Write-Err "Invalid IP address format."))
        $config.IPAddress = $ip

        Write-Host ""
        $maskInput = Get-Input "Subnet mask (e.g. 255.255.255.0 or 24)"
        $config.PrefixLength = Convert-MaskToCIDR $maskInput
        Write-Info "Using prefix length: /$($config.PrefixLength)"

        Write-Host ""
        do {
            $gw = Get-Input "Gateway IP address"
        } while (-not (Test-ValidIP $gw) -and (Write-Err "Invalid gateway IP."))
        $config.Gateway = $gw
    }

    Write-Host ""
    do {
        $dns1 = Get-Input "Primary DNS server IP"
    } while (-not (Test-ValidIP $dns1) -and (Write-Err "Invalid IP address."))
    $config.DNSPrimary = $dns1

    Write-Host ""
    $useSecDNS = Get-YesNo "Configure a secondary DNS server?" "n"
    if ($useSecDNS) {
        do {
            $dns2 = Get-Input "Secondary DNS server IP"
        } while (-not (Test-ValidIP $dns2) -and (Write-Err "Invalid IP address."))
        $config.DNSSecondary = $dns2
    } else {
        $config.DNSSecondary = ""
    }

    Write-Host ""
    $config.Domain = Get-Input "Domain name (e.g. grp1.local)"

    # ---- Hostname ----
    Write-Host ""
    Write-Host "=== System Identity ===" -ForegroundColor White
    Write-Host ""

    $doRename = Get-YesNo "Do you want to set/change the hostname?" "y"
    if ($doRename) {
        do {
            $hn = Get-Input "Hostname for this system"
        } while (-not (Test-ValidHostname $hn) -and (Write-Err "Invalid hostname. Use letters, numbers, hyphens only."))
        $config.Hostname = $hn
    } else {
        $config.Hostname = $env:COMPUTERNAME
        Write-Info "Keeping current hostname: $($env:COMPUTERNAME)"
    }
    $config.DoRename = $doRename

    # ---- User Creation ----
    Write-Host ""
    Write-Host "=== User Configuration ===" -ForegroundColor White
    Write-Host ""

    Write-Info "Let's create local user accounts for this system."
    Write-Host ""

    $users = @()
    $createUsers = Get-YesNo "Do you want to create local user accounts?" "y"

    if ($createUsers) {
        $firstUser   = Get-Input "Username for first user"
        $firstPass   = Get-SecureInput "Password for $firstUser"
        $firstAdmin  = Get-YesNo "Should $firstUser have local Administrator privileges?" "y"
        $users += @{ Username = $firstUser; Password = $firstPass; IsAdmin = $firstAdmin }

        while ($true) {
            Write-Host ""
            $another = Get-YesNo "Create another local user?" "n"
            if (-not $another) { break }

            $uname  = Get-Input "Username"
            $upass  = Get-SecureInput "Password for $uname"
            $uadmin = Get-YesNo "Should $uname have local Administrator privileges?" "n"
            $users += @{ Username = $uname; Password = $upass; IsAdmin = $uadmin }
        }
    }
    $config.Users = $users

    # ---- Domain Join ----
    Write-Host ""
    Write-Host "=== Domain Join ===" -ForegroundColor White
    Write-Host ""

    $doDomainJoin = Get-YesNo "Do you want to join this system to a domain?" "y"
    $config.DoDomainJoin = $doDomainJoin

    if ($doDomainJoin) {
        $config.DomainJoinTarget = Get-Input "Domain to join" $config.Domain
        $config.DomainUser       = Get-Input "Domain admin username (e.g. Administrator)"
        $config.DomainPass       = Get-SecureInput "Password for $($config.DomainUser)"

        $useOU = Get-YesNo "Specify a custom OU path?" "n"
        if ($useOU) {
            $config.OUPath = Get-Input "OU Path (e.g. OU=Computers,DC=grp1,DC=local)"
        } else {
            $config.OUPath = ""
        }
    }

    # ---- Services ----
    Write-Host ""
    Write-Host "=== Service & Feature Configuration ===" -ForegroundColor White
    Write-Host ""

    $config.DoFirewall = Get-YesNo "Configure Windows Firewall (enable + allow RDP, WinRM, ping)?" "y"
    Write-Host ""
    $config.DoWinRM    = Get-YesNo "Enable WinRM for remote management (required for Ansible)?" "y"
    Write-Host ""
    $config.DoRDP      = Get-YesNo "Enable Remote Desktop (RDP)?" "y"

    # RSAT -- only offered on Server GUI machines (e.g. MGMT1)
    $config.DoRSAT = $false
    if ($osInfo.Type -eq "ServerGUI") {
        Write-Host ""
        Write-Info "This is a Server GUI machine (e.g. MGMT1)."
        Write-Info "RSAT gives you AD Users and Computers, DNS Manager, DHCP Manager, DFS, and Group Policy Management Console."
        $config.DoRSAT = Get-YesNo "Install RSAT management tools?" "y"
    }

    # ---- Summary & Confirm ----
    Write-Host ""
    Show-Summary $config

    $proceed = Get-YesNo "Proceed with configuration?" "y"
    if (-not $proceed) {
        Write-Warn "Configuration cancelled by user."
        exit 0
    }

    Write-Host ""
    Write-Info "Starting system configuration..."
    Write-Host ""

    # Apply network
    $netParams = @{
        AdapterName  = $config.AdapterName
        UseDHCP      = $config.UseDHCP
        IPAddress    = $config.IPAddress
        PrefixLength = $config.PrefixLength
        Gateway      = $config.Gateway
        DNSPrimary   = $config.DNSPrimary
        DNSSecondary = $config.DNSSecondary
        Domain       = $config.Domain
    }
    try {
        Set-NetworkConfig @netParams
    } catch {
        Write-Err "Network configuration failed: $_"
    }

    # Apply hostname
    if ($config.DoRename) {
        try {
            $renamed = Set-SystemHostname -NewHostname $config.Hostname
            if ($renamed) { $config.RebootNeeded = $true }
        } catch {
            Write-Err "Hostname rename failed: $_"
        }
    }

    # Create users
    foreach ($u in $config.Users) {
        try {
            New-LocalSystemUser -Username $u.Username -Password $u.Password -IsAdmin $u.IsAdmin
        } catch {
            Write-Err "Failed to create user '$($u.Username)': $_"
        }
    }

    # Domain join
    if ($config.DoDomainJoin) {
        try {
            $joined = Join-ADDomain `
                -DomainName $config.DomainJoinTarget `
                -DomainUser $config.DomainUser `
                -DomainPassword $config.DomainPass `
                -OUPath $config.OUPath
            if ($joined) { $config.RebootNeeded = $true }
        } catch {
            Write-Err "Domain join failed: $_"
        }
    }

    # Firewall
    if ($config.DoFirewall) {
        try {
            Set-FirewallConfig
        } catch {
            Write-Err "Firewall configuration failed: $_"
        }
    }

    # WinRM
    if ($config.DoWinRM) {
        try {
            Enable-WinRMAccess
        } catch {
            Write-Err "WinRM configuration failed: $_"
        }
    }

    # RDP
    if ($config.DoRDP) {
        try {
            Enable-RDPAccess
        } catch {
            Write-Err "RDP enable failed: $_"
        }
    }

    # RSAT (Server GUI only)
    if ($config.DoRSAT) {
        try {
            Install-RSATTools
        } catch {
            Write-Err "RSAT installation failed: $_"
        }
    }

    # Connectivity test (skip if DHCP — IP may not be assigned yet)
    if (-not $config.UseDHCP -and (Test-ValidIP $config.Gateway)) {
        Test-Connectivity -Gateway $config.Gateway -DNSPrimary $config.DNSPrimary -Domain $config.Domain
    }

    # Final summary
    Write-Host ""
    Write-Success "======================================"
    Write-Success "  Configuration Complete!"
    Write-Success "======================================"
    Write-Host ""
    Show-Summary $config
    Write-Host ""
    Write-Info "Log file saved to: $LogFile"

    if ($config.RebootNeeded) {
        Write-Warn "A REBOOT IS REQUIRED to apply hostname/domain changes."
        $doReboot = Get-YesNo "Reboot now?" "y"
        if ($doReboot) {
            Write-Info "Rebooting in 5 seconds..."
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        } else {
            Write-Warn "Please reboot manually when ready: Restart-Computer"
        }
    }
}

# Entry point
Main
