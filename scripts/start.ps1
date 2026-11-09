# Starts everything and keeps it running:
#   helper  (helper\helper.ps1 -ManageLauncher: also starts the launcher window and restarts it if it closes)
#   hotkeys (hotkeys\tv.ahk, needs AutoHotkey v2)
# This script stays running as a supervisor and restarts either one if it exits.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start.ps1 [-Windowed] [-TestMode]
#
#   -Windowed  launcher in a normal 1280x720 window instead of kiosk (for trying it on a desktop PC).
#              Also turns on test mode.
#   -TestMode  Sleep, Restart, Shut Down, the sleep timer and screen-off only pretend (logged, and the page
#              says "Test Mode"). Use it to try the kiosk on a PC you do not want switched off.

param([switch]$Windowed, [switch]$TestMode)
if ($Windowed) { $TestMode = $true }
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'helper\common.ps1')

$mutex = New-Object Threading.Mutex($false, 'Local\TVLauncherStart')
if (-not $mutex.WaitOne(0)) { Write-Host 'Already running.'; exit 0 }

function Log([string]$m) { Write-TVLog 'start' $m; Write-Host $m }

function Find-AutoHotkey {
    foreach ($p in @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
                     "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey.exe",
                     "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
                     "$env:ProgramFiles\AutoHotkey\AutoHotkey64.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Start-Helper {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
           '-File', "`"$(Join-Path $TV.Root 'helper\helper.ps1')`"", '-ManageLauncher')
    if ($Windowed) { $a += '-Windowed' }
    if ($TestMode) { $a += '-TestMode' }
    Start-Process powershell.exe -ArgumentList ($a -join ' ') -WindowStyle Hidden -PassThru
}

function Wait-Helper {
    $info = Get-HelperInfo
    for ($i = 0; $i -lt 40; $i++) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$($info.port)/ping" -Headers @{ 'X-TV-Token' = $info.token } -TimeoutSec 1 | Out-Null
            return $true
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return $false
}

$ahkExe = Find-AutoHotkey
if (-not $ahkExe) { Log 'AutoHotkey v2 not found: Home/Back buttons will not work until it is installed.' }

Log "start $($TV.Version) windowed=$Windowed"
$null = Get-HelperInfo     # create the token now, before the helper and the launcher need it
$helper = Start-Helper
if (-not (Wait-Helper)) { Log 'helper did not answer within 10 s (continuing; it will be restarted if it exits)' }
$ahk = $null
if ($ahkExe) { $ahk = Start-Process $ahkExe -ArgumentList "`"$(Join-Path $TV.Root 'hotkeys\tv.ahk')`"" -PassThru }

while ($true) {
    Start-Sleep -Seconds 5
    if ($helper.HasExited) { Log "helper exited ($($helper.ExitCode)): restarting"; $helper = Start-Helper }
    if ($ahk -and $ahk.HasExited) { Log "hotkeys exited ($($ahk.ExitCode)): restarting"; $ahk = Start-Process $ahkExe -ArgumentList "`"$(Join-Path $TV.Root 'hotkeys\tv.ahk')`"" -PassThru }
}
