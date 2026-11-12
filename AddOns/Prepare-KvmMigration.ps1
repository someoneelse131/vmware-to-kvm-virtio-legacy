#Requires -Version 5.1
<#
==========================================================
 Prepare-KvmMigration.ps1 (legacy, lite, optional add-on)
==========================================================
LEGACY VARIANT - WORK IN PROGRESS, not tested yet.
Prepares a Windows Server 2012 R2 for the move from VMware to KVM.
Lean version of the add-on in vmware-to-kvm-virtio: no SAN policy, no questions.

When:  after the WinPE run (Windows is running on VMware again), before the migration.
Where: on the admin PC / jump host (PowerShell 5.1). The script connects to the server
       via WinRM. Everything that runs on the server works with PowerShell 4.0.

Usage:
    .\Prepare-KvmMigration.ps1 -ComputerName SRV01
    .\Prepare-KvmMigration.ps1 -ComputerName SRV01 -Credential (Get-Credential)

What it does, step by step:
- 0. Checks that the server is 2012 R2 and that WinPE has injected the VirtIO drivers.
     Removes StartOverride. If the check fails: it stops. Do NOT migrate the VM.
- 1. Copies everything in the folder PostMigrationFiles next to this script
     to C:\virtio-inject on the server (cleanup script, QEMU Guest Agent MSI, drivers).
- 2. Saves the IP configuration and creates a scheduled task.
     On the first start on KVM the task sets the same IP on the new network adapter.
     On every start on VMware the task removes StartOverride again.
     Works for 1 adapter with a static IP. With DHCP there is nothing to save.
     Other cases: the IP is only shown and saved on the admin PC, and you set it by hand.

Notes:
- The script does not change the network settings of the server.
- It only stops if the check fails or WinRM does not work. Everything else is a warning.
- Results of an earlier run are removed first, so an old IP is never applied.
- Set the IP by hand (console of the target hypervisor, as administrator):
    powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComputerName,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$LocalCopyPath,

    [string]$PostMigrationFilesPath
)

$ErrorActionPreference = 'Stop'

# ==========================================================
# CONFIG
# ==========================================================

$base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location -PSProvider FileSystem).ProviderPath }

# Here we keep a copy of the saved IP configuration
if (-not $LocalCopyPath) {
    $LocalCopyPath = Join-Path $base 'NetConfig'
}

# Here are the files for the cleanup
if (-not $PostMigrationFilesPath) {
    $PostMigrationFilesPath = Join-Path $base 'PostMigrationFiles'
}

$TaskName = 'VirtIO-Restore-NetConfig'
$warnings = New-Object System.Collections.Generic.List[string]
$taskOk   = $false   # task in place? It also removes StartOverride at every start on VMware.

# ==========================================================
# FUNCTIONS
# ==========================================================

# Show a warning and remember it for the summary at the end
function Warn([string]$Text) {
    Write-Host "  WARNING: $Text" -ForegroundColor Yellow
    $warnings.Add($Text)
}

# Remove what an earlier run left behind (on the server and on the admin PC).
# Otherwise an old task could set an old IP on KVM.
function Remove-OldRestore([string]$Computer) {
    Invoke-Command -Session $session -ArgumentList $TaskName -ScriptBlock {
        param($Task)
        Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item 'C:\virtio-inject\Restore-NetConfig.ps1' -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in "${Computer}_Restore-NetConfig.ps1", "${Computer}_IP-Configuration.txt") {
        Remove-Item -LiteralPath (Join-Path $LocalCopyPath $f) -Force -ErrorAction SilentlyContinue
    }
}

# Turn a text into a safe PowerShell string: abc -> 'abc'
function ConvertTo-Literal([string]$Text) {
    "'" + ($Text -replace "'", "''") + "'"
}

# Turn a list into a PowerShell array: a, b -> @('a', 'b')
function ConvertTo-ArrayLiteral($Items) {
    '@(' + ((@($Items) | Where-Object { $_ } | ForEach-Object { ConvertTo-Literal $_ }) -join ', ') + ')'
}

# ==========================================================
# RESTORE SCRIPT
# ==========================================================
# This builds the script that sets the IP on KVM. It runs on the server (PowerShell 4.0).
# Top part: the saved values of this server. Bottom part: always the same logic.

function New-RestoreScript($net, $cfg) {
$header = @"
#Requires -Version 4.0
#Requires -RunAsAdministrator
# Created by Prepare-KvmMigration.ps1 (legacy) at $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME
# Sets the IPv4 configuration of $($net.Computer) on the new network adapter after the migration.
# Runs automatically at startup (scheduled task VirtIO-Restore-NetConfig, switch -AtStartup).
# Manual run (as administrator):
#   powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1
# After success the script deletes the task and itself; the log stays.
param([switch]`$AtStartup)

# Saved values (adapter '$($cfg.Alias)', $($cfg.Description), MAC $($cfg.Mac))
`$Computer       = $(ConvertTo-Literal $net.Computer)
`$OldGuid        = $(ConvertTo-Literal $cfg.Guid)
`$OldDescription = $(ConvertTo-Literal $cfg.Description)
`$IPs            = $(ConvertTo-ArrayLiteral $cfg.IPs)
`$Gateway        = $(ConvertTo-ArrayLiteral $cfg.Gateway)
`$Dns            = $(ConvertTo-ArrayLiteral $cfg.Dns)
`$Suffix         = $(ConvertTo-Literal $cfg.Suffix)
`$Register       = `$$($cfg.Register.ToString().ToLower())

"@

$body = @'
$ErrorActionPreference = 'Stop'
$TaskName = 'VirtIO-Restore-NetConfig'

Start-Transcript -Path 'C:\virtio-inject\Restore-NetConfig.log' -Append | Out-Null
try {
    # ==========================================================
    # SAFETY
    # ==========================================================

    if ($env:COMPUTERNAME -ne $Computer) {
        throw "This script belongs to $Computer, not to $env:COMPUTERNAME."
    }

    # Is the old VMware network adapter still there? Then we are still on VMware.
    # In that case: do not touch the network, only remove StartOverride again.
    # (Windows can set StartOverride at every start on VMware. On KVM it would cause blue screen 0x7B.)
    $stillVMware = "The old network adapter ($OldDescription) is still present (server is still running on VMware)."

    function Skip-OnVMware {
        foreach ($s in 'viostor', 'vioscsi') {
            Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$s\StartOverride" -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "$stillVMware StartOverride (if present) removed, network not changed, next attempt at the next start."
    }

    if (Get-NetAdapter | Where-Object InterfaceGuid -eq $OldGuid) {
        if ($AtStartup) {
            Skip-OnVMware
            return
        }
        throw "$stillVMware Run the script only after the migration."
    }

    # ==========================================================
    # WAIT FOR THE NEW ADAPTER
    # ==========================================================

    # At startup Windows may still be installing the new VirtIO adapter.
    # Check every 5 seconds, at most 5 minutes.
    $nics = @(Get-NetAdapter -Physical)
    if ($AtStartup) {
        $until = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $until) {
            $nics = @(Get-NetAdapter -Physical)
            if ($nics.Count -eq 1 -and
                (Get-NetIPInterface -InterfaceIndex $nics[0].ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                break
            }
            Start-Sleep -Seconds 5
        }
    }

    if ($nics.Count -ne 1) {
        throw "Expected exactly 1 network adapter, found: $($nics.Count) ($(($nics | ForEach-Object Name) -join ', ')). Please set manually."
    }
    $nic = $nics[0]

    # Still the old adapter (e.g. found late at startup)? Then we are on VMware.
    if ($nic.InterfaceGuid -eq $OldGuid) {
        if ($AtStartup) {
            Skip-OnVMware
            return
        }
        throw "$stillVMware Run the script only after the migration."
    }

    $idx = $nic.ifIndex
    Write-Host "New adapter: $($nic.Name) ($($nic.InterfaceDescription))"

    # ==========================================================
    # OLD ADAPTER
    # ==========================================================

    # The old adapter is hidden now, but still has the IP in the registry.
    # Remove it, otherwise Windows says "IP address is already assigned to another adapter".
    $oldKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$OldGuid"
    if (Test-Path $oldKey) {
        Set-ItemProperty -Path $oldKey -Name EnableDHCP -Value 1
        foreach ($name in 'IPAddress', 'SubnetMask', 'DefaultGateway', 'NameServer') {
            Remove-ItemProperty -Path $oldKey -Name $name -ErrorAction SilentlyContinue
        }
        Write-Host "IP entries of the old adapter removed."
    }

    # ==========================================================
    # SET IP
    # ==========================================================

    # New adapter: turn DHCP off and remove what is there (e.g. 169.254.x.x)
    Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    foreach ($ip in $IPs) {
        $addr, $len = $ip -split '/'
        New-NetIPAddress -InterfaceIndex $idx -IPAddress $addr -PrefixLength $len | Out-Null
    }

    foreach ($gw in $Gateway) {
        New-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -NextHop $gw | Out-Null
    }

    if ($Dns.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $Dns
    }

    $dnsClient = @{ InterfaceIndex = $idx; RegisterThisConnectionsAddress = $Register }
    if ($Suffix) {
        $dnsClient.ConnectionSpecificSuffix = $Suffix
    }
    Set-DnsClient @dnsClient

    # ==========================================================
    # VERIFY
    # ==========================================================

    $nowIp  = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
    $nowGw  = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object NextHop)
    $nowDns = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4).ServerAddresses)
    Write-Host "Set: IP $($nowIp -join ', ') | Gateway $($nowGw -join ', ') | DNS $($nowDns -join ', ')"

    # Ping the gateway (fails if the VM is in the wrong VLAN)
    if ($Gateway.Count -gt 0) {
        Start-Sleep -Seconds 3
        $pingOk = Test-Connection -ComputerName $Gateway[0] -Count 2 -Quiet
        Write-Host "Ping gateway $($Gateway[0]): $pingOk"
        if (-not $pingOk) {
            Write-Host "IP is set anyway -> check VLAN/network of the VM on the target hypervisor."
        }
    }

    # ==========================================================
    # CLEAN UP
    # ==========================================================

    # Done: delete this script and the task (a copy of the values is on the admin PC).
    # The task is removed last, in case that stops this script.
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up: $PSCommandPath and scheduled task $TaskName removed."
    Write-Host "Done."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    throw
}
finally {
    Stop-Transcript | Out-Null
}
'@

# Windows line endings, so Notepad shows the script correctly
($header + "`n" + $body) -replace "`r?`n", "`r`n"
}

# ==========================================================
# CONNECT
# ==========================================================

$remote = @{ ComputerName = $ComputerName }
if ($Credential) {
    $remote.Credential = $Credential
}
$session = New-PSSession @remote

try {
    # ==========================================================
    # 0. CHECK
    # ==========================================================
    # This add-on is only for 2012 R2 (2008 R2 has PowerShell 2.0, 2016+ use the main repo).
    # A Windows logon alone does not prove that WinPE worked
    # (e.g. the key press at the CD boot was missed).
    # So we check on the server:
    # - completed.txt exists (written by WinPE on success)
    # - viostor/vioscsi are boot drivers (Start=0)
    # - netkvm is in the driver store (otherwise no network on KVM)
    # We also remove StartOverride. Windows can set it when it starts on VMware and finds
    # no VirtIO disk. If it stays, the VM gets blue screen 0x7B on KVM.

    Write-Host "Checking $ComputerName ..."

    $chk = Invoke-Command -Session $session -ScriptBlock {
        $svc = 'HKLM:\SYSTEM\CurrentControlSet\Services'

        $r = [ordered]@{
            Build     = [string](Get-CimInstance Win32_OperatingSystem).BuildNumber
            PSVersion = [string]$PSVersionTable.PSVersion
            Completed = Test-Path 'C:\virtio-inject\completed.txt'
        }

        foreach ($s in 'viostor', 'vioscsi') {
            $r["${s}Start"]   = [string](Get-ItemProperty "$svc\$s" -ErrorAction SilentlyContinue).Start
            $r["${s}Removed"] = $false
            if (Test-Path "$svc\$s\StartOverride") {
                Remove-Item "$svc\$s\StartOverride" -Recurse -Force -ErrorAction SilentlyContinue
                $r["${s}Removed"] = $true
            }
            $r["${s}Override"] = Test-Path "$svc\$s\StartOverride"
        }

        $r.NetKvm = [bool](Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'netkvm.inf_*' -ErrorAction SilentlyContinue)

        # Execution policy from a GPO (then the restore and cleanup scripts cannot run)
        $r.GpoPolicy = [string](Get-ExecutionPolicy -Scope MachinePolicy)

        [pscustomobject]$r
    }

    if ($chk.Build -ne '9600') {
        throw "$ComputerName has build $($chk.Build), this add-on is only for Server 2012 R2 (9600). 2016-2025: use vmware-to-kvm-virtio. 2008 R2: manual steps."
    }
    Write-Host "  Server 2012 R2 (build $($chk.Build)), PowerShell $($chk.PSVersion)."

    $problems = @()
    if (-not $chk.Completed) {
        $problems += 'C:\virtio-inject\completed.txt missing (WinPE did not run or ended with an error)'
    }
    foreach ($s in 'viostor', 'vioscsi') {
        if ($chk."${s}Start" -ne '0') {
            $problems += "$s Start='$($chk."${s}Start")' instead of 0 (boot driver not ready)"
        }
        if ($chk."${s}Override") {
            $problems += "$s StartOverride could not be removed (permissions?)"
        }
    }
    if (-not $chk.NetKvm) {
        $problems += 'netkvm missing in the driver store (no network after the migration)'
    }

    if ($problems.Count -gt 0) {
        throw "VirtIO check failed, do NOT migrate:`n  - " + ($problems -join "`n  - ") +
              "`nLog on the server: C:\virtio-inject\inject.log. Repeat the WinPE run, then start this script again."
    }

    Write-Host "  VirtIO check ok: completed.txt, viostor/vioscsi Start=0 without StartOverride, netkvm present."

    $removed = @('viostor', 'vioscsi' | Where-Object { $chk."${_}Removed" })
    if ($removed.Count -gt 0) {
        Write-Host "  StartOverride removed for: $($removed -join ', ')." -ForegroundColor Yellow
    }
    if ($chk.GpoPolicy -in 'AllSigned', 'Restricted') {
        Warn "Execution policy set by GPO = $($chk.GpoPolicy): restore and cleanup scripts will probably not start -> do these steps manually after the migration."
    }

    # ==========================================================
    # 1. FILES FOR THE CLEANUP
    # ==========================================================
    # Copy everything in PostMigrationFiles to C:\virtio-inject on the server
    # (subfolders included). The files are sent as bytes through the WinRM session:
    # no file share needed, and it works with PowerShell 4.0 on the server.

    Write-Host "`nCopying files for the cleanup from $PostMigrationFilesPath ..."

    $files = @()
    if (Test-Path -LiteralPath $PostMigrationFilesPath -PathType Container) {
        $root  = (Get-Item -LiteralPath $PostMigrationFilesPath).FullName.TrimEnd('\')
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -ne '.gitkeep' })
    }

    if ($files.Count -eq 0) {
        Warn "$PostMigrationFilesPath missing or empty - nothing copied, the cleanup has no files."
    }
    foreach ($req in 'Cleanup-AfterMigration.ps1', 'qemu-ga-x86_64.msi') {
        if ($files.Count -gt 0 -and -not ($files | Where-Object { $_.Name -eq $req })) {
            Warn "$req missing in $PostMigrationFilesPath."
        }
    }
    if ($files.Count -gt 0 -and -not ($files | Where-Object { $_.Extension -eq '.inf' -and $_.FullName.StartsWith((Join-Path $root 'Drivers')) })) {
        Warn "No drivers (.inf) in $PostMigrationFilesPath\Drivers - the cleanup cannot install them."
    }

    # WinRM accepts at most 10 MB per object (default). One file is one object.
    $copied = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1)
        if ($f.Length -gt 7MB) {
            Warn "$rel is too big for the copy via WinRM. Copy it by hand to C:\virtio-inject\$rel."
            continue
        }
        try {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $have = Invoke-Command -Session $session -ArgumentList $rel, $bytes -ScriptBlock {
                param($Rel, $Bytes)
                $path = Join-Path 'C:\virtio-inject' $Rel
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                [IO.File]::WriteAllBytes($path, $Bytes)
                (Get-Item -LiteralPath $path).Length
            }
            if ($have -eq $f.Length) {
                $copied++
            } else {
                Warn "$rel on the server has $have instead of $($f.Length) bytes."
            }
        }
        catch {
            Warn "$rel not copied: $($_.Exception.Message)"
        }
    }
    if ($files.Count -gt 0) {
        Write-Host "  $copied of $($files.Count) files copied to C:\virtio-inject."
    }

    # ==========================================================
    # 2. NETWORK CONFIGURATION
    # ==========================================================

    Write-Host "`nReading network configuration from $ComputerName ..."

    # Read all physical adapters on the server.
    # Only text and numbers come back, so nothing is lost on the way through WinRM.
    $net = Invoke-Command -Session $session -ScriptBlock {
        $list = foreach ($nic in @(Get-NetAdapter -Physical | Sort-Object ifIndex)) {
            $idx  = $nic.ifIndex
            $addr = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            $dnsClient = Get-DnsClient -InterfaceIndex $idx -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Index       = $idx
                Alias       = $nic.Name
                Description = $nic.InterfaceDescription
                Mac         = $nic.MacAddress
                Guid        = [string]$nic.InterfaceGuid
                Status      = [string]$nic.Status
                Dhcp        = [string](Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
                IPs         = @($addr | Where-Object PrefixOrigin -eq 'Manual' | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                SkipIPs     = @($addr | Where-Object SkipAsSource | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                AllIPs      = @($addr | ForEach-Object {
                                  $t = "$($_.IPAddress)/$($_.PrefixLength) ($($_.PrefixOrigin)"
                                  if ($_.SkipAsSource) { $t += ', SkipAsSource' }
                                  "$t)" })
                Gateway     = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                                Where-Object NextHop -ne '0.0.0.0' | ForEach-Object NextHop | Sort-Object -Unique)
                Dns         = @((Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
                Suffix      = [string]$dnsClient.ConnectionSpecificSuffix
                Register    = if ($dnsClient) { [bool]$dnsClient.RegisterThisConnectionsAddress } else { $null }
            }
        }
        [pscustomobject]@{
            Computer = $env:COMPUTERNAME
            Nics     = @($list)
            # Extra static routes (they are lost with the old adapter)
            Routes   = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
                         Where-Object DestinationPrefix -ne '0.0.0.0/0' |
                         ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) (ifIndex $($_.InterfaceIndex), metric $($_.RouteMetric))" })
        }
    }
    $nics = @($net.Nics)

    # Can the IP be set automatically? Only with exactly 1 active adapter and a static IP.
    $reasons = @()
    if ($nics.Count -ne 1) {
        $reasons += "$($nics.Count) physical network adapters ($(($nics | ForEach-Object Alias) -join ', '))"
    }
    foreach ($n in $nics) {
        if ($n.Status -ne 'Up') {
            $reasons += "adapter '$($n.Alias)' not up (status $($n.Status))"
        }
        if (@($n.SkipIPs).Count -gt 0) {
            $reasons += "SkipAsSource on $(@($n.SkipIPs) -join ', ') (adapter '$($n.Alias)')"
        }
    }

    # DHCP? (Only 'Enabled' means DHCP. Empty, e.g. a team member, is a special case.)
    $isDhcp = $reasons.Count -eq 0 -and $nics[0].Dhcp -eq 'Enabled'
    if ($reasons.Count -eq 0 -and -not $isDhcp) {
        if (@($nics[0].IPs).Count -eq 0) {
            $reasons += "no static IPv4 address on '$($nics[0].Alias)' (DHCP status '$($nics[0].Dhcp)')"
        }
        if (-not $nics[0].Guid) {
            $reasons += "no InterfaceGuid for '$($nics[0].Alias)'"
        }
        if ($null -eq $nics[0].Register) {
            $reasons += "DNS settings of '$($nics[0].Alias)' not readable"
        }
    }

    # Create the copy folder and remove results of an earlier run
    $LocalCopyPath = (New-Item -ItemType Directory -Path $LocalCopyPath -Force).FullName
    Remove-OldRestore $net.Computer

    if ($isDhcp) {
        # ==========================================================
        # 2a. DHCP: nothing to save
        # ==========================================================
        Write-Host "  $ComputerName gets its IP via DHCP: nothing to save." -ForegroundColor Yellow
        Write-Host "  If a DHCP reservation exists: update it to the new MAC of the VirtIO adapter after the migration." -ForegroundColor Yellow
        Write-Host "  To check after the migration: DNS $(@($nics[0].Dns) -join ', '), suffix '$($nics[0].Suffix)', DNS reg. $($nics[0].Register)"
    }
    elseif ($reasons.Count -gt 0) {
        # ==========================================================
        # 2b. SPECIAL CASE: show and save the configuration, you set the IP by hand
        # ==========================================================
        Write-Host "  Special case - the IP is NOT set automatically:" -ForegroundColor Yellow
        $reasons | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }

        $lines = @(
            "IP configuration of $($net.Computer) before the migration to KVM",
            "Read at $(Get-Date -Format 'yyyy-MM-dd HH:mm') by Prepare-KvmMigration.ps1 (legacy) on $env:COMPUTERNAME",
            "Set it manually on the new VirtIO adapter(s) after the migration.",
            ''
        )
        foreach ($n in $nics) {
            $lines += "Adapter  : $($n.Alias) ($($n.Description)), ifIndex $($n.Index), MAC $($n.Mac), status $($n.Status), DHCP $($n.Dhcp)"
            $lines += "IP       : $(@($n.AllIPs) -join '; ')"
            $lines += "Gateway  : $(@($n.Gateway) -join ', ')"
            $lines += "DNS      : $(@($n.Dns) -join ', ')"
            $lines += "Suffix   : $($n.Suffix)"
            $lines += "DNS reg. : $($n.Register)"
            $lines += ''
        }
        $lines += 'Static routes (persistent):'
        if (@($net.Routes).Count -eq 0) {
            $lines += '  none'
        }
        foreach ($r in @($net.Routes)) {
            $lines += "  $r"
        }
        $info = $lines -join "`r`n"

        Write-Host ''
        Write-Host $info

        # Saved on the admin PC only: after the migration the server has no network until the IP is set
        $localInfo = Join-Path $LocalCopyPath "$($net.Computer)_IP-Configuration.txt"
        Set-Content -Path $localInfo -Value $info -Encoding UTF8
        Write-Host "  Saved on the admin PC: $localInfo"

        Warn 'Network special case: set the IP manually on the console of the target hypervisor after the migration.'
    }
    else {
        # ==========================================================
        # 2c. STANDARD CASE: restore script + scheduled task
        # ==========================================================
        $cfg = $nics[0]

        Write-Host "  Adapter  : $($cfg.Alias) ($($cfg.Description)), MAC $($cfg.Mac)"
        Write-Host "  IP       : $(@($cfg.IPs) -join ', ')"
        Write-Host "  Gateway  : $(@($cfg.Gateway) -join ', ')"
        Write-Host "  DNS      : $(@($cfg.Dns) -join ', ')"
        Write-Host "  Suffix   : $($cfg.Suffix)"
        Write-Host "  DNS reg. : $($cfg.Register)"

        $restoreScript = New-RestoreScript $net $cfg

        # Save the copy on the admin PC first, so the values are safe even if the next step fails
        $localFile = Join-Path $LocalCopyPath "$($net.Computer)_Restore-NetConfig.ps1"
        Set-Content -Path $localFile -Value $restoreScript -Encoding UTF8
        Write-Host "  Copy on the admin PC:  $localFile"

        try {
            Invoke-Command -Session $session -ArgumentList $restoreScript, $TaskName -ScriptBlock {
                param($Text, $Task)
                $ErrorActionPreference = 'Stop'
                New-Item -ItemType Directory -Path 'C:\virtio-inject' -Force | Out-Null
                Set-Content -Path 'C:\virtio-inject\Restore-NetConfig.ps1' -Value $Text -Encoding UTF8

                # Task: at every start, as SYSTEM, no logon needed
                $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\virtio-inject\Restore-NetConfig.ps1 -AtStartup'
                $trigger   = New-ScheduledTaskTrigger -AtStartup
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
                Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger `
                    -Principal $principal -Settings $settings -Force | Out-Null
            }
            Write-Host "  Placed on the server:  C:\virtio-inject\Restore-NetConfig.ps1"
            Write-Host "  Scheduled task $TaskName created: sets the IP automatically on the first start on KVM."
            $taskOk = $true
        }
        catch {
            # Failed: remove the half-done parts on the server (the copy on the admin PC stays)
            $err = $_.Exception.Message
            Invoke-Command -Session $session -ArgumentList $TaskName -ScriptBlock {
                param($Task)
                Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
                Remove-Item 'C:\virtio-inject\Restore-NetConfig.ps1' -Force -ErrorAction SilentlyContinue
            }
            Warn "Restore not placed on the server: $err - set the IP manually after the migration (values: $localFile)."
        }

        if (@($net.Routes).Count -gt 0) {
            Warn "Persistent routes are lost when the adapter changes, create them again after the migration: $(@($net.Routes) -join '; ')"
        }
    }

    # ==========================================================
    # RESULT
    # ==========================================================

    Write-Host ''
    if ($warnings.Count -eq 0) {
        Write-Host "Done: VirtIO check ok, $ComputerName is ready for the migration (without re-IP)." -ForegroundColor Green
    } else {
        Write-Host "Done with $($warnings.Count) warning(s). VirtIO check ok, migration possible - read them first:" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
    if (-not $taskOk) {
        # Without the task nobody removes StartOverride after a reboot on VMware
        Write-Host 'No scheduled task: after every reboot on VMware run this script again before the migration.' -ForegroundColor Yellow
    }
}
finally {
    Remove-PSSession $session
}
