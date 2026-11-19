<#
    Run-Tests.ps1 - functional test suite (no Pester dependency).

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
    powershell ... -File tests\Run-Tests.ps1 -Offline    # skip network tests
#>

[CmdletBinding()]
param([switch]$Offline)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Global:GHL_Root = $root
$Global:GHL_DebugLog = $false
$Global:GHL_TestTemp = Join-Path ([IO.Path]::GetTempPath()) ('ghl-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Global:GHL_TestTemp -Force | Out-Null

foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $file.FullName
}

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host ("  PASS  " + $Name) -ForegroundColor Green
    } catch {
        $script:Failed++
        $script:Failures.Add("$Name :: $($_.Exception.Message)")
        Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
        Write-Host ("        " + $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        throw ("expected '$Expected' but got '$Actual'. $Message")
    }
}

Write-Host ''
Write-Host ' GitHub Launcher - test suite' -ForegroundColor Cyan
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray
Write-Host ''
Write-Host ' Core' -ForegroundColor Yellow

# ---------------------------------------------------------------------------
Test-Case 'Format-GhlSize' {
    Assert-Equal '512 B' (Format-GhlSize 512)
    Assert-Equal '1.5 KB' (Format-GhlSize 1536)
    Assert-Equal '2.0 MB' (Format-GhlSize (2MB))
    Assert-Equal '1.00 GB' (Format-GhlSize (1GB))
}

Test-Case 'Format-GhlDuration' {
    Assert-Equal '45s' (Format-GhlDuration 45)
    Assert-Equal '2m 05s' (Format-GhlDuration 125)
}

Test-Case 'ConvertTo-GhlSafeName' {
    Assert-Equal 'a_b_c' (ConvertTo-GhlSafeName 'a/b\c')
    Assert-Equal 'trailing' (ConvertTo-GhlSafeName 'trailing.')
    Assert-Equal 'repo' (ConvertTo-GhlSafeName '   ')
    Assert-True ((ConvertTo-GhlSafeName 'x:y*z') -eq 'x_y_z') 'illegal chars must be replaced'
}

Test-Case 'Get-GhlRepoDir layout' {
    $dir = Get-GhlRepoDir -BaseDir 'C:\DL' -User 'octocat' -Repo 'Hello-World'
    Assert-Equal 'C:\DL\octocat\Hello-World' $dir
}

Test-Case 'Test-GhlSafePath (zip-slip)' {
    $rootDir = Join-Path $Global:GHL_TestTemp 'safepath'
    New-Item -ItemType Directory -Path $rootDir -Force | Out-Null

    Assert-True (Test-GhlSafePath -Root $rootDir -Relative 'folder/file.txt') 'normal path must pass'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative '../escape.txt')) 'parent traversal must fail'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative 'a/../../escape.txt')) 'nested traversal must fail'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative 'C:\Windows\evil.dll')) 'absolute path must fail'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative '/etc/passwd')) 'rooted path must fail'
}

Test-Case 'Test-GhlAssetCompatible' {
    Assert-True (Test-GhlAssetCompatible 'app.exe')
    Assert-True (Test-GhlAssetCompatible 'setup.msi')
    Assert-True (Test-GhlAssetCompatible 'src.zip')
    Assert-True (Test-GhlAssetCompatible 'app.TAR.GZ')
    Assert-True (Test-GhlAssetCompatible 'tool-windows-x64.zip')
    Assert-True (-not (Test-GhlAssetCompatible 'tool-linux-x86_64.tar.gz')) 'linux build must not be offered'
    Assert-True (-not (Test-GhlAssetCompatible 'tool-darwin-arm64.tar.gz')) 'macOS build must not be offered'
    Assert-True (-not (Test-GhlAssetCompatible 'app.deb'))
    Assert-True (-not (Test-GhlAssetCompatible 'app.dmg'))
    Assert-True (-not (Test-GhlAssetCompatible 'checksums.txt'))
}

Test-Case 'Get-GhlAssetScore prefers Windows packages' {
    Assert-True ((Get-GhlAssetScore 'app-windows-x64.exe') -gt (Get-GhlAssetScore 'app-linux-x64.tar.gz')) `
        'a Windows exe must outrank a linux tarball'
    Assert-True ((Get-GhlAssetScore 'app-setup.msi') -gt (Get-GhlAssetScore 'source.zip')) `
        'an installer must outrank a source zip'
    Assert-True ((Get-GhlAssetScore 'app-arm64.exe') -lt (Get-GhlAssetScore 'app-x64.exe')) `
        'arm64 must rank below x64'
    Assert-True ((Get-GhlAssetScore 'app.sha256') -lt 0) 'checksums must be penalised'
}

Test-Case 'Convert-GhlRepo / Convert-GhlRelease' {
    $raw = [pscustomobject]@{
        name = 'demo'; full_name = 'me/demo'; owner = [pscustomobject]@{ login = 'me' }
        description = 'd'; language = $null; stargazers_count = 7; forks_count = 2
        updated_at = '2024-05-01T10:00:00Z'; html_url = 'https://github.com/me/demo'
        default_branch = 'main'; archived = $false; fork = $true; size = 100
    }
    $repo = Convert-GhlRepo $raw
    Assert-Equal 'demo' $repo.Name
    Assert-Equal 'me' $repo.Owner
    Assert-Equal 7 $repo.Stars
    Assert-Equal '-' $repo.Language

    $rel = Convert-GhlRelease ([pscustomobject]@{
            tag_name = 'v1.0.0'; name = 'First'; body = 'notes'; prerelease = $false
            draft = $false; published_at = '2024-05-02T00:00:00Z'
            assets = @([pscustomobject]@{
                    name = 'app.zip'; size = 2048; browser_download_url = 'https://x/app.zip'; content_type = 'application/zip'
                })
            html_url = 'h'; tarball_url = 't'; zipball_url = 'z'
        })
    Assert-Equal 'v1.0.0' $rel.Tag
    Assert-Equal 1 $rel.Assets.Count
    Assert-True $rel.Assets[0].Compatible 'zip asset must be compatible'
    Assert-True $rel.Assets[0].IsArchive 'zip asset must be an archive'
}

Write-Host ''
Write-Host ' Archive' -ForegroundColor Yellow

function New-TestZip {
    param([string]$Path, [hashtable]$Entries)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            $writer.Write([string]$Entries[$name])
            $writer.Dispose()
        }
    } finally { $zip.Dispose() }
}

Test-Case 'Expand-GhlZip + unwrap single root folder' {
    $zipPath = Join-Path $Global:GHL_TestTemp 'ok.zip'
    New-TestZip -Path $zipPath -Entries @{
        'demo-main/README.md' = 'hello'
        'demo-main/tool.exe'  = 'binary'
        'demo-main/docs/a.md' = 'doc'
    }

    $out = Join-Path $Global:GHL_TestTemp 'extract-ok'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $count = Expand-GhlArchive -Path $zipPath -Destination $out
    Assert-Equal 3 $count
    Assert-True (Test-Path -LiteralPath (Join-Path $out 'README.md')) 'root folder must be unwrapped'
    Assert-True (Test-Path -LiteralPath (Join-Path $out 'tool.exe')) 'nested file must be unwrapped'
}

Test-Case 'Expand-GhlZip rejects zip-slip archive' {
    $zipPath = Join-Path $Global:GHL_TestTemp 'evil.zip'
    New-TestZip -Path $zipPath -Entries @{
        '../evil.txt' = 'pwned'
        'ok.txt'      = 'fine'
    }

    $out = Join-Path $Global:GHL_TestTemp 'extract-evil'
    New-Item -ItemType Directory -Path $out -Force | Out-Null

    $threw = $false
    try { [void](Expand-GhlZip -Path $zipPath -Destination $out) } catch { $threw = $true }
    Assert-True $threw 'zip-slip archive must be rejected'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Global:GHL_TestTemp 'evil.txt'))) 'no file may escape the destination'
}

Test-Case 'Find-GhlExecutables ranking' {
    $dir = Join-Path $Global:GHL_TestTemp 'findexe'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'helpers') -Force | Out-Null

    foreach ($f in @('MyTool.exe', 'helpers\unins000.exe', 'demo\readme.txt', 'helpers\vc_redist.x64.exe')) {
        $full = Join-Path $dir $f
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllBytes($full, (New-Object byte[] 8192))
    }

    $found = @(Find-GhlExecutables -Root $dir -RepoName 'MyTool')
    Assert-True ($found.Count -ge 1) 'at least one exe'
    Assert-Equal 'MyTool.exe' $found[0].Name 'the primary exe must rank first'
    Assert-True ($found.Count -eq 3) "expected 3 exe files, got $($found.Count)"
}

Write-Host ''
Write-Host ' Settings' -ForegroundColor Yellow

Test-Case 'DPAPI round-trip' {
    $secret = 'ghp_exampleToken1234567890'
    $cipher = Protect-GhlSecret -PlainText $secret
    Assert-True ($cipher.Length -gt 0) 'cipher must not be empty'
    Assert-True ($cipher -ne $secret) 'cipher must not equal the plaintext'
    Assert-Equal $secret (Unprotect-GhlSecret -CipherText $cipher)
}

Test-Case 'Config merge keeps unknown keys and defaults' {
    $cfg = Merge-GhlConfig -Base (Get-GhlDefaultConfig) -Override @{ BaseDir = 'D:\x'; Custom = 42 }
    Assert-Equal 'D:\x' $cfg.BaseDir
    Assert-Equal 42 $cfg.Custom
    Assert-True ($null -ne $cfg.Window) 'nested defaults must survive the merge'
    Assert-True ($cfg.RunAfterDownload -eq $true) 'unchanged defaults must survive'
}

Test-Case 'Config JSON round-trip' {
    $cfg = Get-GhlDefaultConfig
    $cfg.BaseDir = 'D:\Downloads'
    $cfg.DimmingOpacity = 0.42
    $json = $cfg | ConvertTo-Json -Depth 8
    $back = Convert-GhlToHashtable (ConvertFrom-Json $json)
    Assert-Equal 'D:\Downloads' $back.BaseDir
    Assert-Equal 0.42 $back.DimmingOpacity
    Assert-Equal 1280 $back.Window.Width
}

Test-Case 'Marker write/read + repo state' {
    $base = Join-Path $Global:GHL_TestTemp 'state'
    $dir = Get-GhlRepoDir -BaseDir $base -User 'u' -Repo 'r'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Assert-Equal 'Not downloaded' (Get-GhlRepoBadge -BaseDir $base -User 'u' -Repo 'r')

    [IO.File]::WriteAllText((Join-Path $dir 'app.exe'), 'x')
    Assert-Equal 'Partial' (Get-GhlRepoBadge -BaseDir $base -User 'u' -Repo 'r')

    [void](Set-GhlMarker -Directory $dir -User 'u' -Repo 'r' -Mode 'Release' -Tag 'v1' -Executable 'app.exe' -Files @('app.exe'))
    Assert-Equal 'Downloaded' (Get-GhlRepoBadge -BaseDir $base -User 'u' -Repo 'r')

    $state = Get-GhlRepoState -BaseDir $base -User 'u' -Repo 'r'
    Assert-Equal 'Downloaded' $state.State
    Assert-Equal 'v1' $state.Marker.Tag
    Assert-Equal 1 $state.Files
}

Test-Case 'Open-GhlFolder rejects missing directory' {
    $threw = $false
    try { Open-GhlFolder -Path (Join-Path $Global:GHL_TestTemp 'nope-does-not-exist') } catch { $threw = $true }
    Assert-True $threw 'must throw for a missing folder'
}

# ---------------------------------------------------------------------------
if (-not $Offline) {
    Write-Host ''
    Write-Host ' Network + workers' -ForegroundColor Yellow

    $sync = [hashtable]::Synchronized(@{
            Phase           = 'idle'
            StatusText      = ''
            ProgressPercent = -1.0
            BytesReceived   = 0L
            BytesTotal      = -1L
            SpeedBps        = 0.0
            CancelRequested = $false
            Events          = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        })

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in (Get-GhlWorkerNames)) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($cmd) {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $cmd.Definition)))
        }
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 3, $iss, $Host)
    $pool.Open()

    function Wait-Event {
        param([int]$TimeoutSec = 60, [string]$Kind, $PS)
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $evt = $null
            while ($sync.Events.TryDequeue([ref]$evt)) {
                if (-not $Kind -or $evt.Kind -eq $Kind) { return $evt }
                $evt = $null
            }
            if ($PS -and $PS.InvocationStateInfo.State -in @('Completed', 'Failed', 'Stopped')) {
                $errors = @($PS.Streams.Error | ForEach-Object { $_.Exception.Message })
                if ($errors.Count -gt 0) {
                    throw "worker ended without an event: $($errors -join '; ')"
                }
                throw "worker ended ($($PS.InvocationStateInfo.State)) without publishing an event"
            }
            Start-Sleep -Milliseconds 120
        }
        return $null
    }

    function Invoke-Worker {
        param([string]$Kind, [hashtable]$Arguments)
        $body = switch ($Kind) {
            'Repos'    { Get-GhlWorkerRepos }
            'Release'  { Get-GhlWorkerRelease }
            'Download' { Get-GhlWorkerDownload }
        }
        $text = Join-GhlWorkerScript -Body $body
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($text)
        foreach ($k in $Arguments.Keys) { [void]$ps.AddParameter($k, $Arguments[$k]) }
        [void]$ps.BeginInvoke()
        return $ps
    }

    Test-Case 'Worker: load repositories' {
        $ps = Invoke-Worker -Kind 'Repos' -Arguments @{ Sync = $sync; User = 'octocat'; Token = '' }
        $evt = Wait-Event -Kind 'Repos' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Repos event received'
        Assert-True $evt.Ok "worker failed: $($evt.Message)"
        Assert-True (@($evt.Data).Count -ge 5) "expected repositories, got $(@($evt.Data).Count)"
        Assert-Equal 'octocat' $evt.User
        $ps.Dispose()
    }

    Test-Case 'Worker: unknown user is reported as notfound' {
        $ps = Invoke-Worker -Kind 'Repos' -Arguments @{ Sync = $sync; User = 'ghl-user-that-should-not-exist-9z8x7'; Token = '' }
        $evt = Wait-Event -Kind 'Repos' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Repos event received'
        Assert-True (-not $evt.Ok) 'unknown user must fail'
        Assert-Equal 'notfound' $evt.ErrKind
        $ps.Dispose()
    }

    Test-Case 'Worker: latest release lookup' {
        $ps = Invoke-Worker -Kind 'Release' -Arguments @{ Sync = $sync; User = 'octocat'; Repo = 'Hello-World'; Token = ''; IncludePrerelease = $false }
        $evt = Wait-Event -Kind 'Release' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Release event received'
        Assert-True ($evt.Ok -or $evt.ErrKind -eq 'norelease') "unexpected result: $($evt.ErrKind) $($evt.Message)"
        $ps.Dispose()
    }

    Test-Case 'Download + extract source zipball' {
        $base = Join-Path $Global:GHL_TestTemp 'dlbase'
        $dest = Get-GhlRepoDir -BaseDir $base -User 'octocat' -Repo 'Hello-World'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        $sync.CancelRequested = $false
        $sync.Phase = 'downloading'
        $job = @{
            Url      = 'https://api.github.com/repos/octocat/Hello-World/zipball'
            FileName = 'Hello-World-source.zip'
            DestDir  = $dest
            Mode     = 'Source'
            Tag      = ''
            Token    = ''
            User     = 'octocat'
            Repo     = 'Hello-World'
            AutoRun  = $false
        }
        $ps = Invoke-Worker -Kind 'Download' -Arguments @{ Sync = $sync; Job = $job }
        $evt = Wait-Event -Kind 'Download' -TimeoutSec 120 -PS $ps
        Assert-True ($null -ne $evt) 'no Download event received'
        Assert-True $evt.Ok "download failed: $($evt.Message)"
        Assert-True (Test-Path -LiteralPath (Join-Path $dest '.ghl.json')) 'marker must be written'
        Assert-True (Test-Path -LiteralPath (Join-Path $dest 'README')) 'archive must be unpacked'
        Assert-Equal 'Downloaded' (Get-GhlRepoBadge -BaseDir $base -User 'octocat' -Repo 'Hello-World')
        $ps.Dispose()
    }

    Test-Case 'Download: 404 is classified' {
        $dest = Join-Path $Global:GHL_TestTemp 'dl404'
        $sync.CancelRequested = $false
        $job = @{
            Url      = 'https://api.github.com/repos/octocat/definitely-not-a-repo-xyz/zipball'
            FileName = 'x.zip'
            DestDir  = $dest
            Mode     = 'Source'
            Tag      = ''
            Token    = ''
            User     = 'octocat'
            Repo     = 'nope'
            AutoRun  = $false
        }
        $ps = Invoke-Worker -Kind 'Download' -Arguments @{ Sync = $sync; Job = $job }
        $evt = Wait-Event -Kind 'Download' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Download event received'
        Assert-True (-not $evt.Ok) 'must fail'
        Assert-Equal 'notfound' $evt.ErrKind
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dest 'x.zip'))) 'no partial file may remain'
        $ps.Dispose()
    }

    $pool.Close()
    $pool.Dispose()
} else {
    Write-Host ''
    Write-Host ' Network tests skipped (-Offline).' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
try { Remove-Item -LiteralPath $Global:GHL_TestTemp -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host (" {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor DarkRed }
    exit 1
}
Write-Host ''
exit 0
