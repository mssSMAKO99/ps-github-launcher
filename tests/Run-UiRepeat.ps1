<#
    Run-UiRepeat.ps1 - the "second run in the same session" regression.

    Why this exists: Application.Run() shuts the dispatcher of its thread down for
    good, and only one Application may exist per AppDomain. Running the launcher
    twice in the same PowerShell session therefore used to die with a misleading
    "The interface failed to load" (the real cause: the styles never reached
    Application.Resources, so every StaticResource lookup threw).

    This suite runs the built artifact twice in one process, plus once via -File
    and once in an MTA host.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-UiRepeat.ps1
#>

[CmdletBinding()]
param([int]$SmokeTestMs = 1200)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$artifact = Join-Path $root 'GitHubLauncher.ps1'

if (-not (Test-Path -LiteralPath $artifact)) {
    & (Join-Path $root 'Compile.ps1') -SkipXamlTest -NoVersionBump | Out-Null
}
if (-not (Test-Path -LiteralPath $artifact)) { throw "Artifact not found: $artifact" }

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

function Invoke-Artifact {
    <#
        Runs the artifact in a child PowerShell and returns its output.
        A hard timeout prevents a stray interactive window from hanging the suite
        (the artifact skips the smoke timer whenever GHL_SMOKE_TEST is not set).
    #>
    param([string[]]$Arguments, [string]$Command, [int]$TimeoutSec = 90)

    if ($Command) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "{0}"' -f $Command.Replace('"', '\"')
    } else {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = (@('-NoProfile') + $Arguments | ForEach-Object {
                if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
            }) -join ' '
    }

    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['GHL_SMOKE_TEST'] = '1'
    $psi.EnvironmentVariables['GHL_SMOKE_TEST_MS'] = [string]$SmokeTestMs

    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        throw "the child process did not exit within ${TimeoutSec}s (a window probably stayed open)"
    }

    $text = $stdout.Result + $stderr.Result
    return @{
        Output = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        ExitCode = $proc.ExitCode
    }
}

Write-Host ''
Write-Host ' GitHub Launcher - repeat-start suite' -ForegroundColor Cyan
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray
Write-Host ''

Test-Case 'the artifact opens twice in one PowerShell session' {
    $quoted = $artifact.Replace("'", "''")
    $command = @(
        "`$env:GHL_SMOKE_TEST='1'"
        "Write-Output 'RUN1'"
        "& '$quoted'"
        "Write-Output 'RUN2'"
        "& '$quoted'"
        "Write-Output 'END'"
    ) -join '; '

    $result = Invoke-Artifact -Command $command
    $text = ($result.Output -join "`n")

    if ($text -notmatch 'SMOKE') {
        throw "the window never came up:`n$text"
    }
    if ($text -match 'Cannot create more than one instance') {
        throw "the second run hit the old Application bug:`n$text"
    }
    if ($text -match 'failed to load|failed to load') {
        throw "the interface failed to load:`n$text"
    }
    if ($text -notmatch 'END') {
        throw "the second run never completed:`n$text"
    }

    $smokeCount = ([regex]::Matches($text, 'SMOKE')).Count
    if ($smokeCount -lt 2) {
        throw "expected two window starts, got ${smokeCount}:`n$text"
    }
}

Test-Case 'the artifact runs from a file (-File) on an STA host' {
    $result = Invoke-Artifact -Arguments @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $artifact)
    $text = ($result.Output -join "`n")
    if ($text -notmatch 'SMOKE') { throw "no window start:`n$text" }
    if ($result.ExitCode -ne 0) { throw "exit code $($result.ExitCode)`n$text" }
}

Test-Case 'the artifact explains itself in an MTA host instead of crashing' {
    # -MTA forces a multi-threaded apartment; WPF cannot run there. GHL_RELAUNCHED
    # and GHL_HEADLESS make the process take the "cannot help you" branch instead
    # of spawning an STA child or blocking on a MessageBox.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -MTA -ExecutionPolicy Bypass -File "{0}"' -f $artifact
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['GHL_SMOKE_TEST'] = '1'
    $psi.EnvironmentVariables['GHL_HEADLESS'] = '1'

    $proc = [Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(60000)) {
        try { $proc.Kill() } catch { }
        throw 'the MTA child did not exit'
    }
    $text = ($out.Result + $err.Result)

    if ($text -match 'SMOKE') {
        throw "a window must not appear in a pure MTA host:`n$text"
    }
    if ($text -match 'not recognized') {
        throw "the script failed to even start in MTA:`n$text"
    }
    if ($proc.ExitCode -ne 0) {
        throw "exit code $($proc.ExitCode) in MTA:`n$text"
    }
}

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
