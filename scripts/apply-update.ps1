# Installs a downloaded version of the launcher over the installed one, then restarts the launcher.
# Started by the helper (Settings > Updates, or the "New update" pop-up), from the NEW version's own copy of this
# script, in a process of its own (the helper is restarted part-way through).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File apply-update.ps1 -Source <new version folder> -Target C:\TVLauncher [-NoRestart]
#
# Kept as they are: config\settings.json (your settings and desktop PIN), launcher\js\helper-token.js, the app icons
# taken from this PC, and anything else that is only on the TV. Writes a log to %LOCALAPPDATA%\TVLauncher\logs\update.log.
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target, [switch]$NoRestart)
$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'TVLauncher\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'update.log'
function Log([string]$m) { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" -Encoding UTF8 }

try {
    if (-not (Test-Path (Join-Path $Source 'VERSION'))) { throw "not a launcher folder: $Source" }
    if (Test-Path (Join-Path $Target '.git')) { throw "refusing to update a development folder ($Target has .git)" }
    $from = [string](Get-Content (Join-Path $Target 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1)
    $to = ([string](Get-Content (Join-Path $Source 'VERSION') | Select-Object -First 1)).Trim()
    Log "update $from -> $to from $Source"

    # Did this update change what setup does? Then setup should run once more (it needs an administrator).
    $setupChanged = $false
    foreach ($f in 'scripts\setup.ps1', 'scripts\setup-lib.ps1') {
        $a = Join-Path $Target $f; $b = Join-Path $Source $f
        if (-not (Test-Path $a) -or (Get-FileHash $a).Hash -ne (Get-FileHash $b).Hash) { $setupChanged = $true }
    }

    # Copy everything new or changed (the scripts and pages are read when they start, so copying over the running
    # ones is safe); the files that belong to this TV are left alone.
    $out = & robocopy.exe $Source $Target /E /R:2 /W:1 /NFL /NDL /NP /NJH `
        /XF settings.json helper-token.js wake-report.txt /XD .git
    if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy $LASTEXITCODE): $($out -join ' ')" }
    Log "copied (robocopy $LASTEXITCODE)"

    $data = Join-Path $env:LOCALAPPDATA 'TVLauncher'
    $state = @{ version = $to; from = $from; at = (Get-Date).ToString('o'); setupChanged = $setupChanged }
    Set-Content -Path (Join-Path $data 'last-update.json') -Value ($state | ConvertTo-Json -Compress) -Encoding UTF8

    if (-not $NoRestart) {
        # Restart on the new files: the TV windows, their companions, the hotkeys and the helper. start.ps1 (the shell)
        # notices that the helper and the hotkeys stopped and starts them again; the helper opens the home screen.
        $procs = Get-CimInstance Win32_Process | Where-Object {
            ($_.Name -eq 'msedge.exe' -and $_.CommandLine -like '*TVLauncher\profiles\*') -or
            ($_.Name -like 'AutoHotkey*' -and $_.CommandLine -like '*tv.ahk*') -or
            ($_.Name -eq 'powershell.exe' -and ($_.CommandLine -like '*helper.ps1*' -or $_.CommandLine -like '*tvnav-host.ps1*'))
        }
        foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Log "restarted ($(@($procs).Count) processes stopped; start.ps1 starts them again)"
    }
    Log "done: now $to$(if ($setupChanged) { ' (setup changed: run it once more)' })"
} catch {
    Log "FAILED: $($_.Exception.Message)"
    exit 1
} finally {
    # The downloaded copy is not needed any more.
    try { if ($Source -like "$env:TEMP*") { Remove-Item -Recurse -Force (Split-Path -Parent $Source) -ErrorAction SilentlyContinue } } catch { }
}
