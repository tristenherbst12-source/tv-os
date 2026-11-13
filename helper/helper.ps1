# TV Launcher helper: a small local web service the launcher page talks to.
# Listens on 127.0.0.1 only and rejects any request without the secret token.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File helper\helper.ps1 [-ManageLauncher] [-Windowed] [-TestMode]
#
#   -ManageLauncher  start the launcher window and restart it if it closes or crashes (used by start.ps1)
#   -Windowed        launcher in a normal window instead of full-screen kiosk (for testing on a desktop PC)
#   -TestMode        sleep, restart, shut down, the sleep timer and screen-off only log what they would do
#                    (start.ps1 -Windowed turns this on, so testing on a desktop PC never powers it off)
#
# Endpoints (all need header X-TV-Token):
#   GET  /ping                      helper is up
#   GET  /config/{apps|keymap|settings|wec-schedule}
#   POST /settings                  merge a JSON object into config/settings.json
#   GET  /cache/{name}, POST /cache/{name}   offline copy of downloaded data (the F1 calendar)
#   POST /launch/{appId}            open an app from config/apps.json; body {url} opens it at that page (same site only)
#   GET  /continue                  the latest video watched in each app (Continue Watching), newest first
#   POST /home                      tv.ahk asks what to do with the window in front (close / minimize)
#   GET  /keys?since=N, POST /keys  keys seen by tv.ahk, for the key-test page
#   GET  /status                    uptime, storage, version, network, bluetooth
#   GET  /volume, POST /volume      {level, muted}; POST takes level, delta and/or muted
#   GET  /audio-output, POST /audio-output   playback devices; POST {id} makes one the default
#   GET  /sleep-timer, POST /sleep-timer     POST {minutes (0 = off), action: sleep|shutdown}
#   GET  /now-playing               what Spotify is playing (written by tvnav-host.ps1), or nowPlaying = null
#   POST /screen-off               turn the display off now
#   POST /power/{standby|restart|shutdown}   (sleep = standby: screen off, muted, low power; a button ends it)
#   GET  /standby                   {standby, since}
#   POST /open-settings/{wifi|bluetooth|sound}   open that Windows Settings page
#   POST /restart-launcher
#   GET  /desktop, POST /desktop    escape hatch: start explorer.exe (PIN-checked when one is set)
#   POST /desktop-pin               {current, new}: set, change or (new empty) remove the PIN

param([switch]$ManageLauncher, [switch]$Windowed, [switch]$TestMode)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

# One helper at a time.
$mutex = New-Object Threading.Mutex($false, 'Local\TVLauncherHelper')
if (-not $mutex.WaitOne(0)) { Write-Host 'Helper already running.'; exit 0 }

function Log([string]$m) { Write-TVLog 'helper' $m; Write-Host $m }

# ---------- Windows APIs (Store app activation, window focus, audio, power): see Native.cs ----------
Add-Type -TypeDefinition (Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'Native.cs'))

# ---------- state ----------
$Helper   = Get-HelperInfo
$Prefix   = "http://127.0.0.1:$($Helper.port)/"
$Started  = Get-Date
$Packages = @{}      # package Name -> @{ Aumid; InstallLocation } (null when not installed)
$KeyLog   = New-Object Collections.ArrayList
$KeySeq   = 0
$LastLaunched = $null
$LauncherProc = $null
$AllowedOrigins = @('null', 'http://localhost:8080', 'http://127.0.0.1:8080')   # file:// pages, and the dev server
$SleepTimerFile = Join-Path $TV.Data 'sleep-timer.json'
$CacheDir = Join-Path $TV.Data 'cache'
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$SleepTimer = Read-JsonFile $SleepTimerFile       # {endsAt (ISO), action, minutes} or null; survives a helper restart
$SettingsPages = @{ wifi = 'ms-settings:network-wifi'; bluetooth = 'ms-settings:bluetooth'; sound = 'ms-settings:sound' }
$SettingsAumid = 'windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel'

# Opens a Windows Settings page in front of the TV window. Without the Windows desktop running, the ms-settings:
# link can fail; then Settings is started directly (its main page), and for Bluetooth Windows' own "Add a
# device" window is the last resort. Returns how it was opened, or $null.
function Open-SettingsPage([string]$Page) {
    $tried = @()
    try { Start-Process $SettingsPages[$Page] -ErrorAction Stop; $via = 'link' }
    catch { $tried += "link: $($_.Exception.Message)"; $via = $null }
    if (-not $via) {
        try { [void][TVHelper.Native]::Activate($SettingsAumid); $via = 'settings app' }
        catch { $tried += "app: $($_.Exception.Message)" }
    }
    if ($via) {
        # Bring the Settings window in front of the full-screen TV window.
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 200
            $w = Get-Process ApplicationFrameHost, SystemSettings -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'Settings|Einstellungen' } | Select-Object -First 1
            if ($w) { [void][TVHelper.Native]::ForceForeground($w.MainWindowHandle); Log "settings ($Page) opened via $via"; return $via }
        }
        $tried += "$via started, but no Settings window appeared"
    }
    if ($Page -eq 'bluetooth') {
        $wizard = Join-Path $env:windir 'System32\DevicePairingWizard.exe'
        if (Test-Path $wizard) {
            try { Start-Process $wizard -ErrorAction Stop; Log "settings (bluetooth): $($tried -join '; '); opened Add a device instead"; return 'add a device' }
            catch { $tried += "wizard: $($_.Exception.Message)" }
        }
    }
    Log "settings ($Page) could not be opened: $($tried -join '; ')"
    return $null
}

function Get-Apps { Read-JsonFile (Join-Path $TV.Config 'apps.json') }
function Get-Settings { Read-JsonFile (Join-Path $TV.Config 'settings.json') }

# ---------- Store apps ----------
function Resolve-Package {
    param([string]$Name)
    if ($Packages.ContainsKey($Name) -and $Packages[$Name]) { return $Packages[$Name] }
    $pkg = Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) { $Packages[$Name] = $null; return $null }
    $manifest = [xml](Get-Content -Raw -LiteralPath (Join-Path $pkg.InstallLocation 'AppxManifest.xml'))
    $appId = @($manifest.Package.Applications.Application)[0].Id
    $r = @{ Aumid = "$($pkg.PackageFamilyName)!$appId"; Family = $pkg.PackageFamilyName; InstallLocation = $pkg.InstallLocation.TrimEnd('\') + '\' }
    $Packages[$Name] = $r
    return $r
}

# ---------- launching ----------
function Wait-MainWindow {
    param([int]$ProcessId, [int]$Seconds = 10)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $p) { return [IntPtr]::Zero }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { return $p.MainWindowHandle }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Get-ProfileWindow {
    param([string]$ProfileName)
    Get-ProcessesForProfile $ProfileName | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
}

function Get-FreePort {
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    return $port
}

function Start-EdgeWindow {
    param($l, [string]$ProfileName, [switch]$App)
    # Already open (e.g. Spotify minimised with music playing): bring that window back instead of opening a
    # second one, which would start the site again.
    $running = Get-ProfileWindow $ProfileName
    if ($running) { [void][TVHelper.Native]::ForceForeground($running.MainWindowHandle); return 'resumed' }

    # Remote navigation is added by helper\tvnav-host.ps1 over a local debugging port (127.0.0.1 only), not as an
    # extension: Edge switches --load-extension extensions off from a profile's second start.
    $port = Get-FreePort
    $edgeArgs = @("--user-data-dir=`"$(Get-ProfileDir $ProfileName)`"", '--no-first-run', '--no-default-browser-check', '--disable-sync',
              '--autoplay-policy=no-user-gesture-required', '--disable-features=Translate',
              "--remote-debugging-port=$port", '--remote-debugging-address=127.0.0.1')
    if ($App) { $edgeArgs += @("--app=`"$($l.url)`"", '--start-fullscreen') }
    else      { $edgeArgs += @('--start-maximized', "`"$($l.url)`"") }
    if ($l.userAgent) { $edgeArgs += "--user-agent=`"$($l.userAgent)`"" }
    if ($l.scale) {
        # Zoom for the couch. Applies to this profile's own Edge process only, never to the user's everyday Edge.
        $edgeArgs += "--force-device-scale-factor=$([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', [double]$l.scale))"
    }
    $p = Start-Process -FilePath (Get-EdgePath) -ArgumentList ($edgeArgs -join ' ') -PassThru
    # Remote navigation (arrows / OK / Back) in every TV window; H.264 only where asked for (Haswell has no VP9).
    $hostArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'tvnav-host.ps1')`" -Port $port -Name $ProfileName"
    if ($l.forceH264) { $hostArgs += ' -H264' }
    if ($l.resume) { $hostArgs += ' -Resume' }
    Start-Process powershell.exe -ArgumentList $hostArgs -WindowStyle Hidden | Out-Null
    # If this profile was already running, Edge hands the request over and this process exits at once.
    $h = Wait-MainWindow $p.Id 10
    if ($h -ne [IntPtr]::Zero) { [void][TVHelper.Native]::ForceForeground($h) }
    else {
        $existing = Get-ProfileWindow $ProfileName
        if ($existing) { [void][TVHelper.Native]::ForceForeground($existing.MainWindowHandle) }
    }
    return 'started'
}

# Same site? (Continue Watching may only open pages of the app's own site.) Compares the last two parts of the
# host name, so www.netflix.com and netflix.com match, and so do dstv.stream and now.dstv.stream.
function Test-SameSite([string]$A, [string]$B) {
    try {
        $site = { param($u) (([Uri]$u).Host -split '\.' | Select-Object -Last 2) -join '.' }
        return ([Uri]$A).Scheme -eq 'https' -and (& $site $A) -eq (& $site $B)
    } catch { return $false }
}

# The latest video watched in each app (written by tvnav-host.ps1), newest first, for the home screen.
function Get-ContinueWatching {
    $dir = Join-Path $TV.Data 'continue'
    if (-not (Test-Path $dir)) { return @() }
    $apps = Get-Apps
    $items = foreach ($f in Get-ChildItem $dir -Filter *.json) {
        if (((Get-Date) - $f.LastWriteTime).TotalDays -gt 21) { continue }      # old: not "continue" any more
        try { $w = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
        $profileName = $f.BaseName
        $id = $apps.apps.PSObject.Properties | Where-Object { $_.Value.launch.profile -eq $profileName } | Select-Object -First 1 -ExpandProperty Name
        if (-not $id -or -not $w.url -or -not (Test-SameSite $w.url $apps.apps.$id.launch.url)) { continue }
        [pscustomobject]@{ app = $id; title = $w.title; sub = $w.sub; art = $w.art; url = $w.url; live = [bool]$w.live
                           position = $w.position; duration = $w.duration; at = $w.at }
    }
    return @($items | Sort-Object at -Descending)
}

function Invoke-Launch {
    param([string]$Id, [string]$Url = '')
    $apps = Get-Apps
    $a = $apps.apps.$Id
    if (-not $a) { return @{ status = 404; body = @{ error = 'unknown app'; app = $Id } } }
    $l = $a.launch
    # Continue Watching: open the app at that page instead of its start page (only pages of its own site).
    if ($Url -and $l.type -in 'edge-app', 'edge') {
        if (-not (Test-SameSite $Url $l.url)) { return @{ status = 400; body = @{ error = 'not this app''s site'; app = $Id } } }
        $l = $l.PSObject.Copy(); $l.url = $Url
        $l | Add-Member -NotePropertyName resume -NotePropertyValue $true -Force      # the video there counts as started by you
    }
    switch ($l.type) {
        'store' {
            $aumid = $l.aumid
            if (-not $aumid) { $pk = Resolve-Package $l.package; if ($pk) { $aumid = $pk.Aumid } }
            if ($aumid) {
                $procId = [TVHelper.Native]::Activate($aumid)
                Log "launch $Id store $aumid pid=$procId"
                return @{ status = 200; body = @{ ok = $true; app = $Id; pid = $procId } }
            }
            if ($l.exeFallback) {
                $exe = [Environment]::ExpandEnvironmentVariables($l.exeFallback)
                if (Test-Path $exe) {
                    $p = Start-Process -FilePath $exe -PassThru
                    $h = Wait-MainWindow $p.Id 8
                    if ($h -ne [IntPtr]::Zero) { [void][TVHelper.Native]::ForceForeground($h) }
                    Log "launch $Id exe $exe"
                    return @{ status = 200; body = @{ ok = $true; app = $Id; pid = $p.Id } }
                }
            }
            Log "launch $Id failed: $($l.package) not installed"
            return @{ status = 404; body = @{ error = 'not installed'; app = $Id } }
        }
        'edge-app' { $how = Start-EdgeWindow $l $l.profile -App; Log "launch $Id edge-app $($l.url) ($how)" }
        'edge'     { $how = Start-EdgeWindow $l $(if ($l.profile) { $l.profile } else { 'browser' }); Log "launch $Id edge $($l.url) ($how)" }
        default    { return @{ status = 400; body = @{ error = "launch type '$($l.type)' is handled by the launcher page"; app = $Id } } }
    }
    return @{ status = 200; body = @{ ok = $true; app = $Id } }
}

# ---------- Home: which app owns the window in front? ----------
# tv.ahk sends the foreground window's handle and process info; the answer says whether to close or minimise it.
function Find-AppForWindow {
    param($info)
    $apps = Get-Apps
    $exe = if ($info.coreExe) { [string]$info.coreExe } else { [string]$info.exe }
    $exeLower = $exe.ToLower()

    # 1. Store apps: the window's app ID starts with the package family name.
    if ($info.hwnd) {
        $aumid = [TVHelper.Native]::WindowAumid([IntPtr][long]$info.hwnd)
        if ($aumid -and $aumid.Contains('!')) {
            $family = $aumid.Split('!')[0].ToLower()
            foreach ($p in $apps.apps.PSObject.Properties) {
                $l = $p.Value.launch
                if ($l.type -ne 'store') { continue }
                $pk = Resolve-Package $l.package
                if ($pk -and $pk.Family.ToLower() -eq $family) { return $p.Name }
            }
        }
    }

    # 2. Our own Edge windows: the browser process's command line names its profile folder.
    if ($exeLower.EndsWith('\msedge.exe') -and $info.pid) {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$info.pid)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmd) {
            $cmd = $cmd.ToLower()
            if ($cmd.Contains((Get-ProfileDir 'launcher').ToLower())) { return 'launcher' }
            foreach ($p in $apps.apps.PSObject.Properties) {
                $l = $p.Value.launch
                if ($l.type -in 'edge', 'edge-app') {
                    $prof = if ($l.profile) { $l.profile } else { 'browser' }
                    if ($cmd.Contains((Get-ProfileDir $prof).ToLower())) { return $p.Name }
                }
            }
        }
        return $null
    }
    foreach ($p in $apps.apps.PSObject.Properties) {
        $l = $p.Value.launch
        if ($l.type -ne 'store') { continue }
        $pk = Resolve-Package $l.package
        if ($pk -and $exeLower.StartsWith($pk.InstallLocation.ToLower())) { return $p.Name }
        if ($l.exeFallback -and $exeLower -eq [Environment]::ExpandEnvironmentVariables($l.exeFallback).ToLower()) { return $p.Name }
    }
    # A Store app window whose content process we could not see: assume it is the one we opened last.
    if ($exeLower.EndsWith('\applicationframehost.exe') -and $LastLaunched) { return $LastLaunched }
    return $null
}

function Invoke-Home {
    param($info)
    $id = Find-AppForWindow $info
    if ($id -eq 'launcher') { return @{ app = 'launcher'; action = 'none' } }
    $action = 'minimize'
    if ($id) {
        $a = (Get-Apps).apps.$id
        if ($a.onHome) { $action = $a.onHome }
    }
    Log "home: window exe=$($info.exe) core=$($info.coreExe) -> app=$id action=$action"
    return @{ app = $id; action = $action }
}

# ---------- settings ----------
function Update-Settings {
    param($patch)
    $path = Join-Path $TV.Config 'settings.json'
    $s = Read-JsonFile $path
    if (-not $s) { $s = [pscustomobject]@{} }
    foreach ($p in $patch.PSObject.Properties) {
        if ($p.Name -in 'helperPort', 'version', 'desktopPin') { continue }   # not changeable this way
        if ($s.PSObject.Properties[$p.Name]) { $s.($p.Name) = $p.Value }
        else { $s | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    Write-TextAtomic $path ($s | ConvertTo-Json -Depth 10)
    return $s
}

# ---------- desktop PIN (stored salted and hashed, never in plain text) ----------
function Get-PinHash {
    param([string]$Pin, [string]$Salt)
    $sha = [Security.Cryptography.SHA256]::Create()
    return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Salt|$Pin")))
}

function Test-DesktopPin {
    param([string]$Pin)
    $stored = (Get-Settings).desktopPin
    if (-not $stored) { return $true }                      # no PIN set
    if ($stored -is [string]) { return $Pin -eq $stored }   # old plain format, replaced on next change
    return (Get-PinHash $Pin $stored.salt) -eq $stored.hash
}

function Set-DesktopPin {
    param([string]$Pin)
    $path = Join-Path $TV.Config 'settings.json'
    $s = Read-JsonFile $path
    $value = $null
    if ($Pin) {
        $bytes = New-Object byte[] 12
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $salt = [Convert]::ToBase64String($bytes)
        $value = [pscustomobject]@{ salt = $salt; hash = (Get-PinHash $Pin $salt) }
    }
    if ($s.PSObject.Properties['desktopPin']) { $s.desktopPin = $value } else { $s | Add-Member -NotePropertyName desktopPin -NotePropertyValue $value }
    Write-TextAtomic $path ($s | ConvertTo-Json -Depth 10)
}

# ---------- power ----------
# In test mode nothing is switched off: the action is logged and reported back to the page.
function Invoke-Power {
    param([ValidateSet('sleep', 'standby', 'restart', 'shutdown', 'screen-off')][string]$Action, [string]$Reason = 'request')
    # Sleep is a standby on the TV PC (the remote cannot wake it from real Sleep), and so is the idle screen-off.
    if ($Action -in 'sleep', 'standby', 'screen-off') { return Enter-Standby $Reason }
    if ($TestMode) { Log "TEST MODE: would $Action now ($Reason)"; return @{ ok = $true; testMode = $true; action = $Action } }
    Log "power: $Action ($Reason)"
    switch ($Action) {
        'screen-off' { [TVHelper.Native]::MonitorOff() }
        'sleep'      { [void][TVHelper.Native]::Sleep() }
        'restart'    { Start-Process shutdown.exe -ArgumentList '/r /t 0' -WindowStyle Hidden }
        'shutdown'   { Start-Process shutdown.exe -ArgumentList '/s /t 0' -WindowStyle Hidden }
    }
    return @{ ok = $true; action = $Action }
}

# ---------- sleep timer ----------
function Get-SleepTimerState {
    if (-not $SleepTimer) { return @{ active = $false; minutes = 0 } }
    $ends = [DateTime]::Parse($SleepTimer.endsAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $remaining = [int][math]::Max(0, ($ends - (Get-Date)).TotalSeconds)
    return @{ active = $true; minutes = $SleepTimer.minutes; action = $SleepTimer.action; endsAt = $SleepTimer.endsAt; remainingSec = $remaining }
}

function Set-SleepTimer {
    param([int]$Minutes, [string]$Action)
    if ($Minutes -le 0) {
        $script:SleepTimer = $null
        Remove-Item -LiteralPath $SleepTimerFile -ErrorAction SilentlyContinue
        Log 'sleep timer off'
    } else {
        if ($Action -notin 'sleep', 'shutdown') { $Action = 'sleep' }
        $script:SleepTimer = [pscustomobject]@{ minutes = $Minutes; action = $Action; endsAt = (Get-Date).AddMinutes($Minutes).ToString('o') }
        Write-TextAtomic $SleepTimerFile ($SleepTimer | ConvertTo-Json -Compress)
        Log "sleep timer: $Action in $Minutes min"
    }
    return Get-SleepTimerState
}

# ---------- standby ----------
# The TV PC cannot be woken from Sleep by the remote (tested: no USB device wakes it), so "Sleep" is a standby
# instead, as a TV does: the screen goes off, the sound is muted, Spotify pauses and the PC idles
# on its usual plan (not Balanced: that one would put it to real Sleep after 30 minutes). The first button
# press (or touchpad movement) brings everything back at once. While in standby the PC restarts once at 04:00,
# so it starts each day fresh, and goes back to standby after the restart.
$Standby = $null                                     # @{ since; tick; wasMuted } while in standby
$StandbyResumeFile = Join-Path $TV.Data 'standby-after-restart'
$NightlyRestartDone = (Get-Date).Date                # never on the day the helper starts
$StandbyAfterStart = $null
if (Test-Path $StandbyResumeFile) {                  # restarted from standby: back to standby once the launcher is up
    Remove-Item $StandbyResumeFile -ErrorAction SilentlyContinue
    $StandbyAfterStart = (Get-Date).AddSeconds(45)
}

function Enter-Standby([string]$Reason) {
    if ($TestMode) { Log "TEST MODE: would go to standby ($Reason)"; return @{ ok = $true; testMode = $true; action = 'standby' } }
    if ($script:Standby) { [TVHelper.Native]::MonitorOff(); return @{ ok = $true; action = 'standby' } }
    Log "standby on ($Reason)"
    # Spotify playing: pause it (the window keeps running).
    $np = Join-Path $TV.Data 'now-playing.json'
    try {
        if ((Test-Path $np) -and ((Get-Date) - (Get-Item $np).LastWriteTime).TotalSeconds -lt 30 -and ([IO.File]::ReadAllText($np) | ConvertFrom-Json).playing) {
            [TVHelper.Native]::MediaPlayPause()
        }
    } catch { }
    $muted = $false
    try { $muted = [TVHelper.Audio]::GetMute(); [TVHelper.Audio]::SetMute($true) } catch { }
    Start-Sleep -Milliseconds 400
    [TVHelper.Native]::MonitorOff()
    $script:Standby = @{ since = Get-Date; tick = [TVHelper.Native]::LastInputTick(); wasMuted = $muted }
    return @{ ok = $true; action = 'standby' }
}

function Exit-Standby([string]$Reason) {
    if (-not $script:Standby) { return }
    $s = $script:Standby
    $script:Standby = $null
    try { [TVHelper.Audio]::SetMute([bool]$s.wasMuted) } catch { }
    Log "standby off ($Reason, after $([int]((Get-Date) - $s.since).TotalMinutes) min)"
}

# Every second: a button press ends standby; 04:00 restarts once a day.
function Test-Standby {
    if ($StandbyAfterStart -and (Get-Date) -ge $StandbyAfterStart) {
        $script:StandbyAfterStart = $null
        if (-not $Standby) { [void](Enter-Standby 'after the nightly restart') }
    }
    if (-not $Standby) { return }
    $tick = [TVHelper.Native]::LastInputTick()
    if (((Get-Date) - $Standby.since).TotalSeconds -lt 2) { $Standby.tick = $tick; return }   # the press that started it
    if ($tick -ne $Standby.tick) { Exit-Standby 'button pressed'; return }
    $now = Get-Date
    if ($now.Hour -eq 4 -and $now.Minute -lt 10 -and $now.Date -ne $NightlyRestartDone -and ($now - $Standby.since).TotalMinutes -ge 30) {
        $script:NightlyRestartDone = $now.Date
        Log 'nightly restart (in standby since a while)'
        try { Set-Content -Path $StandbyResumeFile -Value (Get-Date -Format o) } catch { }
        [void](Invoke-Power 'restart' 'nightly restart in standby')
    }
}

function Test-SleepTimer {
    if (-not $SleepTimer) { return }
    $st = Get-SleepTimerState
    if ($st.remainingSec -gt 0) { return }
    $action = $SleepTimer.action
    [void](Set-SleepTimer 0 '')            # clear first, so waking up does not set it off again
    [void](Invoke-Power $action 'sleep timer')
}

# ---------- audio ----------
function Get-VolumeState { return @{ level = [TVHelper.Audio]::GetVolume(); muted = [TVHelper.Audio]::GetMute() } }

function Set-VolumeState {
    param($body)
    if ($null -ne $body.delta) { [TVHelper.Audio]::SetVolume([TVHelper.Audio]::GetVolume() + [int]$body.delta) }
    if ($null -ne $body.level) { [TVHelper.Audio]::SetVolume([int]$body.level) }
    if ($null -ne $body.muted) { [TVHelper.Audio]::SetMute([bool]$body.muted) }
    elseif ($null -ne $body.level -or $null -ne $body.delta) { [TVHelper.Audio]::SetMute($false) }   # changing volume unmutes, like a TV
    return Get-VolumeState
}

function Get-AudioOutputs {
    $list = @([TVHelper.Audio]::Devices() | ForEach-Object { @{ id = $_.Id; name = $_.Name; isDefault = $_.IsDefault } })
    return @{ devices = $list }
}

# ---------- status ----------
function Get-NetworkStatus {
    $wifi = $null
    try {
        $lines = & netsh.exe wlan show interfaces 2>$null
        if ($LASTEXITCODE -eq 0 -and $lines) {
            $f = @{}
            foreach ($line in $lines) { if ($line -match '^\s*([^:]+?)\s*:\s*(.*)$') { if (-not $f.ContainsKey($Matches[1])) { $f[$Matches[1]] = $Matches[2].Trim() } } }
            if ($f['State']) {
                $wifi = @{ state = $f['State']; ssid = $f['SSID']; signal = $f['Signal'] }
            }
        }
    } catch { }
    $wired = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }).Count -gt 0
    return @{ wifi = $wifi; ethernet = $wired }
}

function Get-Status {
    $os = Get-CimInstance Win32_OperatingSystem
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    return @{
        version   = $TV.Version
        testMode  = [bool]$TestMode
        uptimeSec = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
        helperUptimeSec = [int]((Get-Date) - $Started).TotalSeconds
        storage   = @{ drive = $env:SystemDrive; freeGB = [math]::Round($drive.FreeSpace / 1GB, 1); totalGB = [math]::Round($drive.Size / 1GB, 1) }
        network   = Get-NetworkStatus
        bluetooth = @{ available = [TVHelper.Native]::HasBluetoothRadio() }
    }
}

# ---------- HTTP plumbing ----------
function Send-Response {
    param($ctx, [int]$Status, $Body)
    $res = $ctx.Response
    $origin = $ctx.Request.Headers['Origin']
    if ($origin -and $AllowedOrigins -contains $origin) {
        $res.AddHeader('Access-Control-Allow-Origin', $origin)
        $res.AddHeader('Vary', 'Origin')
    }
    $res.StatusCode = $Status
    if ($null -ne $Body) {
        $text = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $res.ContentType = 'application/json; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    $res.Close()
}

function Read-Body {
    param($ctx, [long]$MaxBytes = 65536)
    if (-not $ctx.Request.HasEntityBody) { return $null }
    if ($ctx.Request.ContentLength64 -gt $MaxBytes) { throw 'body too large' }
    $r = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $text = $r.ReadToEnd(); $r.Close()
    if (-not $text.Trim()) { return $null }
    return ($text | ConvertFrom-Json)
}

function Handle-Request {
    param($ctx)
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    $method = $req.HttpMethod

    if ($method -eq 'OPTIONS') {
        # CORS preflight from the launcher page (file:// pages send Origin: null).
        $ctx.Response.AddHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $ctx.Response.AddHeader('Access-Control-Allow-Headers', 'X-TV-Token, Content-Type')
        $ctx.Response.AddHeader('Access-Control-Allow-Private-Network', 'true')
        $ctx.Response.AddHeader('Access-Control-Max-Age', '600')
        Send-Response $ctx 204 $null; return
    }
    if ($req.Headers['X-TV-Token'] -ne $Helper.token) { Send-Response $ctx 401 @{ error = 'bad token' }; return }

    switch -Regex ("$method $path") {
        '^GET /ping$' { Send-Response $ctx 200 @{ ok = $true; version = $TV.Version; testMode = [bool]$TestMode }; return }

        '^GET /config/(apps|keymap|settings|wec-schedule)$' {
            $file = Join-Path $TV.Config "$($Matches[1]).json"
            Send-Response $ctx 200 ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)); return
        }
        '^POST /settings$' { $s = Update-Settings (Read-Body $ctx); Send-Response $ctx 200 $s; return }

        # Offline copies of downloaded data (the F1 calendar), kept in %LOCALAPPDATA%\TVLauncher\cache.
        '^GET /cache/([\w-]+)$' {
            $file = Join-Path $CacheDir "$($Matches[1]).json"
            if (Test-Path $file) { Send-Response $ctx 200 ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)) }
            else { Send-Response $ctx 404 @{ error = 'not cached' } }
            return
        }
        '^POST /cache/([\w-]+)$' {
            $name = $Matches[1]
            $body = Read-Body $ctx 1048576
            if ($null -eq $body) { Send-Response $ctx 400 @{ error = 'empty' }; return }
            Write-TextAtomic (Join-Path $CacheDir "$name.json") ($body | ConvertTo-Json -Depth 10 -Compress)
            Send-Response $ctx 204 $null; return
        }

        '^GET /continue$' { Send-Response $ctx 200 @{ items = @(Get-ContinueWatching) }; return }
        '^POST /launch/([\w-]+)$' {
            $id = $Matches[1]
            $b = $null
            if ($ctx.Request.HasEntityBody) { try { $b = Read-Body $ctx } catch { } }
            $r = Invoke-Launch $id $(if ($b -and $b.url) { [string]$b.url } else { '' })
            if ($r.status -eq 200) { $script:LastLaunched = $id }
            Send-Response $ctx $r.status $r.body; return
        }
        '^POST /home$' { Send-Response $ctx 200 (Invoke-Home (Read-Body $ctx)); return }

        '^GET /keys$' {
            $since = 0; [void][int]::TryParse($req.QueryString['since'], [ref]$since)
            $events = @($KeyLog | Where-Object { $_.id -gt $since })
            Send-Response $ctx 200 @{ events = $events }; return
        }
        '^POST /keys$' {
            $k = Read-Body $ctx
            $script:KeySeq++
            [void]$KeyLog.Add(@{ id = $KeySeq; name = [string]$k.name; vk = $k.vk; sc = $k.sc; at = (Get-Date).ToString('o') })
            while ($KeyLog.Count -gt 100) { $KeyLog.RemoveAt(0) }
            Send-Response $ctx 204 $null; return
        }

        '^GET /status$' { Send-Response $ctx 200 (Get-Status); return }

        '^POST /restart-launcher$' {
            Log 'restart-launcher requested'
            Send-Response $ctx 200 @{ ok = $true }
            Stop-Launcher
            if ($ManageLauncher) { Start-Sleep -Milliseconds 500; $script:LauncherProc = Start-Launcher -Windowed:$Windowed }
            return
        }

        '^GET /volume$'  { Send-Response $ctx 200 (Get-VolumeState); return }
        '^POST /volume$' { Send-Response $ctx 200 (Set-VolumeState (Read-Body $ctx)); return }

        '^GET /audio-output$'  { Send-Response $ctx 200 (Get-AudioOutputs); return }
        '^POST /audio-output$' {
            $b = Read-Body $ctx
            [TVHelper.Audio]::SetDefault([string]$b.id)
            Log "audio output -> $($b.id)"
            Send-Response $ctx 200 (Get-AudioOutputs); return
        }

        '^GET /now-playing$' {
            # Spotify's window reports every 10 s while it is open; an older file means it was closed.
            $np = $null
            $f = Join-Path $TV.Data 'now-playing.json'
            if ((Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -lt 30) {
                try { $np = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { }
            }
            if ($np -and -not $np.title) { $np = $null }
            Send-Response $ctx 200 @{ nowPlaying = $np }; return
        }
        '^GET /sleep-timer$'  { Send-Response $ctx 200 (Get-SleepTimerState); return }
        '^POST /sleep-timer$' { $b = Read-Body $ctx; Send-Response $ctx 200 (Set-SleepTimer ([int]$b.minutes) ([string]$b.action)); return }

        '^POST /screen-off$' { Send-Response $ctx 200 (Invoke-Power 'screen-off' 'idle on home screen'); return }
        '^GET /standby$' { Send-Response $ctx 200 @{ standby = [bool]$Standby; since = $(if ($Standby) { $Standby.since.ToString('o') } else { $null }) }; return }
        '^POST /power/(sleep|standby|restart|shutdown)$' {
            $action = $Matches[1]
            if ($TestMode) { Send-Response $ctx 200 (Invoke-Power $action 'power page'); return }
            Send-Response $ctx 200 @{ ok = $true; action = $action }   # answer first: the page may not get a reply afterwards
            Start-Sleep -Milliseconds 800
            [void](Invoke-Power $action 'power page'); return
        }

        '^POST /open-settings/(wifi|bluetooth|sound)$' {
            $via = Open-SettingsPage $Matches[1]
            if ($via) { Send-Response $ctx 200 @{ ok = $true; via = $via } }
            else { Send-Response $ctx 500 @{ error = 'could not open' } }
            return
        }

        '^GET /desktop$' {
            Send-Response $ctx 200 @{ pinRequired = [bool](Get-Settings).desktopPin }; return
        }
        '^POST /desktop$' {
            $body = Read-Body $ctx
            if (-not (Test-DesktopPin ([string]$body.pin))) { Log "escape hatch: wrong PIN ($(([string]$body.pin).Length) digits entered)"; Send-Response $ctx 403 @{ error = 'wrong pin' }; return }
            if ($TestMode -and (Get-Process explorer -ErrorAction SilentlyContinue)) {
                Log 'TEST MODE: would start explorer.exe (it is already running)'
                Send-Response $ctx 200 @{ ok = $true; testMode = $true }; return
            }
            Log 'escape hatch: starting explorer.exe (launcher no longer restarted until the next sign-in)'
            $script:Supervise = $false
            Start-Process explorer.exe
            Send-Response $ctx 200 @{ ok = $true }; return
        }
        '^POST /desktop-pin$' {
            $body = Read-Body $ctx
            if (-not (Test-DesktopPin ([string]$body.current))) { Send-Response $ctx 403 @{ error = 'wrong pin' }; return }
            $new = [string]$body.new
            if ($new -and $new -notmatch '^\d{4}$') { Send-Response $ctx 400 @{ error = 'PIN must be 4 digits' }; return }
            Set-DesktopPin $new
            Log $(if ($new) { 'desktop PIN set' } else { 'desktop PIN removed' })
            Send-Response $ctx 200 @{ ok = $true; pinRequired = [bool]$new }; return
        }
    }
    Send-Response $ctx 404 @{ error = 'not found'; path = $path }
}

# ---------- main loop ----------
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
Log "helper $($TV.Version) listening on $Prefix (manageLauncher=$ManageLauncher windowed=$Windowed testMode=$TestMode)"

function Test-LauncherAlive {
    if ($LauncherProc -and -not $LauncherProc.HasExited) { return $true }
    return [bool](Get-ProcessesForProfile 'launcher' | Select-Object -First 1)
}

# The launcher window's title starts with its page title: "Home" in a window, "Home - [InPrivate] - Microsoft Edge"
# in kiosk mode. Anything else means it left our pages (for example Edge's own home page), and there is no address
# bar to come back with, so the home screen is reloaded. A title that is still the file name (page loading) counts
# as ours. At most 3 reloads in 10 minutes, so a wrong guess can never turn into an endless restart loop.
$OurTitles = '^(Home|Settings|Race Calendar|Power|Remote Key Test)( - |$)|\.html'
$strayChecks = 0
$strayReloads = @()
$Supervise = $true          # turned off by the escape hatch, so the desktop stays usable
function Test-LauncherOnOurPage {
    $ids = @(Get-ProcessesForProfile 'launcher' | ForEach-Object { [int]$_.ProcessId })
    if (-not $ids.Count) { return $true }
    $titles = @(Get-Process -Id $ids -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.MainWindowTitle })
    if (-not $titles.Count) { return $true }            # no window yet (starting up)
    if ($titles | Where-Object { $_ -match $OurTitles }) { return $true }
    $script:StrayTitle = $titles -join ' | '
    return $false
}

$lastCheck = Get-Date '2000-01-01'
$task = $listener.GetContextAsync()
try {
    while ($listener.IsListening) {
        if ($task.Wait(1000)) {
            $ctx = $task.Result
            $task = $listener.GetContextAsync()
            try { Handle-Request $ctx }
            catch {
                Log "error on $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath): $($_.Exception.Message)"
                try { Send-Response $ctx 500 @{ error = $_.Exception.Message } } catch { }
            }
        }
        try { Test-SleepTimer } catch { Log "sleep timer error: $($_.Exception.Message)" }
        try { Test-Standby } catch { Log "standby error: $($_.Exception.Message)" }
        # Keep the launcher window alive (checked every 5 s).
        if ($ManageLauncher -and $Supervise -and ((Get-Date) - $lastCheck).TotalSeconds -ge 5) {
            $lastCheck = Get-Date
            if (-not (Test-LauncherAlive)) {
                Log 'launcher not running: starting it'
                $LauncherProc = Start-Launcher -Windowed:$Windowed
                $strayChecks = 0
            } elseif (-not (Test-LauncherOnOurPage)) {
                $strayChecks++
                $strayReloads = @($strayReloads | Where-Object { ((Get-Date) - $_).TotalMinutes -lt 10 })
                if ($strayChecks -ge 3 -and $strayReloads.Count -lt 3) {   # 15 s away from our pages
                    Log "launcher window left the TV pages (title: $StrayTitle): reloading the home screen"
                    Stop-Launcher; Start-Sleep -Milliseconds 800
                    $LauncherProc = Start-Launcher -Windowed:$Windowed
                    $strayReloads += Get-Date
                    $strayChecks = 0
                } elseif ($strayChecks -eq 3) {
                    Log "launcher window left the TV pages (title: $StrayTitle): already reloaded 3 times in 10 minutes, leaving it"
                }
            } else { $strayChecks = 0 }
        }
    }
} finally {
    $listener.Stop()
    $mutex.ReleaseMutex()
}
