# TV Launcher helper: a small local web service the launcher page talks to.
# Listens on 127.0.0.1 only and rejects any request without the secret token.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File helper\helper.ps1 [-ManageLauncher] [-Windowed]
#
#   -ManageLauncher  start the launcher window and restart it if it closes or crashes (used by start.ps1)
#   -Windowed        launcher in a normal window instead of full-screen kiosk (for testing on a desktop PC)
#
# Endpoints (all need header X-TV-Token):
#   GET  /ping                      helper is up
#   GET  /config/{apps|keymap|settings}
#   POST /settings                  merge a JSON object into config/settings.json
#   POST /launch/{appId}            open an app from config/apps.json
#   POST /home                      tv.ahk asks what to do with the window in front (close / minimize)
#   GET  /keys?since=N, POST /keys  keys seen by tv.ahk, for the key-test page
#   GET  /status                    uptime, storage, version
#   POST /restart-launcher
#   GET  /desktop, POST /desktop    escape hatch: start explorer.exe (PIN-checked when one is set)
# Volume, audio output, sleep timer and power arrive with the Settings and Power pages (stage 3).

param([switch]$ManageLauncher, [switch]$Windowed)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

# One helper at a time.
$mutex = New-Object Threading.Mutex($false, 'Local\TVLauncherHelper')
if (-not $mutex.WaitOne(0)) { Write-Host 'Helper already running.'; exit 0 }

function Log([string]$m) { Write-TVLog 'helper' $m; Write-Host $m }

# ---------- Win32 bits: Store app activation and bringing a window to the front ----------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TVHelper {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IApplicationActivationManager {
    void ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                             [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
  }
  [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  class ApplicationActivationManager { }

  public static class Native {
    // Starts a Store app by its AUMID without going through explorer.exe (which would start the full desktop
    // when it is not the shell). Returns the app's process id.
    public static uint Activate(string aumid) {
      var mgr = (IApplicationActivationManager)new ApplicationActivationManager();
      uint pid;
      mgr.ActivateApplication(aumid, null, 0, out pid);
      return pid;
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // Windows only lets the foreground process hand over focus. The helper runs in the background,
    // so borrow the foreground thread's input state (and, failing that, the Alt-key trick AutoHotkey uses).
    public static bool ForceForeground(IntPtr h) {
      if (IsIconic(h)) ShowWindow(h, 9);
      IntPtr fg = GetForegroundWindow();
      if (fg == h) return true;
      uint fgThread = GetWindowThreadProcessId(fg, IntPtr.Zero), me = GetCurrentThreadId();
      bool attached = fgThread != me && AttachThreadInput(me, fgThread, true);
      BringWindowToTop(h);
      SetForegroundWindow(h);
      if (attached) AttachThreadInput(me, fgThread, false);
      if (GetForegroundWindow() == h) return true;
      keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
      SetForegroundWindow(h);
      return GetForegroundWindow() == h;
    }

    // The window's AppUserModelID (what the taskbar groups by). Store apps, including the ones that are
    // really Edge web apps (Netflix today), carry "<PackageFamilyName>!<AppId>" here.
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)] struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr pad; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { void GetCount(out uint c); void GetAt(uint i, out PROPERTYKEY k); void GetValue(ref PROPERTYKEY k, out PROPVARIANT v); }
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT v);

    public static string WindowAumid(IntPtr h) {
      try {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore ps;
        if (SHGetPropertyStoreForWindow(h, ref iid, out ps) != 0 || ps == null) return null;
        var key = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        PROPVARIANT v;
        ps.GetValue(ref key, out v);
        string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null;   // VT_LPWSTR
        PropVariantClear(ref v);
        Marshal.ReleaseComObject(ps);
        return s;
      } catch { return null; }
    }
  }
}
'@

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

function Start-EdgeWindow {
    param($l, [string]$ProfileName, [switch]$App)
    $edgeArgs = @("--user-data-dir=`"$(Get-ProfileDir $ProfileName)`"", '--no-first-run', '--no-default-browser-check', '--disable-sync',
              '--autoplay-policy=no-user-gesture-required', '--disable-features=Translate')
    if ($App) { $edgeArgs += @("--app=`"$($l.url)`"", '--start-fullscreen') }
    else      { $edgeArgs += @('--start-maximized', "`"$($l.url)`"") }
    if ($l.userAgent) { $edgeArgs += "--user-agent=`"$($l.userAgent)`"" }
    if ($l.forceH264) {
        # Haswell has no VP9 decode: this small extension makes sites think only H.264 is playable.
        $ext = Join-Path $TV.Root 'extensions\h264only'
        $edgeArgs += "--load-extension=`"$ext`""
    }
    $p = Start-Process -FilePath (Get-EdgePath) -ArgumentList ($edgeArgs -join ' ') -PassThru
    # If this profile was already running, Edge hands the request over and this process exits at once.
    $h = Wait-MainWindow $p.Id 10
    if ($h -ne [IntPtr]::Zero) { [void][TVHelper.Native]::ForceForeground($h) }
    else {
        $existing = Get-ProcessesForProfile $ProfileName | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($existing) { [void][TVHelper.Native]::ForceForeground($existing.MainWindowHandle) }
    }
}

function Invoke-Launch {
    param([string]$Id)
    $apps = Get-Apps
    $a = $apps.apps.$Id
    if (-not $a) { return @{ status = 404; body = @{ error = 'unknown app'; app = $Id } } }
    $l = $a.launch
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
        'edge-app' { Start-EdgeWindow $l $l.profile -App; Log "launch $Id edge-app $($l.url)" }
        'edge'     { Start-EdgeWindow $l $(if ($l.profile) { $l.profile } else { 'browser' }); Log "launch $Id edge $($l.url)" }
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
        if ($p.Name -in 'helperPort', 'version') { continue }   # not changeable from the page
        if ($s.PSObject.Properties[$p.Name]) { $s.($p.Name) = $p.Value }
        else { $s | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    Write-TextAtomic $path ($s | ConvertTo-Json -Depth 10)
    return $s
}

# ---------- status ----------
function Get-Status {
    $os = Get-CimInstance Win32_OperatingSystem
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    return @{
        version   = $TV.Version
        uptimeSec = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
        helperUptimeSec = [int]((Get-Date) - $Started).TotalSeconds
        storage   = @{ drive = $env:SystemDrive; freeGB = [math]::Round($drive.FreeSpace / 1GB, 1); totalGB = [math]::Round($drive.Size / 1GB, 1) }
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
    param($ctx)
    if (-not $ctx.Request.HasEntityBody) { return $null }
    if ($ctx.Request.ContentLength64 -gt 65536) { throw 'body too large' }
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
        '^GET /ping$' { Send-Response $ctx 200 @{ ok = $true; version = $TV.Version }; return }

        '^GET /config/(apps|keymap|settings)$' {
            $file = Join-Path $TV.Config "$($Matches[1]).json"
            Send-Response $ctx 200 ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)); return
        }
        '^POST /settings$' { $s = Update-Settings (Read-Body $ctx); Send-Response $ctx 200 $s; return }

        '^POST /launch/([\w-]+)$' {
            $id = $Matches[1]
            $r = Invoke-Launch $id
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

        '^GET /desktop$' {
            $pin = (Get-Settings).desktopPin
            Send-Response $ctx 200 @{ pinRequired = [bool]$pin }; return
        }
        '^POST /desktop$' {
            $pin = (Get-Settings).desktopPin
            $body = Read-Body $ctx
            if ($pin -and (-not $body -or [string]$body.pin -ne [string]$pin)) { Send-Response $ctx 403 @{ error = 'wrong pin' }; return }
            Log 'escape hatch: starting explorer.exe'
            Start-Process explorer.exe
            Send-Response $ctx 200 @{ ok = $true }; return
        }
    }
    Send-Response $ctx 404 @{ error = 'not found'; path = $path }
}

# ---------- main loop ----------
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
Log "helper $($TV.Version) listening on $Prefix (manageLauncher=$ManageLauncher windowed=$Windowed)"

function Test-LauncherAlive {
    if ($LauncherProc -and -not $LauncherProc.HasExited) { return $true }
    return [bool](Get-ProcessesForProfile 'launcher' | Select-Object -First 1)
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
        # Keep the launcher window alive (checked every 5 s).
        if ($ManageLauncher -and ((Get-Date) - $lastCheck).TotalSeconds -ge 5) {
            $lastCheck = Get-Date
            if (-not (Test-LauncherAlive)) {
                Log 'launcher not running: starting it'
                $LauncherProc = Start-Launcher -Windowed:$Windowed
            }
        }
    }
} finally {
    $listener.Stop()
    $mutex.ReleaseMutex()
}
