<#
    05-Archive.ps1
    Safe archive extraction (zip-slip safe, bomb limited) + executable discovery.
#>

$Global:GHL_MaxExtractBytes = 4GB
$Global:GHL_MaxExtractFiles = 60000

function Get-GhlArchiveKind {
    param([Parameter(Mandatory)][string]$Path)

    $n = $Path.ToLowerInvariant()
    if ($n.EndsWith('.zip')) { return 'zip' }
    if ($n.EndsWith('.tar.gz') -or $n.EndsWith('.tgz')) { return 'targz' }
    if ($n.EndsWith('.msi') -or $n.EndsWith('.exe')) { return 'none' }
    return 'unknown'
}

function Test-GhlSafePath {
    <# True when $Candidate stays inside $Root. #>
    param([string]$Root, [string]$Relative)

    if (-not $Relative) { return $false }
    if ($Relative -match '^[\\/]' -or $Relative -match '^[A-Za-z]:') { return $false }
    if ($Relative -match '(^|[\\/])\.\.([\\/]|$)') { return $false }

    try {
        $rootFull = [IO.Path]::GetFullPath($Root)
        if (-not $rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
            $rootFull += [IO.Path]::DirectorySeparatorChar
        }
        $target = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, $Relative))
        return $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Expand-GhlZip {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [object]$Sync
    )

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $destFull = [IO.Path]::GetFullPath($Destination)

    $zip = $null
    $count = 0
    $bytes = 0L

    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        $total = $zip.Entries.Count
        if ($total -gt $Global:GHL_MaxExtractFiles) {
            throw "Archive contains $total entries, which exceeds the $($Global:GHL_MaxExtractFiles) entry limit."
        }

        foreach ($entry in $zip.Entries) {
            if ($Sync -and $Sync.CancelRequested) { throw 'CANCELLED' }

            $rel = $entry.FullName -replace '\\', '/'
            if (-not (Test-GhlSafePath -Root $destFull -Relative $rel)) {
                throw "Archive entry rejected for unsafe path: $($entry.FullName)"
            }

            $target = [IO.Path]::Combine($destFull, $rel)

            if ([string]::IsNullOrEmpty($entry.Name) -and $rel.EndsWith('/')) {
                if (-not (Test-Path -LiteralPath $target)) {
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                }
                continue
            }

            $parent = Split-Path -Parent $target
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            $count++
            $bytes += $entry.Length

            if ($bytes -gt $Global:GHL_MaxExtractBytes) {
                throw "Archive expands beyond the $([Math]::Round($Global:GHL_MaxExtractBytes / 1GB, 1)) GB safety limit."
            }

            if ($Sync -and $total -gt 0) {
                $Sync.ProgressPercent = [Math]::Min(100.0, ($count / $total) * 100.0)
                $Sync.StatusText = 'Extracting {0} / {1} files' -f $count, $total
            }
        }
    } finally {
        if ($zip) { $zip.Dispose() }
    }

    return $count
}

function Expand-GhlTarGz {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [object]$Sync
    )

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw 'tar.exe is not available on this system (Windows 10 1803 or newer is required to extract .tar.gz archives).'
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    # 1) validate member names before touching the disk
    $listing = & $tar.Source -tf $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "The .tar.gz archive could not be read: $listing"
    }
    $members = @($listing | ForEach-Object { [string]$_ })
    if ($members.Count -gt $Global:GHL_MaxExtractFiles) {
        throw "Archive contains $($members.Count) entries, which exceeds the entry limit."
    }
    foreach ($m in $members) {
        if ($m -match '(^|[\\/])\.\.([\\/]|$)' -or $m -match '^[\\/]' -or $m -match '^[A-Za-z]:') {
            throw "Archive member rejected for unsafe path: $m"
        }
    }

    if ($Sync) { $Sync.StatusText = 'Extracting archive...'; $Sync.ProgressPercent = -1.0 }

    $output = & $tar.Source -xf $Path -C $Destination 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Extraction failed: $output"
    }

    return $members.Count
}

function Move-GhlContentsUp {
    <#
        Archives from GitHub wrap everything in "repo-branch/".
        If the destination now has exactly one folder and nothing else, unwrap it.
    #>
    param([Parameter(Mandatory)][string]$Destination)

    try {
        $items = @(Get-ChildItem -LiteralPath $Destination -Force |
            Where-Object { $_.Name -ne $Global:GHL_MarkerName })
        if ($items.Count -ne 1) { return $false }
        if (-not $items[0].PSIsContainer) { return $false }

        $inner = $items[0].FullName
        $children = @(Get-ChildItem -LiteralPath $inner -Force)
        foreach ($child in $children) {
            Move-Item -LiteralPath $child.FullName -Destination $Destination -Force
        }
        Remove-Item -LiteralPath $inner -Force -Recurse -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-GhlLog "Could not unwrap archive root: $($_.Exception.Message)" Warn
        return $false
    }
}

function Expand-GhlArchive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [object]$Sync
    )

    $kind = Get-GhlArchiveKind -Path $Path
    $result = switch ($kind) {
        'zip' { Expand-GhlZip -Path $Path -Destination $Destination -Sync $Sync }
        'targz' { Expand-GhlTarGz -Path $Path -Destination $Destination -Sync $Sync }
        default { throw "Unsupported archive type: $(Split-Path -Leaf $Path)" }
    }

    [void](Move-GhlContentsUp -Destination $Destination)
    return $result
}

# ---------------------------------------------------------------------------
# Executable discovery
# ---------------------------------------------------------------------------

function Find-GhlExecutables {
    <#
        Returns runnable candidates found under $Root, best first.
        Each item: Name, FullPath, RelativePath, Size, SizeText, Score.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RepoName = '',
        [switch]$IncludeScripts
    )

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    $exts = @('.exe', '.msi')
    if ($IncludeScripts) { $exts += @('.ps1', '.bat', '.cmd') }

    try {
        $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLowerInvariant() }
    } catch {
        return @()
    }

    $bad = @('unins', 'uninstall', 'setup_', 'report', 'crash', 'updater', 'del ', 'helper', 'elevate', 'vcredist',
        'dotnet', 'dxsetup', 'vc_redist')

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        $depth = ($rel -split '[\\/]').Count - 1
        $base = [IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()

        $score = 100
        $score -= ($depth * 12)

        if ($RepoName -and $base -eq $RepoName.ToLowerInvariant()) { $score += 60 }
        if ($base -match 'setup|install') { $score += 25 }
        if ($base -match 'launcher|start|run|app|main') { $score += 18 }
        if ($f.Extension -eq '.exe') { $score += 10 }
        if ($f.Name -match 'x64|amd64') { $score += 4 }
        if ($f.Name -match 'arm64|armhf') { $score -= 30 }
        if ($f.Name -match 'ia32|x86|win32|32bit') { $score -= 6 }
        if ($f.Name -match 'debug|test|sample|example|benchmark') { $score -= 45 }
        foreach ($b in $bad) { if ($base -like "*$b*") { $score -= 70; break } }
        if ($f.Length -lt 4KB) { $score -= 15 }

        $out.Add([pscustomobject]@{
            Name         = $f.Name
            FullPath     = $f.FullName
            RelativePath = $rel
            Size         = $f.Length
            SizeText     = (Format-GhlSize $f.Length)
            Extension    = $f.Extension.ToLowerInvariant()
            Score        = $score
        })
    }

    return @($out | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'RelativePath'; Descending = $false })
}
