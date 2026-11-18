#Requires -Version 5.1
<#
.SYNOPSIS
    Console-only universal GitHub Releases downloader.
.DESCRIPTION
    Enter a username -> pick repositories by number -> pick releases -> pick files.
    Downloads the actual release assets (exe/msi/zip/dmg/AppImage etc.).

    Token is only needed for private repos. Sources (in priority order):
      1) -Token parameter
      2) $env:GITHUB_TOKEN
      3) token.txt next to the script

.PARAMETER DefaultUser
    Default GitHub username.
.PARAMETER BaseDir
    Download directory. Defaults to ~/GitHubReleases.
.PARAMETER Token
    GitHub PAT (classic or fine-grained).
.PARAMETER AllVersions
    Show all versions instead of only the latest.
.PARAMETER IncludePrerelease
    Include beta/rc releases.
.PARAMETER AllAssets
    Skip the file picker; download everything from the selected releases.

.EXAMPLE
    .\Github-Releases-Launcher.ps1 -DefaultUser vlc
.EXAMPLE
    .\Github-Releases-Launcher.ps1 -DefaultUser notepad-plus-plus -AllVersions
#>
param(
    [string]$DefaultUser = "YOUR_GITHUB_USERNAME",
    [string]$BaseDir     = (Join-Path $HOME "GitHubReleases"),
    [string]$Token       = "",
    [switch]$AllVersions,
    [switch]$IncludePrerelease,
    [switch]$AllAssets
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ============================ HELPERS ============================

function Get-FlatArray {
    # Flattens accidental single-level array wrapping that PS 5.1 sometimes
    # introduces with @(Invoke-RestMethod ...). Prevents member enumeration
    # in ForEach-Object ($_.name returning an array of names, which is what
    # makes all repos show up in one cell / one comma-separated line).
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    $arr = @($InputObject)
    while ($arr.Count -eq 1 -and $arr[0] -is [System.Array]) { $arr = @($arr[0]) }
    return $arr
}

function Get-Truncated {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    $Text = $Text -replace '\s+', ' '
    if ($Text.Length -gt $Max) {
        if ($Max -le 3) { return $Text.Substring(0, $Max) }
        return $Text.Substring(0, $Max - 3) + '...'
    }
    return $Text
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-AssetPlatform {
    param([string]$Name)
    if (-not $Name) { return 'Any' }
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
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'Windows' }
    if ($IsWindows) { return 'Windows' }
    if ($IsLinux)   { return 'Linux' }
    if ($IsMacOS)   { return 'macOS' }
    return 'Any'
}

function Read-MultiSelect {
    # Returns an array of 1-based indices, or $null on cancel/quit.
    param(
        [int]$Max,
        [string]$Prompt = "Select (e.g. 1,3,5-7 / 'a'=all / empty=cancel)"
    )
    while ($true) {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $raw = $raw.Trim().ToLowerInvariant()
        if ($raw -eq 'q' -or $raw -eq 'quit') { return $null }
        if ($raw -eq 'a' -or $raw -eq 'all')   { return @(1..$Max) }

        $acc  = New-Object System.Collections.Generic.List[int]
        $ok   = $true
        foreach ($part in ($raw -split ',')) {
            $part = $part.Trim()
            if ($part -match '^(\d+)$') {
                $n = [int]$Matches[1]
                if ($n -ge 1 -and $n -le $Max) { $acc.Add($n) } else { $ok = $false; break }
            } elseif ($part -match '^(\d+)\s*-\s*(\d+)$') {
                $a = [int]$Matches[1]; $b = [int]$Matches[2]
                if ($a -ge 1 -and $b -le $Max -and $a -le $b) {
                    for ($i = $a; $i -le $b; $i++) { $acc.Add($i) }
                } else { $ok = $false; break }
            } else { $ok = $false; break }
        }
        if ($ok -and $acc.Count -gt 0) {
            return @($acc | Sort-Object -Unique)
        }
        Write-Host "  Invalid selection. Try again or press Enter to cancel." -ForegroundColor Red
    }
}

function Save-ReleaseAsset {
    param(
        [string]$Name,
        [long]$Size,
        [string]$ApiUrl,
        [string]$BrowserUrl,
        [bool]$IsPrivate,
        [string]$OutputPath,
        [string]$Token,
        [string]$CurlExe
    )
    if ((Test-Path $OutputPath) -and ((Get-Item $OutputPath).Length -eq $Size)) {
        Write-Host "  [=] $Name - already present, skipping" -ForegroundColor DarkGray
        return $true
    }
    $dir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $suffix = if ($Size -gt 0) { " ($(Format-Size $Size))" } else { "" }
    Write-Host "  [v] $Name$suffix" -ForegroundColor Cyan

    # Public: direct browser URL, no auth.
    if (-not $IsPrivate -and $BrowserUrl) {
        try {
            Invoke-WebRequest -Uri $BrowserUrl -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
            Write-Host "  [OK] $Name" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "  [!] $Name : $_" -ForegroundColor Red
            return $false
        }
    }

    # Private: API URL + Accept: octet-stream.
    # Prefer curl so the Authorization header is not forwarded to objects.githubusercontent.com
    # during the cross-host redirect (Invoke-WebRequest 5.1 gets 403 there).
    if ($CurlExe) {
        $args = @('-L', '--fail', '--retry', '3', '--retry-delay', '2',
                  '-o', $OutputPath,
                  '-H', 'Accept: application/octet-stream',
                  '-H', 'User-Agent: PS-GH-Releases-Launcher')
        if ($Token) { $args += @('-H', "Authorization: Bearer $Token") }
        $args += $ApiUrl
        & $CurlExe @args
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] $Name" -ForegroundColor Green
            return $true
        }
        Write-Host "  [!] curl exited with $LASTEXITCODE for $Name" -ForegroundColor Red
        return $false
    }

    # Fallback: IWR (may fail on PS 5.1 for private assets due to auth-on-redirect).
    $headers = @{
        'Accept'     = 'application/octet-stream'
        'User-Agent' = 'PS-GH-Releases-Launcher'
    }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    try {
        Invoke-WebRequest -Uri $ApiUrl -Headers $headers -OutFile $OutputPath -UseBasicParsing -ErrorAction Stop
        Write-Host "  [OK] $Name" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [!] $Name : $_" -ForegroundColor Red
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

$curlExe = $null
foreach ($c in @('curl.exe', 'curl')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { $curlExe = $cmd.Source; break }
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
    $repos = Get-FlatArray (Invoke-RestMethod -Uri $repoApi -Headers $headers -Method Get -ErrorAction Stop)
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

Write-Host ""
Write-Host ("{0,4}  {1,-30}  {2,6}  {3,-7}  {4}" -f '#', 'REPOSITORY', 'STARS', 'PRIVATE', 'DESCRIPTION') -ForegroundColor Cyan
Write-Host ('-' * 100) -ForegroundColor DarkGray
for ($i = 0; $i -lt $repos.Count; $i++) {
    $r    = $repos[$i]
    $priv = if ($r.private) { 'yes' } else { '' }
    $desc = Get-Truncated $r.description 55
    Write-Host ("{0,4}  {1,-30}  {2,6}  {3,-7}  {4}" -f `
        ($i + 1), (Get-Truncated $r.name 30), $r.stargazers_count, $priv, $desc)
}
Write-Host ""

$repoIdx = Read-MultiSelect -Max $repos.Count -Prompt "Repositories (e.g. 1,3,5-7 / 'a'=all / empty=cancel)"
if (-not $repoIdx) { Write-Host "Nothing selected."; return }

$pickedRepos = @($repoIdx | ForEach-Object { $repos[$_ - 1] })

# ============================ RELEASES ============================

Write-Host "[*] Fetching releases..." -ForegroundColor Cyan

$allReleases = @()
foreach ($repo in $pickedRepos) {
    try {
        $rel = Get-FlatArray (Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($repo.full_name)/releases?per_page=50" `
            -Headers $headers -Method Get -ErrorAction Stop)
    } catch {
        Write-Host "[!] $($repo.name): $_" -ForegroundColor Yellow
        continue
    }
    $rel = @($rel | Where-Object { -not $_.draft })
    if (-not $IncludePrerelease) { $rel = @($rel | Where-Object { -not $_.prerelease }) }
    if ($rel.Count -eq 0) {
        Write-Host "[i] $($repo.name): no matching releases" -ForegroundColor DarkGray
        continue
    }
    if (-not $AllVersions) { $rel = @($rel[0]) }
    foreach ($r in $rel) {
        $r | Add-Member -NotePropertyName '_repoName'  -NotePropertyValue $repo.name          -Force
        $r | Add-Member -NotePropertyName '_isPrivate' -NotePropertyValue ([bool]$repo.private) -Force
    }
    $allReleases += $rel
}
if ($allReleases.Count -eq 0) {
    Write-Host "[!] No releases available for the selected repositories." -ForegroundColor Yellow
    Read-Host "Press Enter to exit" | Out-Null
    return
}

Write-Host ""
Write-Host ("{0,4}  {1,-22}  {2,-18}  {3,-10}  {4,5}  {5,-3}  {6}" -f `
    '#', 'REPOSITORY', 'VERSION', 'DATE', 'FILES', 'PRE', 'TITLE') -ForegroundColor Cyan
Write-Host ('-' * 110) -ForegroundColor DarkGray
for ($i = 0; $i -lt $allReleases.Count; $i++) {
    $r     = $allReleases[$i]
    $date  = if ($r.published_at) { ([datetime]$r.published_at).ToString('yyyy-MM-dd') } else { '' }
    $files = @($r.assets).Count
    $pre   = if ($r.prerelease) { 'pre' } else { '' }
    Write-Host ("{0,4}  {1,-22}  {2,-18}  {3,-10}  {4,5}  {5,-3}  {6}" -f `
        ($i + 1),
        (Get-Truncated $r._repoName 22),
        (Get-Truncated $r.tag_name  18),
        $date, $files, $pre,
        (Get-Truncated $r.name 40))
}
Write-Host ""

$relIdx = Read-MultiSelect -Max $allReleases.Count -Prompt "Releases (e.g. 1,3,5-7 / 'a'=all / empty=cancel)"
if (-not $relIdx) { Write-Host "Nothing selected."; return }

$selectedReleases = @($relIdx | ForEach-Object { $allReleases[$_ - 1] })

# ============================ ASSETS ============================

$currentOS = Get-CurrentOS
Write-Host "[i] Current OS: $currentOS" -ForegroundColor DarkGray

$flatAssets = @()
foreach ($rel in $selectedReleases) {
    foreach ($asset in (Get-FlatArray $rel.assets)) {
        $flatAssets += [PSCustomObject]@{
            Repo     = $rel._repoName
            Version  = $rel.tag_name
            Name     = $asset.name
            Size     = [long]$asset.size
            ApiUrl   = $asset.url
            Browser  = $asset.browser_download_url
            Private  = [bool]$rel._isPrivate
            Platform = Get-AssetPlatform $asset.name
        }
    }
}

if ($flatAssets.Count -eq 0) {
    Write-Host "[!] Selected releases have no attached files." -ForegroundColor Yellow
    Read-Host "Press Enter to exit" | Out-Null
    return
}

# Native platform first, then by repo/version/name
$flatAssets = @($flatAssets | Sort-Object `
    @{Expression={ if ($_.Platform -eq $currentOS -or $_.Platform -eq 'Any') {0} else {1} }},
    @{Expression={ $_.Repo }}, @{Expression={ $_.Version }}, @{Expression={ $_.Name }})

Write-Host ""
Write-Host ("{0,4}  {1,-18}  {2,-10}  {3,-40}  {4,-8}  {5,10}" -f `
    '#', 'REPOSITORY', 'VERSION', 'FILE', 'OS', 'SIZE') -ForegroundColor Cyan
Write-Host ('-' * 100) -ForegroundColor DarkGray
for ($i = 0; $i -lt $flatAssets.Count; $i++) {
    $a    = $flatAssets[$i]
    $os   = if ($a.Platform -eq $currentOS -or $a.Platform -eq 'Any') { "*$($a.Platform)" } else { $a.Platform }
    Write-Host ("{0,4}  {1,-18}  {2,-10}  {3,-40}  {4,-8}  {5,10}" -f `
        ($i + 1),
        (Get-Truncated $a.Repo 18),
        (Get-Truncated $a.Version 10),
        (Get-Truncated $a.Name 40),
        $os,
        (Format-Size $a.Size))
}
Write-Host ""

if ($AllAssets) {
    Write-Host "[i] -AllAssets: selecting every file." -ForegroundColor DarkGray
    $selectedAssets = $flatAssets
} else {
    $assetIdx = Read-MultiSelect -Max $flatAssets.Count -Prompt "Files (e.g. 1,3,5-7 / 'a'=all / empty=cancel)"
    if (-not $assetIdx) { Write-Host "Nothing selected."; return }
    $selectedAssets = @($assetIdx | ForEach-Object { $flatAssets[$_ - 1] })
}

# ============================ PRE-FLIGHT ============================

$totalSize = ($selectedAssets | Measure-Object -Property Size -Sum).Sum
Write-Host ""
Write-Host ("[*] Downloading {0} file(s), total {1}" -f $selectedAssets.Count, (Format-Size $totalSize)) -ForegroundColor Cyan

$privateWithoutToken = @($selectedAssets | Where-Object { $_.Private -and -not $Token })
if ($privateWithoutToken.Count -gt 0) {
    Write-Host ("[!] {0} private asset(s) selected but no token provided. They will fail." -f $privateWithoutToken.Count) -ForegroundColor Yellow
    $cont = Read-Host "Continue anyway? [y/N]"
    if ($cont -notmatch '^[yY]') { return }
}

# ============================ DOWNLOAD ============================

$userDir = Join-Path $BaseDir $TargetUser
if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }

$ok = 0; $fail = 0
foreach ($a in $selectedAssets) {
    $outDir  = Join-Path $userDir (Join-Path $a.Repo $a.Version)
    $outPath = Join-Path $outDir  $a.Name
    $done = Save-ReleaseAsset `
        -Name       $a.Name `
        -Size       $a.Size `
        -ApiUrl     $a.ApiUrl `
        -BrowserUrl $a.Browser `
        -IsPrivate  $a.Private `
        -OutputPath $outPath `
        -Token      $Token `
        -CurlExe    $curlExe
    if ($done) { $ok++ } else { $fail++ }
}

Write-Host ""
Write-Host "[OK] Done. Succeeded: $ok, failed: $fail" -ForegroundColor Green
Write-Host "     Folder: $userDir" -ForegroundColor Green
Read-Host "Press Enter to exit" | Out-Null
