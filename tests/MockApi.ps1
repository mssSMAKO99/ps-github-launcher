<#
    MockApi.ps1 - a tiny in-process GitHub API stand-in.

    Returns a session object (listener, port, base url, stop flag, runspace).
    Used by the deterministic tests so they never touch GitHub's rate limit.
#>

function New-GhlMockZip {
    param([string]$Path, [hashtable]$Entries)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $zip.CreateEntry($name)
            $stream = $entry.Open()
            $writer = New-Object IO.StreamWriter($stream)
            $writer.Write([string]$Entries[$name])
            $writer.Dispose()
            $stream.Dispose()
        }
    } finally {
        $zip.Dispose()
    }
}

function Start-GhlMockApi {
    param([string]$WorkDir)

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }

    # fixtures -------------------------------------------------------------
    $exeZip = Join-Path $WorkDir 'demo-tool-win.zip'
    New-GhlMockZip -Path $exeZip -Entries @{
        'demo-tool-1.2.0/DemoTool.exe'      = ('MZ' + ('x' * 4096))
        'demo-tool-1.2.0/helpers/readme.txt' = 'helper'
        'demo-tool-1.2.0/unins000.exe'      = ('MZ' + ('y' * 1024))
    }

    $sourceZip = Join-Path $WorkDir 'demo-tool-source.zip'
    New-GhlMockZip -Path $sourceZip -Entries @{
        'mockuser-demo-tool-abc123/README.md' = 'hello from the mock repository'
        'mockuser-demo-tool-abc123/main.ps1'  = 'Write-Host "hi"'
    }

    # a real, harmless script so the "run after download" path can be verified
    $scriptZip = Join-Path $WorkDir 'script-tool-win.zip'
    New-GhlMockZip -Path $scriptZip -Entries @{
        'script-tool/run.ps1' = "Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'launched.txt') -Value 'launched' -Encoding UTF8"
    }

    $exeBytes = [IO.File]::ReadAllBytes($exeZip)
    $exeB64 = [Convert]::ToBase64String($exeBytes)
    $srcBytes = [IO.File]::ReadAllBytes($sourceZip)
    $srcB64 = [Convert]::ToBase64String($srcBytes)
    $scriptBytes = [IO.File]::ReadAllBytes($scriptZip)
    $scriptB64 = [Convert]::ToBase64String($scriptBytes)
    $directExeB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('MZ' + ('z' * 2048)))

    $port = 0
    $listener = New-Object Net.HttpListener
    foreach ($candidate in 18471..18530) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://127.0.0.1:$candidate/")
            $listener.Start()
            $port = $candidate
            break
        } catch {
            continue
        }
    }
    if ($port -eq 0) { throw 'Could not bind a mock API port.' }

    $baseUrl = "http://127.0.0.1:$port"

    $script = {
        param($Listener, $BaseUrl, $ExeB64, $SrcB64, $ScriptB64, $DirectExeB64)

        $json = { param($Obj) [Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Depth 8)) }

        function Send-Bytes {
            param($Context, [byte[]]$Bytes, [string]$ContentType = 'application/octet-stream', [int]$Status = 200, [hashtable]$Headers)

            $resp = $Context.Response
            $resp.StatusCode = $Status
            $resp.ContentType = $ContentType
            $resp.Headers['User-Agent-Echo'] = 'mock'
            $resp.Headers['X-RateLimit-Limit'] = '60'
            $resp.Headers['X-RateLimit-Remaining'] = '55'
            $resp.Headers['X-RateLimit-Reset'] = [string]([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds())
            if ($Headers) { foreach ($k in $Headers.Keys) { $resp.Headers[$k] = [string]$Headers[$k] } }
            $resp.ContentLength64 = $Bytes.Length
            $resp.OutputStream.Write($Bytes, 0, $Bytes.Length)
            $resp.OutputStream.Close()
        }

        $userRepos = @(
            [pscustomobject]@{
                name = 'demo-tool'; full_name = 'mockuser/demo-tool'; owner = [pscustomobject]@{ login = 'mockuser' }
                description = 'A tool with release assets'; language = 'PowerShell'; stargazers_count = 123
                forks_count = 4; updated_at = '2026-05-01T10:00:00Z'
                html_url = "$BaseUrl/mockuser/demo-tool"; default_branch = 'main'
                archived = $false; fork = $false; size = 500
            },
            [pscustomobject]@{
                name = 'no-release'; full_name = 'mockuser/no-release'; owner = [pscustomobject]@{ login = 'mockuser' }
                description = 'Source only'; language = $null; stargazers_count = 5
                forks_count = 0; updated_at = '2026-04-01T10:00:00Z'
                html_url = "$BaseUrl/mockuser/no-release"; default_branch = 'main'
                archived = $false; fork = $false; size = 20
            },
            [pscustomobject]@{
                name = 'script-tool'; full_name = 'mockuser/script-tool'; owner = [pscustomobject]@{ login = 'mockuser' }
                description = 'Runs a script after download'; language = 'PowerShell'; stargazers_count = 2
                forks_count = 0; updated_at = '2026-03-01T10:00:00Z'
                html_url = "$BaseUrl/mockuser/script-tool"; default_branch = 'main'
                archived = $false; fork = $false; size = 10
            }
        )

        $scriptRelease = [pscustomobject]@{
            tag_name = 'v1.0.0'; name = 'Script Tool'; body = ''; prerelease = $false; draft = $false
            published_at = '2026-04-02T09:00:00Z'
            html_url = "$BaseUrl/mockuser/script-tool/releases/tag/v1.0.0"
            tarball_url = "$BaseUrl/mockuser/script-tool/tarball"; zipball_url = "$BaseUrl/mockuser/script-tool/zipball"
            assets = @(
                [pscustomobject]@{ name = 'ScriptTool-1.0.0-windows.zip'; size = $ScriptB64.Length; browser_download_url = "$BaseUrl/dl/script.zip"; content_type = 'application/zip' }
            )
        }

        $release = [pscustomobject]@{
            tag_name = 'v1.2.0'; name = 'Demo Tool 1.2.0'; body = 'notes'; prerelease = $false; draft = $false
            published_at = '2026-05-02T09:00:00Z'
            html_url = "$BaseUrl/mockuser/demo-tool/releases/tag/v1.2.0"
            tarball_url = "$BaseUrl/mockuser/demo-tool/tarball"; zipball_url = "$BaseUrl/mockuser/demo-tool/zipball"
            assets = @(
                [pscustomobject]@{ name = 'DemoTool-1.2.0-linux-x64.tar.gz'; size = 3000; browser_download_url = "$BaseUrl/dl/linux.tar.gz"; content_type = 'application/gzip' },
                [pscustomobject]@{ name = 'DemoTool-1.2.0-windows-x64.zip'; size = $ExeB64.Length; browser_download_url = "$BaseUrl/dl/win.zip"; content_type = 'application/zip' },
                [pscustomobject]@{ name = 'checksums.txt'; size = 100; browser_download_url = "$BaseUrl/dl/checksums.txt"; content_type = 'text/plain' },
                [pscustomobject]@{ name = 'demo-tool.deb'; size = 2000; browser_download_url = "$BaseUrl/dl/app.deb"; content_type = 'application/vnd.debian.binary-package' }
            )
        }

        while ($Listener.IsListening) {
            $context = $null
            try { $context = $Listener.GetContext() } catch { break }

            try {
                $path = $context.Request.Url.AbsolutePath
                $query = $context.Request.Url.Query
                $exe = [Convert]::FromBase64String($ExeB64)
                $src = [Convert]::FromBase64String($SrcB64)
                $direct = [Convert]::FromBase64String($DirectExeB64)

                switch -Regex ($path) {
                    '^/rate_limit$' {
                        Send-Bytes $context (& $json ([pscustomobject]@{ rate = [pscustomobject]@{ limit = 60; remaining = 55; reset = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds() } })) 'application/json'
                    }
                    '^/users/limiteduser/repos$' {
                        Send-Bytes $context (& $json ([pscustomobject]@{ message = 'API rate limit exceeded' })) 'application/json' 403
                    }
                    '^/users/ghost/repos$' {
                        Send-Bytes $context (& $json ([pscustomobject]@{ message = 'Not Found' })) 'application/json' 404
                    }
                    '^/users/([^/]+)/repos$' {
                        Send-Bytes $context (& $json $userRepos) 'application/json'
                    }
                    '^/repos/mockuser/demo-tool/releases/latest$' {
                        Send-Bytes $context (& $json $release) 'application/json'
                    }
                    '^/repos/mockuser/script-tool/releases/latest$' {
                        Send-Bytes $context (& $json $scriptRelease) 'application/json'
                    }
                    '^/dl/script\.zip$' {
                        Send-Bytes $context ([Convert]::FromBase64String($ScriptB64)) 'application/zip'
                    }
                    '^/repos/mockuser/no-release/releases/latest$' {
                        Send-Bytes $context (& $json ([pscustomobject]@{ message = 'Not Found' })) 'application/json' 404
                    }
                    '^/repos/mockuser/no-release/releases$' {
                        Send-Bytes $context ([Text.Encoding]::UTF8.GetBytes('[]')) 'application/json'
                    }
                    '^/repos/mockuser/demo-tool/zipball$' {
                        Send-Bytes $context $src 'application/zip'
                    }
                    '^/repos/mockuser/no-release/zipball$' {
                        Send-Bytes $context $src 'application/zip'
                    }
                    '^/dl/win\.zip$' {
                        Send-Bytes $context $exe 'application/zip'
                    }
                    '^/dl/linux\.tar\.gz$' {
                        Send-Bytes $context ([Text.Encoding]::UTF8.GetBytes('not a real tarball')) 'application/gzip'
                    }
                    '^/dl/checksums\.txt$' {
                        Send-Bytes $context ([Text.Encoding]::UTF8.GetBytes('abc123  DemoTool.zip')) 'text/plain'
                    }
                    '^/dl/direct\.exe$' {
                        Send-Bytes $context $direct 'application/octet-stream'
                    }
                    '^/dl/truncated\.zip$' {
                        # announces more bytes than it sends
                        $resp = $context.Response
                        $resp.StatusCode = 200
                        $resp.ContentType = 'application/zip'
                        $resp.ContentLength64 = 5000
                        $resp.OutputStream.Write($exe, 0, [Math]::Min(64, $exe.Length))
                        $resp.OutputStream.Flush()
                        $resp.Abort()
                    }
                    default {
                        Send-Bytes $context (& $json ([pscustomobject]@{ message = 'Not Found' })) 'application/json' 404
                    }
                }
            } catch {
                try { $context.Response.StatusCode = 500; $context.Response.OutputStream.Close() } catch { }
            }
        }

        try { $Listener.Stop(); $Listener.Close() } catch { }
    }

    $stopFlag = Join-Path $WorkDir 'stop.flag'
    if (Test-Path -LiteralPath $stopFlag) { Remove-Item -LiteralPath $stopFlag -Force }

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script)
    [void]$ps.AddParameter('Listener', $listener)
    [void]$ps.AddParameter('BaseUrl', $baseUrl)
    [void]$ps.AddParameter('ExeB64', $exeB64)
    [void]$ps.AddParameter('SrcB64', $srcB64)
    [void]$ps.AddParameter('ScriptB64', $scriptB64)
    [void]$ps.AddParameter('DirectExeB64', $directExeB64)
    $handle = $ps.BeginInvoke()

    # wait until the mock answers
    $ready = $false
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $ready) {
        try {
            $r = Invoke-WebRequest -Uri "$baseUrl/rate_limit" -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $ready = $true }
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    if (-not $ready) { throw 'Mock API did not start.' }

    return [pscustomobject]@{
        BaseUrl  = $baseUrl
        Port     = $port
        Listener = $listener
        PS       = $ps
        Handle   = $handle
        WorkDir  = $WorkDir
    }
}

function Stop-GhlMockApi {
    param([Parameter(Mandatory)]$Session)

    try { $Session.Listener.Stop() } catch { }
    try { $Session.Listener.Close() } catch { }
    try { $Session.PS.Stop() } catch { }
    try { $Session.PS.Dispose() } catch { }
}
