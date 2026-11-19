<#
    06-Launcher.ps1
    Target folder layout, download state tracking, process launching.
#>

$Global:GHL_MarkerName = '.ghl.json'

function ConvertTo-GhlSafeName {
    param([string]$Name, [string]$Fallback = 'repo')

    if (-not $Name) { return $Fallback }
    $safe = $Name -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safe = $safe.Trim().TrimEnd('.')
    if (-not $safe) { return $Fallback }
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    return $safe
}

function Get-GhlRepoDir {
    <# {BaseDir}\{User}\{Repo} #>
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Repo
    )

    $u = ConvertTo-GhlSafeName -Name $User -Fallback 'unknown'
    $r = ConvertTo-GhlSafeName -Name $Repo -Fallback 'repo'
    return (Join-Path (Join-Path $BaseDir $u) $r)
}

function Get-GhlMarkerPath {
    param([Parameter(Mandatory)][string]$Directory)
    return (Join-Path $Directory $Global:GHL_MarkerName)
}

function Read-GhlMarker {
    param([Parameter(Mandatory)][string]$Directory)

    $path = Get-GhlMarkerPath -Directory $Directory
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-GhlLog "Marker in '$Directory' is unreadable: $($_.Exception.Message)" Warn
        return $null
    }
}

function Set-GhlMarker {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Mode = '',
        [string]$Tag = '',
        [string]$Executable = '',
        [string[]]$Files = @()
    )

    $marker = [ordered]@{
        Version      = 1
        User         = $User
        Repo         = $Repo
        Mode         = $Mode
        Tag          = $Tag
        DownloadedAt = (Get-Date).ToString('o')
        Executable   = $Executable
        Files        = @($Files | Select-Object -First 300)
    }

    $path = Get-GhlMarkerPath -Directory $Directory
    try {
        $json = $marker | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-GhlLog "Could not write marker in '$Directory': $($_.Exception.Message)" Warn
        return $false
    }
}

function Get-GhlRepoState {
    <#
        Returns @{ State = 'NotFound' | 'Partial' | 'Downloaded'; Files; Marker; Directory }
        'Downloaded' requires a marker written after a successful, verified download.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Repo
    )

    $dir = Get-GhlRepoDir -BaseDir $BaseDir -User $User -Repo $Repo
    $result = @{
        State     = 'NotFound'
        Directory = $dir
        Files     = 0
        Marker    = $null
    }

    if (-not (Test-Path -LiteralPath $dir)) { return $result }

    try {
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $Global:GHL_MarkerName })
        $result.Files = $files.Count
    } catch {
        $result.Files = 0
    }

    $marker = Read-GhlMarker -Directory $dir
    if ($marker) {
        $result.Marker = $marker
        # marker present but everything deleted by hand -> stale
        if ($result.Files -gt 0) {
            $result.State = 'Downloaded'
            return $result
        }
        $result.State = 'Partial'
        return $result
    }

    if ($result.Files -gt 0) { $result.State = 'Partial' }
    return $result
}

function Get-GhlRepoStatusText {
    param([string]$State)

    switch ($State) {
        'Downloaded' { 'Downloaded' }
        'Partial'    { 'Partial' }
        'Error'      { 'Error' }
        default      { 'Not downloaded' }
    }
}

function Get-GhlRepoBadge {
    <#
        Cheap status probe used to paint the list (no recursive scan).
        Returns 'Downloaded' | 'Partial' | 'Not downloaded'.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Repo
    )

    $dir = Get-GhlRepoDir -BaseDir $BaseDir -User $User -Repo $Repo
    if (-not (Test-Path -LiteralPath $dir)) { return 'Not downloaded' }

    if (Test-Path -LiteralPath (Get-GhlMarkerPath -Directory $dir)) { return 'Downloaded' }

    try {
        $any = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $Global:GHL_MarkerName } |
            Select-Object -First 1
        if ($any) { return 'Partial' }
    } catch { }

    return 'Not downloaded'
}

function Open-GhlFolder {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Folder does not exist: $Path"
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop | Out-Null
}

function Start-GhlItem {
    <#
        Launches a downloaded artifact. Returns a short description of what was started.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$WorkingDirectory
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File no longer exists: $Path"
    }

    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Path }

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.exe' {
            Start-Process -FilePath $Path -WorkingDirectory $WorkingDirectory -ErrorAction Stop | Out-Null
            return (Split-Path -Leaf $Path)
        }
        '.msi' {
            Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}"' -f $Path) -ErrorAction Stop | Out-Null
            return (Split-Path -Leaf $Path)
        }
        '.ps1' {
            # RemoteSigned, never Bypass: a downloaded script keeps its
            # "from the internet" mark and unsigned scripts are refused
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -File "{0}"' -f $Path) `
                -WorkingDirectory $WorkingDirectory -ErrorAction Stop | Out-Null
            return (Split-Path -Leaf $Path)
        }
        '.bat' {
            Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "{0}"' -f $Path) `
                -WorkingDirectory $WorkingDirectory -ErrorAction Stop | Out-Null
            return (Split-Path -Leaf $Path)
        }
        '.cmd' {
            Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "{0}"' -f $Path) `
                -WorkingDirectory $WorkingDirectory -ErrorAction Stop | Out-Null
            return (Split-Path -Leaf $Path)
        }
        default {
            Start-Process -FilePath $Path -WorkingDirectory $WorkingDirectory -ErrorAction Stop | Out-Null
            return (Split-Path -Leaf $Path)
        }
    }
}

function Get-GhlRepoFileList {
    param([Parameter(Mandatory)][string]$Directory, [int]$Max = 300)

    if (-not (Test-Path -LiteralPath $Directory)) { return @() }
    try {
        return @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $Global:GHL_MarkerName } |
            Select-Object -First $Max |
            ForEach-Object { $_.FullName.Substring($Directory.Length).TrimStart('\', '/') })
    } catch {
        return @()
    }
}

# ---------------------------------------------------------------------------
# Provenance: mark of the web, signatures, published checksums
# ---------------------------------------------------------------------------

function Set-GhlMarkOfTheWeb {
    <#
        Tags a downloaded file with a Zone.Identifier stream (ZoneId=3, "Internet"),
        so SmartScreen and Defender treat it as content from the web instead of a
        locally created file. Best effort: NTFS alternate data streams do not exist
        on every file system.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$SourceUrl = '')

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $content = @(
        '[ZoneTransfer]'
        'ZoneId=3'
    )
    if ($SourceUrl) { $content += "ReferrerUrl=$SourceUrl" }
    $content += 'HostUrl=about:internet'

    try {
        # NTFS alternate data stream. A path like "file:Zone.Identifier" cannot be
        # opened through System.IO (the colon is parsed as a drive), so the
        # PowerShell -Stream parameter is the reliable way to create it.
        $payload = $content -join "`r`n"
        Set-Content -LiteralPath $Path -Stream 'Zone.Identifier' -Value $payload -Encoding ASCII -ErrorAction Stop
        Write-GhlLog "Mark of the web written to '$Path'." Debug
        return $true
    } catch {
        Write-GhlLog "Could not write the mark of the web: $($_.Exception.Message)" Debug
        return $false
    }
}

function Get-GhlFileSignature {
    <#
        Authenticode summary for a downloaded file.
        Returns @{ Status; StatusText; Signer; IsSigned; IsTrusted }.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = @{
        Status     = 'UnknownError'
        StatusText = 'not verified'
        Signer     = ''
        IsSigned   = $false
        IsTrusted  = $false
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $result.Status = [string]$sig.Status
        $result.Signer = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
        $result.IsSigned = ($null -ne $sig.SignerCertificate)

        switch ([string]$sig.Status) {
            'Valid' {
                $result.StatusText = 'valid signature'
                $result.IsTrusted = $true
            }
            'NotSigned' {
                $result.StatusText = 'not digitally signed'
            }
            'UnknownError' {
                $result.StatusText = 'no signature information'
            }
            'HashMismatch' {
                $result.StatusText = 'SIGNATURE HASH MISMATCH - the file was modified'
            }
            default {
                $result.StatusText = ('signature {0}' -f $sig.Status)
            }
        }
    } catch {
        $result.StatusText = 'could not read the signature'
    }

    return $result
}

function Get-GhlPublishedChecksums {
    <#
        Downloads the release's checksum file, if there is one, and returns
        @{ Name; Entries = @{ file = hash } } or $null.
    #>
    param($Release, [string]$Token, [string]$TempDir)

    if (-not $Release -or -not $Release.Assets) { return $null }

    $candidate = $null
    foreach ($a in @($Release.Assets)) {
        if ($a.Name -match '(?i)^(sha256sums?(\.txt)?|checksums?(\.txt)?|sha256\.txt)$') { $candidate = $a; break }
    }
    if (-not $candidate) {
        foreach ($a in @($Release.Assets)) {
            if ($a.Name -match '(?i)sha256') { $candidate = $a; break }
        }
    }
    if (-not $candidate) { return $null }

    if (-not $TempDir -or -not (Test-Path -LiteralPath $TempDir)) { return $null }
    $path = Join-Path $TempDir ('checksums-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')

    try {
        [void](Invoke-GhlDownload -Url $candidate.Url -OutFile $path -Token $Token)
    } catch {
        Write-GhlLog "Could not download the checksum file: $($_.Exception.Message)" Debug
        return $null
    }

    $entries = @{}
    try {
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                $entries[$Matches[2].Trim()] = $Matches[1].ToLowerInvariant()
            }
        }
    } catch {
        Write-GhlLog "Could not parse the checksum file: $($_.Exception.Message)" Debug
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    if ($entries.Count -eq 0) { return $null }
    return @{ Name = $candidate.Name; Entries = $entries }
}

function Test-GhlHashMatches {
    param([string]$Path, [string]$Expected)

    if (-not $Path -or -not $Expected -or -not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        return ($actual -ieq $Expected)
    } catch {
        return $false
    }
}

function Get-GhlExpectedHash {
    <# Looks a file name up in a checksum table (case-insensitive). #>
    param($Checksums, [string]$FileName)

    if (-not $Checksums -or -not $Checksums.Entries -or -not $FileName) { return '' }
    foreach ($key in $Checksums.Entries.Keys) {
        if ($key -ieq $FileName) { return $Checksums.Entries[$key] }
        if ([IO.Path]::GetFileName($key) -ieq $FileName) { return $Checksums.Entries[$key] }
    }
    return ''
}
