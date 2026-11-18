#Requires -Version 5.1
<#
.SYNOPSIS
    Universal GitHub Releases downloader.
.DESCRIPTION
    Enter a GitHub username -> pick repositories -> pick releases -> pick files.
    Downloads the actual release assets (exe/msi/zip/dmg/AppImage etc.),
    not source code.

    A token is only required for private repositories. Sources (in order):
      1) -Token parameter
      2) $env:GITHUB_TOKEN
      3) token.txt next to the script
    The script itself is safe to publish - it contains no secrets.

.PARAMETER DefaultUser
    Default GitHub username.
.PARAMETER BaseDir
    Download directory. Defaults to ~\GitHubReleases.
.PARAMETER Token
    GitHub PAT (classic or fine-grained with "public_repo" /
    "repo" for private access).
.PARAMETER AllVersions
    Show all versions of the selected repos instead of only the latest.
.PARAMETER IncludePrerelease
    Include beta/rc releases.
.PARAMETER AllAssets
    Skip the file picker: download every asset of every selected release.

.EXAMPLE
    .\Github-Releases-Launcher.ps1 -DefaultUser notepad-plus-plus
.EXAMPLE
    .\Github-Releases-Launcher.ps1 -DefaultUser vlc -AllVersions
#>
param(
    [string]$DefaultUser = "YOUR_GITHUB_USERNAME",
    [string]$BaseDir     = (Join-Path $env:USERPROFILE "GitHubReleases"),
    [string]$Token       = "",
    [switch]$AllVersions,
    [switch]$IncludePrerelease,
    [switch]$AllAssets
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# ============================ HELPERS ============================

function Get-AssetPlatform {
    param([string]$Name)
    $n = $Name.ToLower()
    if ($n -match '\.(exe|msi|msix|appx)$' -or
        $n -match '(^|[-_.])win(32|64|dows)([-_.]|$)' -or
        $n -match '(^|[-_.])windows([-_.]|$)') { return 'Windows' }
    if ($n -match '\.(deb|rpm|appimage|snap|flatpak)$' -or
        $n -match '(^|[-_.])linux([-_.]|$)') { return 'Linux' }
    if ($n -match '\.(dmg|pkg)$' -or
        $n -match '(^|[-_.])(macos|osx|darwin)([-_.]|$)') { return 'macOS' }
    if ($n -match '\.(apk|aab)$') { return 'Android' }
    if ($n -match '\.ipa$') { return 'iOS' }
    return 'Any'
}

function Get-CurrentOS {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'Windows' }  # PS 5.1 = Windows
    if ($IsWindows) { return 'Windows' }
    if ($IsLinux)   { return 'Linux' }
    if ($IsMacOS)   { return 'macOS' }
    return 'Any'
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Save-ReleaseAsset {
    param(
        [string]$AssetName,
        [long]$AssetSize,
        [string]$ApiUrl,
        [string]$BrowserUrl,
        [bool]$IsPrivate,
        [string]$OutputPath,
        [string]$Token
    )
    if ((Test-Path $OutputPath) -and (Get-Item $OutputPath).Length -eq $AssetSize) {
        Write-Host "[=] $AssetName - already present, skipping" -ForegroundColor DarkGray
        return $true
    }

    $dir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $suffix = if ($AssetSize -gt 0) { " ($(Format-Size $AssetSize))" } else { "" }
    Write-Host "[v] $AssetName$suffix" -ForegroundColor Cyan

    # Public repo: browser_download_url, no auth, no redirect surprises
    if (-not $IsPrivate -and $BrowserUrl) {
        try {
            $ProgressPreference = 'Continue'
            Invoke-WebRequest -Uri $BrowserUrl -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
            Write-Host "[OK] $AssetName" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "[!] $AssetName : $_" -ForegroundColor Red
            return $false
        }
    }

    # Private repo: API URL + Accept: octet-stream.
    # curl.exe follows the cross-host redirect (api -> objects.githubusercontent)
    # without forwarding the token to the "foreign" host - IWR on 5.1 often breaks here.
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $curlArgs = @('-L', '--fail', '--retry', '3', '--retry-delay', '2',
                      '-o', $OutputPath,
                      '-H', 'Accept: application/octet-stream',
                      '-H', 'User-Agent: PS-GH-Releases-Launcher')
        if ($Token) { $curlArgs += @('-H', "Authorization: Bearer $Token") }
        $curlArgs += $ApiUrl
        & curl.exe @curlArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] $AssetName" -ForegroundColor Green
            return $true
        }
        Write-Host "[!] curl returned exit code $LASTEXITCODE for $AssetName" -ForegroundColor Red
        return $false
    }

    # Last resort: IWR. On PS 5.1 private downloads may fail due to auth being dropped on redirect.
    $headers = @{
        'Accept'     = 'application/octet-stream'
        'User-Agent' = 'PS-GH-Releases-Launcher'
    }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    try {
        Invoke-WebRequest -Uri $ApiUrl -Headers $headers -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
        Write-Host "[OK] $AssetName" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[!] $AssetName : $_" -ForegroundColor Red
        return $false
    }
}

# ============================ TOKEN ============================

if (-not $Token) { $Token = $env:GITHUB_TOKEN }
if (-not $Token) {
    $tokenFile = Join-Path $PSScriptRoot 'token.txt'
    if (Test-Path $tokenFile) { $Token = (Get-Content $tokenFile -Raw).Trim() }
}

$headers = @{
    'User-Agent' = 'PS-GH-Releases-Launcher'
    'Accept'     = 'application/vnd.github+json'
}
if ($Token) {
    $headers['Authorization'] = "Bearer $Token"
    Write-Host "[i] Token provided - private repos accessible." -ForegroundColor DarkGray
}

# ============================ USERNAME ============================

if ([string]::IsNullOrWhiteSpace($DefaultUser) -or $DefaultUser -eq 'YOUR_GITHUB_USERNAME') {
    $in = Read-Host "GitHub username"
    if ([string]::IsNullOrWhiteSpace($in)) { Write-Host 'Cancelled.'; return }
    $TargetUser = $in.Trim()
} else {
    $in = Read-Host "GitHub username (Enter = '$DefaultUser')"
    $TargetUser = if ([string]::IsNullOrWhiteSpace($in)) { $DefaultUser } else { $in.Trim() }
}

# ============================ REPOSITORIES ============================

Write-Host "[*] Fetching repositories for $TargetUser..." -ForegroundColor Cyan
$repoApi = "https://api.github.com/users/$TargetUser/repos?per_page=100&sort=updated"
try {
    $repos = @(Invoke-RestMethod -Uri $repoApi -Headers $headers -Method Get -ErrorAction Stop)
} catch {
    Write-Host "[!] Failed to fetch repositories: $_" -ForegroundColor Red
    Read-Host "Press Enter to exit" | Out-Null
    return
}
if ($repos.Count -eq 0) {
    Write-Host "[!] '$TargetUser' has no accessible repositories." -ForegroundColor Yellow
    Read-Host "Press Enter to exit" | Out-Null
    return
}
Write-Host "[i] Repositories found: $($repos.Count)" -ForegroundColor DarkGray

$repoMenu = $repos | ForEach-Object {
    [PSCustomObject]@{
        Repository  = $_.name
        Stars       = $_.stargazers_count
        Private     = if ($_.private) { 'Yes' } else { 'No' }
        Archived    = if ($_.archived) { 'Yes' } else { '' }
        Description = $_.description
    }
}
$pickedRepos = $repoMenu |
    Out-GridView -Title "Repositories [$TargetUser] - select (Ctrl for multiple) -> OK" -OutputMode Multiple
if (-not $pickedRepos) { Write-Host 'Nothing selected.'; return }

$pickedRepoNames = @($pickedRepos | ForEach-Object { $_.Repository })
$pickedRepoObjs  = @($repos | Where-Object { $pickedRepoNames -contains $_.name })

# ============================ RELEASES ============================

Write-Host "[*] Fetching releases (this may take a moment)..." -ForegroundColor Cyan

$allReleases = @()
foreach ($repo in $pickedRepoObjs) {
    try {
        $rel = @(Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($repo.full_name)/releases?per_page=50" `
            -Headers $headers -Method Get -ErrorAction Stop)
    } catch {
        Write-Host "[!] $($repo.name): failed to fetch releases: $_" -ForegroundColor Yellow
        continue
    }
    $rel = @($rel | Where-Object { -not $_.draft })
    if (-not $IncludePrerelease) { $rel = @($rel | Where-Object { -not $_.prerelease }) }
    if ($rel.Count -eq 0) {
        Write-Host "[i] $($repo.name): no matching releases" -ForegroundColor DarkGray
        continue
    }
    if (-not $AllVersions) {
        $rel = @($rel[0])   # latest (API already sorts newest first)
    }
    foreach ($r in $rel) {
        $r | Add-Member -NotePropertyName '_repoName'  -NotePropertyValue $repo.name          -Force
        $r | Add-Member -NotePropertyName '_isPrivate' -NotePropertyValue ([bool]$repo.private) -Force
        $r | Add-Member -NotePropertyName '_fullName'  -NotePropertyValue $repo.full_name     -Force
    }
    $allReleases += $rel
}
if ($allReleases.Count -eq 0) {
    Write-Host "[!] None of the selected repositories have releases." -ForegroundColor Yellow
    Read-Host "Press Enter to exit" | Out-Null
    return
}

$releaseMenu = $allReleases | ForEach-Object {
    [PSCustomObject]@{
        Repository = $_._repoName
        Version    = $_.tag_name
        Title      = $_.name
        Date       = if ($_.published_at) { ([datetime]$_.published_at).ToString('yyyy-MM-dd') } else { '' }
        Files      = @($_.assets).Count
        Pre        = if ($_.prerelease) { 'Yes' } else { '' }
        Private    = if ($_._isPrivate) { 'Yes' } else { 'No' }
    }
}
$pickedReleases = $releaseMenu |
    Out-GridView -Title "Releases - select what to download (Ctrl for multiple) -> OK" -OutputMode Multiple
if (-not $pickedReleases) { Write-Host 'Nothing selected.'; return }

# Map back to release objects
$pickedKeys = $pickedReleases | ForEach-Object { "$($_.Repository)|$($_.Version)" }
$selectedReleaseObjs = @($allReleases | Where-Object { $pickedKeys -contains "$($_._repoName)|$($_.tag_name)" })

# ============================ FILES ============================

$currentOS = Get-CurrentOS
Write-Host "[i] Current OS: $currentOS" -ForegroundColor DarkGray

$assetRows = foreach ($rel in $selectedReleaseObjs) {
    foreach ($asset in @($rel.assets)) {
        [PSCustomObject]@{
            Repository = $rel._repoName
            Version    = $rel.tag_name
            File       = $asset.name
            OS         = Get-AssetPlatform $asset.name
            Size       = Format-Size $asset.size
            Downloads  = $asset.download_count
            # Technical fields - hidden from the menu, required for download
            _ApiUrl    = $asset.url
            _Browser   = $asset.browser_download_url
            _Size      = [long]$asset.size
            _Private   = [bool]$rel._isPrivate
            _RelPath   = "$($rel._repoName)/$($rel.tag_name)"
        }
    }
}
$assetRows = @($assetRows)

if ($assetRows.Count -eq 0) {
    Write-Host "[!] Selected releases have no attached files (source archives only)." -ForegroundColor Yellow
    Read-Host "Press Enter to exit" | Out-Null
    return
}

# Show native-OS assets first
$displayRows = $assetRows |
    Sort-Object -Property @{Expression={ if ($_.OS -eq $currentOS -or $_.OS -eq 'Any') { 0 } else { 1 } }},
                          @{Expression={ $_.Repository }}, @{Expression={ $_.Version }} |
    Select-Object Repository, Version, File, OS, Size, Downloads

if ($AllAssets) {
    $selectedAssets = $assetRows
} else {
    $pickedRows = $displayRows |
        Out-GridView -Title "Files - select what to download (Ctrl for multiple) -> OK" -OutputMode Multiple
    if (-not $pickedRows) { Write-Host 'Nothing selected.'; return }
    $pickedKeys = $pickedRows | ForEach-Object { "$($_.Repository)|$($_.Version)|$($_.File)" }
    $selectedAssets = @($assetRows | Where-Object {
        $pickedKeys -contains "$($_.Repository)|$($_.Version)|$($_.File)"
    })
}

# ============================ DOWNLOAD ============================

$userDir = Join-Path $BaseDir $TargetUser
if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }

$ok = 0; $fail = 0
foreach ($a in $selectedAssets) {
    $outDir  = Join-Path $userDir $a._RelPath
    $outPath = Join-Path $outDir  $a.File
    $done = Save-ReleaseAsset `
        -AssetName   $a.File `
        -AssetSize   $a._Size `
        -ApiUrl      $a._ApiUrl `
        -BrowserUrl  $a._Browser `
        -IsPrivate   $a._Private `
        -OutputPath  $outPath `
        -Token       $Token
    if ($done) { $ok++ } else { $fail++ }
}

Write-Host ""
Write-Host "[OK] Done. Succeeded: $ok, failed: $fail" -ForegroundColor Green
Write-Host "     Folder: $userDir" -ForegroundColor Green
Read-Host "Press Enter to exit" | Out-Null
