# vmware-to-kvm-virtio-legacy

> [!WARNING]
> **WORK IN PROGRESS: development version, not tested yet.**
> Do not use it on production VMs. Use only a clone in an isolated network.
> Results and changes are tracked in the commit history. The status changes once tests are done.

Legacy variant of [vmware-to-kvm-virtio](https://github.com/someoneelse131/vmware-to-kvm-virtio) for older Windows Server versions. It moves Windows Server VMs from **VMware** to a **KVM-based hypervisor** (e.g. HPE VM Essentials, Proxmox VE) so that the VM boots on the target without the `0x7B INACCESSIBLE_BOOT_DEVICE` blue screen.

The procedure is the same: a custom **WinPE ISO** injects the VirtIO drivers (disk + network) **offline** into the Windows installation, while the VM is still **on VMware**. Only the driver source is different.

## Status

| OS | Build | Driver source | Status |
|---|---|---|---|
| Windows Server 2012 R2 | 9600 | virtio-win **0.1.215**, folder `2k12R2` | in development, test pending |
| Windows Server 2008 R2 SP1 | 7601 | virtio-win 0.1.302, folder `2k8R2` | planned, not implemented |
| Windows Server 2012 (not R2) | 9200 | virtio-win 0.1.215, folder `2k12` | not planned |
| Windows Server 2016–2025 | | | use [vmware-to-kvm-virtio](https://github.com/someoneelse131/vmware-to-kvm-virtio) |

**Why 0.1.215?** It is the last virtio-win version whose 2012 R2 drivers are production-signed (Red Hat, Microsoft cross-signed, SHA-256). From 0.1.217 on, they are only signed with a test certificate, and Windows does not load them as boot drivers.

**Add-ons are not available yet.** `Prepare-KvmMigration.ps1` and `Cleanup-AfterMigration.ps1` from the main repo do **not** work on 2012 R2: they require PowerShell 5.1 (2012 R2 has 4.0), and `virtio-win-gt-x64.msi` refuses to install before Windows 10.

---

## Contents

```
vmware-to-kvm-virtio-legacy\
└─ WinPEFactory\                       copy to C:\WinPEFactory-Legacy
   ├─ Build-WinPE.ps1                  builds the ISO
   ├─ startnet.cmd                     WinPE autostart
   └─ FilesToCopy\
      ├─ driver_injection.ps1          injects the drivers
      └─ VirtIO\                       (empty, drivers go here in step A3)
```

Windows blocks scripts downloaded from the internet. Unblock them once after downloading:
```powershell
Get-ChildItem <download folder> -Recurse | Unblock-File
```

---

## Part A: Build the ISO (once)

On a Windows admin PC, in **Windows PowerShell 5.1 as Administrator**.

**A1. Install the Windows ADK:** first the ADK itself (the feature "Deployment Tools" is enough), then the **separate** "WinPE add-on". Pick the ADK version for Windows Server 2025 (10.1.26100.x). The current WinPE can service 2012 R2 images offline (Microsoft: "DISM Supported Platforms").
Download: https://learn.microsoft.com/windows-hardware/get-started/adk-install
Check (both must be True). If you installed it to a non-default path, adjust `$ADKPath` in `Build-WinPE.ps1`:
```powershell
$adk = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
Test-Path "$adk\Windows Preinstallation Environment\copype.cmd"      # WinPE add-on
Test-Path "$adk\Deployment Tools\amd64\Oscdimg\oscdimg.exe"         # Deployment Tools
```

**A2. Copy the `WinPEFactory` folder to `C:\WinPEFactory-Legacy`.** Use a separate folder so that the drivers of the main repo are not mixed with these. The ISO is written to `C:\WinPE_Builds\Virtio-Drivers-Legacy.iso`.

**A3. Add the VirtIO drivers from virtio-win 0.1.215:**
https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.215-2/virtio-win-0.1.215.iso

```powershell
$iso = "$env:USERPROFILE\Downloads\virtio-win-0.1.215.iso"   # adjust path
$img = Mount-DiskImage -ImagePath $iso -PassThru
$src = "$((Get-Volume -DiskImage $img).DriveLetter):"
$dst = "C:\WinPEFactory-Legacy\FilesToCopy\VirtIO"
foreach ($drv in "viostor", "vioscsi", "NetKVM") {
    robocopy "$src\$drv\2k12R2\amd64" "$dst\$drv\2k12R2\amd64" /E /XF *.pdb /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -ge 8) { Write-Host "ERROR at $drv" -ForegroundColor Red }
}
Dismount-DiskImage -ImagePath $iso | Out-Null
Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum |
    ForEach-Object { "{0} files, {1:N1} MB" -f $_.Count, ($_.Sum / 1MB) }
"viostor", "vioscsi", "NetKVM" | ForEach-Object {
    Test-Path "$dst\$_\2k12R2\amd64\$_.inf" }                # must be True, True, True
```

**A4. Build the ISO:** `powershell -ExecutionPolicy Bypass -File C:\WinPEFactory-Legacy\Build-WinPE.ps1`

---

## Part B: Per VM (test procedure)

Same steps as in the main repo. Take a snapshot first. While this is in development, test only with a **clone**: keep its network adapter disconnected or in an isolated network, on VMware and on the target, so that the clone does not collide with the original server (same name, same IP).

| # | Where | What |
|---|---|---|
| 1 | VMware | Shut down the VM, attach the ISO, force entry into the EFI/BIOS setup for the next boot, boot from CD and **press a key at "Press any key to boot from CD"**. |
| 2 | VMware (console) | WinPE injects the drivers and **reboots**. **Do not press a key**, so Windows starts normally. On a red **FAILED** message, read it first, then reset the VM without pressing a key. Disconnect the ISO afterwards. |
| 3 | Server | Check the injection and remove `StartOverride` (commands below), after the **last** reboot on VMware. |
| 4 | Migration tool | Migrate the VM (e.g. Zerto). |
| 5 | KVM | Check that the VM boots, set the IP on the new VirtIO adapter manually, fix the VLAN if needed. Bring additional disks online if needed (not shared cluster disks). |

Step 3, on the server as administrator (works with PowerShell 4.0). Every reboot on VMware can set `StartOverride` again (seen on 2016+, still to be confirmed on 2012 R2), and there is no add-on task that removes it. So run this again after **each** reboot on VMware, directly before the migration:
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

Logs: `C:\virtio-inject\inject.log` and `dism.log`, same as in the main repo. If WinPE does not find Windows, the log exists only inside WinPE (`X:\virtio-ram.log`) and is lost on reboot. Read the console before you reset the VM.

---

## License

MIT, see [LICENSE](LICENSE). No warranty. Use at your own risk.
