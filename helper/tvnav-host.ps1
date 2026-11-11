# Remote navigation for one TV window (started by helper.ps1 next to each app window, ends when the window closes).
#
# Connects to the window's Edge over its local debugging port and:
#   - adds inject\tvnav.js (arrows / OK / Back) and inject\youtube.js (1080p) to every page, and
#     inject\h264only.js where asked for (YouTube);
#   - turns the remote's OK into a real click inside the page (the page calls window.tvnavClick, this script then
#     sends a genuine mouse click at that spot). Sites that ignore made-up clicks (Prime Video) respond to these,
#     and the real pointer never moves.
#   - runs steps only a user action may do (full screen when a video you opened starts) when the page calls
#     window.tvnavGesture.
#
# Why not an Edge extension: Edge switches extensions loaded with --load-extension off from the second start of a
# profile, and the switch that prevented that stopped working with Edge 157.0.4341.46 (11 Nov 2026).
#
#   powershell -File helper\tvnav-host.ps1 -Port 9310 [-H264] [-Name youtube]
param([Parameter(Mandatory)][int]$Port, [switch]$H264, [string]$Name = 'app', [switch]$Trace)

. (Join-Path $PSScriptRoot 'common.ps1')
$LogFile = Join-Path $TV.Logs 'tvnav-host.log'
$NowPlayingFile = Join-Path $TV.Data 'now-playing.json'
function Log([string]$m) {
    try { Add-Content -Path $LogFile -Value "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))  [$Name] $m" -Encoding UTF8 } catch { }
}

# Read as plain text: Get-Content attaches file details to the string, which ConvertTo-Json would then serialise
# too (very slowly).
function Read-Text([string]$Rel) { return [IO.File]::ReadAllText((Join-Path $TV.Root $Rel), [Text.Encoding]::UTF8) }
# (youtube.js and spotify.js each act only on their own site)
$Source = (Read-Text 'inject\tvnav.js') + "`n" + (Read-Text 'inject\youtube.js') + "`n" + (Read-Text 'inject\spotify.js')
if ($H264) { $Source = (Read-Text 'inject\h264only.js') + "`n" + $Source }

# ---------- wait for the window's Edge to open its debugging port ----------
$wsUrl = $null
$deadline = (Get-Date).AddSeconds(30)
while (-not $wsUrl -and (Get-Date) -lt $deadline) {
    try { $wsUrl = (Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2).webSocketDebuggerUrl } catch { Start-Sleep -Milliseconds 300 }
}
if (-not $wsUrl) { Log "no Edge on port $Port, giving up"; exit 1 }

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
$ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait()
Log "connected on port $Port"

$script:NextId = 0
function Send-Cdp([string]$Method, $Params = @{}, [string]$Session = $null) {
    $script:NextId++
    $msg = @{ id = $script:NextId; method = $Method; params = $Params }
    if ($Session) { $msg.sessionId = $Session }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($msg | ConvertTo-Json -Depth 8 -Compress))
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).Wait()
}

$buffer = New-Object byte[] 65536
# Edge still there? (When its process is killed rather than closed, the connection can stay silently open.)
function Test-EdgeAlive {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $c.Connected } catch { return $false } finally { $c.Dispose() }
}
function Receive-Cdp {
    $ms = New-Object IO.MemoryStream
    do {
        $task = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None)
        while (-not $task.Wait(5000)) { if (-not (Test-EdgeAlive)) { return $null } }
        $r = $task.Result
        if ($r.MessageType -eq 'Close') { return $null }
        $ms.Write($buffer, 0, $r.Count)
    } until ($r.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

# Pages (the window, and any tab or pop-up it opens) are attached as they appear.
$Attached = @{}
Send-Cdp 'Target.setDiscoverTargets' @{ discover = $true }

function Set-UpPage([string]$Session) {
    Send-Cdp 'Page.enable' @{} $Session
    Send-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $Source } $Session
    Send-Cdp 'Runtime.addBinding' @{ name = 'tvnavClick' } $Session
    Send-Cdp 'Runtime.addBinding' @{ name = 'tvnavGesture' } $Session
    Send-Cdp 'Runtime.addBinding' @{ name = 'tvnavLog' } $Session          # notes for this log (where the highlight got stuck)
    Send-Cdp 'Runtime.addBinding' @{ name = 'tvnavNowPlaying' } $Session   # what Spotify is playing, for the home screen
    Send-Cdp 'Runtime.enable' @{} $Session
    Send-Cdp 'Runtime.evaluate' @{ expression = $Source } $Session          # the page that is already open
    Send-Cdp 'Runtime.runIfWaitingForDebugger' @{} $Session
}

function Send-Click([string]$Session, [double]$X, [double]$Y) {
    $base = @{ x = $X; y = $Y; button = 'left'; clickCount = 1; pointerType = 'mouse' }
    Send-Cdp 'Input.dispatchMouseEvent' (@{ type = 'mouseMoved'; x = $X; y = $Y; button = 'none'; pointerType = 'mouse' }) $Session
    Send-Cdp 'Input.dispatchMouseEvent' ($base + @{ type = 'mousePressed'; buttons = 1 }) $Session
    Send-Cdp 'Input.dispatchMouseEvent' ($base + @{ type = 'mouseReleased'; buttons = 0 }) $Session
}

try {
    while ($ws.State -eq 'Open') {
        $text = Receive-Cdp
        if ($null -eq $text) { break }
        if ($Trace) { Log ("<< " + $text.Substring(0, [Math]::Min(300, $text.Length))) }
        if (-not $text.StartsWith('{"method"')) { continue }        # replies to our own commands
        $m = $text | ConvertFrom-Json
        switch ($m.method) {
            'Target.targetCreated' {
                $t = $m.params.targetInfo
                if ($t.type -eq 'page' -and -not $Attached.ContainsKey($t.targetId)) {
                    $Attached[$t.targetId] = $true
                    Send-Cdp 'Target.attachToTarget' @{ targetId = $t.targetId; flatten = $true }
                }
            }
            'Target.attachedToTarget' {
                if ($m.params.targetInfo.type -eq 'page') { Set-UpPage $m.params.sessionId }
            }
            'Target.targetDestroyed' { $Attached.Remove($m.params.targetId) }
            'Runtime.bindingCalled' {
                if ($m.params.name -eq 'tvnavGesture') {
                    # The page asks for something only a user action may do (full screen): either a real key press
                    # ("key:f", the players' own full-screen key) or its prepared step, run as a user action.
                    if ($m.params.payload -match '^key:(\w)$') {
                        $k = $Matches[1]; $code = [int][char]$k.ToUpper()
                        $kb = @{ key = $k; code = "Key$($k.ToUpper())"; windowsVirtualKeyCode = $code; nativeVirtualKeyCode = $code }
                        Send-Cdp 'Input.dispatchKeyEvent' ($kb + @{ type = 'keyDown'; text = $k }) $m.sessionId
                        Send-Cdp 'Input.dispatchKeyEvent' ($kb + @{ type = 'keyUp' }) $m.sessionId
                    }
                    else {
                        Send-Cdp 'Runtime.evaluate' @{ expression = 'window.__tvnavGesture && window.__tvnavGesture()'; userGesture = $true } $m.sessionId
                    }
                }
                elseif ($m.params.name -eq 'tvnavLog') { $t = [string]$m.params.payload; Log $t.Substring(0, [Math]::Min(400, $t.Length)) }
                elseif ($m.params.name -eq 'tvnavNowPlaying') {
                    # Spotify's song (title, artist, picture, playing): kept in a file the helper hands to the home screen.
                    try { [IO.File]::WriteAllText($NowPlayingFile, [string]$m.params.payload, (New-Object Text.UTF8Encoding $false)) } catch { }
                }
                elseif ($m.params.name -eq 'tvnavClick') {
                    try {
                        $p = $m.params.payload | ConvertFrom-Json
                        if ($p.move) {       # just move the page's pointer there (players show their controls)
                            Send-Cdp 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = [double]$p.x; y = [double]$p.y; button = 'none'; pointerType = 'mouse' } $m.sessionId
                        }
                        else { Send-Click $m.sessionId ([double]$p.x) ([double]$p.y) }
                    } catch { Log "click failed: $($_.Exception.Message)" }
                }
            }
        }
    }
} catch {
    Log "stopped: $($_.Exception.InnerException.Message) $($_.Exception.Message)"
}
Log 'window closed'
