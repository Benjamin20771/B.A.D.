<#
    .SYNOPSIS
    Changes the champuser password across base/golden images via the QEMU guest
    agent. No reimaging; nothing else on the image is touched.

    .DESCRIPTION
    Targets VMs tagged "base-vms" (or a manually entered VMID list), changes the
    password on each running image through the guest agent, verifies the change
    succeeded (Level A: command success + agent healthy), then gracefully shuts
    the VM down.

    VMs must be POWERED ON before running this. The guest agent only responds on
    running VMs. VMs that aren't running (or have no working agent) are skipped
    and reported at the end.

    For appliances (VyOS/pfSense/OPNsense) where the user may not be champuser,
    the script falls through a list of likely usernames until one succeeds.

    .NOTES
    Requires: powershell-yaml is NOT needed. Requires cv4pve-api-powershell (same
    module the deploy script uses) and Credentials.ps1 / ScriptConfig.ps1 for the
    Proxmox connection, OR run directly on a Proxmox node using `qm` (see the
    USE_QM switch below).

    Last Edit: <date> - <you>
#>

# ─────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────

# Username tried first on every image.
$PrimaryUser = "champuser"

# Fallback usernames for appliances / images where champuser isn't the admin.
# Tried in order until one succeeds.
$FallbackUsers = @("admin", "root", "vyos", "Administrator")

# The tag that marks base images.
$BaseTag = "base-vms"

# Seconds to wait for the guest agent to answer a ping before treating the VM
# as unreachable.
$AgentTimeout = 10

# ─────────────────────────────────────────────────────────────
# CONNECT (matches the deploy script's connection method)
# ─────────────────────────────────────────────────────────────
. .\deployment-and-removal\Credentials.ps1
. .\deployment-and-removal\ScriptConfig.ps1

Write-Host "Connecting to Proxmox cluster..." -ForegroundColor Cyan
Connect-PveCluster -HostsAndPorts $Global:ConnectedNode -SkipCertificateCheck `
    -ApiToken "$User@$global:Realm!$TokenName=$Token" | Out-Null

# ─────────────────────────────────────────────────────────────
# 1. TARGET SELECTION
# ─────────────────────────────────────────────────────────────
function Get-TargetVMs {
    Write-Host ""
    Write-Host "How would you like to select base images?" -ForegroundColor Cyan
    Write-Host "  1. Auto-find all VMs tagged '$BaseTag'"
    Write-Host "  2. Enter VMIDs manually"
    $choice = Read-Host "Select (1 or 2)"

    $targets = @()

    if ($choice -eq "1") {
        # Pull all VMs, keep the ones carrying the base-vms tag.
        $allVMs = (Get-PveClusterResources -Type vm).ToData()
        foreach ($vm in $allVMs) {
            if ($vm.tags -and ($vm.tags -split "[;, ]") -contains $BaseTag) {
                $targets += [PSCustomObject]@{
                    VMID = $vm.vmid
                    Name = $vm.name
                    Node = $vm.node
                    Status = $vm.status
                }
            }
        }
        Write-Host "Found $($targets.Count) VM(s) tagged '$BaseTag'." -ForegroundColor Green
    }
    else {
        # Manual entry loop — enter VMIDs until 'done'.
        Write-Host "Enter VMIDs one at a time. Type 'done' when finished." -ForegroundColor Yellow
        while ($true) {
            $entry = Read-Host "VMID (or 'done')"
            if ($entry -ieq "done") { break }
            if ($entry -notmatch '^\d+$') {
                Write-Host "  '$entry' is not a valid VMID." -ForegroundColor Red
                continue
            }
            $vm = (Get-PveClusterResources -Type vm).ToData() |
                  Where-Object vmid -eq [int]$entry | Select-Object -First 1
            if (-not $vm) {
                Write-Host "  VMID $entry not found on the cluster." -ForegroundColor Red
                continue
            }
            $targets += [PSCustomObject]@{
                VMID = $vm.vmid; Name = $vm.name; Node = $vm.node; Status = $vm.status
            }
            Write-Host "  Added $($vm.vmid) ($($vm.name))" -ForegroundColor Green
        }
    }
    return $targets
}

# ─────────────────────────────────────────────────────────────
# 2. PASSWORD PROMPT (twice, must match)
# ─────────────────────────────────────────────────────────────
function Get-NewPassword {
    while ($true) {
        $p1 = Read-Host "Enter the NEW password for the base images" -AsSecureString
        $p2 = Read-Host "Confirm the NEW password" -AsSecureString

        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))

        if ($plain1 -ne $plain2) {
            Write-Host "Passwords do not match. Try again." -ForegroundColor Red
            continue
        }
        if ([string]::IsNullOrWhiteSpace($plain1)) {
            Write-Host "Password cannot be empty. Try again." -ForegroundColor Red
            continue
        }
        return $plain1
    }
}

# ─────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────

# Is the guest agent responding on this VM?
function Test-AgentAlive {
    param($Node, $VMID)
    try {
        $ping = Get-PveNodesQemuAgentPing -Node $Node -Vmid $VMID -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Try to set the password for a given user. Returns $true on success.
function Set-GuestPassword {
    param($Node, $VMID, $User, $Password)
    try {
        # crypted=0 => plaintext; Proxmox/QGA hashes it inside the guest.
        $result = Set-PveNodesQemuAgentSetUserPassword `
            -Node $Node -Vmid $VMID -Username $User -Password $Password -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────

$targets = Get-TargetVMs
if ($targets.Count -eq 0) {
    Write-Host "No target VMs selected. Exiting." -ForegroundColor Red
    return
}

# Show what we're about to touch and get a final confirmation.
Write-Host ""
Write-Host "About to change the password on these VM(s):" -ForegroundColor Cyan
$targets | ForEach-Object {
    $stateColor = if ($_.Status -eq "running") { "Green" } else { "Red" }
    Write-Host ("  {0,-10} {1,-35} node:{2,-8} [{3}]" -f `
        $_.VMID, $_.Name, $_.Node, $_.Status) -ForegroundColor $stateColor
}
Write-Host ""
Write-Host "NOTE: VMs not 'running' will be skipped (agent needs a running VM)." -ForegroundColor Yellow
$confirm = Read-Host "Proceed? (yes/no)"
if ($confirm -ine "yes") { Write-Host "Cancelled."; return }

$NewPassword = Get-NewPassword

# Track results for the final report.
$succeeded = @()
$failed    = @()
$skipped   = @()

foreach ($vm in $targets) {
    Write-Host ""
    Write-Host "=== $($vm.VMID) ($($vm.Name)) ===" -ForegroundColor Cyan

    # Skip anything not running.
    if ($vm.Status -ne "running") {
        Write-Host "  SKIP: not running (power it on first)." -ForegroundColor Yellow
        $skipped += "$($vm.VMID) ($($vm.Name)) - not running"
        continue
    }

    # Verify the agent answers before we try anything.
    if (-not (Test-AgentAlive -Node $vm.Node -VMID $vm.VMID)) {
        Write-Host "  SKIP: guest agent not responding." -ForegroundColor Yellow
        $skipped += "$($vm.VMID) ($($vm.Name)) - agent not responding"
        continue
    }

    # Try champuser first, then fall through the appliance usernames.
    $usersToTry = @($PrimaryUser) + $FallbackUsers
    $changed = $false
    $usedUser = $null

    foreach ($user in $usersToTry) {
        Write-Host "  Trying user '$user'..." -NoNewline
        if (Set-GuestPassword -Node $vm.Node -VMID $vm.VMID -User $user -Password $NewPassword) {
            Write-Host " OK" -ForegroundColor Green
            $changed = $true
            $usedUser = $user
            break
        } else {
            Write-Host " no" -ForegroundColor DarkGray
        }
    }

    if (-not $changed) {
        Write-Host "  FAILED: no username worked." -ForegroundColor Red
        $failed += "$($vm.VMID) ($($vm.Name)) - no matching user"
        continue
    }

    # Level A verify: change reported success AND agent is still healthy.
    if (Test-AgentAlive -Node $vm.Node -VMID $vm.VMID) {
        Write-Host "  VERIFIED: password set for '$usedUser', agent healthy." -ForegroundColor Green
    } else {
        Write-Host "  WARN: password set but agent went unresponsive after." -ForegroundColor Yellow
    }

    # Graceful shutdown (lets the change flush + OS shut down cleanly).
    Write-Host "  Shutting down gracefully..." -NoNewline
    try {
        Stop-PveNodesQemuShutdown -Node $vm.Node -Vmid $vm.VMID -ErrorAction Stop | Out-Null
        Write-Host " done" -ForegroundColor Green
    } catch {
        Write-Host " shutdown command failed (VM may need manual shutdown)." -ForegroundColor Yellow
    }

    $succeeded += "$($vm.VMID) ($($vm.Name)) - user '$usedUser'"
}

# ─────────────────────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════ SUMMARY ══════════════" -ForegroundColor Cyan
Write-Host "Changed  ($($succeeded.Count)):" -ForegroundColor Green
$succeeded | ForEach-Object { Write-Host "   $_" }
Write-Host "Skipped  ($($skipped.Count)):" -ForegroundColor Yellow
$skipped   | ForEach-Object { Write-Host "   $_" }
Write-Host "Failed   ($($failed.Count)):" -ForegroundColor Red
$failed    | ForEach-Object { Write-Host "   $_" }
Write-Host "═════════════════════════════════════" -ForegroundColor Cyan

# Clear the plaintext password from memory.
$NewPassword = $null
[System.GC]::Collect()
