# Gives the TV user the normal Windows desktop back and turns off automatic sign-in.
#
#   Preview (changes nothing):  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall.ps1
#   For real (admin window):    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall.ps1 -Apply
#
#   -TVUser <name>      the account setup.ps1 was run for (default: the account running this)
#   -KeepEdgePolicies   leave the Edge settings for that user in place
#   -RemoveData         also delete %LOCALAPPDATA%\TVLauncher (the TV windows' Edge profiles with their sign-ins,
#                       logs and the saved F1 calendar). The launcher folder itself is never deleted.
#
# Not undone (they are harmless on a normal PC and some cannot be undone): removed preinstalled apps (reinstall
# from the Store if wanted), the power plan, Windows Update active hours, the time zone, the tips/ads settings.
param([switch]$Apply, [string]$TVUser = $env:USERNAME, [switch]$KeepEdgePolicies, [switch]$RemoveData)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'setup-lib.ps1')
$Script:ApplyChanges = [bool]$Apply
$Root = Split-Path -Parent $PSScriptRoot

if ($Apply -and -not (Test-Admin)) { Write-Host 'Run this in an administrator window.' -ForegroundColor Red; exit 1 }
$user = Open-TVUser $TVUser
$U = $user.Hive

Write-Host ''
Write-Host 'TV Launcher uninstall' -ForegroundColor Cyan
Write-Host "  Mode:     $(if ($Apply) { 'APPLY: changes will be made' } else { 'PREVIEW: nothing will be changed (add -Apply to do it)' })"
Write-Host "  TV user:  $($user.Name)"
if (-not $U) { Write-Warn "$($user.Name)'s own settings cannot be read from this window (not signed in, no admin). Their rows are left out." }

try {
Write-Section '1. Normal Windows desktop again'
if ($U) {
    $shell = Get-RegValue "$U\$UserShellSubkey" 'Shell'
    if ($shell -and $shell -notmatch 'start\.vbs') {
        Write-Warn "The user's shell is '$shell', which setup.ps1 did not set. Left as it is."
    } else { Remove-RegValue "$U\$UserShellSubkey" 'Shell' }
}

Write-Section '2. Automatic sign-in off'
$auto = Get-RegValue $WinlogonKey 'AutoAdminLogon'
$who = Get-RegValue $WinlogonKey 'DefaultUserName'
if ($auto -eq '1' -and $who -and $who -ne $user.Name) {
    Write-Warn "Automatic sign-in is set for '$who', not $($user.Name). Left as it is."
} else {
    if ($auto -eq '1') { Set-Reg $WinlogonKey 'AutoAdminLogon' '0' 'String' } else { Write-Ok 'automatic sign-in is not on' }
    Remove-RegValue $WinlogonKey 'DefaultPassword'
    if (Test-Admin) {
        if ([TVSetup.Lsa]::HasDefaultPassword()) { Invoke-Change 'delete the stored sign-in password (LSA secret)' { [TVSetup.Lsa]::SetDefaultPassword($null) } }
        else { Write-Ok 'no stored sign-in password' }
    } else { Write-Change 'delete the stored sign-in password, if there is one (needs admin to check)' }
}

Write-Section '3. Edge settings for the TV user'
if ($KeepEdgePolicies) { Write-Info 'kept (-KeepEdgePolicies)' }
elseif ($U) { foreach ($k in $EdgePolicies.Keys) { Remove-RegValue "$U\$EdgePolicySubkey" $k } }

Write-Section '4. Stop the launcher'
$running = @(Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and $_.CommandLine.Contains($Root) -and $_.CommandLine -match 'start\.ps1|helper\.ps1|tv\.ahk|start\.vbs'
})
$running += @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -match 'TVLauncher\\profiles\\' })
if (-not $running.Count) { Write-Ok 'not running' }
else {
    # start.ps1 first, so it does not restart the helper; then the helper, so it does not restart the launcher.
    $order = $running | Sort-Object { if ($_.CommandLine -match 'start\.') { 0 } elseif ($_.CommandLine -match 'helper\.ps1') { 1 } else { 2 } }
    foreach ($p in $order) {
        Invoke-Change "stop $($p.Name) (pid $($p.ProcessId))" { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }.GetNewClosure()
    }
}

Write-Section '5. Launcher data'
$data = Join-Path $user.LocalAppData 'TVLauncher'
if (-not (Test-Path $data)) { Write-Ok 'none' }
elseif ($RemoveData) { Invoke-Change "delete $data (TV Edge profiles and their sign-ins, logs, saved calendar)" { Remove-Item -Recurse -Force $data }.GetNewClosure() }
else { Write-Info "kept: $data (add -RemoveData to delete it)" }
} finally { Close-TVUser $user }

Write-Host ''
if ($Apply) { Write-Host "Done ($Changes changes). Sign out and back in (or restart) to get the normal desktop." -ForegroundColor Cyan }
else { Write-Host "Preview finished: $Changes changes would be made. Nothing was changed." -ForegroundColor Cyan }
