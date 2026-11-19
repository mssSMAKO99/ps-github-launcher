<#
    07-Workers.ps1
    Script text executed inside the RunspacePool. Workers never touch WPF -
    they publish plain-data events into $Sync.Events and let the UI thread
    render them.
#>

function Get-GhlWorkerPreamble {
    <# Constants + helpers every worker needs, resolved at pool-build time. #>
    return @"
`$Global:GHL_ApiBase = '$($Global:GHL_ApiBase)'
`$Global:GHL_UserAgent = '$($Global:GHL_UserAgent)'
`$Global:GHL_MarkerName = '$($Global:GHL_MarkerName)'
`$Global:GHL_MaxExtractBytes = [long]$($Global:GHL_MaxExtractBytes)
`$Global:GHL_MaxExtractFiles = [int]$($Global:GHL_MaxExtractFiles)
`$Global:GHL_DebugLog = `$$([bool]$Global:GHL_DebugLog)
`$ErrorActionPreference = 'Stop'

function Get-GhlFailureInfo {
    param(`$ErrorRecord)
    `$msg = 'Unexpected error.'
    `$kind = 'exception'
    try {
        if (`$ErrorRecord.Exception) {
            `$msg = `$ErrorRecord.Exception.Message
            if (`$ErrorRecord.Exception.Data -and `$ErrorRecord.Exception.Data['Kind']) {
                `$kind = [string]`$ErrorRecord.Exception.Data['Kind']
            }
        } else {
            `$msg = [string]`$ErrorRecord
        }
    } catch { }
    if (`$msg -eq 'CANCELLED') { `$kind = 'cancelled' }
    return [pscustomobject]@{ Message = `$msg; Kind = `$kind }
}
"@
}

function Get-GhlWorkerRepos {
    return @'

param($Sync, $User, $Token)

try {
    $Sync.Phase = 'repos'
    $Sync.StatusText = "Loading repositories of $User..."
    $Sync.ProgressPercent = -1.0

    $r = Get-GhlUserRepos -User $User -Token $Token

    $resetAt = ''
    if ($r.ResetAt) { $resetAt = ([DateTime]$r.ResetAt).ToString('o') }

    $Sync.Events.Enqueue(@{
        Kind      = 'Repos'
        Ok        = [bool]$r.Ok
        Data      = $r.Data
        Message   = [string]$r.Message
        ErrKind   = [string]$r.Kind
        Remaining = [int]$r.Remaining
        ResetAt   = $resetAt
        User      = [string]$User
    })
} catch {
    $info = Get-GhlFailureInfo $_
    $Sync.Events.Enqueue(@{
        Kind = 'Repos'; Ok = $false; Data = $null
        Message = $info.Message; ErrKind = $info.Kind; Remaining = -1; User = [string]$User
    })
}
'@
}

function Get-GhlWorkerRelease {
    return @'

param($Sync, $User, $Repo, $Token, [bool]$IncludePrerelease)

try {
    $Sync.Phase = 'release'
    $Sync.StatusText = "Loading releases of $Repo..."
    $Sync.ProgressPercent = -1.0

    $r = Get-GhlLatestRelease -User $User -Repo $Repo -Token $Token -IncludePrerelease:$IncludePrerelease

    $Sync.Events.Enqueue(@{
        Kind    = 'Release'
        Ok      = [bool]$r.Ok
        Data    = $r.Data
        Message = [string]$r.Message
        ErrKind = [string]$r.Kind
        User    = [string]$User
        Repo    = [string]$Repo
    })
} catch {
    $info = Get-GhlFailureInfo $_
    $Sync.Events.Enqueue(@{
        Kind = 'Release'; Ok = $false; Data = $null
        Message = $info.Message; ErrKind = $info.Kind
        User = [string]$User; Repo = [string]$Repo
    })
}
'@
}

function Get-GhlWorkerDownload {
    return @'

param($Sync, $Job)

$dest = [string]$Job.DestDir
$mode = [string]$Job.Mode
$fileName = [string]$Job.FileName

try {
    if (-not (Test-Path -LiteralPath $dest)) {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
    }

    # batch mode passes no Url: resolve the best Windows asset for this repo here,
    # inside the worker, so the UI thread never waits on the API
    if (-not $Job.Url) {
        $Sync.Phase = 'release'
        $Sync.StatusText = "Resolving $($Job.Repo)..."

        if ($mode -eq 'Source') {
            $src = New-GhlSourceArchive -User $Job.User -Repo $Job.Repo
            $Job.Url = $src.Url
            $fileName = $src.FileName
        } else {
            $rel = Get-GhlLatestRelease -User $Job.User -Repo $Job.Repo -Token $Job.Token `
                -IncludePrerelease:([bool]$Job.IncludePrerelease)

            if (-not $rel.Ok -and $rel.Kind -eq 'norelease') {
                # no release at all: fall back to the source archive
                $mode = 'Source'
                $Job.Mode = 'Source'
                $src = New-GhlSourceArchive -User $Job.User -Repo $Job.Repo
                $Job.Url = $src.Url
                $fileName = $src.FileName
            } elseif (-not $rel.Ok) {
                throw ($rel.Message)
            } else {
                $best = $null
                $bestScore = [int]::MinValue
                foreach ($a in @($rel.Data.Assets)) {
                    if (-not $a.Compatible) { continue }
                    if ([int]$a.Score -gt $bestScore) { $bestScore = [int]$a.Score; $best = $a }
                }
                if (-not $best) {
                    $ex = New-Object System.Exception("No Windows-compatible asset in $($rel.Data.Tag).")
                    $ex.Data['Kind'] = 'noasset'
                    throw $ex
                }
                $Job.Url = [string]$best.Url
                $fileName = [string]$best.Name
                $Job.Tag = [string]$rel.Data.Tag

                try {
                    $tempDir = Join-Path $env:TEMP ('ghl-cs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
                    $Job.Checksums = Get-GhlPublishedChecksums -Release $rel.Data -Token $Job.Token -TempDir $tempDir
                    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                } catch { }
            }
        }
    }

    # archives are staged outside the repository folder: a copy sitting next to
    # the extracted tree would break the "unwrap the single root folder" step
    $kind = Get-GhlArchiveKind -Path $fileName
    $isArchive = ($kind -eq 'zip' -or $kind -eq 'targz')

    if ($isArchive) {
        $staging = Join-Path (Join-Path $env:LOCALAPPDATA 'GitHubLauncher\tmp') ([guid]::NewGuid().ToString('N').Substring(0, 12))
        if (-not (Test-Path -LiteralPath $staging)) {
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
        }
        $target = Join-Path $staging $fileName
    } else {
        $target = Join-Path $dest $fileName
    }

    $Sync.Phase = 'downloading'
    $Sync.ProgressPercent = 0.0
    $Sync.StatusText = "Downloading $fileName"

    $dl = Invoke-GhlDownload -Url $Job.Url -OutFile $target -Token $Job.Token -Sync $Sync

    $Sync.ProgressPercent = -1.0
    $Sync.SpeedBps = 0.0

    # provenance: mark the file as downloaded and, when the release publishes
    # checksums, refuse to continue if the hash does not match
    [void](Set-GhlMarkOfTheWeb -Path $target -SourceUrl ([string]$Job.Url))

    $hashNote = ''
    if ($Job.Checksums -and $Job.Checksums.Entries) {
        $expected = Get-GhlExpectedHash -Checksums $Job.Checksums -FileName $fileName
        if ($expected) {
            if (-not (Test-GhlHashMatches -Path $target -Expected $expected)) {
                $ex = New-Object System.Exception(
                    "Checksum mismatch for $fileName - the download does not match $($Job.Checksums.Name).")
                $ex.Data['Kind'] = 'hashmismatch'
                throw $ex
            }
            $hashNote = $expected
            $Sync.StatusText = "Checksum verified for $fileName"
        }
    }

    $exePath = ''
    $candidates = @()

    if ($isArchive) {
        $Sync.Phase = 'extracting'
        $Sync.StatusText = 'Extracting archive...'
        $Sync.ProgressPercent = -1.0

        [void](Expand-GhlArchive -Path $target -Destination $dest -Sync $Sync)

        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
        $container = Split-Path -Parent $target
        if ($container -and (Test-Path -LiteralPath $container)) {
            try { Remove-Item -LiteralPath $container -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }

        $candidates = @(Find-GhlExecutables -Root $dest -RepoName ([string]$Job.Repo) -IncludeScripts)

        # the archive sat in a temporary folder; what the user will actually run
        # are the extracted files, so those are the ones that get marked
        foreach ($file in @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in @('.exe', '.msi', '.ps1', '.bat', '.cmd') })) {
            [void](Set-GhlMarkOfTheWeb -Path $file.FullName -SourceUrl ([string]$Job.Url))
        }
    } else {
        $candidates = @(Find-GhlExecutables -Root $dest -RepoName ([string]$Job.Repo) -IncludeScripts |
            Where-Object { $_.FullPath -eq $target })
        if ($candidates.Count -eq 0 -and (Test-Path -LiteralPath $target)) {
            $fi = Get-Item -LiteralPath $target
            $candidates = @([pscustomobject]@{
                Name = $fi.Name; FullPath = $fi.FullName; RelativePath = $fi.Name
                Size = $fi.Length; SizeText = (Format-GhlSize $fi.Length)
                Extension = $fi.Extension.ToLowerInvariant(); Score = 100
            })
        }
    }

    # remember a fixed launch target per repository
    $markerPath = Join-Path $dest $Global:GHL_MarkerName
    $remembered = ''
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $old = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.Executable -and $candidates.Count -gt 1) {
                $hit = $candidates | Where-Object { $_.RelativePath -eq $old.Executable } | Select-Object -First 1
                if ($hit) { $candidates = @($hit) + @($candidates | Where-Object { $_.RelativePath -ne $hit.RelativePath }) }
            }
        } catch { }
    }

    if ($candidates.Count -gt 0) { $exePath = [string]$candidates[0].RelativePath }

    $files = @(Get-GhlRepoFileList -Directory $dest)
    [void](Set-GhlMarker -Directory $dest -User ([string]$Job.User) -Repo ([string]$Job.Repo) `
            -Mode $mode -Tag ([string]$Job.Tag) -Executable $exePath -Files $files)

    $Sync.Events.Enqueue(@{
        Kind        = 'Download'
        Ok          = $true
        DestDir     = $dest
        Candidates  = $candidates
        Primary     = $exePath
        Mode        = $mode
        Tag         = [string]$Job.Tag
        Repo        = [string]$Job.Repo
        User        = [string]$Job.User
        Bytes       = $dl.Bytes
        AutoRun     = [bool]$Job.AutoRun
        Hash        = $hashNote
    })
} catch {
    $info = Get-GhlFailureInfo $_

    $Sync.Events.Enqueue(@{
        Kind      = 'Download'
        Ok        = $false
        DestDir   = $dest
        Message   = $info.Message
        ErrKind   = $info.Kind
        Repo      = [string]$Job.Repo
        User      = [string]$Job.User
    })
}
'@
}

function Get-GhlWorkerBackground {
    <# Downloads a background image URL into the local cache. #>
    return @'

param($Sync, $Url, $OutFile)

try {
    $Sync.Phase = 'background'
    $Sync.StatusText = 'Fetching background image...'
    $Sync.ProgressPercent = -1.0
    [void](Invoke-GhlDownload -Url $Url -OutFile $OutFile -Sync $Sync)
    $Sync.Events.Enqueue(@{ Kind = 'Background'; Ok = $true; Path = $OutFile; Source = $Url })
} catch {
    $info = Get-GhlFailureInfo $_
    $Sync.Events.Enqueue(@{ Kind = 'Background'; Ok = $false; Message = $info.Message; ErrKind = $info.Kind; Source = $Url })
}
'@
}

function Join-GhlWorkerScript {
    <#
        Composes the final text for a runspace pipeline.
        A param() block is only legal as the very first statement, so it has to
        be hoisted above the shared preamble.
    #>
    param([Parameter(Mandatory)][string]$Body)

    $lines = $Body -replace "`r`n", "`n" -split "`n"

    $index = 0
    while ($index -lt $lines.Count -and $lines[$index].Trim() -eq '') { $index++ }

    $paramLine = ''
    if ($index -lt $lines.Count -and $lines[$index].TrimStart().StartsWith('param(')) {
        $paramLine = $lines[$index].Trim()
        $index++
    }

    $rest = $lines[$index..($lines.Count - 1)] -join "`r`n"
    return ($paramLine + "`r`n" + (Get-GhlWorkerPreamble) + "`r`n" + $rest)
}

function Get-GhlWorkerNames {    return @(
        'Get-GhlUserRepos', 'Get-GhlRepoInfo', 'Get-GhlLatestRelease', 'Get-GhlReleaseList',
        'Invoke-GhlApi', 'Invoke-GhlHttp', 'Invoke-GhlDownload',
        'New-GhlApiResult', 'New-GhlSourceArchive', 'New-GhlError',
        'Convert-GhlRepo', 'Convert-GhlRelease', 'Convert-GhlAsset', 'Convert-GhlResetTime',
        'Test-GhlAssetCompatible', 'Get-GhlAssetScore', 'Get-GhlErrorMessage',
        'Expand-GhlArchive', 'Expand-GhlZip', 'Expand-GhlTarGz', 'Move-GhlContentsUp',
        'Get-GhlArchiveKind', 'Test-GhlSafePath', 'Find-GhlExecutables',
        'Stop-GhlPartialFile',
        'Get-GhlRepoDir', 'Get-GhlMarkerPath', 'Set-GhlMarker', 'Read-GhlMarker',
        'Get-GhlRepoFileList', 'Get-GhlRepoState', 'ConvertTo-GhlSafeName',
        'Start-GhlItem', 'Open-GhlFolder',
        'Write-GhlLog', 'Format-GhlSize', 'Format-GhlDuration', 'Get-GhlFreeSpace',
        'Get-GhlAppDir',
        'Set-GhlMarkOfTheWeb', 'Get-GhlFileSignature', 'Get-GhlPublishedChecksums',
        'Test-GhlHashMatches', 'Get-GhlExpectedHash'
    )
}
