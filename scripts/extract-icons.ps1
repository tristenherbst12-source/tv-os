# Copies each app's own icon into launcher\icons\ (file names from the "icon" paths in config\apps.json).
# Never draws or recreates a logo: the icons come from the apps themselves.
#   Store apps   the package's own logo (AppxManifest.xml -> Square44x44Logo / Square150x150Logo, best size)
#   edge-app     the website's own icon (apple-touch-icon, <link rel=icon> or its web manifest)
#   edge         Microsoft Edge's own logo from its install folder
# A tile whose icon cannot be found keeps its placeholder glyph.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\extract-icons.ps1 [-DryRun] [-User <name>]
#
#   -DryRun  only report what would be copied
#   -User    look up Store apps installed for another Windows user (needs an admin window)
param([switch]$DryRun, [string]$User)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'launcher'
$apps = (Get-Content -Raw -Encoding UTF8 (Join-Path $root 'config\apps.json') | ConvertFrom-Json).apps
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Some sites (Netflix) only answer browsers quickly.
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0'

function Get-ImageSize([string]$path) {
    try { $img = [Drawing.Image]::FromFile($path); try { return $img.Width } finally { $img.Dispose() } } catch { return 0 }
}

# ---------- Store apps ----------
function Find-StoreIcon([string]$packageName) {
    $pkg = if ($User) { Get-AppxPackage -Name $packageName -User $User } else { Get-AppxPackage -Name $packageName }
    $pkg = @($pkg)[0]
    if (-not $pkg) { return @{ error = 'not installed' } }
    $manifest = [xml](Get-Content -Raw (Join-Path $pkg.InstallLocation 'AppxManifest.xml'))
    $ve = @($manifest.Package.Applications.Application)[0].VisualElements
    $best = $null; $bestScore = 0
    foreach ($logo in @($ve.Square44x44Logo, $ve.Square150x150Logo)) {
        if (-not $logo) { continue }
        $dir = Join-Path $pkg.InstallLocation (Split-Path $logo)
        $base = [IO.Path]::GetFileNameWithoutExtension($logo)
        $ext = [IO.Path]::GetExtension($logo)
        if (-not (Test-Path $dir)) { continue }
        # Square44x44Logo is the tight app icon; Square150x150Logo has padding for Start tiles, so it counts for less.
        $weight = if ($logo -eq $ve.Square44x44Logo) { 1.0 } else { 0.3 }
        Get-ChildItem $dir -File | Where-Object {
            ($_.Name -eq "$base$ext" -or $_.Name -like "$base.*$ext") -and $_.Name -notmatch 'contrast-'
        } | ForEach-Object {
            $w = Get-ImageSize $_.FullName
            $score = $w * $weight
            if ($_.Name -match 'altform-unplated') { $score += 1 }        # full-colour icon without a plate
            if ($score -gt $bestScore) { $best = $_.FullName; $bestScore = $score }
        }
    }
    if (-not $best -or $bestScore -lt 64) { return @{ error = 'no logo of a usable size' } }
    return @{ source = $best; size = (Get-ImageSize $best); background = $ve.BackgroundColor }
}

# ---------- websites ----------
function Get-WebIconCandidates([string]$url) {
    $page = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -UserAgent $UA
    $base = [Uri]$page.BaseResponse.ResponseUri
    $list = New-Object Collections.ArrayList
    foreach ($m in [regex]::Matches($page.Content, '<link\b[^>]*>', 'IgnoreCase')) {
        $tag = $m.Value
        $rel = [regex]::Match($tag, 'rel\s*=\s*["'']([^"'']+)', 'IgnoreCase').Groups[1].Value
        $href = [Net.WebUtility]::HtmlDecode([regex]::Match($tag, 'href\s*=\s*["'']([^"'']+)', 'IgnoreCase').Groups[1].Value)
        if (-not $href) { continue }
        $sizes = [regex]::Match($tag, 'sizes\s*=\s*["''](\d+)x', 'IgnoreCase').Groups[1].Value
        if ($rel -match 'manifest') {
            try {
                $man = Invoke-RestMethod -Uri ([Uri]::new($base, $href)) -TimeoutSec 20 -UserAgent $UA
                foreach ($i in @($man.icons)) {
                    if ($i.purpose -match 'monochrome') { continue }      # single-colour silhouette, not the real icon
                    $s =if ($i.sizes -match '^(\d+)x') { [int]$Matches[1] } else { 0 }
                    # "maskable" icons are padded for cropping into shapes; prefer the plain ones.
                    if ($i.purpose -match 'maskable' -and $i.purpose -notmatch 'any') { $s = [int]($s / 3) }
                    [void]$list.Add(@{ url = [Uri]::new([Uri]::new($base, $href), $i.src).AbsoluteUri; size = $s })
                }
            } catch { }
        } elseif ($rel -match 'icon') {
            $s = if ($sizes) { [int]$sizes } elseif ($rel -match 'apple-touch') { 180 } else { 32 }
            [void]$list.Add(@{ url = [Uri]::new($base, $href).AbsoluteUri; size = $s })
        }
    }
    [void]$list.Add(@{ url = [Uri]::new($base, '/apple-touch-icon.png').AbsoluteUri; size = 180 })
    return $list | Where-Object { $_.url -notmatch '\.svg(\?|$)' } | Sort-Object { -$_.size }
}

function Find-WebIcon([string]$url) {
    try { $candidates = Get-WebIconCandidates $url } catch { return @{ error = "site not reachable ($($_.Exception.Message))" } }
    foreach ($c in $candidates) {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri $c.url -OutFile $tmp -UseBasicParsing -TimeoutSec 20 -UserAgent $UA
            $w = Get-ImageSize $tmp
            if ($w -ge 64) { return @{ source = $c.url; size = $w; temp = $tmp } }
        } catch { }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    return @{ error = 'no icon of a usable size on the site' }
}

# ---------- Edge ----------
function Find-EdgeIcon {
    $dirs = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application", "$env:ProgramFiles\Microsoft\Edge\Application")
    $files = foreach ($d in $dirs) { Get-ChildItem "$d\*\VisualElements\Logo.png" -ErrorAction SilentlyContinue }
    $best = $files | Sort-Object { -(Get-ImageSize $_.FullName) } | Select-Object -First 1
    if (-not $best) { return @{ error = 'Edge logo not found' } }
    return @{ source = $best.FullName; size = (Get-ImageSize $best.FullName) }
}

# ---------- copy ----------
# Crops away transparent padding (Edge's Start-tile logo is mostly empty space). Faint shadow pixels are ignored.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class IconTrim {
    public static Bitmap Trim(Bitmap src, int alphaMin, double margin) {
        var rect = new Rectangle(0, 0, src.Width, src.Height);
        var bmp = src.Clone(rect, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var px = new byte[data.Stride * data.Height];
        Marshal.Copy(data.Scan0, px, 0, px.Length);
        bmp.UnlockBits(data);
        int minX = bmp.Width, minY = bmp.Height, maxX = -1, maxY = -1;
        for (int y = 0; y < bmp.Height; y++)
            for (int x = 0; x < bmp.Width; x++)
                if (px[y * data.Stride + x * 4 + 3] >= alphaMin) {
                    if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
                }
        if (maxX < 0) return bmp;
        int side = Math.Max(maxX - minX, maxY - minY) + 1;
        int pad = (int)(side * margin);
        int full = side + 2 * pad;
        var outBmp = new Bitmap(full, full, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(outBmp)) {
            g.Clear(Color.Transparent);
            int ox = pad + (side - (maxX - minX + 1)) / 2, oy = pad + (side - (maxY - minY + 1)) / 2;
            g.DrawImage(bmp, new Rectangle(ox, oy, maxX - minX + 1, maxY - minY + 1),
                        new Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1), GraphicsUnit.Pixel);
        }
        bmp.Dispose();
        return outBmp;
    }
}
'@

function Save-AsPng([string]$from, [string]$to, [switch]$Trim) {
    $dir = Split-Path $to
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $img = [Drawing.Bitmap]::FromFile($from)
    try {
        if ($Trim) { $t = [IconTrim]::Trim($img, 96, 0.04); try { $t.Save($to, [Drawing.Imaging.ImageFormat]::Png) } finally { $t.Dispose() } }
        else { $img.Save($to, [Drawing.Imaging.ImageFormat]::Png) }
    } finally { $img.Dispose() }
}

$results = foreach ($id in $apps.PSObject.Properties.Name) {
    $a = $apps.$id
    if (-not $a.icon -or $a.hidden -or $a.iconKeep) { continue }     # iconKeep: a file kept with the launcher (DStv)
    $type = $a.launch.type
    $found = switch ($type) {
        'store'    { Find-StoreIcon $a.launch.package }
        'edge-app' {
            # A website that also has a Store app (Netflix, Prime Video, ...): the Store app's logo when it is
            # installed, otherwise the website's own icon.
            $f = if ($a.iconPackage) { Find-StoreIcon $a.iconPackage } else { $null }
            if (-not $f -or $f.error) { $f = Find-WebIcon $a.launch.url }
            $f
        }
        'edge'     { Find-EdgeIcon }
        default    { $null }
    }
    if (-not $found) { continue }
    $target = Join-Path $launcher ($a.icon -replace '/', '\')
    $status = if ($found.error -and (Test-Path $target)) { "kept the icon already there ($($found.error))" }
              elseif ($found.error) { "kept glyph: $($found.error)" }
              elseif ($DryRun) { "would copy ($($found.size) px)" }
              else {
                  $src = if ($found.temp) { $found.temp } else { $found.source }
                  try { Save-AsPng $src $target -Trim:($type -eq 'edge'); "copied ($($found.size) px)" } catch { "kept glyph: $($_.Exception.Message)" }
              }
    if ($found.temp) { Remove-Item $found.temp -ErrorAction SilentlyContinue }
    [pscustomobject]@{ App = $a.name; Result = $status; From = $found.source }
}
$results | Format-Table -AutoSize -Wrap
