# Shared paths and functions for helper.ps1 and scripts/start.ps1. Dot-source it: . "$PSScriptRoot\common.ps1"
# Windows PowerShell 5.1.

$TV = [ordered]@{}
$TV.Root     = Split-Path -Parent $PSScriptRoot                     # repo / install folder
$TV.Config   = Join-Path $TV.Root 'config'
$TV.Launcher = Join-Path $TV.Root 'launcher'
$TV.Data     = Join-Path $env:LOCALAPPDATA 'TVLauncher'             # machine-local state, never in the repo
$TV.Profiles = Join-Path $TV.Data 'profiles'                        # Edge user-data-dirs (launcher, youtube, f1tv, browser)
$TV.Logs     = Join-Path $TV.Data 'logs'
$TV.HelperJson = Join-Path $TV.Data 'helper.json'                   # {port, token}; read by tv.ahk
$TV.TokenJs  = Join-Path $TV.Launcher 'js\helper-token.js'          # same values for the launcher page
$TV.Version  = (Get-Content -Raw (Join-Path $TV.Root 'VERSION') -ErrorAction SilentlyContinue)
if ($TV.Version) { $TV.Version = $TV.Version.Trim() } else { $TV.Version = 'dev' }

foreach ($d in $TV.Data, $TV.Profiles, $TV.Logs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

function Write-TVLog {
    param([string]$Name, [string]$Message)
    $file = Join-Path $TV.Logs "$Name.log"
    try {
        if ((Test-Path $file) -and (Get-Item $file).Length -gt 1MB) { Move-Item -Force $file "$file.old" }
        Add-Content -Path $file -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch { }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json)
}

# Write via a temp file and rename, so a power cut never leaves half a settings file.
function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp $Path
}

function Get-EdgePath {
    foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                     "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
        if (Test-Path $p) { return $p }
    }
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue
    if ($reg) { return $reg.'(default)' }
    throw 'Microsoft Edge not found'
}

function Get-ProfileDir { param([string]$Name) return (Join-Path $TV.Profiles $Name) }


function Get-ProcessesForProfile {
    param([string]$Name)
    $needle = (Get-ProfileDir $Name).ToLower()
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($needle) }
}

# ---------- the launcher window itself ----------
function Get-LauncherUrl { return ([Uri](Join-Path $TV.Launcher 'index.html')).AbsoluteUri }

function Get-LauncherArgs {
    param([switch]$Windowed)
    $common = @(
        "--user-data-dir=`"$(Get-ProfileDir 'launcher')`"",
        '--no-first-run', '--no-default-browser-check', '--disable-sync',
        '--disable-features=Translate,LocalNetworkAccessChecks,PrivateNetworkAccessSendPreflights,PrivateNetworkAccessRespectPreflightResults',
        '--autoplay-policy=no-user-gesture-required',
        '--overscroll-history-navigation=0', '--disable-pinch'
    )
    if ($Windowed) { return @("--app=`"$(Get-LauncherUrl)`"", '--window-size=1280,720') + $common }
    return @('--kiosk', "`"$(Get-LauncherUrl)`"", '--edge-kiosk-type=fullscreen') + $common
}

function Start-Launcher {
    param([switch]$Windowed)
    $p = Start-Process -FilePath (Get-EdgePath) -ArgumentList ((Get-LauncherArgs -Windowed:$Windowed) -join ' ') -PassThru
    return $p
}

function Stop-Launcher {
    Get-ProcessesForProfile 'launcher' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ---------- helper port + token ----------
function Get-HelperInfo {
    $info = Read-JsonFile $TV.HelperJson
    if (-not $info -or -not $info.token) {
        $bytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $token = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
        $settings = Read-JsonFile (Join-Path $TV.Config 'settings.json')
        $port = if ($settings -and $settings.helperPort) { [int]$settings.helperPort } else { 8765 }
        $info = [pscustomobject]@{ port = $port; token = $token }
        Write-TextAtomic $TV.HelperJson ($info | ConvertTo-Json -Compress)
    }
    # The phone remote's pairing key (in the QR code the TV shows; a phone without it cannot press anything).
    if (-not $info.remoteKey) {
        $bytes = New-Object byte[] 18
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $info | Add-Member -NotePropertyName remoteKey -NotePropertyValue ([Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')) -Force
        Write-TextAtomic $TV.HelperJson ($info | ConvertTo-Json -Compress)
    }
    # Always refresh the launcher's copy (the install folder may have been replaced).
    Write-TextAtomic $TV.TokenJs ("/* Written by the helper on start. Do not commit. */`nwindow.TV_HELPER = " + ($info | ConvertTo-Json -Compress) + ";`n")
    return $info
}
