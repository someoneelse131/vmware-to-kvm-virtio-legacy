# vmware-to-kvm-virtio-legacy

> [!WARNING]
> **WORK IN PROGRESS: development version, not tested yet.**
> Do not use it on production VMs. Use only a clone in an isolated network.
> Results and changes are tracked in the commit history. The status changes once tests are done.

Legacy variant of [vmware-to-kvm-virtio](https://github.com/someoneelse131/vmware-to-kvm-virtio) for older Windows Server versions. It moves Windows Server VMs from **VMware** to a **KVM-based hypervisor** (e.g. HPE VM Essentials, Proxmox VE) so that the VM boots on the target without the `0x7B INACCESSIBLE_BOOT_DEVICE` blue screen.

The procedure is the same: a custom **WinPE ISO** injects the VirtIO drivers (disk + network) **offline** into the Windows installation, while the VM is still **on VMware**. What is different: the driver sources, and on 2008 R2 additional CriticalDeviceDatabase entries.

## Status

| OS | Build | Driver source | Status |
|---|---|---|---|
| Windows Server 2012 R2 | 9600 | virtio-win **0.1.215**, folder `2k12R2` | in development; first test OK (2026-11-12: boots on HPE VM Essentials, disk + network drivers loaded) |
| Windows Server 2008 R2 SP1 | 7601 | virtio-win **0.1.302**, folder `2k8R2` | in development, test pending (with CriticalDeviceDatabase entries) |
| Windows Server 2012 (not R2) | 9200 | virtio-win 0.1.215, folder `2k12` | not planned |
| Windows Server 2016–2025 | | | use [vmware-to-kvm-virtio](https://github.com/someoneelse131/vmware-to-kvm-virtio) |

**Why 0.1.215?** It is the last virtio-win version whose 2012 R2 drivers are production-signed (Red Hat, Microsoft cross-signed, SHA-256). From 0.1.217 on, they are only signed with a test certificate, and Windows does not load them as boot drivers.

**Why 0.1.302 for 2008 R2?** Its `2k8R2` drivers (viostor/NetKVM 2019, vioscsi 2018) are production-signed (Red Hat, Microsoft cross-signed, SHA-1), so 2008 R2 loads them without the SHA-2 update. They are in the per-driver folders (`viostor\2k8R2\amd64`), not in the top-level `amd64\` tree.

**2008 R2 needs more than DISM.** Windows 7 / 2008 R2 find their boot driver through the `CriticalDeviceDatabase` (Windows 8 and later no longer use it). `driver_injection.ps1` therefore writes these entries for viostor and vioscsi itself, the same way virt-v2v does (`libguestfs-common`, `mlcustomize/inject_virtio_win.ml`).

**Optional add-ons, 2012 R2 only (not tested yet).** Lean versions of the add-ons of the main repo. Those do **not** work on 2012 R2: they require PowerShell 5.1 (2012 R2 has 4.0), and `virtio-win-gt-x64.msi` refuses to install before Windows 10.
- **`Prepare-KvmMigration.ps1`**, run before the migration: it checks the injection and removes `StartOverride`. It restores the static IP automatically on the first boot on KVM, and it places the files for the cleanup.
- **`Cleanup-AfterMigration.ps1`**, run after the migration: it installs the remaining VirtIO drivers (`pnputil`) and the QEMU Guest Agent, and removes VMware Tools.

Not done: SAN policy / bringing disks online, phantom devices. Both add-ons stop on any build other than 9600.
**2008 R2 (PowerShell 2.0, WinRM usually off): no add-ons.** Only the driver injection; check, network and cleanup are done manually.

---

## Contents

```
vmware-to-kvm-virtio-legacy\
├─ WinPEFactory\                       copy to C:\WinPEFactory-Legacy
│  ├─ Build-WinPE.ps1                  builds the ISO
│  ├─ startnet.cmd                     WinPE autostart
│  └─ FilesToCopy\
│     ├─ driver_injection.ps1          injects the drivers
│     └─ VirtIO\                       (only .gitkeep, drivers go here in step A3)
└─ AddOns\                             OPTIONAL, 2012 R2 only
   ├─ Prepare-KvmMigration.ps1         runs on the admin PC / jump host
   └─ PostMigrationFiles\
      └─ Cleanup-AfterMigration.ps1    runs on the server (+ MSI and drivers, see "Add-on: Cleanup")
```

Windows blocks scripts downloaded from the internet. Unblock them once after downloading:
```powershell
Get-ChildItem <download folder> -Recurse | Unblock-File
```

---

## Part A: Build the ISO (once)

On a Windows admin PC, in **Windows PowerShell 5.1 as Administrator**.

**A1. Install the Windows ADK:** first the ADK itself (the feature "Deployment Tools" is enough), then the **separate** "WinPE add-on". Pick the ADK version for Windows Server 2025 (10.1.26100.x). The current WinPE can service 2008 R2 and 2012 R2 images offline (Microsoft: "DISM Supported Platforms", x64 target images only).
Download: https://learn.microsoft.com/windows-hardware/get-started/adk-install
Check (both must be True). If you installed it to a non-default path, adjust `$ADKPath` in `Build-WinPE.ps1`:
```powershell
$adk = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
Test-Path "$adk\Windows Preinstallation Environment\copype.cmd"      # WinPE add-on
Test-Path "$adk\Deployment Tools\amd64\Oscdimg\oscdimg.exe"         # Deployment Tools
```

**A2. Copy the `WinPEFactory` folder to `C:\WinPEFactory-Legacy`.** Use a separate folder so that the drivers of the main repo are not mixed with these. The ISO is written to `C:\WinPE_Builds\Virtio-Drivers-Legacy.iso`.

**A3. Add the VirtIO drivers from two virtio-win versions:**
- 0.1.215 (for 2012 R2): https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.215-2/virtio-win-0.1.215.iso
- 0.1.302 (for 2008 R2): https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso

```powershell
$dst = "C:\WinPEFactory-Legacy\FilesToCopy\VirtIO"
$sources = [ordered]@{                                          # adjust paths
    "2k12R2" = "$env:USERPROFILE\Downloads\virtio-win-0.1.215.iso"
    "2k8R2"  = "$env:USERPROFILE\Downloads\virtio-win-0.1.302.iso"
}
foreach ($os in $sources.Keys) {
    $iso = $sources[$os]
    $img = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop   # stops if the path is wrong or the ISO is already mounted
    $letter = (Get-Volume -DiskImage $img).DriveLetter
    if (-not $letter) { Write-Host "ERROR: no drive letter for $iso" -ForegroundColor Red; Dismount-DiskImage -ImagePath $iso | Out-Null; continue }
    $src = "${letter}:"
    foreach ($drv in "viostor", "vioscsi", "NetKVM") {
        robocopy "$src\$drv\$os\amd64" "$dst\$drv\$os\amd64" /E /XF *.pdb /NFL /NDL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { Write-Host "ERROR at $drv\$os" -ForegroundColor Red }
    }
    Dismount-DiskImage -ImagePath $iso | Out-Null
}
Get-ChildItem $dst -Recurse -File -Exclude .gitkeep | Measure-Object Length -Sum |
    ForEach-Object { "{0} files, {1:N1} MB" -f $_.Count, ($_.Sum / 1MB) }
foreach ($os in $sources.Keys) {
    "viostor", "vioscsi", "NetKVM" | ForEach-Object {
        Test-Path "$dst\$_\$os\amd64\$_.inf" } }               # must be 6x True
```
Expected: 22 files (11 per OS: 3 each for viostor/vioscsi, 5 for NetKVM). Only Server 2008 R2 **SP1** (Build 7601) is supported; without SP1 (7600) WinPE stops with "Unsupported build".

**A4. Build the ISO:** `powershell -ExecutionPolicy Bypass -File C:\WinPEFactory-Legacy\Build-WinPE.ps1`

---

## Part B: Per VM (test procedure)

Same steps as in the main repo. Take a snapshot first. While this is in development, test only with a **clone**: keep its network adapter disconnected or in an isolated network, on VMware and on the target, so that the clone does not collide with the original server (same name, same IP).

| # | Where | What |
|---|---|---|
| 1 | VMware | Shut down the VM, attach the ISO, force entry into the EFI/BIOS setup for the next boot, boot from CD and **press a key at "Press any key to boot from CD"**. |
| 2 | VMware (console) | WinPE injects the drivers and **reboots**. **Do not press a key**, so Windows starts normally. On a red **FAILED** message, read it first, then reset the VM without pressing a key. Disconnect the ISO afterwards. |
| 3 | Server | Check the injection after the **last** reboot on VMware. On 2012 R2 also remove `StartOverride`: use **either** the add-on `Prepare-KvmMigration.ps1` **or** the commands below. On 2008 R2: the commands below. |
| 4 | Migration tool | Migrate the VM (e.g. Zerto). With the add-on, do **not** let the tool change the IP (no re-IP). |
| 5 | KVM | Check that the VM boots. Set the IP on the new VirtIO adapter manually, or let the add-on do it (2012 R2). Fix the VLAN if needed. Bring additional disks online if needed (not shared cluster disks). |
| 6 | KVM | Finalize the migration (e.g. commit in Zerto). Then, on 2012 R2, optionally run `Cleanup-AfterMigration.ps1`. On 2008 R2 the cleanup is manual. |

Step 3 on **2012 R2** without the add-on, on the server as administrator (works with PowerShell 4.0). Every reboot on VMware can set `StartOverride` again (seen on 2016+, still to be confirmed on 2012 R2), and without the add-on task nothing removes it. So run this again after **each** reboot on VMware, directly before the migration:
```powershell
Test-Path C:\virtio-inject\completed.txt                       # must be True
'viostor', 'vioscsi' | ForEach-Object {
    (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$_").Start }   # must be 0, 0
Get-WindowsDriver -Online | Where-Object OriginalFileName -like '*netkvm*' |
    Select-Object Driver, Version                              # must show at least one entry
'viostor', 'vioscsi' | ForEach-Object {
    Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$_\StartOverride" -Recurse -ErrorAction SilentlyContinue
    Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\$_\StartOverride" }   # must be False, False
```

Step 3 on **2008 R2**, in `cmd` as administrator (PowerShell 2.0 has no `Get-WindowsDriver`). Whether Windows 7 / 2008 R2 changes these values when it boots on VMware without VirtIO hardware is not known yet, so check them after the **last** reboot on VMware:
```bat
type C:\virtio-inject\completed.txt
reg query HKLM\SYSTEM\CurrentControlSet\Services\viostor /v Start
reg query HKLM\SYSTEM\CurrentControlSet\Services\vioscsi /v Start
reg query HKLM\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase /s /f VEN_1AF4 /k
dism /online /get-drivers | findstr /i netkvm
```
Expected: `SUCCESS`; `Start` = `0x0` twice; at least these 4 keys: `PCI#VEN_1AF4&DEV_1001&REV_00`, `..._1042&REV_01`, `..._1004&REV_00`, `..._1048&REV_01`; at least one line with `netkvm`. If something is missing: do **not** migrate.

Logs: `C:\virtio-inject\inject.log` and `dism.log`, same as in the main repo. If WinPE does not find Windows, the log exists only inside WinPE (`X:\virtio-ram.log`) and is lost on reboot. Read the console before you reset the VM. The add-ons also write `Restore-NetConfig.log` and `Cleanup-AfterMigration.log` to `C:\virtio-inject`.

---

## Add-on: Prepare-KvmMigration.ps1 (2012 R2)

Run it on the admin PC / jump host (Windows PowerShell 5.1) after step 2 and before the migration: `.\Prepare-KvmMigration.ps1 -ComputerName <SERVER>`.

- **VirtIO check:** `completed.txt`, `Start` = 0 for viostor/vioscsi, netkvm in the driver store; removes `StartOverride`. If the check fails, the script stops: do **not** migrate, repeat steps 1–2.
- **IP restore:** if there is exactly one adapter with a static IPv4, the script saves the IP and registers the scheduled task `VirtIO-Restore-NetConfig`. On the first boot on KVM the task sets the IP and then deletes itself. On every boot on VMware it removes `StartOverride` again. DHCP: nothing to save. Other cases: the values are shown and saved, set the IP manually. **Without a working task**, run Prepare again after the last reboot on VMware. A copy of the values is kept in `NetConfig\` next to the script.
- **Cleanup files:** copies everything in `PostMigrationFiles\` to `C:\virtio-inject` on the server (via WinRM, no file share needed). Put the MSI and the drivers there first (see below), otherwise there is only a warning.

Requirements: WinRM from the admin PC to the server works (`Test-WSMan <SERVER>`), and you have admin rights on the server. To use another account, add `-Credential (Get-Credential)`.

## Add-on: Cleanup-AfterMigration.ps1 (2012 R2)

It needs files from virtio-win **0.1.215** (the same ISO as in A3): the drivers Balloon, vioserial, viorng, fwcfg, pvpanic (only the `2k12R2\amd64` folders, every `.inf` below `Drivers\` is installed) and `guest-agent\qemu-ga-x86_64.msi` (from the same ISO as the drivers; newer versions are not tested on 2012 R2). Put them into `PostMigrationFiles\` once, in Windows PowerShell 5.1:
```powershell
$iso = "$env:USERPROFILE\Downloads\virtio-win-0.1.215.iso"            # adjust paths
$dst = "C:\vmware-to-kvm-virtio-legacy\AddOns\PostMigrationFiles"
$img = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop
$src = "$((Get-Volume -DiskImage $img).DriveLetter):"
foreach ($drv in "Balloon", "vioserial", "viorng", "fwcfg", "pvpanic") {
    robocopy "$src\$drv\2k12R2\amd64" "$dst\Drivers\$drv" /E /XF *.pdb /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) { Write-Host "ERROR at $drv" -ForegroundColor Red }
}
Copy-Item "$src\guest-agent\qemu-ga-x86_64.msi" $dst -Force
Dismount-DiskImage -ImagePath $iso | Out-Null
(Get-ChildItem "$dst\Drivers" -Recurse -File).Count                   # must be 22
(Get-ChildItem "$dst\Drivers" -Recurse -Filter *.inf).Count           # must be 5
Test-Path "$dst\qemu-ga-x86_64.msi"                                   # must be True
```
Without Prepare, copy the script, the MSI and `Drivers\` to `C:\virtio-inject` on the server manually.

Run it on the server (console of the target or RDP, as administrator) **after** the migration is final (step 6):
```
powershell -ExecutionPolicy Bypass -File C:\virtio-inject\Cleanup-AfterMigration.ps1
```
It stops if the VM still runs on VMware or is not 2012 R2. It installs the drivers and the QEMU Guest Agent, uninstalls VMware Tools and removes the leftover folder. It only reports the AC'97 sound card (disable it by hand). Windows may ask whether to trust Red Hat: tick "Always trust" and install. No automatic reboot. It can run again; if VMware Tools need a reboot, reboot and run it again.

---

## License

MIT, see [LICENSE](LICENSE). No warranty. Use at your own risk.
