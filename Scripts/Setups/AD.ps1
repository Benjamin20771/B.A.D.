#Requires -RunAsAdministrator
# ad-setup.ps1
# Ben Deyot - SYS-265
# Interactive Active Directory setup script
# Handles DC1 promotion, DC2 promotion (auto-detects DC1), and domain user creation
# Run this AFTER windows-onboard.ps1 has been run on the target machine

# =============================================
# Color Output & Logging
# =============================================

$LogFile = "C:\ad-setup.log"

function Write-Log {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$Timestamp] $Message" -ErrorAction SilentlyContinue
}

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
# Input Helpers
# =============================================

function Get-Input {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    while ($true) {
        if ($Default -ne "") {
            $val = Read-Host "$Prompt (default: $Default)"
            if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
            return $val
        } else {
            $val = Read-Host $Prompt
            if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
            Write-Err "Input cannot be empty. Please try again."
        }
    }
}

function Get-SecureInput {
    param([string]$Prompt)
    while ($true) {
        $p1 = Read-Host $Prompt -AsSecureString
        $p2 = Read-Host "Confirm password" -AsSecureString
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        if ($plain1 -eq $plain2 -and -not [string]::IsNullOrWhiteSpace($plain1)) {
            return $p1
        }
        Write-Err "Passwords do not match or are empty. Try again."
    }
}

function Get-SecureInputSingle {
    param([string]$Prompt)
    $p = Read-Host $Prompt -AsSecureString
    return $p
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
# Detect Current Machine State
# =============================================

function Get-MachineState {
    $state = @{
        Hostname        = $env:COMPUTERNAME
        IsDC            = $false
        IsPDC           = $false
        IsAdditionalDC  = $false
        DomainName      = ""
        ADInstalled     = $false
        Role            = "Unknown"
    }

    # Check if AD DS role is installed
    $adFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue
    if ($adFeature -and $adFeature.Installed) {
        $state.ADInstalled = $true
    }

    # Attempt to import AD module before using AD cmdlets
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    # Check if machine is a DC
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $state.IsDC = $true
        $state.DomainName = $domain.DNSRoot

        # Check if PDC emulator (primary DC)
        $pdc = $domain.PDCEmulator.Split('.')[0]
        if ($pdc -eq $env:COMPUTERNAME) {
            $state.IsPDC = $true
            $state.Role = "DC1 (PDC Emulator)"
        } else {
            $state.IsAdditionalDC = $true
            $state.Role = "DC2 (Additional DC)"
        }
    } catch {
        # Not a DC yet
        $state.IsDC = $false

        if ($state.ADInstalled) {
            $state.Role = "AD-DS Installed, Not Yet Promoted"
        } else {
            $state.Role = "Standalone Server (No AD-DS)"
        }
    }

    return $state
}

# =============================================
# Install AD-DS Role
# =============================================

function Install-ADDSRole {
    Write-Info "Installing Active Directory Domain Services role..."

    $feature = Get-WindowsFeature -Name AD-Domain-Services
    if ($feature.Installed) {
        Write-Warn "AD-DS role is already installed. Skipping."
        return
    }

    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -ErrorAction Stop
    Write-Success "AD-DS role installed successfully."
}

# =============================================
# DC1 - Promote as New Forest (Primary DC)
# =============================================

function Invoke-DC1Promotion {
    param(
        [string]$DomainName,
        [string]$NetBIOSName,
        [System.Security.SecureString]$DSRMPassword
    )

    Write-Info "Promoting this machine as the first Domain Controller for: $DomainName"
    Write-Info "NetBIOS Name: $NetBIOSName"
    Write-Warn "This will restart the computer automatically when complete."

    $confirm = Get-YesNo "Proceed with DC1 promotion?" "y"
    if (-not $confirm) {
        Write-Warn "DC1 promotion cancelled."
        return
    }

    try {
        Install-ADDSForest `
            -DomainName $DomainName `
            -DomainNetbiosName $NetBIOSName `
            -DomainMode "WinThreshold" `
            -ForestMode "WinThreshold" `
            -SafeModeAdministratorPassword $DSRMPassword `
            -InstallDns:$true `
            -Force:$true `
            -NoRebootOnCompletion:$false `
            -ErrorAction Stop

        Write-Success "DC1 promotion initiated. System will reboot."
    } catch {
        Write-Err "DC1 promotion failed: $_"
    }
}

# =============================================
# DC2 - Auto-detect DC1 and Join as Replica
# =============================================

function Find-PrimaryDC {
    param([string]$DomainName)

    Write-Info "Searching for existing Domain Controller in: $DomainName"

    try {
        $dc = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain(
            (New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext("Domain", $DomainName))
        ).PdcRoleOwner.Name

        Write-Success "Found PDC Emulator: $dc"
        return $dc
    } catch {
        Write-Warn "Could not auto-detect PDC. Will attempt promotion using domain name directly."
        return $DomainName
    }
}

function Invoke-DC2Promotion {
    param(
        [string]$DomainName,
        [System.Security.SecureString]$DSRMPassword,
        [System.Management.Automation.PSCredential]$DomainCredential
    )

    Write-Info "Promoting this machine as an additional Domain Controller for: $DomainName"

    # Auto-detect DC1
    $sourceDC = Find-PrimaryDC -DomainName $DomainName

    Write-Info "Will replicate from: $sourceDC"
    Write-Warn "This will restart the computer automatically when complete."

    $confirm = Get-YesNo "Proceed with DC2 promotion?" "y"
    if (-not $confirm) {
        Write-Warn "DC2 promotion cancelled."
        return
    }

    try {
        Install-ADDSDomainController `
            -DomainName $DomainName `
            -Credential $DomainCredential `
            -SafeModeAdministratorPassword $DSRMPassword `
            -InstallDns:$true `
            -ReplicationSourceDC $sourceDC `
            -Force:$true `
            -NoRebootOnCompletion:$false `
            -ErrorAction Stop

        Write-Success "DC2 promotion initiated. System will reboot."
    } catch {
        Write-Err "DC2 promotion failed: $_"
    }
}

# =============================================
# Domain User Creation
# =============================================

function New-DomainUserAccount {
    param(
        [string]$Username,
        [string]$DisplayName,
        [System.Security.SecureString]$Password,
        [bool]$IsAdmin,
        [string]$DomainName
    )

    # Check if user already exists
    $existing = Get-ADUser -Filter "SamAccountName -eq '$Username'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warn "User '$Username' already exists in AD. Skipping creation."
        return
    }

    Write-Info "Creating domain user: $Username ($DisplayName)"

    New-ADUser `
        -SamAccountName $Username `
        -UserPrincipalName "$Username@$DomainName" `
        -Name $DisplayName `
        -DisplayName $DisplayName `
        -GivenName $Username `
        -AccountPassword $Password `
        -Enabled $true `
        -PasswordNeverExpires $true `
        -Description "Created by ad-setup.ps1 - SYS-265" `
        -ErrorAction Stop

    Write-Success "User '$Username' created successfully."

    if ($IsAdmin) {
        Add-ADGroupMember -Identity "Domain Admins" -Members $Username -ErrorAction Stop
        Write-Success "Added '$Username' to Domain Admins."
    }
}

function New-LinuxAdminsGroup {
    Write-Info "Creating 'linux-admins' AD security group..."

    $existing = Get-ADGroup -Filter "Name -eq 'linux-admins'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warn "'linux-admins' group already exists. Skipping."
        return
    }

    New-ADGroup `
        -Name "linux-admins" `
        -GroupScope Global `
        -GroupCategory Security `
        -Description "Members can sudo to root on Linux systems - SYS-265" `
        -ErrorAction Stop

    Write-Success "'linux-admins' security group created."
}

function Invoke-UserCreation {
    param([string]$DomainName)

    Write-Host ""
    Write-Host "=== Domain User Creation ===" -ForegroundColor White
    Write-Host ""
    Write-Info "Creating standard domain accounts for SYS-265..."
    Write-Host ""

    # --- Goose (Domain Admin) ---
    Write-Info "Account 1: Goose (Domain Admin)"
    $goosePass = Get-SecureInput "Set password for Goose"
    try {
        New-DomainUserAccount `
            -Username "goose" `
            -DisplayName "Goose" `
            -Password $goosePass `
            -IsAdmin $true `
            -DomainName $DomainName
    } catch {
        Write-Err "Failed to create Goose: $_"
    }

    Write-Host ""

    # --- Duck (Standard User) ---
    Write-Info "Account 2: Duck (Standard Domain User)"
    $duckPass = Get-SecureInput "Set password for Duck"
    try {
        New-DomainUserAccount `
            -Username "duck" `
            -DisplayName "Duck" `
            -Password $duckPass `
            -IsAdmin $false `
            -DomainName $DomainName
    } catch {
        Write-Err "Failed to create Duck: $_"
    }

    Write-Host ""

    # Additional users
    while ($true) {
        $another = Get-YesNo "Do you want to create another domain user?" "n"
        if (-not $another) { break }

        Write-Host ""
        $uname       = Get-Input "Username"
        $udisplay    = Get-Input "Display name"
        $upass       = Get-SecureInput "Password for $uname"
        $uadmin      = Get-YesNo "Should $uname be a Domain Admin?" "n"

        try {
            New-DomainUserAccount `
                -Username $uname `
                -DisplayName $udisplay `
                -Password $upass `
                -IsAdmin $uadmin `
                -DomainName $DomainName
        } catch {
            Write-Err "Failed to create ${uname}: $_"
        }
        Write-Host ""
    }

    # Create linux-admins group
    Write-Host ""
    $createLinuxAdmins = Get-YesNo "Create the 'linux-admins' AD security group? (Required for Requirement 6)" "y"
    if ($createLinuxAdmins) {
        try {
            New-LinuxAdminsGroup

            # Ask if Goose should be in linux-admins
            $addGoose = Get-YesNo "Add Goose to the 'linux-admins' group?" "y"
            if ($addGoose) {
                Add-ADGroupMember -Identity "linux-admins" -Members "goose" -ErrorAction SilentlyContinue
                Write-Success "Added Goose to linux-admins."
            }
        } catch {
            Write-Err "Failed to create linux-admins group: $_"
        }
    }
}

# =============================================
# Verify AD Replication
# =============================================

function Test-ADReplication {
    Write-Host ""
    Write-Host "=== AD Replication Check ===" -ForegroundColor White
    Write-Host ""
    Write-Info "Checking replication status between domain controllers..."

    try {
        $replStatus = Get-ADReplicationPartnerMetadata -Target $env:COMPUTERNAME -ErrorAction Stop
        foreach ($partner in $replStatus) {
            Write-Info "Partner: $($partner.Partner)"
            Write-Info "  Last Replication Success : $($partner.LastReplicationSuccess)"
            Write-Info "  Last Replication Result  : $($partner.LastReplicationResult)"
            if ($partner.LastReplicationResult -eq 0) {
                Write-Success "  Replication with $($partner.Partner) is healthy."
            } else {
                Write-Warn "  Replication with $($partner.Partner) may have issues. Result code: $($partner.LastReplicationResult)"
            }
        }
    } catch {
        Write-Warn "Could not retrieve replication data: $_"
        Write-Info "Try running: repadmin /showrepl"
    }

    # Force sync
    $forceSync = Get-YesNo "Force a replication sync now?" "y"
    if ($forceSync) {
        Write-Info "Forcing replication sync..."
        try {
            $dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
            foreach ($dc in $dcs) {
                $output = & repadmin /syncall $dc /AdeP 2>&1
                Write-Success "Sync initiated with: $dc"
                Write-Info ($output | Out-String).Trim()
            }
        } catch {
            Write-Warn "repadmin sync failed: $_"
        }
    }
}

# =============================================
# Summary
# =============================================

function Show-Summary {
    param([hashtable]$Config)

    Write-Host ""
    Write-Host "======================================" -ForegroundColor White
    Write-Host "  AD Setup Summary" -ForegroundColor White
    Write-Host "======================================" -ForegroundColor White
    Write-Host "Hostname:    $($Config.Hostname)"
    Write-Host "Role:        $($Config.Role)"
    Write-Host "Domain:      $($Config.DomainName)"
    Write-Host "Action:      $($Config.Action)"
    Write-Host "======================================" -ForegroundColor White
    Write-Host ""
}

# =============================================
# Main
# =============================================

function Main {
    Clear-Host
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  Active Directory Setup Script" -ForegroundColor Cyan
    Write-Host "  Ben Deyot - SYS-265" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Log "=== AD setup script started ==="

    # Detect current machine state
    Write-Info "Detecting machine state..."
    $state = Get-MachineState

    Write-Host ""
    Write-Host "======================================" -ForegroundColor White
    Write-Host "  Machine Detection Results" -ForegroundColor White
    Write-Host "======================================" -ForegroundColor White
    Write-Host "Hostname  : $($state.Hostname)"
    Write-Host "Role      : $($state.Role)"
    Write-Host "Domain    : $(if ($state.DomainName) { $state.DomainName } else { 'Not joined' })"
    Write-Host "AD-DS     : $(if ($state.ADInstalled) { 'Installed' } else { 'Not installed' })"
    Write-Host "======================================" -ForegroundColor White
    Write-Host ""

    $config = @{
        Hostname   = $state.Hostname
        Role       = $state.Role
        DomainName = $state.DomainName
        Action     = ""
    }

    # ---- Already a DC - offer user creation and replication check ----
    if ($state.IsDC) {
        Write-Success "This machine is already a Domain Controller ($($state.Role))."
        Write-Host ""

        $doUsers = Get-YesNo "Do you want to create/manage domain users?" "y"
        if ($doUsers) {
            Invoke-UserCreation -DomainName $state.DomainName
            $config.Action = "User Creation"
        }

        Write-Host ""
        $doRepl = Get-YesNo "Do you want to check AD replication status?" "y"
        if ($doRepl) {
            Test-ADReplication
            if ($config.Action -ne "") {
                $config.Action += " + Replication Check"
            } else {
                $config.Action = "Replication Check"
            }
        }

        Show-Summary $config
        Write-Info "Log saved to: $LogFile"
        return
    }

    # ---- Not a DC yet — determine what to do ----

    # Get domain name
    Write-Host ""
    Write-Host "=== Domain Configuration ===" -ForegroundColor White
    Write-Host ""
    $domainName = Get-Input "Enter the domain name (e.g. grp1.local)"
    $config.DomainName = $domainName

    # Try to find an existing DC to determine if this is DC1 or DC2
    Write-Host ""
    Write-Info "Checking if a domain already exists for: $domainName"

    $domainExists = $false
    try {
        [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain(
            (New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext("Domain", $domainName))
        ) | Out-Null
        $domainExists = $true
        Write-Success "Existing domain found. This machine will be promoted as DC2 (additional DC)."
    } catch {
        Write-Info "No existing domain found. This machine will be promoted as DC1 (new forest)."
    }

    # Install AD-DS role if not already installed
    Write-Host ""
    if (-not $state.ADInstalled) {
        $installRole = Get-YesNo "Install the AD Domain Services role now?" "y"
        if ($installRole) {
            try {
                Install-ADDSRole
            } catch {
                Write-Err "Failed to install AD-DS role: $_"
                exit 1
            }
        } else {
            Write-Err "AD-DS role is required. Exiting."
            exit 1
        }
    } else {
        Write-Info "AD-DS role is already installed."
    }

    Write-Host ""

    if (-not $domainExists) {
        # ---- DC1 Path ----
        Write-Host "=== DC1 Promotion - New Forest ===" -ForegroundColor White
        Write-Host ""

        # NetBIOS name (auto-derive from domain)
        $netBIOS = ($domainName.Split('.')[0]).ToUpper()
        Write-Info "Auto-derived NetBIOS name: $netBIOS"
        $confirmNetBIOS = Get-YesNo "Use this NetBIOS name?" "y"
        if (-not $confirmNetBIOS) {
            $netBIOS = (Get-Input "Enter NetBIOS name").ToUpper()
        }

        Write-Host ""
        Write-Info "You will need a Directory Services Restore Mode (DSRM) password."
        Write-Info "This is used to recover AD if something goes wrong. Store it safely."
        $dsrmPass = Get-SecureInput "Set DSRM password"

        $config.Action = "DC1 Promotion (New Forest)"
        Show-Summary $config

        Invoke-DC1Promotion `
            -DomainName $domainName `
            -NetBIOSName $netBIOS `
            -DSRMPassword $dsrmPass

    } else {
        # ---- DC2 Path ----
        Write-Host "=== DC2 Promotion - Additional Domain Controller ===" -ForegroundColor White
        Write-Host ""

        Write-Info "You need a domain admin credential to join as an additional DC."
        $domainUser  = Get-Input "Domain admin username (e.g. Administrator)"
        $domainPass  = Get-SecureInputSingle "Password for $domainUser"
        $credential  = New-Object System.Management.Automation.PSCredential(
            "$domainName\$domainUser", $domainPass)

        Write-Host ""
        Write-Info "You will need a DSRM password for this DC as well."
        $dsrmPass = Get-SecureInput "Set DSRM password"

        $config.Action = "DC2 Promotion (Additional DC)"
        Show-Summary $config

        Invoke-DC2Promotion `
            -DomainName $domainName `
            -DSRMPassword $dsrmPass `
            -DomainCredential $credential
    }

    Write-Host ""
    Write-Info "Log saved to: $LogFile"
    Write-Host ""
}

# Entry point
Main
