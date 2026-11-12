#Requires -Version 4.0
#Requires -RunAsAdministrator
<#
==========================================================
 Cleanup-AfterMigration.ps1 (legacy, lite, optional add-on)
==========================================================
LEGACY VARIANT - WORK IN PROGRESS, not tested yet.
Cleans up a Windows Server 2012 R2 after the move from VMware to KVM.
Lean version of the add-on in vmware-to-kvm-virtio (works with PowerShell 4.0).

When:  after the migration is final (e.g. commit in the migration tool).
       Afterwards the VM no longer boots cleanly on VMware.
Where: on the server itself (console of the target hypervisor or RDP, as administrator).

Usage:
    powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Cleanup-AfterMigration.ps1
    Add -Force to skip the question "Continue? (Y/N)".

Needs these files in C:\virtio-inject (Prepare-KvmMigration.ps1 puts them there, or copy them by hand):
    Cleanup-AfterMigration.ps1, qemu-ga-x86_64.msi (virtio-win 0.1.215),
    Drivers\<driver>\ = all files of <driver>\2k12R2\amd64 (virtio-win 0.1.215, without *.pdb).
    Only these folders: every .inf below Drivers is installed.

What it does, step by step:
- 1. Stops if the VM is still running on VMware or is not 2012 R2.
- 2. Installs the other VirtIO drivers from C:\virtio-inject\Drivers (pnputil).
- 3. Installs the QEMU Guest Agent.
- 4. Reports the AC'97 sound card (disable it by hand, 2012 R2 has no cmdlet for it).
- 5. Uninstalls VMware Tools.
- 6. Removes the VMware Tools folder if it is left over.

Not done (on purpose): disks online / SAN policy, phantom devices, VMware driver packages.

Notes:
- Run it in a maintenance window. On cluster nodes, pause the node first.
- No automatic reboot.
- Windows may ask "Install driver from Red Hat?". Tick "Always trust" and click Install.
  If the script seems to hang, look for this window.
- You can run it again: finished steps are skipped (drivers are just added again).
  If VMware Tools need a reboot: reboot, then run it again to remove the leftovers.
- Log: C:\virtio-inject\Cleanup-AfterMigration.log
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'

# ==========================================================
# CONFIG
# ==========================================================

$dir      = 'C:\virtio-inject'
$drvDir   = Join-Path $dir 'Drivers'
$audioId  = 'PCI\VEN_8086&DEV_2415*'   # AC'97 sound card some KVM hypervisors add
$warnings = New-Object System.Collections.Generic.List[string]
$changed  = $false   # did we change something? Then we recommend a reboot at the end.

# ==========================================================
# FUNCTIONS
# ==========================================================

# Show a warning and remember it for the summary at the end
function Warn([string]$Text) {
    Write-Host "WARNING: $Text" -ForegroundColor Yellow
    $warnings.Add($Text)
}

function Step([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Get-Installed([string]$Name) {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1
}

function Invoke-Msi([string]$Arguments) {
    (Start-Process msiexec.exe -ArgumentList $Arguments -Wait -PassThru).ExitCode
}

# Run pnputil, hide its output, return the exit code.
# (Error output of pnputil must not stop the script.)
function Invoke-PnpUtil([string[]]$Arguments) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & pnputil.exe @Arguments 2>&1
        $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $eap
    }
}

# Present devices with a problem (Get-PnpDevice does not exist on 2012 R2, so WMI)
function Get-ProblemDevice {
    @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
}

# ==========================================================
# START
# ==========================================================

New-Item -ItemType Directory -Path $dir -Force | Out-Null
Start-Transcript -Path "$dir\Cleanup-AfterMigration.log" -Append | Out-Null

try {
    # ==========================================================
    # 1. SAFETY
    # ==========================================================

    # 64-bit PowerShell only (the 32-bit one sees a different registry)
    if (-not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit PowerShell (not SysWOW64).'
    }

    $cs    = Get-CimInstance Win32_ComputerSystem
    $build = [string](Get-CimInstance Win32_OperatingSystem).BuildNumber
    Write-Host "Server: $env:COMPUTERNAME   Manufacturer: $($cs.Manufacturer)   Model: $($cs.Model)   Build: $build"
    if ($cs.Manufacturer -like 'VMware*') {
        throw 'The VM is still running on VMware. Run this only after the migration is final.'
    }
    if ($build -ne '9600') {
        throw "Build ${build}: this script is only for Server 2012 R2 (9600). 2016-2025: use vmware-to-kvm-virtio. 2008 R2: manual steps."
    }

    if (-not $Force) {
        Write-Host 'Installs the VirtIO drivers + QEMU Guest Agent and removes VMware Tools.'
        Write-Host 'Run only after the migration is final: afterwards the VM no longer boots cleanly on VMware.'
        Write-Host 'The network can be interrupted briefly (maintenance window).'
        if ((Read-Host 'Continue? (Y/N)') -notmatch '^[Yy]') {
            Write-Host 'Cancelled, nothing changed.'
            return
        }
    }

    # ==========================================================
    # 2. VIRTIO DRIVERS
    # ==========================================================
    # WinPE only injected the disk and network drivers. The other devices
    # (Balloon, Serial, RNG, fwcfg, pvpanic) have no driver yet.
    # The MSI with all drivers refuses to install before Windows 10, so we use pnputil.
    # Old syntax: -i -a = add to the driver store and install on matching devices.
    # A driver without a matching device is only added to the store, that is fine.

    Step 'VirtIO drivers'

    $infs = @()
    if (Test-Path $drvDir) {
        $infs = @(Get-ChildItem $drvDir -Recurse -Filter *.inf)
    }
    if ($infs.Count -eq 0) {
        Warn "No .inf files in $drvDir - VirtIO drivers not installed."
    }

    # The exit codes of the old pnputil are not documented.
    # So we check in the driver store whether the driver is there.
    foreach ($inf in $infs) {
        $rc = Invoke-PnpUtil @('-i', '-a', $inf.FullName)
        $inStore = Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Directory `
            -Filter "$($inf.Name)_*" -ErrorAction SilentlyContinue
        if (@(0, 3010) -contains $rc) {
            Write-Host "$($inf.Name): installed (exit code $rc)"
            $changed = $true
        } elseif ($inStore) {
            Write-Host "$($inf.Name): in the driver store, no device installed (exit code $rc) - fine if the device is missing"
        } else {
            Warn "$($inf.Name): pnputil exit code $rc, not in the driver store. See C:\Windows\inf\setupapi.dev.log"
        }
    }

    # ==========================================================
    # 3. QEMU GUEST AGENT
    # ==========================================================
    # Needs the VirtIO Serial driver (step 2). qemu-ga from virtio-win 0.1.215,
    # the same ISO as the drivers. Newer versions are not tested on 2012 R2.

    Step 'QEMU Guest Agent'

    $gaMsi = Join-Path $dir 'qemu-ga-x86_64.msi'
    if (Get-Installed 'QEMU guest agent') {
        Write-Host 'QEMU guest agent: already installed.'
    }
    elseif (-not (Test-Path $gaMsi)) {
        Warn "$gaMsi missing - QEMU Guest Agent not installed."
    }
    else {
        # Install silently (3010 = ok, reboot needed)
        Write-Host 'Installing qemu-ga-x86_64.msi ...'
        $changed = $true
        $exit = Invoke-Msi "/i `"$gaMsi`" /qn /norestart /l*v `"$dir\qemu-ga-x86_64.msi.log`""
        if (@(0, 3010) -contains $exit) {
            Write-Host "  ok (exit code $exit)"
        } else {
            Warn "qemu-ga-x86_64.msi: exit code $exit, log $dir\qemu-ga-x86_64.msi.log"
        }
    }

    if (Get-Service QEMU-GA -ErrorAction SilentlyContinue) {
        Start-Service QEMU-GA -ErrorAction SilentlyContinue
        $ga = Get-Service QEMU-GA
        if ($ga.Status -eq 'Running') {
            Write-Host 'QEMU Guest Agent is running.'
        } else {
            Warn "QEMU Guest Agent is not running (status $($ga.Status)) - check again after the reboot."
        }
    }

    # ==========================================================
    # 4. SOUND CARD
    # ==========================================================
    # Some KVM hypervisors add an AC'97 sound card (PCI 8086:2415). Windows Server has no driver,
    # so it shows as an error in the Device Manager. 2012 R2 has no cmdlet to disable a device,
    # so we only report it (cosmetic only).

    Step 'Sound card'

    $audio = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -like $audioId })
    if ($audio.Count -eq 0) {
        Write-Host 'No AC97 sound card present.'
    }
    foreach ($a in $audio) {
        # Error code 22 = disabled
        if ([int]$a.ConfigManagerErrorCode -eq 22) {
            Write-Host "Already disabled: $($a.Name)"
        } else {
            Write-Host "AC97 sound card present: $($a.Name). Cosmetic only - disable it in the Device Manager if you like."
        }
    }

    # ==========================================================
    # 5. UNINSTALL VMWARE TOOLS
    # ==========================================================
    # Normally VMware Tools refuse to uninstall on non-VMware hardware
    # (the check "VM_CheckRequirements" in the MSI stops it).
    # Workaround from the community (not from VMware):
    # remove this check from the cached MSI, then uninstall normally.

    Step 'Uninstall VMware Tools'

    $toolsExit = $null
    $tools = Get-Installed 'VMware Tools'

    if (-not $tools) {
        Write-Host 'VMware Tools not installed (anymore).'
    }
    else {
        $code = $tools.PSChildName
        Write-Host "Found: VMware Tools $($tools.DisplayVersion) $code"

        # Find the cached MSI that Windows uses for the uninstall
        $cache = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' |
            ForEach-Object { Get-ItemProperty (Join-Path $_.PSPath 'InstallProperties') -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -eq 'VMware Tools' } | Select-Object -First 1
        $msi = [string]$cache.LocalPackage

        if (-not $msi -or -not (Test-Path $msi)) {
            Warn 'Cached VMware Tools MSI not found - not uninstalled, check manually.'
        }
        else {
            $patched = $false
            try {
                # Backup first
                $backup = "$dir\VMwareTools-original.msi"
                if (-not (Test-Path $backup)) {
                    Copy-Item $msi $backup
                }
                Write-Host "MSI: $msi (backup: $backup)"
                Set-ItemProperty $msi -Name IsReadOnly -Value $false

                # Open the MSI database and delete the check
                $installer = New-Object -ComObject WindowsInstaller.Installer
                $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($msi, [int]1))
                foreach ($table in 'CustomAction', 'InstallExecuteSequence') {
                    $sql = "DELETE FROM $table WHERE Action='VM_CheckRequirements' OR Action='VM_LogStart'"
                    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($sql))
                    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
                }

                [void]$db.GetType().InvokeMember('Commit', 'InvokeMethod', $null, $db, $null)
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
                $patched = $true
            }
            catch {
                Warn "MSI could not be modified: $($_.Exception.Message) - not uninstalled."
            }

            # Uninstall. Success = VMware Tools are no longer listed as installed.
            if ($patched) {
                Write-Host 'Uninstalling (can take a few minutes) ...'
                $changed = $true
                $toolsExit = Invoke-Msi "/x $code /qn /norestart /l*v `"$dir\VMwareTools-uninstall.log`""
                if (Get-Installed 'VMware Tools') {
                    Warn "VMware Tools still installed (exit code $toolsExit), log $dir\VMwareTools-uninstall.log - leftovers NOT removed."
                }
                elseif ($toolsExit -eq 3010) {
                    Warn 'VMware Tools uninstalled, reboot required. Then run this script again (it removes the leftovers).'
                }
                else {
                    Write-Host "  ok (exit code $toolsExit)"
                }
            }
        }
    }

    # ==========================================================
    # 6. VMWARE LEFTOVERS
    # ==========================================================
    # Only if VMware Tools are gone and no reboot is pending.
    # If the uninstall failed, we delete nothing by hand.

    Step 'VMware leftovers'

    if (Get-Installed 'VMware Tools') {
        Write-Host 'Skipped, because VMware Tools are still installed.'
    }
    elseif ($toolsExit -eq 3010) {
        Write-Host 'Skipped until after the reboot.'
    }
    else {
        foreach ($name in 'VMTools', 'VGAuthService', 'VM3DService', 'vmvss') {
            if (Get-Service $name -ErrorAction SilentlyContinue) {
                Warn "Service $name still exists - check manually."
            }
        }

        $folder = Join-Path $env:ProgramFiles 'VMware\VMware Tools'
        if (Test-Path $folder) {
            Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $folder) {
                Warn "$folder not deleted completely (files in use) - run the script again after a reboot."
            } else {
                Write-Host "$folder deleted."
            }
            $changed = $true
        }
        else {
            Write-Host 'No VMware Tools folder left.'
        }

        $parent = Split-Path $folder
        if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) {
            Remove-Item $parent -Force
        }
    }

    # ==========================================================
    # RESULT
    # ==========================================================

    Step 'Result'

    # Devices that still have a problem (except the sound card)
    $problems = @(Get-ProblemDevice | Where-Object { $_.DeviceID -notlike $audioId })
    if ($problems.Count -gt 0) {
        Write-Host 'Devices with a problem (check again after the reboot):'
        $problems | Format-Table ConfigManagerErrorCode, Name, DeviceID -AutoSize | Out-Host
    } else {
        Write-Host 'No devices with a problem (except the sound card, if present).'
    }

    if ($warnings.Count -eq 0) {
        Write-Host 'Done without warnings.' -ForegroundColor Green
    } else {
        Write-Host "Done with $($warnings.Count) warning(s):" -ForegroundColor Yellow
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }

    if ($changed -or $warnings.Count -gt 0) {
        Write-Host 'Please reboot the server. No automatic reboot.'
    } else {
        Write-Host 'Nothing changed - no reboot needed.'
    }
    Write-Host "Log: $dir\Cleanup-AfterMigration.log"
}
catch {
    Write-Host "ABORTED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    throw
}
finally {
    Stop-Transcript | Out-Null
}
