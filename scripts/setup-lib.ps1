# Shared by setup.ps1 and uninstall.ps1. Every change goes through these functions, so that without -Apply
# (the default) the scripts only print what they would do, with each setting's current value, and change nothing.

$Script:ApplyChanges = $false
$Script:Changes = 0

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- output ----------
function Write-Section([string]$t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Ok([string]$t)      { Write-Host "  [ok]     $t" -ForegroundColor DarkGray }
function Write-Info([string]$t)    { Write-Host "  [info]   $t" }
function Write-Warn([string]$t)    { Write-Host "  [check]  $t" -ForegroundColor Yellow }
function Write-Change([string]$t) {
    $Script:Changes++
    if ($Script:ApplyChanges) { Write-Host "  [change] $t" -ForegroundColor Green }
    else { Write-Host "  [would]  $t" -ForegroundColor Green }
}

# Runs $Action only with -Apply. $Describe says what it does.
function Invoke-Change([string]$Describe, [scriptblock]$Action) {
    Write-Change $Describe
    if ($Script:ApplyChanges) {
        try { & $Action } catch { Write-Host "  [failed] $Describe`: $($_.Exception.Message)" -ForegroundColor Red }
    }
}

# ---------- registry ----------
function Format-RegPath([string]$p) {
    $p -replace '^Registry::HKEY_LOCAL_MACHINE', 'HKLM' -replace '^Registry::HKEY_USERS\\[^\\]+', 'TV user' -replace '^Registry::HKEY_CURRENT_USER', 'HKCU'
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $current = Get-RegValue $Path $Name
    $show = "$(Format-RegPath $Path)\$Name"
    if ($null -ne $current -and "$current" -eq "$Value") { Write-Ok "$show = $Value"; return }
    $was = if ($null -eq $current) { 'not set' } else { "$current" }
    Invoke-Change "$show = $Value   (now: $was)" {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }.GetNewClosure()
}

function Remove-RegValue([string]$Path, [string]$Name) {
    $current = Get-RegValue $Path $Name
    $show = "$(Format-RegPath $Path)\$Name"
    if ($null -eq $current) { Write-Ok "$show not set"; return }
    Invoke-Change "remove $show   (now: $current)" { Remove-ItemProperty -Path $Path -Name $Name -Force }.GetNewClosure()
}

# ---------- the TV user ----------
# Finds the account, its profile folder and its registry hive. Loads the hive from NTUSER.DAT when that user
# is not signed in (needs admin); Close-TVUser unloads it again.
function Open-TVUser([string]$Name) {
    try { $sid = (New-Object Security.Principal.NTAccount($Name)).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { throw "No Windows account called '$Name' on this PC." }
    $profilePath = Get-RegValue "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" 'ProfileImagePath'
    if (-not $profilePath) { throw "'$Name' has never signed in on this PC. Sign in as that user once, then run this again." }
    $profilePath = [Environment]::ExpandEnvironmentVariables($profilePath)
    $local = $null
    try { $local = Get-LocalUser -SID $sid -ErrorAction Stop } catch { }
    $u = [ordered]@{
        Name        = $Name
        Sid         = $sid
        Profile     = $profilePath
        LocalAppData = Join-Path $profilePath 'AppData\Local'
        IsCurrent   = ($sid -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        Microsoft   = ($local -and "$($local.PrincipalSource)" -eq 'MicrosoftAccount')
        HasPassword = if ($local) { [bool]$local.PasswordRequired } else { $true }
        Hive        = $null
        LoadedByUs  = $false
    }
    if (Test-Path "Registry::HKEY_USERS\$sid") { $u.Hive = "Registry::HKEY_USERS\$sid" }
    elseif (Test-Admin) {
        & reg.exe load "HKU\TVSetupUser" (Join-Path $profilePath 'NTUSER.DAT') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not open $Name's settings (is that user signed in somewhere else?)." }
        $u.Hive = 'Registry::HKEY_USERS\TVSetupUser'; $u.LoadedByUs = $true
    }
    return [pscustomobject]$u
}

function Close-TVUser($u) {
    if ($u -and $u.LoadedByUs) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload 'HKU\TVSetupUser' | Out-Null
    }
}

# ---------- auto-login password: kept as an LSA secret (like Sysinternals Autologon), never as plain text ----------
if (-not ('TVSetup.Lsa' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Security;
namespace TVSetup {
public static class Lsa {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attr, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, out IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    const uint POLICY_ALL = 0x00F0FFF;

    static IntPtr Open() {
        var attr = new LSA_OBJECT_ATTRIBUTES(); attr.Length = Marshal.SizeOf(attr);
        IntPtr h; uint s = LsaOpenPolicy(IntPtr.Zero, ref attr, POLICY_ALL, out h);
        if (s != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(s));
        return h;
    }
    static LSA_UNICODE_STRING Key() {
        const string k = "DefaultPassword";
        var u = new LSA_UNICODE_STRING(); u.Buffer = Marshal.StringToHGlobalUni(k);
        u.Length = (ushort)(k.Length * 2); u.MaximumLength = (ushort)(k.Length * 2 + 2); return u;
    }
    /* null removes the secret. */
    public static void SetDefaultPassword(SecureString password) {
        IntPtr h = Open(); var key = Key(); IntPtr plain = IntPtr.Zero; IntPtr data = IntPtr.Zero;
        try {
            if (password != null) {
                plain = Marshal.SecureStringToGlobalAllocUnicode(password);
                var v = new LSA_UNICODE_STRING(); v.Buffer = plain;
                v.Length = (ushort)(password.Length * 2); v.MaximumLength = (ushort)(password.Length * 2 + 2);
                data = Marshal.AllocHGlobal(Marshal.SizeOf(v)); Marshal.StructureToPtr(v, data, false);
            }
            uint s = LsaStorePrivateData(h, ref key, data);
            if (s != 0 && !(password == null && s == 0xC0000034)) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(s));
        } finally {
            if (plain != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(plain);
            if (data != IntPtr.Zero) Marshal.FreeHGlobal(data);
            Marshal.FreeHGlobal(key.Buffer); LsaClose(h);
        }
    }
    public static bool HasDefaultPassword() {
        IntPtr h = Open(); var key = Key(); IntPtr data;
        try { uint s = LsaRetrievePrivateData(h, ref key, out data); if (s == 0) { LsaFreeMemory(data); return true; } return false; }
        finally { Marshal.FreeHGlobal(key.Buffer); LsaClose(h); }
    }
}}
'@
}

function Test-LocalPassword([string]$user, [Security.SecureString]$pw) {
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $ctx = New-Object DirectoryServices.AccountManagement.PrincipalContext('Machine')
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($pw))
    try { return $ctx.ValidateCredentials($user, $plain) } finally { $plain = $null; $ctx.Dispose() }
}

# ---------- values shared by setup and uninstall ----------
$Script:WinlogonKey = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$Script:UserShellSubkey = 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
$Script:EdgePolicySubkey = 'Software\Policies\Microsoft\Edge'
# Edge policies for the TV user (see docs/build-notes.md, stage 2): no account sign-in or sync in our profiles,
# no first-run pages, and closing a window really ends it (the launcher watchdog relies on that).
$Script:EdgePolicies = [ordered]@{
    ImplicitSignInEnabled        = 0
    BrowserSignin                = 0
    SyncDisabled                 = 1
    HideFirstRunExperience       = 1
    BackgroundModeEnabled        = 0
    StartupBoostEnabled          = 0
    DefaultBrowserSettingEnabled = 0
    ShowRecommendationsEnabled   = 0
    PromotionalTabsEnabled       = 0
    HubsSidebarEnabled           = 0
}
