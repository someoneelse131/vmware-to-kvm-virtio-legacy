# LEGACY VARIANT - WORK IN PROGRESS, not tested yet.
# Same procedure as vmware-to-kvm-virtio, but for Windows Server 2012 R2 (Build 9600)
# and Windows Server 2008 R2 SP1 (Build 7601).
# - 2012 R2: drivers from virtio-win 0.1.215, the last version whose 2k12R2 drivers are
#   production-signed (Red Hat + Microsoft cross root). From 0.1.217 on they are only test-signed.
# - 2008 R2: drivers from virtio-win 0.1.302 (2k8R2, production-signed, SHA-1).
#   2008 R2 also needs CriticalDeviceDatabase entries, see section "2008 R2: CRITICAL DEVICE DATABASE".
#
# Notes:
# - netkvm (network driver) added; "all drivers" = @() instead of ""
# - Selected driver missing (folder or Windows version) -> error instead of silently skipped
# - X: (WinPE itself) is skipped when searching for Windows; multiple Windows volumes -> error
# - Only Server 2008 R2 and 2012 R2 (2016-2025: use vmware-to-kvm-virtio); no /ForceUnsigned
# - Build not readable -> error; old marker files are deleted at the start
# - Success: reboot (not shutdown), so Windows is running again (the migration needs the VM running).
#   The reboot passes the "Press any key to boot from CD" prompt without a key press and boots Windows.
# - Error: no reboot, VM stays in WinPE, the message stays visible on the console.
#   A successful Windows logon alone proves nothing -> check C:\virtio-inject\completed.txt (README, step 3).

$ErrorActionPreference = "SilentlyContinue"

# ==================================================
# USER CONFIGURATION
# ==================================================
$VIRTIO_ROOT = "X:\VirtIO"

# @() = ALL drivers
$DRIVERS_TO_INCLUDE = @("viostor", "vioscsi", "netkvm")

# ==================================================
# GLOBALS
# ==================================================
$RAMLOG    = "X:\virtio-ram.log"
$LOGFILE   = $RAMLOG
$WINDRV    = $null
$WINFOUND  = @()
$BUILD     = $null
$OSVER     = $null
$ERRORFLAG = $false

# ==================================================
# LOG FUNCTION
# ==================================================
function Log {
    param([string]$msg)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line
    Add-Content -Path $LOGFILE -Value $line
}

# Error: write marker, VM stays in WinPE (no reboot), console stays open
function Fail {
    param([string]$msg, [string]$markerDir)

    Log "ERROR: $msg"
    "FAILED" | Out-File (Join-Path $markerDir "failed.txt")
    Write-Host ""
    Write-Host "==== FAILED - VM stays in WinPE. Log: $LOGFILE ====" -ForegroundColor Red
    exit 1
}

# ==================================================
# START
# ==================================================
Write-Host "`n==== VirtIO Injection PS v1.0 (legacy, dev) ====`n"
"==== START ====" | Out-File $RAMLOG

# ==================================================
# INIT
# ==================================================
wpeinit | Out-Null

Log "Waiting for disks..."
Start-Sleep -Seconds 5

# ==================================================
# MOUNT OS-CANDIDATE VOLUMES
# ==================================================
Log "Scanning volumes and assigning drive letters..."

# Collect used letters
$usedLetters = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter })

# Static pool of allowed letters (C-Z, excluding X)
$allLetters = ([char[]](67..90) | Where-Object { $_ -ne 'X' })

$assignedVolumes = @()

Get-Partition | ForEach-Object {

    try {
        Log "[DEBUG] Processing Partition: $($_.DiskNumber):$($_.PartitionNumber)"

        $partition = $_
        $vol = Get-Volume -Partition $partition -ErrorAction SilentlyContinue

        if (-not $vol) {
            Log "[DEBUG] No volume object"
            return
        }

        Log "[DEBUG] Volume found: DriveLetter=$($vol.DriveLetter)"

        if ($vol.DriveLetter) {
            Log "[DEBUG] Skipping (already has drive letter)"
            return
        }

        if (-not $vol.Size) {
            Log "[DEBUG] Skipping (no size info)"
            return
        }

        if ($vol.Size -lt 10GB) {
            Log "[DEBUG] Skipping (too small: $($vol.Size))"
            return
        }

        # calculate free letters
        $free = $allLetters | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1

        if (-not $free) {
            Log "[DEBUG] No free drive letter available"
            return
        }

        Log "[DEBUG] Assigning letter $free"

        Set-Partition -DiskNumber $partition.DiskNumber `
                      -PartitionNumber $partition.PartitionNumber `
                      -NewDriveLetter $free -ErrorAction Stop

        # Update state
        $usedLetters += $free
        $assignedVolumes += $partition

        Log "Assigned drive letter $free to volume ($([int]($vol.Size / 1GB)) GB)"
    }
    catch {
        Log "[ERROR] Exception while processing partition: $($_.Exception.Message)"
    }
}

# ==================================================
# FIND WINDOWS
# ==================================================

Log "[DEBUG] Forcing storage rescan..."
Update-HostStorageCache
Start-Sleep -Seconds 2

Log "Searching for Windows installation..."

Log "[DEBUG] Listing all volumes with drive letters..."

Get-Volume | Where-Object DriveLetter | ForEach-Object {
    $sizeGB = if ($_.Size) { [int]($_.Size / 1GB) } else { "?" }
    $fs     = if ($_.FileSystem) { $_.FileSystem } else { "unknown" }
    $label  = if ($_.FileSystemLabel) { $_.FileSystemLabel } else { "" }

    Log ("Drive {0}: Size={1}GB FS={2} Label={3}" -f `
        $_.DriveLetter,
        $sizeGB,
        $fs,
        $label)
}

Get-Volume | Where-Object DriveLetter | ForEach-Object {

    # X: is the running WinPE itself, it also has Windows\System32\Config\SOFTWARE
    if ($_.DriveLetter -eq 'X') {
        Log "[DEBUG] Skipping X: (WinPE)"
        return
    }

    $drive = "$($_.DriveLetter):"
    Log "[DEBUG] Checking $drive"

    dir $drive | Out-Null 2>&1

    $windowsPath = Join-Path $drive "Windows"
    $system32    = Join-Path $windowsPath "System32"
    $software    = Join-Path $windowsPath "System32\Config\SOFTWARE"

    $hasWindows  = Test-Path $windowsPath
    $hasSystem32 = Test-Path $system32
    $hasSoftware = Test-Path $software

    Log "[DEBUG] $drive -> Windows=$hasWindows System32=$hasSystem32 SOFTWARE=$hasSoftware"

    if ($hasSystem32 -and $hasSoftware) {
        $WINFOUND += $drive
        Log "[DEBUG] Windows detected on $drive"
        return
    }
}

if ($WINFOUND.Count -eq 0) {
    Fail "Windows not found" "X:\"
}
# Multiple hits (e.g. old system disk attached as data disk) -> do not guess, abort
if ($WINFOUND.Count -gt 1) {
    Fail "Multiple Windows volumes found: $($WINFOUND -join ' ')" "X:\"
}
$WINDRV = $WINFOUND[0]

Log "Windows found on $WINDRV"

# ==================================================
# SWITCH TO PERSISTENT LOGGING
# ==================================================
$LOGDIR = "$WINDRV\virtio-inject"
New-Item -ItemType Directory -Path $LOGDIR -Force | Out-Null

$LOGFILE = "$LOGDIR\inject.log"
$DISMLOG = "$LOGDIR\dism.log"

# Remove markers of a previous run, otherwise completed.txt and failed.txt could both exist
Remove-Item "$LOGDIR\completed.txt", "$LOGDIR\failed.txt" -Force

if (Test-Path $RAMLOG) {
    Copy-Item $RAMLOG $LOGFILE -Force
}

Log "Switched logging to $LOGFILE"

# ==================================================
# DETECT BUILD
# ==================================================
Log "Detecting Windows build..."

reg load HKLM\OFFLINE_SOFTWARE "$WINDRV\Windows\System32\Config\SOFTWARE" | Out-Null

$reg = reg query "HKLM\OFFLINE_SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild
$BUILD = ($reg | Select-String "CurrentBuild").ToString().Split()[-1]

reg unload HKLM\OFFLINE_SOFTWARE | Out-Null

Log "Build detected: $BUILD"

# Without this check, ContainsKey($null) under SilentlyContinue would skip the whole if
if (-not $BUILD) {
    Fail "Windows build not readable (reg load failed?)" $LOGDIR
}

# ==================================================
# MAP BUILD
# ==================================================
# 2k12R2 must come from virtio-win 0.1.215 (newer versions are only test-signed ->
# boot driver is not loaded, VM does not boot). 2k8R2 comes from virtio-win 0.1.302.
# 2016-2025 are not mapped on purpose: they belong to vmware-to-kvm-virtio (current drivers).
$map = @{
    "7601" = "2k8R2"
    "9600" = "2k12R2"
}

if ($map.ContainsKey($BUILD)) {
    $OSVER = $map[$BUILD]
} else {
    Fail "Unsupported build $BUILD" $LOGDIR
}

Log "Using driver set: $OSVER"

# ==================================================
# CHECK SOURCE
# ==================================================
if (-not (Test-Path $VIRTIO_ROOT)) {
    Fail "VirtIO source missing ($VIRTIO_ROOT)" $LOGDIR
}

# ==================================================
# DRIVER FILTER INFO
# ==================================================
if ($DRIVERS_TO_INCLUDE.Count -eq 0) {
    Log "Driver selection: ALL"
} else {
    Log "Driver selection: $($DRIVERS_TO_INCLUDE -join ' ')"

    # Selected driver missing in VirtIO folder -> error (e.g. netkvm forgotten = no network later)
    foreach ($d in $DRIVERS_TO_INCLUDE) {
        if (-not (Test-Path (Join-Path $VIRTIO_ROOT $d))) {
            Log "ERROR: driver folder $d missing in $VIRTIO_ROOT"
            $ERRORFLAG = $true
        }
    }
}

# ==================================================
# DRIVER INSTALL LOOP
# ==================================================
Get-ChildItem $VIRTIO_ROOT -Directory | ForEach-Object {

    $product = $_.Name

    $install = $false

    if ($DRIVERS_TO_INCLUDE.Count -eq 0) {
        $install = $true
    } elseif ($DRIVERS_TO_INCLUDE -contains $product) {
        $install = $true
    }

    if (-not $install) {
        Log "Skipping $product (filtered)"
        return
    }

    $driverPath = Join-Path $_.FullName "$OSVER\amd64"

    if (-not (Test-Path $driverPath)) {
        if ($DRIVERS_TO_INCLUDE.Count -eq 0) {
            Log "Skipping $product (no matching path)"
        } else {
            # Selected driver has no folder for this Windows version -> error
            Log "ERROR: $product has no folder $OSVER\amd64"
            $ERRORFLAG = $true
        }
        return
    }

    Log "Installing $product from $driverPath"

    $dismArgs = "/image:$WINDRV\ /add-driver /driver:`"$driverPath`" /recurse /logpath:$DISMLOG"

    $proc = Start-Process dism -ArgumentList $dismArgs -Wait -PassThru

    if ($proc.ExitCode -ne 0) {
        Log "ERROR installing $product"
        $ERRORFLAG = $true
    } else {
        Log "SUCCESS installing $product"
    }
}

# ==================================================
# 2008 R2: CRITICAL DEVICE DATABASE
# ==================================================
# Windows 7 / 2008 R2 find their boot driver through the CriticalDeviceDatabase
# (Windows 8 and later no longer use it). Without an entry for the VirtIO disk,
# the VM gets a blue screen 0x7B on KVM. Whether DISM writes these entries offline
# is not documented, so we set them ourselves, the same way virt-v2v does
# (libguestfs-common, mlcustomize/inject_virtio_win.ml): one key per PCI ID
# (legacy + modern device) and the service values of the driver.
if ($BUILD -eq "7601" -and -not $ERRORFLAG) {

    Log "2008 R2: writing CriticalDeviceDatabase entries..."

    reg load HKLM\OFFLINE_SYSTEM "$WINDRV\Windows\System32\Config\SYSTEM" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: reg load of the SYSTEM hive failed"
        $ERRORFLAG = $true
    } else {

        # The active control set is in Select\Current (normally 1 -> ControlSet001)
        $sel = reg query "HKLM\OFFLINE_SYSTEM\Select" /v Current
        $cur = 0
        if ($sel) { $cur = [int](($sel | Select-String "Current").ToString().Trim().Split()[-1]) }

        if ($cur -lt 1) {
            Log "ERROR: active control set not readable (Select\Current)"
            $ERRORFLAG = $true
        } else {
            $cs = "HKLM\OFFLINE_SYSTEM\ControlSet{0:D3}" -f $cur
            Log "Using control set $cs"

            $scsiClass = "{4D36E97B-E325-11CE-BFC1-08002BE10318}"
            $cdd = [ordered]@{
                "VEN_1AF4&DEV_1001&REV_00" = "viostor"
                "VEN_1AF4&DEV_1042&REV_01" = "viostor"
                "VEN_1AF4&DEV_1004&REV_00" = "vioscsi"
                "VEN_1AF4&DEV_1048&REV_01" = "vioscsi"
            }

            # Each reg add returns exit code 0 on success
            $regs = @()
            foreach ($id in $cdd.Keys) {
                $key = "$cs\Control\CriticalDeviceDatabase\PCI#$id"
                $regs += ,@($key, "Service",   "REG_SZ", $cdd[$id])
                $regs += ,@($key, "ClassGUID", "REG_SZ", $scsiClass)
            }
            foreach ($svc in "viostor", "vioscsi") {
                $key = "$cs\Services\$svc"
                $regs += ,@($key, "Type",         "REG_DWORD",     "1")
                $regs += ,@($key, "Start",        "REG_DWORD",     "0")
                $regs += ,@($key, "ErrorControl", "REG_DWORD",     "1")
                $regs += ,@($key, "Group",        "REG_SZ",        "SCSI miniport")
                $regs += ,@($key, "ImagePath",    "REG_EXPAND_SZ", "system32\drivers\$svc.sys")
            }

            foreach ($r in $regs) {
                reg add $r[0] /v $r[1] /t $r[2] /d $r[3] /f | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Log "ERROR: reg add $($r[0]) $($r[1]) failed"
                    $ERRORFLAG = $true
                }
            }
            if (-not $ERRORFLAG) { Log "CriticalDeviceDatabase and service entries written" }
        }

        # Without a clean unload the changes may not be written to the hive file
        reg unload HKLM\OFFLINE_SYSTEM | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log "ERROR: reg unload of the SYSTEM hive failed"
            $ERRORFLAG = $true
        }
    }

    # ImagePath points to System32\drivers: DISM normally copies boot drivers there,
    # if not -> copy the .sys file from the driver folder (virt-v2v does the same)
    foreach ($svc in "viostor", "vioscsi") {
        $sys = "$WINDRV\Windows\System32\drivers\$svc.sys"
        if (-not (Test-Path $sys)) {
            Copy-Item (Join-Path $VIRTIO_ROOT "$svc\$OSVER\amd64\$svc.sys") $sys -Force
            if (Test-Path $sys) {
                Log "Copied $svc.sys to System32\drivers"
            } else {
                Log "ERROR: $svc.sys missing in System32\drivers"
                $ERRORFLAG = $true
            }
        }
    }
}

# ==================================================
# RESULT
# ==================================================
if ($ERRORFLAG) {
    Fail "Completed with ERRORS (see $LOGFILE and $DISMLOG)" $LOGDIR
}

Log "Completed successfully"
"SUCCESS" | Out-File "$LOGDIR\completed.txt"

# ==================================================
# END
# ==================================================
Log "Rebooting into Windows in 10 seconds (do NOT press a key at 'Press any key to boot from CD')..."
Start-Sleep -Seconds 10

wpeutil reboot
