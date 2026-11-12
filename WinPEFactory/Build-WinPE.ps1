#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
==========================================================
 WinPE ISO Builder (Self-contained folder mode)
==========================================================
- Uses the folder this script is in as input source (e.g. C:\WinPEFactory-Legacy)
- Copies startnet.cmd into WinPE
- Copies ALL subfolders of FilesToCopy into WinPE X:\

Notes:
- Pre-check that driver_injection.ps1 and the VirtIO folder exist in FilesToCopy
- Aborts if copype/dism/oscdimg fail (otherwise the script would continue with a half-built image)
- Packages as a list with exit code check; lp.cab not needed (see below)
- Copy errors abort the build; icacls by SID (language independent); orphaned mounts are cleaned up
- "Press any key" is kept (bootfix.bin, efisys.bin): after success the reboot falls through to Windows without a key press

LEGACY VARIANT - WORK IN PROGRESS: same as vmware-to-kvm-virtio, except the ISO name
(Virtio-Drivers-Legacy.iso, so both ISOs can exist side by side) and clearer ADK error messages.
#>

# ==========================================================
# CONFIG
# ==========================================================

#Source Dir
$ScriptRoot = $PSScriptRoot

#Output
$Name          = "Virtio-Drivers-Legacy"
$Arch          = "amd64"
$WorkspaceRoot = "C:\WinPE_Builds"

# Adjust if needed
$ADKPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"

# ==========================================================
# Root Directory
# ==========================================================

Write-Host "Using source folder:"
Write-Host $ScriptRoot
Write-Host ""

# Required files
$StartnetFile = Join-Path $ScriptRoot "startnet.cmd"
$SourcePath   = Join-Path $ScriptRoot "FilesToCopy"

if (-not (Test-Path $StartnetFile)) {
    throw "startnet.cmd not found in $ScriptRoot"
}
if (-not (Test-Path (Join-Path $SourcePath "driver_injection.ps1"))) {
    throw "driver_injection.ps1 not found in $SourcePath"
}
if (-not (Test-Path (Join-Path $SourcePath "VirtIO"))) {
    throw "VirtIO folder not found in $SourcePath"
}

# ==========================================================
# PATHS
# ==========================================================

$WorkDir  = Join-Path $WorkspaceRoot $Name
$MountDir = Join-Path $WorkDir "mount"
$MediaDir = Join-Path $WorkDir "media"
$BootWim  = Join-Path $MediaDir "sources\boot.wim"
$ISOPath  = Join-Path $WorkspaceRoot "$Name.iso"

$Oscdimg   = "$ADKPath\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
$copype    = "$ADKPath\Windows Preinstallation Environment\copype.cmd"
$envScript = Join-Path $ADKPath "Deployment Tools\DandISetEnv.bat"

# ==========================================================
# CLEAN BUILD DIR
# ==========================================================

if (Test-Path $WorkDir) {
    Write-Host "Cleaning previous build..."
    # In case an aborted run left boot.wim mounted (errors ignored if not)
    dism /unmount-wim /mountdir:$MountDir /discard 2>&1 | Out-Null
    # Clean up orphaned mounts (e.g. after a reboot, status "Needs Remount")
    dism /cleanup-mountpoints 2>&1 | Out-Null
    Remove-Item $WorkDir -Recurse -Force -ErrorAction Stop
}

# ==========================================================
# CREATE WINPE
# ==========================================================

# copype.cmd comes with the separate WinPE add-on, oscdimg.exe with the ADK feature "Deployment Tools"
if (!(Test-Path $copype)) {
    throw "copype.cmd not found: $copype - is the WinPE add-on installed (separate download)? Otherwise adjust `$ADKPath."
}
if (!(Test-Path $Oscdimg)) {
    throw "oscdimg.exe not found: $Oscdimg - is the ADK feature 'Deployment Tools' installed? Otherwise adjust `$ADKPath."
}

$cmd = "`"$envScript`" && `"$copype`" $Arch `"$WorkDir`""
cmd.exe /c $cmd
if ($LASTEXITCODE -ne 0) { throw "copype failed (exit code $LASTEXITCODE)" }

# ==========================================================
# MOUNT IMAGE
# ==========================================================

Write-Host "Mounting boot.wim..."
dism /mount-wim /wimfile:$BootWim /index:1 /mountdir:$MountDir
if ($LASTEXITCODE -ne 0) { throw "Mounting boot.wim failed (exit code $LASTEXITCODE)" }

# ==========================================================
# ADD POWERSHELL SUPPORT TO WINPE
# ==========================================================

Write-Host "Adding PowerShell support..."

$WinPEOCs = "$ADKPath\Windows Preinstallation Environment\$Arch\WinPE_OCs"

# Order and packages as in the Microsoft guide "WinPE: Adding PowerShell support"
# (per package the neutral .cab and the matching en-us language file).
# lp.cab is not needed: the base image created by copype is already en-us.
$Packages = @(
    "WinPE-WMI.cab",        "en-us\WinPE-WMI_en-us.cab",
    "WinPE-NetFx.cab",      "en-us\WinPE-NetFx_en-us.cab",
    "WinPE-Scripting.cab",  "en-us\WinPE-Scripting_en-us.cab",
    "WinPE-PowerShell.cab", "en-us\WinPE-PowerShell_en-us.cab",
    "WinPE-StorageWMI.cab", "en-us\WinPE-StorageWMI_en-us.cab"
)

foreach ($pkg in $Packages) {
    dism /image:$MountDir /add-package /packagepath:"$WinPEOCs\$pkg"
    if ($LASTEXITCODE -ne 0) { throw "Adding $pkg failed (exit code $LASTEXITCODE)" }
}

# ==========================================================
# COPY FILES
# ==========================================================

Write-Host "Copying files and folders to WinPE root..."

$Items = Get-ChildItem $SourcePath -Recurse -Force

foreach ($item in $Items) {

    # Build relative path
    $relativePath = $item.FullName.Substring($SourcePath.Length).TrimStart('\')
    $destination  = Join-Path $MountDir $relativePath

    if ($item.PSIsContainer) {
        # Create directory if it doesn't exist
        if (-not (Test-Path $destination)) {
            Write-Host "  [DIR]  -> $relativePath"
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
        }
    }
    else {
        # Ensure directory exists before copying file
        $destDir = Split-Path $destination -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        Write-Host "  [FILE] -> $relativePath"
        Copy-Item $item.FullName $destination -Force -ErrorAction Stop
    }
}

# ==========================================================
# COPY STARTNET
# ==========================================================

$TargetStartnet = "$MountDir\Windows\System32\startnet.cmd"

Write-Host "Injecting startnet.cmd..."

takeown /f $TargetStartnet | Out-Null
# SID instead of group name: "Administrators" has a different name on non-English Windows
icacls $TargetStartnet /grant "*S-1-5-32-544:F" | Out-Null

# If this fails, the ISO would contain the default startnet.cmd and WinPE would do nothing
Copy-Item $StartnetFile $TargetStartnet -Force -ErrorAction Stop

# ==========================================================
# UNMOUNT
# ==========================================================

Write-Host "Committing image..."
dism /unmount-wim /mountdir:$MountDir /commit
if ($LASTEXITCODE -ne 0) { throw "Unmount/commit failed (exit code $LASTEXITCODE). Cleanup: dism /unmount-wim /mountdir:$MountDir /discard" }

# ==========================================================
# "PRESS ANY KEY" STAYS ACTIVE (BIOS + UEFI)
# ==========================================================
# After a successful injection WinPE reboots. Without a key press the reboot
# falls through from the CD to the hard disk -> Windows starts, no boot loop.
# That is why \boot\bootfix.bin (BIOS) is kept and UEFI uses efisys.bin instead of efisys_noprompt.bin.

# ==========================================================
# DETERMINE BOOT FILE LOCATIONS
# ==========================================================

$BootEtfs = "$WorkDir\bootbins\etfsboot.com"
$BootEfi  = "$WorkDir\bootbins\efisys.bin"

if (!(Test-Path $BootEtfs)) {
    Write-Host "bootbins not found, using media paths..."

    $BootEtfs = "$MediaDir\boot\etfsboot.com"
    $BootEfi  = "$MediaDir\efi\microsoft\boot\efisys.bin"
}

# Validate
if (!(Test-Path $BootEtfs)) {
    throw "Missing BIOS boot file: $BootEtfs"
}
if (!(Test-Path $BootEfi)) {
    throw "Missing UEFI boot file: $BootEfi"
}

# ==========================================================
# BUILD ISO
# ==========================================================

Write-Host "Building ISO..."

& $Oscdimg `
    -m `
    -o `
    -u2 `
    -udfver102 `
    "-bootdata:2#p0,e,b$BootEtfs#pEF,e,b$BootEfi" `
    $MediaDir `
    $ISOPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit code $LASTEXITCODE)" }

# ==========================================================
# DONE
# ==========================================================

Write-Host ""
Write-Host "ISO created:"
Write-Host $ISOPath
