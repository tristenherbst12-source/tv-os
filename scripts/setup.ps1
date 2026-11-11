# Sets up this PC as the TV: the launcher replaces the Windows desktop for one user, who is signed in
# automatically. Safe to run again (each step checks first and only changes what is different).
#
#   Preview (changes nothing; any window):
#     powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1
#   Set up for real (admin window, on the TV PC only):
#     powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1 -Apply
#
#   -TVUser <name>   the Windows account the TV runs as (default: the account running this)
#   -Skip <steps>    leave out steps, e.g. -Skip debloat,autologin
#                    (windows, timezone, debloat, updates, power, autologin, shell, install, apps, icons, edge)
#   -Yes             do not ask for the confirmation word (with -Apply)
#
# Undo with scripts\uninstall.ps1. See README.md.
param([switch]$Apply, [string]$TVUser = $env:USERNAME, [string[]]$Skip = @(), [switch]$Yes)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setup-lib.ps1')
$Script:ApplyChanges = [bool]$Apply
$Root = Split-Path -Parent $PSScriptRoot
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
function Want([string]$step) { if ($Skip -contains $step) { Write-Info "skipped (-Skip $step)"; return $false }; return $true }

$HKLM = 'Registry::HKEY_LOCAL_MACHINE'
$apps = (Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'config\apps.json') | ConvertFrom-Json).apps

# ---------- before anything ----------
if ($Apply -and -not (Test-Admin)) { Write-Host 'Run this in an administrator window (right-click PowerShell > Run as administrator).' -ForegroundColor Red; exit 1 }
$user = Open-TVUser $TVUser
$U = $user.Hive

Write-Host ''
Write-Host "TV Launcher setup ($((Get-Content -Raw (Join-Path $Root 'VERSION')).Trim()))" -ForegroundColor Cyan
Write-Host "  Mode:       $(if ($Apply) { 'APPLY: changes will be made' } else { 'PREVIEW: nothing will be changed (add -Apply to set up for real)' })"
Write-Host "  TV user:    $($user.Name)$(if ($user.Microsoft) { ' (Microsoft account)' })"
Write-Host "  Installed:  $Root"
if (-not $U) { Write-Warn "$($user.Name) is not signed in and this window is not an admin window, so that user's own settings cannot be read. Their rows below are left out." }

if ($Root -match '\\OneDrive|\\Desktop\\|\\Downloads\\') {
    Write-Warn "The launcher folder is inside OneDrive, Desktop or Downloads. On the TV PC, copy it to C:\TVLauncher first and run setup from there."
}
if ($Apply -and -not $Yes) {
    Write-Host ''
    Write-Host 'This replaces the Windows desktop for that user with the TV launcher and signs them in automatically.' -ForegroundColor Yellow
    Write-Host 'Only do this on the TV PC. Type SETUP to continue, anything else to stop.' -ForegroundColor Yellow
    if ((Read-Host 'Confirm') -cne 'SETUP') { Write-Host 'Stopped. Nothing was changed.'; Close-TVUser $user; exit 1 }
}

try {
# ---------- 1. Windows ----------
Write-Section '1. Windows version'
if (Want 'windows') {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "$($os.Caption), version $((Get-RegValue "$HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" 'DisplayVersion')) (build $($os.BuildNumber))"
    if ($os.Caption -notmatch 'Pro') { Write-Warn 'The launcher is built for Windows 10 Pro.' }
    if ($os.Caption -match 'Windows 10') {
        Write-Warn 'Windows 10 needs the free consumer Extended Security Updates (ESU) enrolment for security fixes until 12 October 2027.'
        Write-Info 'Settings > Update & Security > Windows Update > "Enroll now". Check that it says the PC is enrolled.'
    }
}

# ---------- 2. Time zone ----------
Write-Section '2. Time zone'
if (Want 'timezone') {
    $tz = (Get-TimeZone).Id
    if ($tz -eq 'South Africa Standard Time') { Write-Ok 'South Africa Standard Time' }
    else { Invoke-Change "time zone $tz -> South Africa Standard Time" { Set-TimeZone -Id 'South Africa Standard Time' } }
}

# ---------- 3. Remove extras, quiet Windows down ----------
Write-Section '3. Remove preinstalled extras, turn off tips, ads and pop-ups'
if (Want 'debloat') {
    # Exact names only. Never removed: Store, Edge, App Installer (winget), frameworks, Calculator, Photos, and the
    # TV apps (Netflix, Prime Video, Disney+, Spotify).
    $remove = @(
        'Microsoft.3DBuilder', 'Microsoft.Microsoft3DViewer', 'Microsoft.BingNews', 'Microsoft.BingWeather',
        'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
        'Microsoft.Messaging', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes', 'Microsoft.MixedReality.Portal', 'Microsoft.Office.OneNote',
        'Microsoft.OneConnect', 'Microsoft.People', 'Microsoft.Print3D', 'Microsoft.SkypeApp', 'Microsoft.Wallet',
        'Microsoft.WindowsAlarms', 'Microsoft.WindowsCamera', 'microsoft.windowscommunicationsapps',
        'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.WindowsSoundRecorder',
        'Microsoft.XboxApp', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
        'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'Clipchamp.Clipchamp', 'MicrosoftTeams',
        'Microsoft.549981C3F5F10'   # Cortana
    )
    $installed = if (Test-Admin) { Get-AppxPackage -AllUsers } else { Get-AppxPackage }
    $provisioned = if (Test-Admin) { Get-AppxProvisionedPackage -Online } else { @() }
    $found = 0
    foreach ($name in $remove + @('king.com.*')) {
        foreach ($p in @($installed | Where-Object Name -like $name)) {
            $found++
            Invoke-Change "remove app $($p.Name)" { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }.GetNewClosure()
        }
        foreach ($p in @($provisioned | Where-Object DisplayName -like $name)) {
            Invoke-Change "stop $($p.DisplayName) coming back for new users" { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null }.GetNewClosure()
        }
    }
    if (-not $found) { Write-Ok 'none of the extras are installed' }
    if (-not (Test-Admin)) { Write-Info 'Preview without admin: only this account''s apps were checked.' }

    if ($U) {
        $cdm = "$U\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        foreach ($n in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
                       'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SubscribedContentEnabled',
                       'SystemPaneSuggestionsEnabled', 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled',
                       'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                       'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') {
            Set-Reg $cdm $n 0
        }
        Set-Reg "$U\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0   # "Let's finish setting up"
        Set-Reg "$U\Software\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled' 0                     # notification pop-ups
        Set-Reg "$U\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" 'GlobalUserDisabled' 1    # background apps
        Set-Reg "$U\Software\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled' 0
        Set-Reg "$U\Software\Microsoft\Windows\CurrentVersion\Search" 'CortanaConsent' 0
        Set-Reg "$U\Software\Microsoft\Windows\CurrentVersion\SearchSettings" 'IsDynamicSearchBoxEnabled' 0         # search highlights
        Set-Reg "$U\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1
    }
    Set-Reg "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1
    Set-Reg "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableSoftLanding' 1
    Set-Reg "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'AllowCortana' 0
    Set-Reg "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'EnableDynamicContentInWSB' 0
}

# ---------- 4. Windows Update ----------
Write-Section '4. Windows Update: never restart in the evening'
if (Want 'updates') {
    # Active hours 08:00 to 02:00 (18 hours, the most Windows allows): updates restart only between 02:00 and 08:00.
    $wu = "$HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    Set-Reg $wu 'SetActiveHours' 1
    Set-Reg $wu 'ActiveHoursStart' 8
    Set-Reg $wu 'ActiveHoursEnd' 2
    Set-Reg "$wu\AU" 'NoAutoRebootWithLoggedOnUsers' 1
}

# ---------- 5. Power ----------
Write-Section '5. Power: never sleep on its own, keep the remote awake'
if (Want 'power') {
    $high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    if (((& powercfg.exe /list) -join ' ') -notmatch $high) {
        # Some installs hide the plan; this brings the built-in one back under its usual ID.
        Invoke-Change 'add the built-in High performance plan back' { & powercfg.exe /duplicatescheme $high $high | Out-Null }.GetNewClosure()
    }
    $active = (& powercfg.exe /getactivescheme) -join ' '
    if ($active -match $high) { Write-Ok 'High performance plan is active' }
    else { Invoke-Change "power plan -> High performance   (now: $(($active -split '\(')[-1].TrimEnd(')',' ')))" { & powercfg.exe /setactive SCHEME_MIN } }
    Invoke-Change 'never sleep, hibernate, turn off the screen or the disk by itself (Settings > Screen Off When Idle does the screen)' {
        foreach ($s in 'standby-timeout-ac', 'hibernate-timeout-ac', 'monitor-timeout-ac', 'disk-timeout-ac') { & powercfg.exe /change $s 0 }
    }
    Invoke-Change 'USB selective suspend off (keeps the remote''s USB receiver awake)' {
        & powercfg.exe /setacvalueindex SCHEME_MIN 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
    }
    Invoke-Change 'no password after waking from sleep' { & powercfg.exe /setacvalueindex SCHEME_MIN SUB_NONE CONSOLELOCK 0 }
    Invoke-Change 'apply the plan again' { & powercfg.exe /setactive SCHEME_MIN }
    $hib = Get-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\Power" 'HibernateEnabled'
    if ($hib -eq 0) { Write-Ok 'hibernation is off' }
    else { Invoke-Change 'hibernation off (Sleep then really sleeps; frees disk space)' { & powercfg.exe /hibernate off } }
}

# ---------- 6. Auto-login ----------
Write-Section "6. Sign in automatically as $($user.Name)"
if (Want 'autologin') {
    if ($user.Microsoft) {
        Write-Warn "$($user.Name) is a Microsoft account. Automatic sign-in is set up here for local accounts only."
        Write-Info 'Use a local account for the TV (README, step 1), or set it up with Sysinternals Autologon.'
    } else {
        # The password is always asked for (Windows' "password required" flag is often off even when the account
        # has one, which is why an earlier version skipped the question). Automatic sign-in is only switched on
        # once a password is known to be right, so a wrong one never leaves the PC stuck at "invalid password".
        $ready = $false
        if ($Apply) {
            $have = [TVSetup.Lsa]::HasDefaultPassword()
            $blankHint = if ($have) { 'press Enter to keep the one already stored' } else { 'press Enter if the account has no password' }
            for ($i = 1; $i -le 3 -and -not $ready; $i++) {
                $pw = Read-Host "Windows password for $($user.Name) ($blankHint)" -AsSecureString
                if ($pw.Length -eq 0) {
                    if ($have) { Write-Ok 'keeping the stored password'; $ready = $true }
                    elseif ((Read-Host "Does $($user.Name) sign in with no password at all? (y/n)") -match '^y') {
                        Write-Info 'no password stored'; $ready = $true
                    }
                } elseif (Test-LocalPassword $user.Name $pw) {
                    Invoke-Change 'store the password as a Windows secret (LSA), the way Sysinternals Autologon does' { [TVSetup.Lsa]::SetDefaultPassword($pw) }.GetNewClosure()
                    $ready = $true
                } else { Write-Warn 'That password is not right. Try again.' }
            }
        } else {
            Write-Change "ask for $($user.Name)'s password, check it, and store it encrypted (LSA secret, never plain text)"
            $ready = $true
        }
        if ($ready) {
            Set-Reg $WinlogonKey 'AutoAdminLogon' '1' 'String'
            Set-Reg $WinlogonKey 'DefaultUserName' $user.Name 'String'
            Set-Reg $WinlogonKey 'DefaultDomainName' $env:COMPUTERNAME 'String'
            Remove-RegValue $WinlogonKey 'DefaultPassword'      # a plain-text copy, if anything ever left one
            Set-Reg "$HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device" 'DevicePasswordLessBuildVersion' 0
        } else {
            Write-Warn 'No correct password given, so automatic sign-in was NOT switched on. Run setup again to retry.'
        }
    }
}

# ---------- 7. Replace the desktop for the TV user ----------
Write-Section "7. Start the TV launcher instead of the Windows desktop (only for $($user.Name))"
if (Want 'shell') {
    $shell = "wscript.exe `"$Root\scripts\start.vbs`""
    if ($U) { Set-Reg "$U\$UserShellSubkey" 'Shell' $shell 'String' }
    Write-Info 'Other accounts on this PC keep the normal desktop. To get the desktop on the TV: Settings > Windows Desktop,'
    Write-Info 'Ctrl+Alt+Shift+D, or Ctrl+Alt+Del > Task Manager > Run new task > explorer.'
}

# ---------- 8. Programs ----------
Write-Section '8. Programs'
if (Want 'install') {
    $ahk = @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe", "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey.exe",
             "$($user.LocalAppData)\Programs\AutoHotkey\v2\AutoHotkey64.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($ahk) { Write-Ok "AutoHotkey v2: $ahk" }
    elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Invoke-Change 'install AutoHotkey v2 with winget (needed for the Home and Back buttons)' {
            & winget.exe install --id AutoHotkey.AutoHotkey --exact --scope machine --silent --accept-source-agreements --accept-package-agreements
        }
    } else { Write-Warn 'AutoHotkey v2 is missing and winget is not available: install it from autohotkey.com.' }
}

Write-Section '9. Apps'
if (Want 'apps') {
    foreach ($id in $apps.PSObject.Properties.Name) {
        $a = $apps.$id
        if ($a.hidden) { continue }
        switch ($a.launch.type) {
            'edge-app' { Write-Ok "$($a.name): website in a TV window ($($a.launch.url)); sign in once from the home screen" }
            'store' {
                $p = if ((Test-Admin) -and -not $user.IsCurrent) { @(Get-AppxPackage -Name $a.launch.package -User $user.Name)[0] } else { @(Get-AppxPackage -Name $a.launch.package)[0] }
                if ($p) { Write-Ok "$($a.name): Store app installed" }
                else { Write-Warn "$($a.name) is not installed: get it from the Microsoft Store." }
            }
        }
    }
    Write-Info 'No Store apps are needed: every streaming tile opens its website. (Installed Store apps only lend their icons.)'
}

# ---------- 10. Icons ----------
Write-Section '10. App icons'
if (Want 'icons') {
    $argsIcons = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'extract-icons.ps1'))
    if (-not $Apply) { $argsIcons += '-DryRun' }
    if ((Test-Admin) -and -not $user.IsCurrent) { $argsIcons += @('-User', $user.Name) }
    & powershell.exe @argsIcons | Out-Host
}

# ---------- 11. Edge ----------
Write-Section '11. Edge for the TV windows'
if (Want 'edge') {
    if ($U) { foreach ($k in $EdgePolicies.Keys) { Set-Reg "$U\$EdgePolicySubkey" $k $EdgePolicies[$k] } }
    $profiles = Join-Path $user.LocalAppData 'TVLauncher\profiles'
    $profileNames = @('launcher') + @($apps.PSObject.Properties | ForEach-Object { $_.Value.launch } |
        Where-Object { $_.type -in 'edge', 'edge-app' } | ForEach-Object { if ($_.profile) { $_.profile } else { 'browser' } }) | Select-Object -Unique
    foreach ($p in $profileNames) {
        $d = Join-Path $profiles $p
        if (Test-Path $d) { Write-Ok "profile folder $p" }
        else { Invoke-Change "create Edge profile folder $d" { New-Item -ItemType Directory -Force $d | Out-Null }.GetNewClosure() }
    }
    Invoke-Change 'refresh the launcher''s built-in copy of config\ (scripts\sync-defaults.ps1)' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-defaults.ps1') | Out-Null
    }
}
} finally { Close-TVUser $user }

# ---------- summary ----------
Write-Host ''
if ($Apply) {
    Write-Host "Done ($Changes changes)." -ForegroundColor Cyan
    Write-Host 'Restart the PC. It should sign in by itself and open the TV home screen.'
} else {
    Write-Host "Preview finished: $Changes changes would be made. Nothing was changed." -ForegroundColor Cyan
    Write-Host 'On the TV PC, run again in an administrator window with -Apply.'
}
Write-Host 'By hand afterwards: open each tile once from the home screen and sign in there (the TV windows keep the'
Write-Host 'logins); pair the remote; check its buttons in Settings > Remote Button Test (README).'
