# Self-test: opens every app tile through the helper, presses the remote's Home key, and checks that
# the app closed or minimised as configured and the launcher is back in front.
# Needs everything running first:  scripts\start.cmd -Windowed   (or the real kiosk start)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-apps.ps1 [-Apps youtube,netflix] [-WaitSeconds 8]
#
# It really opens the apps, so expect windows to appear for a few seconds each.

param([string[]]$Apps, [int]$WaitSeconds = 8)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'helper\common.ps1')

Add-Type -Namespace TVTest -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint flags, UIntPtr extra);
'@

$info = Get-HelperInfo
$base = "http://127.0.0.1:$($info.port)"
$hdr  = @{ 'X-TV-Token' = $info.token }
$cfg  = Read-JsonFile (Join-Path $TV.Config 'apps.json')

function Title($h) { $s = New-Object Text.StringBuilder 256; [void][TVTest.U]::GetWindowText($h, $s, 256); $s.ToString() }
function LauncherPids { @(Get-ProcessesForProfile 'launcher' | ForEach-Object { [uint32]$_.ProcessId }) }
function IsLauncher($h) { $p = [uint32]0; [void][TVTest.U]::GetWindowThreadProcessId($h, [ref]$p); (LauncherPids) -contains $p }
function PressHome {
    # VK_BROWSER_HOME (0xAC) is an extended key: what most remotes send for their Home button.
    [TVTest.U]::keybd_event(0xAC, 0, 1, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60
    [TVTest.U]::keybd_event(0xAC, 0, 3, [UIntPtr]::Zero)
}

try { Invoke-RestMethod "$base/ping" -Headers $hdr -TimeoutSec 2 | Out-Null }
catch { Write-Host 'Helper is not running. Start it first: scripts\start.cmd -Windowed' -ForegroundColor Red; exit 1 }
if (-not (Get-Process AutoHotkey64, AutoHotkey -ErrorAction SilentlyContinue)) { Write-Host 'AutoHotkey (tv.ahk) is not running: Home will not work.' -ForegroundColor Yellow }

$ids = if ($Apps) { $Apps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $cfg.apps.PSObject.Properties | Where-Object { $_.Value.launch.type -ne 'page' -and -not $_.Value.hidden } | ForEach-Object Name }
$results = foreach ($id in $ids) {
    $a = $cfg.apps.$id
    $expect = if ($a.onHome) { $a.onHome } else { 'minimize' }
    $r = [ordered]@{ App = $id; Opened = $false; InFront = ''; Home = ''; Expected = $expect; Launcher = $false; Notes = '' }
    try { Invoke-RestMethod "$base/launch/$id" -Method Post -Headers $hdr -TimeoutSec 25 | Out-Null; $r.Opened = $true }
    catch { $r.Notes = "launch failed: $($_.ErrorDetails.Message)"; [pscustomobject]$r; continue }

    # Wait for something other than the launcher to take the front.
    $deadline = (Get-Date).AddSeconds($WaitSeconds); $fg = [IntPtr]::Zero
    do { Start-Sleep -Milliseconds 400; $fg = [TVTest.U]::GetForegroundWindow() } while ((IsLauncher $fg) -and (Get-Date) -lt $deadline)
    Start-Sleep -Seconds 2   # let it settle (web apps change their title while loading)
    $fg = [TVTest.U]::GetForegroundWindow()
    if (IsLauncher $fg) { $r.InFront = '(launcher)'; $r.Notes = 'app never came to the front' }
    else { $r.InFront = (Title $fg) }

    PressHome
    Start-Sleep -Seconds 3
    if (-not (IsLauncher $fg)) {
        $r.Home = if (-not [TVTest.U]::IsWindow($fg) -or -not [TVTest.U]::IsWindowVisible($fg)) { 'close' }
                  elseif ([TVTest.U]::IsIconic($fg)) { 'minimize' } else { 'still open' }
    }
    $r.Launcher = IsLauncher ([TVTest.U]::GetForegroundWindow())
    [pscustomobject]$r
}

$results | Format-Table -AutoSize -Wrap
$bad = @($results | Where-Object { -not $_.Opened -or $_.Home -ne $_.Expected -or -not $_.Launcher })
if ($bad.Count) { Write-Host "$($bad.Count) of $(@($results).Count) failed" -ForegroundColor Red; exit 1 }
Write-Host "All $(@($results).Count) passed" -ForegroundColor Green
