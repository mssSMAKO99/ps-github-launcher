<#
    02-Config.ps1
    Persistent settings + DPAPI-protected PAT.
#>

function Get-GhlDefaultConfig {
    return [ordered]@{
        Version         = 1
        BaseDir         = (Join-Path $env:USERPROFILE 'GitHub Downloads')
        BackgroundPath  = ''
        BackgroundKind  = 'file'          # file | url
        DimmingOpacity  = 0.55
        PatCipher       = ''
        PatPlain        = ''              # only used when DPAPI is unavailable
        LastUser        = ''
        FavoriteUsers   = @()             # pinned GitHub logins
        DownloadMode    = 'Release'       # Release | Source
        RunAfterDownload = $false         # opt-in: never launch by default
        IncludePrerelease = $false
        DebugLog        = $false
        Window          = [ordered]@{ Width = 1280; Height = 820; Left = -1; Top = -1; Maximized = $false }
    }
}

function Get-GhlFavoriteUsers {
    <#
        Returns a normalised, de-duplicated list of pinned logins.

        A single-element array becomes a plain string after a JSON round-trip,
        so the value is always wrapped in @() and stringified element by element.
    #>
    param([Parameter(Mandatory)]$Config)

    $list = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($item in @($Config.FavoriteUsers)) {
        if ($null -eq $item) { continue }
        $name = ([string]$item).Trim().TrimStart('@')
        if (-not $name) { continue }
        if ($name.Length -gt 39) { $name = $name.Substring(0, 39) }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9\-]*$') { continue }
        if ($seen.Add($name)) { [void]$list.Add($name) }
        if ($list.Count -ge 15) { break }
    }

    return $list.ToArray()
}

function Add-GhlFavoriteUser {
    <# Adds (or moves to front) a login. Returns the new array. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$User)

    $name = $User.Trim().TrimStart('@')
    if (-not $name) { return Get-GhlFavoriteUsers -Config $Config }

    $list = New-Object System.Collections.Generic.List[string]
    [void]$list.Add($name)
    foreach ($existing in @(Get-GhlFavoriteUsers -Config $Config)) {
        if (-not $existing.Equals($name, [StringComparison]::OrdinalIgnoreCase)) { [void]$list.Add($existing) }
    }

    $result = @($list.ToArray())
    if ($result.Count -gt 15) { $result = @($result[0..14]) }
    return $result
}

function Remove-GhlFavoriteUser {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$User)

    $kept = @(Get-GhlFavoriteUsers -Config $Config | Where-Object {
            -not $_.Equals($User.Trim(), [StringComparison]::OrdinalIgnoreCase)
        })
    return $kept
}

function Test-GhlFavoriteUser {
    param([Parameter(Mandatory)]$Config, [string]$User)

    if (-not $User) { return $false }
    $name = $User.Trim().TrimStart('@')
    foreach ($f in @(Get-GhlFavoriteUsers -Config $Config)) {
        if ($f.Equals($name, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Convert-GhlToHashtable {
    <#
        Normalises parsed JSON into ordered dictionaries / arrays.

        Order matters: in PowerShell every object also satisfies
        "-is [pscustomobject]" (it is the PSObject wrapper), so dictionaries and
        enumerables have to be handled first - otherwise an array of favourites
        would be turned into a dictionary of its properties.
    #>
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string] -or $InputObject -is [ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $out[$k] = Convert-GhlToHashtable $InputObject[$k] }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) { $items.Add((Convert-GhlToHashtable $item)) }
        return ,$items.ToArray()
    }

    $props = $InputObject.PSObject.Properties
    if ($props -and $props.Count -gt 0) {
        $out = [ordered]@{}
        foreach ($p in $props) { $out[$p.Name] = Convert-GhlToHashtable $p.Value }
        return $out
    }

    return $InputObject
}

function Merge-GhlConfig {
    <# Recursive merge: values from $Override win, unknown keys are kept. #>
    param([hashtable]$Base, $Override)

    if ($null -eq $Override) { return $Base }

    foreach ($k in @($Override.Keys)) {
        $v = $Override[$k]
        if ($v -is [System.Collections.IDictionary] -and $Base[$k] -is [System.Collections.IDictionary]) {
            $Base[$k] = Merge-GhlConfig -Base $Base[$k] -Override $v
        } elseif ($null -ne $v) {
            $Base[$k] = $v
        }
    }
    return $Base
}

function Get-GhlConfigPath {
    return (Join-Path (Get-GhlAppDir) 'config.json')
}

function Get-GhlConfig {
    <# Always returns a complete, valid config hashtable. Never throws. #>

    $cfg = Get-GhlDefaultConfig
    $path = Get-GhlConfigPath

    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $parsed = Convert-GhlToHashtable (ConvertFrom-Json $raw)
                $cfg = Merge-GhlConfig -Base $cfg -Override $parsed
            }
        } catch {
            Write-GhlLog "config.json is corrupt, falling back to defaults: $($_.Exception.Message)" Warn
            try {
                Copy-Item -LiteralPath $path -Destination ($path -replace '\.json$', '.bad.json') -Force
            } catch { }
        }
    }

    # --- sanity checks ---------------------------------------------------
    if (-not $cfg.BaseDir) { $cfg.BaseDir = Join-Path $env:USERPROFILE 'GitHub Downloads' }

    try {
        if (-not (Test-Path -LiteralPath $cfg.BaseDir)) {
            New-Item -ItemType Directory -Path $cfg.BaseDir -Force | Out-Null
        }
    } catch {
        Write-GhlLog "BaseDir '$($cfg.BaseDir)' is not usable: $($_.Exception.Message)" Warn
        $cfg.BaseDir = Join-Path $env:USERPROFILE 'GitHub Downloads'
        try { New-Item -ItemType Directory -Path $cfg.BaseDir -Force | Out-Null } catch { }
    }

    $dim = 0.0
    if ([double]::TryParse([string]$cfg.DimmingOpacity, [ref]$dim)) {
        $cfg.DimmingOpacity = [Math]::Min(0.95, [Math]::Max(0.0, $dim))
    } else {
        $cfg.DimmingOpacity = 0.55
    }

    if ($cfg.DownloadMode -notin @('Release', 'Source')) { $cfg.DownloadMode = 'Release' }

    $Global:GHL_DebugLog = [bool]($cfg.DebugLog -or $env:GHL_DEBUG)
    return $cfg
}

function Save-GhlConfig {
    param([Parameter(Mandatory)]$Config)

    $path = Get-GhlConfigPath
    $tmp = "$path.tmp"

    try {
        $json = $Config | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))

        if (Test-Path -LiteralPath $path) {
            # File.Replace keeps a backup and is still atomic enough on NTFS
            try {
                [IO.File]::Replace($tmp, $path, $null)
            } catch {
                Move-Item -LiteralPath $tmp -Destination $path -Force
            }
        } else {
            Move-Item -LiteralPath $tmp -Destination $path -Force
        }
        Write-GhlLog "Config saved ('$path')." Debug
        return $true
    } catch {
        Write-GhlLog "Failed to save config: $($_.Exception.Message)" Error
        return $false
    }
}

function Protect-GhlSecret {
    <# Encrypt with the current user's DPAPI key. Returns '' on failure. #>
    param([string]$PlainText)

    if (-not $PlainText) { return '' }
    try {
        $ss = ConvertTo-SecureString -String $PlainText -AsPlainText -Force
        return (ConvertFrom-SecureString -SecureString $ss)
    } catch {
        Write-GhlLog "DPAPI protect failed: $($_.Exception.Message)" Warn
        return ''
    }
}

function Unprotect-GhlSecret {
    param([string]$CipherText)

    if (-not $CipherText) { return '' }
    $bstr = [IntPtr]::Zero
    try {
        $ss = ConvertTo-SecureString -String $CipherText -ErrorAction Stop
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } catch {
        Write-GhlLog "Could not decrypt stored token: $($_.Exception.Message)" Warn
        return ''
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Get-GhlStoredToken {
    param([Parameter(Mandatory)]$Config)

    if ($Config.PatCipher) {
        $token = Unprotect-GhlSecret -CipherText $Config.PatCipher
        if ($token) { return $token }
    }
    if ($Config.PatPlain) { return [string]$Config.PatPlain }
    return ''
}

function Test-GhlWritablePath {
    <# True when we can create files inside $Path. #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        $probe = Join-Path $Path ('.ghl-write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}
