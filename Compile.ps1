<#
.SYNOPSIS
    Builds the standalone GitHubLauncher.ps1 from ui/ + src/.

.DESCRIPTION
    Concatenates src/*.ps1 in numeric order, embeds every XAML document and
    binary asset as base64, then validates the result:

        * every XAML document must parse as XML
        * the produced script must parse without a single error token
        * forbidden constructs (external file reads, module imports) are rejected

.PARAMETER OutFile
    Output path. Defaults to GitHubLauncher.ps1 next to this script.

.PARAMETER SkipXamlTest
    Skips loading the XAML through XamlReader (the slower but exact check).

.PARAMETER NoVersionBump
    Keeps the version string untouched.

.PARAMETER Bom
    Writes the artifact with a UTF-8 BOM. Off by default: GitHub Pages serves
    .ps1 as application/octet-stream without a charset, PowerShell 5.1 then
    decodes it as ANSI and the BOM becomes garbage before the first token,
    which breaks "irm | iex". Keep this off unless you really need it.
#>

[CmdletBinding()]
param(
    [string]$OutFile,
    [switch]$SkipXamlTest,
    [switch]$NoVersionBump,
    [switch]$Bom
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
if (-not $OutFile) { $OutFile = Join-Path $root 'GitHubLauncher.ps1' }
$srcDir = Join-Path $root 'src'
$uiDir = Join-Path $root 'ui'
$assetDir = Join-Path $uiDir 'assets'

function Write-Step { param([string]$Text) Write-Host "  $Text" -ForegroundColor DarkGray }
function Write-Ok { param([string]$Text) Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Fail { param([string]$Text) Write-Host "  [!!] $Text" -ForegroundColor Red }

Write-Host ''
Write-Host ' GitHub Launcher - build' -ForegroundColor Cyan
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 0. sanity
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $srcDir)) { throw "Source folder not found: $srcDir" }
if (-not (Test-Path -LiteralPath $uiDir)) { throw "UI folder not found: $uiDir" }

$modules = @(Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' -File | Sort-Object Name)
if ($modules.Count -eq 0) { throw 'No modules found in src/.' }
Write-Step ("modules: " + (($modules | ForEach-Object { $_.Name }) -join ', '))

# ---------------------------------------------------------------------------
# 1. version
# ---------------------------------------------------------------------------
$versionFile = Join-Path $root 'VERSION'
$version = '1.0.0'
if (Test-Path -LiteralPath $versionFile) {
    $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
}
if (-not $NoVersionBump) {
    $parts = $version.Split('.')
    if ($parts.Count -eq 3) {
        $parts[2] = [string]([int]$parts[2] + 1)
        $version = $parts -join '.'
    }
    [IO.File]::WriteAllText($versionFile, $version + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
Write-Step "version: $version"

# ---------------------------------------------------------------------------
# 2. assets (auto-generate the app icon when missing)
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $assetDir)) {
    New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
}

$iconPath = Join-Path $assetDir 'icon.png'
if (-not (Test-Path -LiteralPath $iconPath)) {
    try {
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        $rect = New-Object System.Drawing.Rectangle 2, 2, 60, 60
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 14
        $path.AddArc($rect.X, $rect.Y, $r * 2, $r * 2, 180, 90)
        $path.AddArc($rect.Right - $r * 2, $rect.Y, $r * 2, $r * 2, 270, 90)
        $path.AddArc($rect.Right - $r * 2, $rect.Bottom - $r * 2, $r * 2, $r * 2, 0, 90)
        $path.AddArc($rect.X, $rect.Bottom - $r * 2, $r * 2, $r * 2, 90, 90)
        $path.CloseFigure()

        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 31, 111, 235))
        $g.FillPath($brush, $path)

        $font = New-Object System.Drawing.Font 'Segoe UI', 26, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.DrawString('GH', $font, $white, (New-Object System.Drawing.RectangleF 0, 0, 64, 64), $fmt)

        $bmp.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose(); $brush.Dispose(); $white.Dispose(); $font.Dispose()
        Write-Step 'generated ui/assets/icon.png'
    } catch {
        Write-Step "icon generation skipped: $($_.Exception.Message)"
    }
}

$assets = @{}
if (Test-Path -LiteralPath $iconPath) {
    $assets['icon'] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($iconPath))
    $iconKb = [Math]::Round((Get-Item -LiteralPath $iconPath).Length / 1KB, 1)
    Write-Step "icon: $iconKb KB"
}

# ---------------------------------------------------------------------------
# 3. XAML
# ---------------------------------------------------------------------------
$xamlFiles = [ordered]@{
    'Styles'       = 'Styles.xaml'
    'MainWindow'   = 'MainWindow.xaml'
    'PickerWindow' = 'PickerWindow.xaml'
}

$xamlText = @{}
$sbXaml = New-Object Text.StringBuilder
[void]$sbXaml.AppendLine('$Global:GHL_Xaml = @{')

foreach ($key in $xamlFiles.Keys) {
    $path = Join-Path $uiDir $xamlFiles[$key]
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing XAML: $path" }

    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n").TrimEnd()

    # a line starting with '@ would terminate the here-string early
    foreach ($line in ($text -split "`r`n")) {
        if ($line.TrimStart().StartsWith("'@")) {
            throw "XAML '$($xamlFiles[$key])' contains a line starting with '@ - the here-string would break."
        }
    }

    try { [void][xml]$text }
    catch { throw "XAML '$($xamlFiles[$key])' is not valid XML: $($_.Exception.Message)" }

    # StaticResource keys must exist in Styles.xaml
    if ($key -ne 'Styles') {
        $styleText = [IO.File]::ReadAllText((Join-Path $uiDir 'Styles.xaml'), [Text.Encoding]::UTF8)
        $used = [regex]::Matches($text, '\{StaticResource\s+([A-Za-z0-9_\.]+)\s*\}') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($token in $used) {
            if ($styleText -notmatch ('x:Key\s*=\s*"' + [regex]::Escape($token) + '"')) {
                throw "XAML '$($xamlFiles[$key])' uses StaticResource '$token' which is not defined in Styles.xaml."
            }
        }
    }

    $xamlText[$key] = $text
    [void]$sbXaml.AppendLine("'$key' = @'")
    [void]$sbXaml.AppendLine($text)
    [void]$sbXaml.AppendLine("'@")
    Write-Step "xaml: $($xamlFiles[$key]) ($([Math]::Round($text.Length / 1KB, 1)) KB)"
}
[void]$sbXaml.AppendLine('}')
Write-Ok "XAML embedded ($($xamlText.Count) documents)"

# ---------------------------------------------------------------------------
# 4. concatenate modules
# ---------------------------------------------------------------------------
$sbBody = New-Object Text.StringBuilder
$expectedOrder = @(
    '01-Bootstrap.ps1', '02-Config.ps1', '03-Api.ps1', '04-Downloader.ps1',
    '05-Archive.ps1', '06-Launcher.ps1', '07-Workers.ps1', '08-Main.ps1'
)
$actualOrder = @($modules | ForEach-Object { $_.Name })
if (($actualOrder -join '|') -ne ($expectedOrder -join '|')) {
    throw "Module order mismatch.`n  expected: $($expectedOrder -join ', ')`n  found:    $($actualOrder -join ', ')"
}

$requiredFunctions = @(
    'Start-GitHubLauncher', 'Get-GhlConfig', 'Invoke-GhlApi', 'Invoke-GhlDownload',
    'Expand-GhlArchive', 'Find-GhlExecutables', 'Start-GhlItem', 'Get-GhlRepoDir'
)
$defined = @{}

foreach ($module in $modules) {
    $text = [IO.File]::ReadAllText($module.FullName, [Text.Encoding]::UTF8)
    $text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n").TrimEnd()

    foreach ($m in [regex]::Matches($text, '(?m)^\s*function\s+([A-Za-z0-9_\-]+)')) {
        $defined[$m.Groups[1].Value] = $module.Name
    }

    [void]$sbBody.AppendLine('')
    [void]$sbBody.AppendLine("# ===========================================================================")
    [void]$sbBody.AppendLine("#  $($module.Name)")
    [void]$sbBody.AppendLine("# ===========================================================================")
    [void]$sbBody.AppendLine($text)
}

foreach ($fn in $requiredFunctions) {
    if (-not $defined.ContainsKey($fn)) { throw "Required function '$fn' is not defined by any module." }
}
Write-Ok "$($defined.Count) functions across $($modules.Count) modules"

# --- worker closure check ---------------------------------------------------
# Every function a runspace job can reach must be exported into the pool's
# session state, otherwise it fails at runtime with "not recognized".
$bodies = @{}
foreach ($module in $modules) {
    $text = [IO.File]::ReadAllText($module.FullName, [Text.Encoding]::UTF8)
    $matches = [regex]::Matches($text, '(?ms)^\s*function\s+([A-Za-z0-9_\-]+)\s*(?:\{[^{}]*?)*?\{(.*?)^\}')
    foreach ($m in $matches) { $bodies[$m.Groups[1].Value] = $m.Groups[2].Value }
}

$workersFile = Join-Path $srcDir '07-Workers.ps1'
$workersText = [IO.File]::ReadAllText($workersFile, [Text.Encoding]::UTF8)
$namesBlock = [regex]::Match($workersText, '(?s)function\s+Get-GhlWorkerNames.*?return\s+@\((.*?)\)\s*\}')
if (-not $namesBlock.Success) { throw 'Could not parse Get-GhlWorkerNames().' }
$exported = @([regex]::Matches($namesBlock.Groups[1].Value, "'([A-Za-z0-9_\-]+)'") | ForEach-Object { $_.Groups[1].Value })

$preambleOnly = @('Get-GhlFailureInfo')

foreach ($name in $exported) {
    if (-not $bodies.ContainsKey($name)) { throw "Get-GhlWorkerNames exports '$name', which no module defines." }
}

$unresolved = @()
foreach ($name in $exported) {
    $body = $bodies[$name]
    foreach ($m in [regex]::Matches($body, '\b([A-Z][A-Za-z0-9]*-Ghl[A-Za-z0-9]*)\b')) {
        $ref = $m.Groups[1].Value
        if ($preambleOnly -contains $ref) { continue }
        if ($exported -contains $ref) { continue }
        if (-not $bodies.ContainsKey($ref)) { continue }   # not ours (e.g. a cmdlet)
        $unresolved += ("$name -> $ref")
    }
}
if ($unresolved.Count -gt 0) {
    throw ("These functions are used by workers but missing from Get-GhlWorkerNames():`n  " + (($unresolved | Sort-Object -Unique) -join "`n  "))
}
Write-Ok "worker closure complete ($($exported.Count) functions exported)"

# ---------------------------------------------------------------------------
# 5. header + entry point
# ---------------------------------------------------------------------------
$assetsXaml = New-Object Text.StringBuilder
[void]$assetsXaml.AppendLine('$Global:GHL_Assets = @{')
foreach ($k in $assets.Keys) {
    [void]$assetsXaml.AppendLine("    '$k' = '$($assets[$k])'")
}
[void]$assetsXaml.AppendLine('}')

$buildStamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$header = @"
<#
    GitHub Launcher v$version
    Built $buildStamp by Compile.ps1 - do not edit this file by hand.

    Run with:
        irm <url> | iex
    or:
        powershell.exe -STA -ExecutionPolicy Bypass -File GitHubLauncher.ps1

    Repository: https://github.com/
#>

#requires -Version 5.1

`$Global:GHL_Build = @{
    Version = '$version'
    Built   = '$buildStamp'
    Modules = $($modules.Count)
}
"@

$entry = @"

# ===========================================================================
#  entry point
# ===========================================================================
if (`$env:GHL_SMOKE_TEST) {
    Start-GitHubLauncher -UiSmokeTest
} else {
    Start-GitHubLauncher
}
"@

$final = $header + "`r`n" + $sbXaml.ToString() + "`r`n" + $assetsXaml.ToString() + "`r`n" + $sbBody.ToString() + $entry

# ---------------------------------------------------------------------------
# 6. validation
# ---------------------------------------------------------------------------
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($final, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    foreach ($e in $errors | Select-Object -First 8) {
        Write-Fail ("line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
    }
    throw "The generated script has $($errors.Count) parse error(s)."
}
Write-Ok 'generated script parses cleanly'

$forbidden = @(
    @{ Pattern = '(?m)^\s*Import-Module\s'; Reason = 'Import-Module is not allowed in a single-file script' },
    @{ Pattern = '#requires\s+-Modules'; Reason = '#requires -Modules breaks irm | iex' },
    @{ Pattern = '\bInvoke-WebRequest\b'; Reason = 'use HttpClient (Invoke-GhlHttp) instead of Invoke-WebRequest' }
)
foreach ($rule in $forbidden) {
    if ($final -match $rule.Pattern) { throw "Forbidden construct: $($rule.Reason)." }
}
Write-Ok 'no forbidden constructs'

# ASCII-only artifact: a BOM-less file is decoded as ANSI by PowerShell 5.1
# when it arrives without a charset (GitHub Pages -> application/octet-stream),
# so any non-ASCII byte would be mangled on the "irm | iex" path.
$nonAscii = [regex]::Match($final, '[^\x00-\x7F]')
if ($nonAscii.Success -and -not $Bom) {
    $line = ($final.Substring(0, $nonAscii.Index) -split "`n").Count
    $code = [int][char]$nonAscii.Value
    $msg = @(
        "The generated script contains a non-ASCII character at line ${line}: '$($nonAscii.Value)' (U+$('{0:X4}' -f $code)).",
        'Keep the sources ASCII-only so the artifact survives the ANSI decode of the irm | iex path:',
        "  - replace typographic dashes/quotes with ASCII equivalents",
        "  - or pass -Bom and distribute the file in a way that declares UTF-8"
    ) -join [Environment]::NewLine
    throw $msg
}
Write-Ok 'artifact is ASCII-only (irm | iex safe)'

# ---------------------------------------------------------------------------
# 7. write
# ---------------------------------------------------------------------------
# No BOM by default: see .PARAMETER Bom and the ASCII guard above.
[IO.File]::WriteAllText($OutFile, $final, (New-Object Text.UTF8Encoding($Bom.IsPresent)))
$sizeKb = [Math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB, 1)
$hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash

$raw = [IO.File]::ReadAllBytes($OutFile)
$hasBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
$encodingLabel = if ($hasBom) { 'UTF-8 with BOM' } else { 'UTF-8 without BOM' }

Write-Host ''
Write-Host " Built $OutFile" -ForegroundColor Green
Write-Host "   size    : $sizeKb KB" -ForegroundColor Gray
Write-Host "   version : $version" -ForegroundColor Gray
Write-Host "   encoding: $encodingLabel" -ForegroundColor Gray
Write-Host "   sha256  : $hash" -ForegroundColor Gray
Write-Host "   lines   : $(($final -split "`n").Count)" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# 8. XAML load test (exact, requires STA)
# ---------------------------------------------------------------------------
if (-not $SkipXamlTest) {
    $testScript = Join-Path $root 'tools\Test-Xaml.ps1'
    if (Test-Path -LiteralPath $testScript) {
        Write-Host ''
        Write-Host ' Validating XAML through XamlReader...' -ForegroundColor Cyan
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -UiPath "{1}"' -f $testScript, $uiDir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = [Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(60000) | Out-Null

        if ($stdout) { Write-Host $stdout.TrimEnd() -ForegroundColor DarkGray }
        if ($stderr) { Write-Host $stderr.TrimEnd() -ForegroundColor DarkYellow }

        if ($proc.ExitCode -ne 0) {
            throw 'XAML validation failed. See the output above.'
        }
        Write-Ok 'XAML loads through XamlReader'
    } else {
        Write-Step 'tools/Test-Xaml.ps1 not found - skipped'
    }
}

Write-Host ''
Write-Host ' Build finished.' -ForegroundColor Cyan
Write-Host ''
