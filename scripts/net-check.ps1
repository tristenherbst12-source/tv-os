# Checks the two things the TV PC does over the network besides the apps, and says what stops them:
#   1. Updates: reaching GitHub (api.github.com) from PowerShell and from curl.exe.
#   2. Phone remote: phones on the home network reaching this PC on the remote's port.
# Writes everything to net-report.txt in the launcher folder (bring it back, or a photo of it, if something fails).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\net-check.ps1           # report only
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\net-check.ps1 -Apply    # and fix what it can (admin)
#
# -Apply: sets the home network to Private, turns on strong cryptography for .NET (so PowerShell can use modern TLS),
# adds the remote's URL reservation and firewall rule if missing.
param([switch]$Apply)
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$report = Join-Path $Root 'net-report.txt'
$lines = New-Object Collections.ArrayList
function Out-Line([string]$t, [string]$color = 'Gray') { Write-Host $t -ForegroundColor $color; [void]$lines.Add($t) }
function Ok([string]$t)   { Out-Line "  [ok]     $t" 'DarkGray' }
function Bad([string]$t)  { Out-Line "  [PROBLEM] $t" 'Red' }
function Info([string]$t) { Out-Line "  [info]   $t" }
function Fix([string]$t)  { Out-Line "  [fixed]  $t" 'Green' }
function Section([string]$t) { Out-Line ''; Out-Line "== $t ==" 'Cyan' }
function Chain($ex) { $p = @(); for ($e = $ex; $e; $e = $e.InnerException) { $p += $e.Message }; ($p | Select-Object -Unique) -join ' <- ' }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Apply -and -not $isAdmin) { Write-Host 'Run this in an administrator window for -Apply (right-click PowerShell > Run as administrator).' -ForegroundColor Red; exit 1 }

$cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'config\updates.json') | ConvertFrom-Json
$settings = try { Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'config\settings.json') | ConvertFrom-Json } catch { $null }
$port = if ($settings -and $settings.remotePort) { [int]$settings.remotePort } else { 8766 }
Out-Line "TV network check, $(Get-Date -Format 'yyyy-MM-dd HH:mm'), launcher $(Get-Content (Join-Path $Root 'VERSION') -TotalCount 1)"
Out-Line "Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion), .NET release $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release)"

# ---------------------------------------------------------------- network
Section 'Network'
$up = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address })
foreach ($c in $up) {
    Info "$($c.InterfaceAlias): $(@($c.IPv4Address)[0].IPAddress)/$(@($c.IPv4Address)[0].PrefixLength), router $(if ($c.IPv4DefaultGateway) { $c.IPv4DefaultGateway.NextHop } else { 'none' }), DNS $(@($c.DNSServer | Where-Object AddressFamily -eq 2 | ForEach-Object { $_.ServerAddresses }) -join ', ')"
}
if (-not $up) { Bad 'no network adapter is connected' }
$wlan = (& netsh.exe wlan show interfaces 2>$null) -join "`n"
if ($wlan -match '(?m)^\s*SSID\s*:\s*(.+)$') { Info "Wi-Fi network: $($Matches[1].Trim())  (the phone must be on this same network, not a guest one)" }
foreach ($p in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
    if ($p.NetworkCategory -eq 'Public') {
        if ($Apply) { try { Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop; Fix "network ""$($p.Name)"" set to Private" } catch { Bad "could not set ""$($p.Name)"" to Private: $(Chain $_.Exception)" } }
        else { Bad "network ""$($p.Name)"" is Public: Windows lets no phone in (fix: -Apply, or Settings > Network > the network > Private)" }
    } else { Ok "network ""$($p.Name)"" is $($p.NetworkCategory)" }
}

# ---------------------------------------------------------------- updates
Section "Updates (GitHub: $($cfg.repo))"
$api = "https://api.github.com/repos/$($cfg.repo)"
$proxy = (& netsh.exe winhttp show proxy 2>$null) -join ' '
if ($proxy -match 'Direct access') { Ok 'no system proxy (WinHTTP)' } else { Info "WinHTTP proxy: $($proxy.Trim())" }
$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($ie.ProxyEnable -eq 1 -or $ie.AutoConfigURL) { Info "user proxy: $($ie.ProxyServer) $($ie.AutoConfigURL)" } else { Ok 'no user proxy' }
try { $ips = [Net.Dns]::GetHostAddresses('api.github.com') | ForEach-Object { $_.IPAddressToString }; Ok "api.github.com is $($ips -join ', ')" }
catch { Bad "api.github.com cannot be looked up (DNS): $(Chain $_.Exception)" }
try {
    $tcp = New-Object Net.Sockets.TcpClient
    $ar = $tcp.BeginConnect('api.github.com', 443, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(8000) -and $tcp.Connected) { Ok 'api.github.com port 443 answers' } else { Bad 'api.github.com port 443 does not answer (firewall, router or internet filter)' }
    $tcp.Close()
} catch { Bad "cannot connect to api.github.com:443: $(Chain $_.Exception)" }

# .NET's TLS: without "strong cryptography" older .NET programs (Windows PowerShell 5.1) may offer only old TLS.
$strong = @('HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')
$weak = @($strong | Where-Object { (Get-ItemProperty $_ -ErrorAction SilentlyContinue).SchUseStrongCrypto -ne 1 })
if (-not $weak) { Ok '.NET strong cryptography is on' }
elseif ($Apply) { foreach ($k in $weak) { New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null; Set-ItemProperty $k SchUseStrongCrypto 1 -Type DWord; Set-ItemProperty $k SystemDefaultTlsVersions 1 -Type DWord }; Fix '.NET strong cryptography turned on (new PowerShell windows use modern TLS)' }
else { Info '.NET strong cryptography is off (-Apply turns it on; it helps PowerShell reach modern websites)' }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    $r = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'tv-launcher' } -TimeoutSec 20 -UseBasicParsing
    Ok "PowerShell reaches GitHub (repository is $(if ($r.private) { 'PRIVATE: updates need a token' } else { 'public' }))"
} catch {
    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
    if ($code) { Bad "GitHub answered PowerShell with $code (404: the repository is private or the name in config\updates.json is wrong)" }
    else { Bad "PowerShell cannot reach GitHub: $(Chain $_.Exception)" }
}
$curl = Join-Path $env:WINDIR 'System32\curl.exe'
if (Test-Path $curl) {
    $out = (& $curl -sS --max-time 20 -o NUL -w '%{http_code}' -H 'User-Agent: tv-launcher' $api 2>&1) -join ' '
    if ($LASTEXITCODE -eq 0 -and $out -match '200') { Ok 'curl.exe reaches GitHub (the TV falls back to it)' }
    else { Bad "curl.exe cannot reach GitHub: $out" }
} else { Info 'curl.exe is not on this PC' }
try {
    $d = (& $curl -sSI --max-time 10 https://www.github.com 2>$null) | Where-Object { $_ -match '^date:' } | Select-Object -First 1
    if ($d) {
        $net = [datetime]::Parse(($d -replace '^date:\s*', '').Trim()).ToUniversalTime()
        $off = [Math]::Round(([datetime]::UtcNow - $net).TotalMinutes)
        if ([Math]::Abs($off) -gt 5) { Bad "this PC's clock is $off minutes off (secure websites then fail): Settings > Time > Sync now" } else { Ok 'clock is right' }
    }
} catch { }

# ---------------------------------------------------------------- phone remote
Section "Phone remote (port $port)"
$helper = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*helper\helper.ps1*' }
if ($helper) { Ok 'the helper is running' } else { Bad 'the helper is not running (restart the PC, or Settings > Restart Launcher)' }
$listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listen) { Ok "something listens on port $port ($(@($listen.LocalAddress | Select-Object -Unique) -join ', '))" } else { Bad "nothing listens on port $port (the helper could not start the remote)" }
$url = "http://+:$port/"
$acl = (& netsh.exe http show urlacl url=$url 2>$null) -join ' '
if ($acl -match 'User:') { Ok "URL reservation $url exists" }
elseif ($Apply) { & netsh.exe http add urlacl url=$url "user=$env:USERDOMAIN\$env:USERNAME" | Out-Null; Fix "URL reservation $url added for $env:USERNAME (restart the launcher)" }
else { Bad "no URL reservation for $url (setup step 12, or -Apply)" }
$log = Join-Path $env:LOCALAPPDATA 'TVLauncher\logs\helper.log'
if (Test-Path $log) {
    $l = Get-Content $log -Tail 400 | Where-Object { $_ -match 'phone remote' } | Select-Object -Last 1
    if ($l) { Info "helper.log: $($l.Substring([Math]::Min(21, $l.Length)))" }
    Get-Content $log -Tail 400 | Where-Object { $_ -match 'updates:' } | Select-Object -Last 3 | ForEach-Object { Info "helper.log: $($_.Substring([Math]::Min(21, $_.Length)))" }
}
$rule = Get-NetFirewallRule -DisplayName 'TV Launcher phone remote' -ErrorAction SilentlyContinue
if ($rule) {
    $pf = $rule | Get-NetFirewallPortFilter; $af = $rule | Get-NetFirewallAddressFilter
    Ok "firewall rule: enabled=$($rule.Enabled), profiles=$($rule.Profile), port=$($pf.LocalPort), from=$($af.RemoteAddress -join ',')"
} elseif ($Apply) {
    New-NetFirewallRule -DisplayName 'TV Launcher phone remote' -Direction Inbound -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -Profile Private, Domain -Action Allow | Out-Null
    Fix "firewall rule added for port $port (home network only)"
} else { Bad 'no firewall rule for the phone remote (setup step 12, or -Apply)' }
foreach ($fp in @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
    if ($fp.Enabled -and $fp.AllowInboundRules -eq 'False') { Bad "the firewall's $($fp.Name) profile ignores all allow rules ('Block all incoming connections' is on)" }
}
foreach ($c in $up) {
    $ip = @($c.IPv4Address)[0].IPAddress
    try {
        $r = Invoke-WebRequest "http://${ip}:$port/" -UseBasicParsing -TimeoutSec 5
        Ok "the remote page answers on http://${ip}:$port/ (from this PC)"
    } catch { Bad "http://${ip}:$port/ does not answer even from this PC: $(Chain $_.Exception)" }
}
Out-Line ''
Out-Line 'If everything above is [ok] and the phone still cannot open the page:' 'Cyan'
Out-Line '  - the phone must be on the same Wi-Fi as the TV, with an address starting the same way (e.g. 192.168.0.x);'
Out-Line '    a guest network or a second router/extender keeps them apart;'
Out-Line '  - the router may keep devices apart ("AP isolation", "client isolation", "wireless isolation"): turn that off'
Out-Line '    in the router''s settings for your home network;'
Out-Line '  - on the phone, turn off a VPN or "private DNS" app while trying.'
Set-Content -Path $report -Value ($lines -join "`r`n") -Encoding UTF8
Write-Host ''
Write-Host "Saved to $report" -ForegroundColor Cyan
