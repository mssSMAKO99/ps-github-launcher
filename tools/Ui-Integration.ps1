<#
    Ui-Integration.ps1
    End-to-end check: boots the real window, searches a user, picks a repository,
    waits for its release list and downloads the smallest compatible asset.

    powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\Ui-Integration.ps1
    powershell ... -File tools\Ui-Integration.ps1 -User octocat -Repo Hello-World
#>

[CmdletBinding()]
param(
    [string]$User = 'octocat',
    [string]$Repo = 'Hello-World',
    [string]$BaseDir = (Join-Path $env:TEMP ('ghl-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'This script must run in an STA PowerShell (use powershell.exe -STA).'
}

$root = Split-Path -Parent $PSScriptRoot
$Global:GHL_Root = $root
Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File |
    Sort-Object Name | ForEach-Object { . $_.FullName }

$resultFile = Join-Path ([IO.Path]::GetTempPath()) ('ghl-ui-result-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
$script:Stage = 'boot'
$script:Failure = ''

function Save-Result {
    param([string]$Text)
    [IO.File]::WriteAllText($resultFile, $Text, (New-Object Text.UTF8Encoding($false)))
}

$automation = {
    param($window)

    $st = $Global:GhlState
    $ui = $st.UI
    $deadline = (Get-Date).AddSeconds(180)

    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(200)

    $tick.Add_Tick({
            param($s, $e)

            try {
                $st = $Global:GhlState
                $ui = $st.UI

                switch ($script:Stage) {

                    'boot' {
                        $ui.cbUser.Text = $script:TestUser
                        $ui.txtBaseDir.Text = $script:TestBaseDir
                        $st.Config.BaseDir = $script:TestBaseDir
                        $ui.chkRunAfter.IsChecked = $false
                        $ui.txtFilter.Text = ''
                        $script:Stage = 'searching'
                        Start-GhlSearch
                    }

                    'searching' {
                        if (-not $st.Busy -and $st.AllRepos.Count -gt 0) {
                            $script:RepoCount = $st.AllRepos.Count
                            $script:Stage = 'selecting'
                        } elseif (-not $st.Busy -and $st.LastErrorText) {
                            throw "repository load failed: $($st.LastErrorText)"
                        }
                    }

                    'selecting' {
                        $row = $null
                        foreach ($r in $st.Repos) {
                            if ($r.Name -eq $script:TestRepo -and $r.Owner -eq $script:TestUser) { $row = $r; break }
                        }
                        if (-not $row) { throw "repository '$($script:TestRepo)' not found in the list" }

                        $ui.dgRepos.SelectedItem = $row
                        $script:Stage = 'release'
                    }

                    'release' {
                        if ($st.ReleaseFor -and $st.CurrentRelease) {
                            $script:ReleaseTag = [string]$st.CurrentRelease.Tag
                            Update-GhlAssetList

                            # pick the best compatible asset (highest score)
                            $best = $null
                            for ($i = 0; $i -lt $st.Assets.Count; $i++) {
                                $a = $st.Assets[$i]
                                if (-not $a.Compatible) { continue }
                                if (-not $best -or $a.Score -gt $st.Assets[$best].Score) { $best = $i }
                            }

                            if ($null -eq $best) {
                                $ui.rbModeSource.IsChecked = $true
                                $st.Mode = 'Source'
                                Update-GhlAssetList
                                $ui.lstAssets.SelectedIndex = 0
                            } else {
                                $ui.rbModeRelease.IsChecked = $true
                                $st.Mode = 'Release'
                                Update-GhlAssetList
                                $ui.lstAssets.SelectedIndex = $best
                            }
                            $script:AssetName = [string]$ui.lstAssets.SelectedItem.Name
                            $script:Stage = 'download'
                            $ui.btnDownload.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                        } elseif ($st.ReleaseFor -and -not $st.Busy -and -not $st.CurrentRelease) {
                            # repository without releases -> source mode
                            $ui.rbModeSource.IsChecked = $true
                            $st.Mode = 'Source'
                            Update-GhlAssetList
                            $script:ReleaseTag = '(none)'
                            $script:AssetName = 'source'
                            $script:Stage = 'download'
                            $ui.btnDownload.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                        }
                    }

                    'download' {
                        if (-not $st.Busy -and $st.LastDownloadDir) {
                            $script:Stage = 'verify'
                        } elseif (-not $st.Busy -and $st.BusyKind -eq '' -and -not $st.LastDownloadDir -and $ui.txtStatus.Text -match 'failed|cancel') {
                            throw "download failed: $($ui.txtStatus.Text)"
                        }
                    }

                    'verify' {
                        $dir = [string]$st.LastDownloadDir
                        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force |
                            Where-Object { $_.Name -ne '.ghl.json' })
                        if ($files.Count -eq 0) { throw "no files were written to $dir" }
                        $script:FileCount = $files.Count
                        $script:MarkerOk = Test-Path -LiteralPath (Join-Path $dir '.ghl.json')
                        $script:Stage = 'done'
                    }
                }

                if ($script:Stage -ne $script:LastStage) {
                    $script:LastStage = $script:Stage
                    Write-GhlLog ("automation stage -> {0} | busy={1} repos={2} releaseFor='{3}' hasRelease={4} assets={5}" -f `
                            $script:Stage, $st.Busy, $st.AllRepos.Count, $st.ReleaseFor,
                        ($null -ne $st.CurrentRelease), $st.Assets.Count) Debug
                }

                if ($script:Stage -eq 'done') {
                    $s.Stop()
                    Save-Result ("OK`nrepos=$($script:RepoCount)`nrelease=$($script:ReleaseTag)`nasset=$($script:AssetName)`nfiles=$($script:FileCount)`nmarker=$($script:MarkerOk)`ndir=$($st.LastDownloadDir)")
                    $ui.Window.Close()
                }

                if ((Get-Date) -gt $script:Deadline) {
                    throw "timed out while '$($script:Stage)'"
                }
            } catch {                $s.Stop()
                $script:Failure = $_.Exception.Message
                Save-Result ("FAIL[$($script:Stage)] $($script:Failure)")
                try { $Global:GhlState.UI.Window.Close() } catch { }
            }
        })

    $script:Deadline = $deadline
    $script:TestUser = [string]$Global:GhlUiTestUser
    $script:TestRepo = [string]$Global:GhlUiTestRepo
    $script:TestBaseDir = [string]$Global:GhlUiTestBase
    $tick.Start()
}

$Global:GhlUiTestUser = $User
$Global:GhlUiTestRepo = $Repo
$Global:GhlUiTestBase = $BaseDir

# keep the integration run away from the real settings file
# never touch the user's real settings: point the app at a throwaway folder
$env:GHL_CONFIG_DIR = Join-Path $env:TEMP ('ghl-cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $env:GHL_CONFIG_DIR -Force | Out-Null
$configPath = Join-Path $env:GHL_CONFIG_DIR 'config.json'
$configBackup = $null
if (Test-Path -LiteralPath $configPath) {
    $configBackup = [IO.File]::ReadAllText($configPath)
}

try {
    Start-GitHubLauncher -AutomationScript $automation
} finally {
    try { Remove-Item -LiteralPath $env:GHL_CONFIG_DIR -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

if (-not (Test-Path -LiteralPath $resultFile)) {
    Write-Host 'INTEGRATION: no result was produced (window closed early?)' -ForegroundColor Red
    exit 1
}

$text = [IO.File]::ReadAllText($resultFile)
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ($text -replace "`n", "`n  ") -ForegroundColor Cyan

$ok = $text.StartsWith('OK')

if (-not $KeepFiles) {
    try { Remove-Item -LiteralPath $BaseDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
} else {
    Write-Host "  files kept in $BaseDir"
}

if ($ok) {
    Write-Host ' INTEGRATION PASSED' -ForegroundColor Green
    exit 0
}

Write-Host ' INTEGRATION FAILED' -ForegroundColor Red
exit 1
