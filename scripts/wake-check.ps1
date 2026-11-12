# Why does the remote not wake the PC from Sleep? Run on the TV PC in an administrator PowerShell:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\wake-check.ps1           # report only
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\wake-check.ps1 -Apply    # also fix what it can
#
# Writes wake-report.txt next to this folder (C:\TVLauncher\wake-report.txt), to bring back if it still fails.
#
# What can stop a USB remote waking the PC:
#   1. Windows does not let the remote's devices wake it ("Allow this device to wake the computer").
#   2. Windows powers down the USB hub the receiver hangs off while sleeping ("Allow the computer to turn off this
#      device to save power"), or the hub itself may not wake the PC.
#   3. The sleep state is not real Sleep (S3), where USB wake works.
#   4. The BIOS cuts USB power in sleep (on ThinkCentres: Power > "Enhanced Power Saving Mode" and similar).
#   5. The receiver itself cannot wake a PC (many cheap air-mouse receivers cannot): then a USB keyboard would wake
#      the PC but the remote never will.
# -Apply fixes 1 and 2 for every keyboard, mouse, HID and USB hub/controller device. 3-5 are reported.
param([switch]$Apply)

. (Join-Path $PSScriptRoot 'setup-lib.ps1')
$Script:ApplyChanges = [bool]$Apply
$report = New-Object Collections.Generic.List[string]
function Note([string]$t) { $report.Add($t); Write-Host $t }

if (-not (Test-Admin)) { Write-Warn 'Run this in an administrator PowerShell (right-click Windows PowerShell > Run as administrator).'; exit 1 }

Note "== Wake check $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME =="
$bios = Get-CimInstance Win32_BIOS
$cs = Get-CimInstance Win32_ComputerSystem
Note "PC: $($cs.Manufacturer) $($cs.Model), BIOS $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"

# ---- 3. sleep states ----
Note ''
Note '-- Sleep states (powercfg /a) --'
$states = & powercfg.exe /a
$states | ForEach-Object { Note "   $_" }
$avail = ($states -join "`n") -split 'not available' | Select-Object -First 1
if ($avail -notmatch 'Standby \(S3\)') { Note '[check] Sleep (S3) is not available: USB wake from Sleep may not work. See the lines above for why (often a graphics driver).' }

# ---- the remote's devices ----
# Keyboards, mice and HID devices, with the USB device they sit on (the receiver) and its hub.
$wanted = 'Keyboard', 'Mouse', 'HIDClass', 'USB'
$devs = Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in $wanted -and $_.InstanceId -match '^(HID|USB)\\' }
Note ''
Note '-- Keyboards and pointing devices and the USB device each sits on --'
foreach ($d in $devs | Where-Object { $_.Class -in 'Keyboard', 'Mouse' }) {
    $chain = @()
    $id = $d.InstanceId
    for ($i = 0; $i -lt 4 -and $id; $i++) {
        $p = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data
        if (-not $p) { break }
        $pd = Get-PnpDevice -InstanceId $p -ErrorAction SilentlyContinue
        $chain += "$($pd.FriendlyName)"
        $id = $p
    }
    Note "   $($d.Class): $($d.FriendlyName)  <-  $($chain -join '  <-  ')"
}

# ---- 1 and 2: Windows' wake and power-off switches (the device Properties > Power Management tab) ----
$wake = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction SilentlyContinue)
$off  = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)
function Find-Switch($list, $instanceId) { $list | Where-Object { $_.InstanceName -like "$instanceId*" } | Select-Object -First 1 }
Note ''
Note '-- "Allow this device to wake the computer" / "Allow the computer to turn off this device" --'
foreach ($d in $devs) {
    $w = Find-Switch $wake $d.InstanceId
    $o = Find-Switch $off $d.InstanceId
    if (-not $w -and -not $o) { continue }
    $name = "$($d.Class): $($d.FriendlyName)"
    if ($w) {
        if ($w.Enable) { Write-Ok "may wake the PC: $name" ; $report.Add("   [ok] may wake: $name") }
        else {
            $report.Add("   [fix] may not wake: $name")
            Invoke-Change "let '$name' wake the PC" { Set-CimInstance -InputObject $w -Property @{ Enable = $true } }.GetNewClosure()
        }
    }
    # USB hubs and controllers: keep them powered while sleeping, so the receiver behind them can wake the PC.
    if ($o -and $d.Class -eq 'USB' -and $o.Enable) {
        $report.Add("   [fix] may be powered down: $name")
        Invoke-Change "keep '$name' powered (no power saving)" { Set-CimInstance -InputObject $o -Property @{ Enable = $false } }.GetNewClosure()
    }
}
if (-not $wake) { Note '[check] Windows lists no device that could wake the PC.' }

# ---- what Windows thinks may wake it now ----
Note ''
Note '-- Devices that may wake the PC now (powercfg /devicequery wake_armed) --'
& powercfg.exe /devicequery wake_armed | ForEach-Object { Note "   $_" }

# ---- the last wakes ----
Note ''
Note '-- Last wake (powercfg /lastwake) --'
& powercfg.exe /lastwake | ForEach-Object { Note "   $_" }
Note ''
Note '-- Recent sleep and wake events --'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter', 'Microsoft-Windows-Kernel-Power'; Id = 1, 42, 107 } -MaxEvents 8 -ErrorAction SilentlyContinue |
    ForEach-Object { Note "   $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm'))  $($_.Id)  $((($_.Message -split "`n") | Where-Object { $_ -match 'Wake Source|Sleep Time|Wake Time|reason|entering' } | Select-Object -First 3) -join ' / ')" }

Note ''
Note '-- If the remote still does not wake the PC after -Apply and a restart --'
Note '   1. Try a USB keyboard in the same port: if a key wakes the PC, the remote''s receiver cannot (a limit of the remote).'
Note '   2. If the keyboard cannot either: BIOS (F1 at start) > Power: turn "Enhanced Power Saving Mode" off and any'
Note '      USB / keyboard wake option on; then try again.'
Note '   3. Try the receiver in another USB port (a USB 2.0 port often wakes when a USB 3.0 one does not).'

$out = Join-Path (Split-Path $PSScriptRoot -Parent) 'wake-report.txt'
$report | Set-Content -Path $out -Encoding UTF8
Write-Host ''
Write-Host "Report written to $out" -ForegroundColor Cyan
if (-not $Apply) { Write-Host 'Nothing was changed. Run again with -Apply to fix what is listed as [would], then restart the PC.' -ForegroundColor Cyan }
