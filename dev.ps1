<#
    dev.ps1 - run the app straight from source (no build step).
    The build pipeline exists for distribution; this is the fast loop.
#>
[CmdletBinding()]
param(
    [switch]$UiSmokeTest,
    [int]$SmokeTestMs = 1500
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Restarting in an STA PowerShell...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($UiSmokeTest) { $argList += @('-UiSmokeTest', '-SmokeTestMs', $SmokeTestMs) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
    return
}

$Global:GHL_Root = $PSScriptRoot

foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $file.FullName
}

Start-GitHubLauncher @PSBoundParameters
