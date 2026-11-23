<#
    03-Api.ps1
    GitHub REST API wrapper.
    Rule: never throws for expected failures - always returns a result object
    so the worker can decide what to show to the user.
#>

$Global:GHL_ApiBase = if ($env:GHL_API_BASE) { $env:GHL_API_BASE.TrimEnd('/') } else { 'https://api.github.com' }
$Global:GHL_UserAgent = 'GitHubLauncher-Client'

function New-GhlApiResult {
    param(
        [bool]$Ok,
        [int]$Status = 0,
        [string]$Kind = 'ok',
        [object]$Data = $null,
        [string]$Message = '',
        [Nullable[DateTime]]$ResetAt = $null,
        [int]$Remaining = -1
    )
    return [pscustomobject]@{
        Ok        = $Ok
        Status    = $Status
        Kind      = $Kind
        Data      = $Data
        Message   = $Message
        ResetAt   = $ResetAt
        Remaining = $Remaining
    }
}

function Invoke-GhlHttp {
    <#
        Single HTTP entry point. Returns:
          @{ Ok; Status; Body; Json; Headers; Error; Kind }
        Retries on 5xx and transport errors only.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Token,
        [string]$Accept = 'application/vnd.github+json',
        [int]$MaxRetry = 2,
        [int]$TimeoutSec = 30
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $lastError = ''
    $attempt = 0

    # One client for the whole call: a retry must not pay for a new TLS handshake.
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    try {
        while ($attempt -le $MaxRetry) {
            $attempt++
            $req = $null
            try {
                $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
                [void]$req.Headers.TryAddWithoutValidation('User-Agent', $Global:GHL_UserAgent)
                [void]$req.Headers.TryAddWithoutValidation('Accept', $Accept)
                [void]$req.Headers.TryAddWithoutValidation('X-GitHub-Api-Version', '2022-11-28')
                if ($Token) {
                    [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token")
                }

                $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $status = [int]$resp.StatusCode
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

                $headers = @{}
                foreach ($h in $resp.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
                foreach ($h in $resp.Content.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
                $resp.Dispose()

                $json = $null
                if ($body) {
                    try { $json = ConvertFrom-Json $body } catch { $json = $null }
                }

                $kind = 'ok'
                if ($status -ge 400) {
                    $remaining = -1
                    if ($headers.ContainsKey('X-RateLimit-Remaining')) {
                        [void][int]::TryParse($headers['X-RateLimit-Remaining'], [ref]$remaining)
                    }
                    if ($status -eq 401) { $kind = 'auth' }
                    elseif ($status -eq 403 -and $remaining -eq 0) { $kind = 'ratelimit' }
                    elseif ($status -eq 403 -and $body -match 'rate limit') { $kind = 'ratelimit' }
                    elseif ($status -eq 403) { $kind = 'forbidden' }
                    elseif ($status -eq 404) { $kind = 'notfound' }
                    elseif ($status -eq 422) { $kind = 'invalid' }
                    elseif ($status -eq 429) { $kind = 'ratelimit' }
                    elseif ($status -ge 500) { $kind = 'server' }
                    else { $kind = 'http' }
                }

                # retry only transient server failures
                if ($kind -eq 'server' -and $attempt -le $MaxRetry) {
                    $lastError = "HTTP $status"
                    Start-Sleep -Milliseconds (400 * $attempt)
                    continue
                }

                return [pscustomobject]@{
                    Ok      = ($status -ge 200 -and $status -lt 300)
                    Status  = $status
                    Body    = $body
                    Json    = $json
                    Headers = $headers
                    Error   = ''
                    Kind    = $kind
                }
            } catch {
                $lastError = $_.Exception.Message
                $inner = $_.Exception.InnerException
                if ($inner) { $lastError = $inner.Message }

                if ($attempt -le $MaxRetry) {
                    Start-Sleep -Milliseconds (400 * $attempt)
                    continue
                }
                return [pscustomobject]@{
                    Ok      = $false
                    Status  = 0
                    Body    = ''
                    Json    = $null
                    Headers = @{}
                    Error   = $lastError
                    Kind    = 'network'
                }
            } finally {
                if ($req) { $req.Dispose() }
            }
        }

        return [pscustomobject]@{
            Ok = $false; Status = 0; Body = ''; Json = $null; Headers = @{}
            Error = $lastError; Kind = 'network'
        }
    } finally {
        if ($client) { $client.Dispose() }
    }
}

function Convert-GhlResetTime {
    param($Headers)

    if ($Headers -and $Headers.ContainsKey('X-RateLimit-Reset')) {
        $unix = 0
        if ([long]::TryParse([string]$Headers['X-RateLimit-Reset'], [ref]$unix)) {
            return [DateTimeOffset]::FromUnixTimeSeconds($unix).LocalDateTime
        }
    }
    return $null
}

function Convert-GhlApiDate {
    <# Parses a GitHub timestamp without depending on the current culture. #>
    param($Raw)

    if (-not $Raw) { return $null }
    try {
        return [DateTime]::Parse(
            [string]$Raw,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
    } catch {
        return $null
    }
}

function Invoke-GhlApi {
    <# GET a GitHub API path, e.g. '/users/x/repos'. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Token,
        [string]$Accept = 'application/vnd.github+json',
        [int]$MaxRetry = 2
    )

    $url = if ($Path -match '^https?://') { $Path } else { "$Global:GHL_ApiBase$Path" }
    $r = Invoke-GhlHttp -Url $url -Token $Token -Accept $Accept -MaxRetry $MaxRetry

    $remaining = -1
    if ($r.Headers.ContainsKey('X-RateLimit-Remaining')) {
        [void][int]::TryParse($r.Headers['X-RateLimit-Remaining'], [ref]$remaining)
    }

    if ($r.Ok) {
        return New-GhlApiResult -Ok $true -Status $r.Status -Kind 'ok' -Data $r.Json -Remaining $remaining
    }

    $kind = $r.Kind
    switch ($kind) {
        'network'   { $msg = "Network error: $($r.Error)" }
        'auth'      { $msg = 'GitHub rejected the token (HTTP 401). Check the personal access token.' }
        'ratelimit' { $msg = 'GitHub rate limit exceeded.' }
        'notfound'  { $msg = 'Not found on GitHub (HTTP 404).' }
        'forbidden' { $msg = 'Access forbidden (HTTP 403).' }
        default     { $msg = "GitHub returned HTTP $($r.Status)." }
    }
    if ($r.Json -and $r.Json.message -and $kind -notin @('network')) {
        $msg = [string]$r.Json.message
    }

    $resetAt = Convert-GhlResetTime -Headers $r.Headers
    if ($kind -eq 'ratelimit' -and $resetAt) {
        $wait = $resetAt - (Get-Date)
        if ($wait.TotalSeconds -gt 0) {
            $msg = '{0} Limit resets at {1:HH:mm} (in {2}).' -f $msg, $resetAt, (Format-GhlDuration $wait.TotalSeconds)
        } else {
            $msg = "$msg Limit resets at $($resetAt.ToString('HH:mm'))."
        }
    }

    return New-GhlApiResult -Ok $false -Status $r.Status -Kind $kind -Message $msg -ResetAt $resetAt -Remaining $remaining
}

# ---------------------------------------------------------------------------
# Normalisation
# ---------------------------------------------------------------------------

function Convert-GhlRepo {
    param($Raw)

    $updated = $null
    if ($Raw.updated_at) {
        try { $updated = [DateTime]::Parse($Raw.updated_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) } catch { }
    }

    return [pscustomobject]@{
        Name          = [string]$Raw.name
        FullName      = [string]$Raw.full_name
        Owner         = [string]$Raw.owner.login
        Description   = [string]$Raw.description
        Language      = if ($Raw.language) { [string]$Raw.language } else { '-' }
        Stars         = [int]$Raw.stargazers_count
        Forks         = [int]$Raw.forks_count
        Updated       = $updated
        HtmlUrl       = [string]$Raw.html_url
        DefaultBranch = [string]$Raw.default_branch
        Archived      = [bool]$Raw.archived
        Fork          = [bool]$Raw.fork
        SizeKb        = [int]$Raw.size
    }
}

function Test-GhlAssetCompatible {
    <#
        True when the asset can plausibly be used on Windows: a native package
        or an archive that is not explicitly built for another OS.
    #>
    param([string]$Name)

    if (-not $Name) { return $false }
    $n = $Name.ToLowerInvariant()

    if ($n -match '\.(deb|rpm|apk|dmg|pkg|snap|flatpak|appimage|jar|py|whl)$') { return $false }
    if ($n -match '(^|[^a-z])(linux|darwin|macos|mac-osx|osx|freebsd|openbsd|netbsd|solaris|android|haiku)([^a-z]|$)') { return $false }

    foreach ($ext in @('.exe', '.msi', '.msix', '.appx', '.zip', '.tar.gz', '.tgz', '.ps1', '.bat', '.cmd')) {
        if ($n.EndsWith($ext)) { return $true }
    }
    return $false
}

function Get-GhlAssetScore {
    <#
        Higher is better. Used both for the "best asset" auto-selection and for
        sorting the list, so a Windows package always beats a source tarball.
    #>
    param([string]$Name)

    if (-not $Name) { return 0 }
    $n = $Name.ToLowerInvariant()
    $score = 0

    if ($n.EndsWith('.exe')) { $score += 60 }
    elseif ($n.EndsWith('.msi')) { $score += 58 }
    elseif ($n.EndsWith('.msix') -or $n.EndsWith('.appx')) { $score += 56 }
    elseif ($n.EndsWith('.zip')) { $score += 40 }
    elseif ($n.EndsWith('.tar.gz') -or $n.EndsWith('.tgz')) { $score += 20 }

    if ($n -match 'windows|win32|win64|-win\.|_win|x64-windows') { $score += 30 }
    elseif ($n -match '(^|[^a-z])win([^a-z]|$)') { $score += 16 }

    if ($n -match 'x64|amd64|x86_64') { $score += 10 }
    if ($n -match 'arm64|aarch64|armhf|armel') { $score -= 25 }
    if ($n -match 'ia32|x86(?!_64)|win32|32bit') { $score -= 6 }
    if ($n -match 'setup|installer') { $score += 4 }
    if ($n -match 'portable|standalone') { $score += 6 }
    if ($n -match 'debug|symbols|pdb|test|sample|checksum|sha256|\.sig$|\.asc$') { $score -= 40 }

    return $score
}

function Convert-GhlAsset {
    param($Raw)

    $name = [string]$Raw.name
    $autoLaunch = -not ($name -match '(?i)\.(msix|msixbundle|appx|appxbundle)$')
    return [pscustomobject]@{
        Name          = $name
        Size          = [long]$Raw.size
        Url           = [string]$Raw.browser_download_url
        ContentType   = [string]$Raw.content_type
        Compatible    = (Test-GhlAssetCompatible -Name $name)
        Score         = (Get-GhlAssetScore -Name $name)
        IsArchive     = ($name -match '\.(zip|tar\.gz|tgz)$')
        DownloadCount = [int]$Raw.download_count
        AutoLaunchable = $autoLaunch
    }
}

function Convert-GhlRelease {
    param($Raw)

    $published = Convert-GhlApiDate -Raw $Raw.published_at
    $created = Convert-GhlApiDate -Raw $Raw.created_at

    return [pscustomobject]@{
        Tag        = [string]$Raw.tag_name
        Name       = if ($Raw.name) { [string]$Raw.name } else { [string]$Raw.tag_name }
        Body       = [string]$Raw.body
        Prerelease = [bool]$Raw.prerelease
        Draft      = [bool]$Raw.draft
        Published  = $published
        CreatedAt  = $created
        Assets     = @($Raw.assets | ForEach-Object { Convert-GhlAsset $_ })
        HtmlUrl    = [string]$Raw.html_url
        TarballUrl = [string]$Raw.tarball_url
        ZipballUrl = [string]$Raw.zipball_url
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-GhlUserRepos {
    param(
        [Parameter(Mandatory)][string]$User,
        [string]$Token,
        [int]$MaxPages = 5
    )

    $User = $User.Trim().TrimStart('@').TrimEnd('/')
    if ($User -match 'github\.com/([^/]+)') { $User = $Matches[1] }
    if (-not $User) { return New-GhlApiResult -Ok $false -Kind 'invalid' -Message 'Enter a GitHub username.' }

    $all = New-Object System.Collections.Generic.List[object]
    $page = 1
    $lastRemaining = -1

    while ($page -le $MaxPages) {
        $path = '/users/{0}/repos?per_page=100&page={1}&sort=updated&direction=desc' -f [Uri]::EscapeDataString($User), $page
        $res = Invoke-GhlApi -Path $path -Token $Token

        if (-not $res.Ok) {
            if ($res.Kind -eq 'notfound') {
                $res.Message = "GitHub user '$User' was not found."
            }
            return $res
        }

        $items = @($res.Data)
        foreach ($item in $items) { $all.Add((Convert-GhlRepo $item)) }
        $lastRemaining = $res.Remaining

        if ($items.Count -lt 100) { break }
        if ($lastRemaining -eq 0) { break }
        $page++
    }

    # note: @() on a generic List<T> throws ArgumentException on Windows 11 builds,
    # so the list is materialised with ToArray() instead
    return New-GhlApiResult -Ok $true -Status 200 -Kind 'ok' -Data $all.ToArray() -Remaining $lastRemaining
}

function Get-GhlRepoInfo {
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Repo, [string]$Token)

    $res = Invoke-GhlApi -Path ('/repos/{0}/{1}' -f [Uri]::EscapeDataString($User), [Uri]::EscapeDataString($Repo)) -Token $Token
    if (-not $res.Ok) { return $res }
    return New-GhlApiResult -Ok $true -Status 200 -Kind 'ok' -Data (Convert-GhlRepo $res.Data) -Remaining $res.Remaining
}

function Get-GhlReleases {
    <#
        Returns every published release of the repository, newest first.
        Drafts are dropped; pre-releases stay in the list because the UI filters
        them client-side without spending another API request.
        Kind='norelease' means "nothing to show", not an error.
    #>
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Token,
        [int]$PerPage = 30
    )

    $path = '/repos/{0}/{1}/releases?per_page={2}' -f [Uri]::EscapeDataString($User), [Uri]::EscapeDataString($Repo), $PerPage
    $res = Invoke-GhlApi -Path $path -Token $Token

    if (-not $res.Ok) {
        if ($res.Kind -eq 'notfound') {
            return New-GhlApiResult -Ok $false -Kind 'norelease' -Message 'This repository has no published releases.' -Remaining $res.Remaining
        }
        return $res
    }

    $list = @(@($res.Data) | ForEach-Object { if ($_) { Convert-GhlRelease $_ } } | Where-Object { $_ -and -not $_.Draft })

    $sorted = @($list | Sort-Object -Property @{
            Expression = { if ($_.Published) { [DateTime]$_.Published } elseif ($_.CreatedAt) { [DateTime]$_.CreatedAt } else { [DateTime]::MinValue } }
            Descending = $true
        })

    if ($sorted.Count -eq 0) {
        return New-GhlApiResult -Ok $false -Kind 'norelease' -Message 'This repository has no published releases.' -Remaining $res.Remaining
    }

    return New-GhlApiResult -Ok $true -Status 200 -Kind 'ok' -Data $sorted -Remaining $res.Remaining
}

function Select-GhlReleaseByTag {
    <# Finds a release in a list by tag (case-insensitive). Returns $null when absent. #>
    param($Releases, [string]$Tag)

    if (-not $Tag) { return $null }
    $wanted = $Tag.Trim()
    foreach ($r in @($Releases)) {
        if ($null -eq $r) { continue }
        if ([string]$r.Tag -ieq $wanted) { return $r }
    }
    return $null
}

function Get-GhlLatestRelease {
    <#
        Compatibility wrapper around Get-GhlReleases: the newest stable release,
        or the newest release of any kind when -IncludePrerelease is set.
    #>
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Token,
        [switch]$IncludePrerelease
    )

    $list = Get-GhlReleases -User $User -Repo $Repo -Token $Token
    if (-not $list.Ok) { return $list }

    $candidates = @($list.Data)
    if (-not $IncludePrerelease) {
        $candidates = @($candidates | Where-Object { -not $_.Prerelease })
    }

    if ($candidates.Count -eq 0) {
        return New-GhlApiResult -Ok $false -Kind 'norelease' `
            -Message 'This repository only has pre-release versions. Enable "Include pre-release" to see them.' `
            -Remaining $list.Remaining
    }

    return New-GhlApiResult -Ok $true -Status 200 -Kind 'ok' -Data $candidates[0] -Remaining $list.Remaining
}

function New-GhlSourceArchive {
    <# Builds download info for the source zip of the default branch. #>
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Repo)

    $safeRepo = ($Repo -replace '[^\w\.\-]', '_')
    return [pscustomobject]@{
        Url      = ('{0}/repos/{1}/{2}/zipball' -f $Global:GHL_ApiBase, [Uri]::EscapeDataString($User), [Uri]::EscapeDataString($Repo))
        FileName = "$safeRepo-source.zip"
        IsArchive = $true
    }
}
