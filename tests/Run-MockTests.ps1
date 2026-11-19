<#
    Run-MockTests.ps1 - deterministic API / download / UI tests against a local mock.

    powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\Run-MockTests.ps1
    powershell ... -File tests\Run-MockTests.ps1 -NoUi    # skip the window test

    No network, no GitHub quota, no Pester.
#>

[CmdletBinding()]
param([switch]$NoUi)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Global:GHL_Root = $root
$Global:GHL_DebugLog = $false

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ghl-mock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

. (Join-Path $PSScriptRoot 'MockApi.ps1')

$mock = Start-GhlMockApi -WorkDir (Join-Path $tempRoot 'server')
$env:GHL_API_BASE = $mock.BaseUrl
$env:GHL_SMOKE_TEST = ''

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
    if ($Expected -ne $Actual) { throw ("expected '$Expected' but got '$Actual'. $Message") }
}

Write-Host ''
Write-Host ' GitHub Launcher - deterministic mock suite' -ForegroundColor Cyan
Write-Host (" mock api: " + $mock.BaseUrl) -ForegroundColor DarkGray
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray
Write-Host ''
Write-Host ' API against the mock' -ForegroundColor Yellow

Test-Case 'GET /users/{u}/repos returns normalised repositories' {
    $r = Get-GhlUserRepos -User 'mockuser'
    Assert-True $r.Ok "request failed: $($r.Message)"
    Assert-Equal 3 $r.Data.Count
    Assert-Equal 'demo-tool' $r.Data[0].Name
    Assert-Equal 'mockuser' $r.Data[0].Owner
    Assert-Equal 123 $r.Data[0].Stars
    Assert-Equal 55 $r.Remaining
}

Test-Case 'unknown user is classified as notfound' {
    $r = Get-GhlUserRepos -User 'ghost'
    Assert-True (-not $r.Ok)
    Assert-Equal 'notfound' $r.Kind
    Assert-True ($r.Message -match 'ghost') 'message must name the user'
}

Test-Case 'rate limit 403 carries the reset time' {
    $r = Get-GhlUserRepos -User 'limiteduser'
    Assert-True (-not $r.Ok)
    Assert-Equal 'ratelimit' $r.Kind
    Assert-True ($null -ne $r.ResetAt) 'reset time must be parsed'
    Assert-True ($r.Message -match 'resets') "message must explain the reset: $($r.Message)"
}

Test-Case 'latest release with assets' {
    $r = Get-GhlLatestRelease -User 'mockuser' -Repo 'demo-tool'
    Assert-True $r.Ok "failed: $($r.Message)"
    Assert-Equal 'v1.2.0' $r.Data.Tag
    Assert-Equal 4 $r.Data.Assets.Count

    $win = $r.Data.Assets | Where-Object { $_.Name -eq 'DemoTool-1.2.0-windows-x64.zip' }
    $linux = $r.Data.Assets | Where-Object { $_.Name -eq 'DemoTool-1.2.0-linux-x64.tar.gz' }
    $deb = $r.Data.Assets | Where-Object { $_.Name -eq 'demo-tool.deb' }
    $sum = $r.Data.Assets | Where-Object { $_.Name -eq 'checksums.txt' }

    Assert-True $win.Compatible 'windows zip must be compatible'
    Assert-True (-not $linux.Compatible) 'linux tarball must be rejected'
    Assert-True (-not $deb.Compatible) 'deb must be rejected'
    Assert-True (-not $sum.Compatible) 'checksums must be rejected'
    Assert-True ($win.Score -gt $linux.Score) 'windows asset must outrank linux'
}

Test-Case 'release without releases becomes norelease' {
    $r = Get-GhlLatestRelease -User 'mockuser' -Repo 'no-release'
    Assert-True (-not $r.Ok)
    Assert-Equal 'norelease' $r.Kind
}

Write-Host ''
Write-Host ' Downloads against the mock' -ForegroundColor Yellow

function New-TestSync {
    return [hashtable]::Synchronized(@{
            Phase           = 'idle'
            StatusText      = ''
            ProgressPercent = -1.0
            BytesReceived   = 0L
            BytesTotal      = -1L
            SpeedBps         = 0.0
            CancelRequested = $false
            Events          = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        })
}

Test-Case 'download writes the file atomically' {
    $sync = New-TestSync
    $out = Join-Path $tempRoot 'direct.exe'
    $r = Invoke-GhlDownload -Url "$($mock.BaseUrl)/dl/direct.exe" -OutFile $out -Sync $sync
    Assert-True (Test-Path -LiteralPath $out) 'file must exist'
    Assert-True (-not (Test-Path -LiteralPath "$out.part")) '.part must be gone'
    Assert-True ($r.Bytes -gt 1000) "unexpected size: $($r.Bytes)"
    Assert-Equal 100.0 $sync.ProgressPercent
}

Test-Case 'truncated transfer is rejected' {
    $sync = New-TestSync
    $out = Join-Path $tempRoot 'truncated.zip'
    $threw = $false
    $kind = ''
    try { [void](Invoke-GhlDownload -Url "$($mock.BaseUrl)/dl/truncated.zip" -OutFile $out -Sync $sync) }
    catch { $threw = $true; if ($_.Exception.Data['Kind']) { $kind = $_.Exception.Data['Kind'] } }
    Assert-True $threw 'a short transfer must fail'
    Assert-True (-not (Test-Path -LiteralPath $out)) 'no file may be produced'
    Assert-True (-not (Test-Path -LiteralPath "$out.part")) 'no .part may remain'
}

Test-Case 'cancel stops the download and cleans up' {
    $sync = New-TestSync
    $sync.CancelRequested = $true
    $out = Join-Path $tempRoot 'cancelled.zip'
    $threw = $false
    $cancelled = $false
    try { [void](Invoke-GhlDownload -Url "$($mock.BaseUrl)/dl/win.zip" -OutFile $out -Sync $sync) }
    catch { $threw = $true; if ($_.Exception.Message -match 'CANCELLED') { $cancelled = $true } }
    Assert-True $threw 'must abort'
    Assert-True $cancelled 'must report CANCELLED'
    Assert-True (-not (Test-Path -LiteralPath $out)) 'no file may be produced'
    Assert-True (-not (Test-Path -LiteralPath "$out.part")) 'no .part may remain'
}

Write-Host ''
Write-Host ' End-to-end through the real window' -ForegroundColor Yellow

$uiScript = Join-Path $PSScriptRoot 'Run-MockUi.ps1'
if ($NoUi) {
    Write-Host '  SKIP  window integration (-NoUi)' -ForegroundColor DarkGray
} else {
    # one child process per scenario: WPF only allows a single Application object
    # per AppDomain, so the scenarios cannot share this host.
    $scenarios = @(
        @{ Repo = 'demo-tool'; Label = 'release asset -> exe -> marker'; AutoRun = $false },
        @{ Repo = 'no-release'; Label = 'no releases -> source archive -> marker'; AutoRun = $false },
        @{ Repo = 'script-tool'; Label = 'run after download -> script launched'; AutoRun = $true }
    )

    foreach ($scenario in $scenarios) {
        $uiBase = Join-Path $tempRoot ('ui-' + $scenario.Repo)

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -User mockuser -Repo "{1}" -BaseDir "{2}"{3}' -f `
            $uiScript, $scenario.Repo, $uiBase, $(if ($scenario.AutoRun) { ' -AutoRun' } else { '' })
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['GHL_API_BASE'] = $mock.BaseUrl
        $psi.EnvironmentVariables['GHL_DEBUG'] = '1'

        $proc = [Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        [void]$proc.WaitForExit(180000)

        if ($stdout) { Write-Host ($stdout.TrimEnd() -split "`n" | ForEach-Object { "  $_" }) -ForegroundColor DarkGray }
        if ($stderr) { Write-Host ($stderr.TrimEnd() -split "`n" | ForEach-Object { "  $_" }) -ForegroundColor DarkYellow }

        if ($proc.ExitCode -eq 0) {
            $script:Passed++
            Write-Host ("  PASS  window: " + $scenario.Label) -ForegroundColor Green
        } else {
            $script:Failed++
            $script:Failures.Add("window ($($scenario.Repo)) :: exit code $($proc.ExitCode)")
            Write-Host ("  FAIL  window: " + $scenario.Label) -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------------------
Stop-GhlMockApi -Session $mock
Remove-Item Env:\GHL_API_BASE -ErrorAction SilentlyContinue
try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

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
