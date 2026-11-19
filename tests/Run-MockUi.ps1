<#
    Run-MockUi.ps1 - window-level end-to-end test against the mock API.
    Expects tests\Run-MockTests.ps1 to have exported $env:GHL_API_BASE.
#>

[CmdletBinding()]
param(
    [string]$User = 'mockuser',
    [string]$Repo = 'demo-tool',
    [string]$BaseDir,
    [switch]$AutoRun
)

$ErrorActionPreference = 'Stop'

if (-not $env:GHL_API_BASE) { throw '$env:GHL_API_BASE is not set - run this through tests\Run-MockTests.ps1.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'STA PowerShell is required.' }
if (-not $BaseDir) { $BaseDir = Join-Path ([IO.Path]::GetTempPath()) ('ghl-mockui-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }

$root = Split-Path -Parent $PSScriptRoot
$Global:GHL_Root = $root

# works both standalone and when invoked from the suite
if (-not (Get-Command Start-GitHubLauncher -CommandType Function -ErrorAction SilentlyContinue)) {
    Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File |
        Sort-Object Name | ForEach-Object { . $_.FullName }
}

$Global:GhlUiTestUser = $User
$Global:GhlUiTestRepo = $Repo
$Global:GhlUiTestBase = $BaseDir
$Global:GhlUiTestAutoRun = [bool]$AutoRun

$resultFile = Join-Path ([IO.Path]::GetTempPath()) ('ghl-mockui-result-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
$script:Stage = 'boot'
$script:LastStage = ''
$script:Deadline = (Get-Date).AddSeconds(120)

function Save-Result {
    param([string]$Text)
    [IO.File]::WriteAllText($resultFile, $Text, (New-Object Text.UTF8Encoding($false)))
}

$automation = {
    param($window)

    $st = $Global:GhlState
    $ui = $st.UI
    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(150)

    $tick.Add_Tick({
            param($s, $e)
            try {
                $st = $Global:GhlState
                $ui = $st.UI

                switch ($script:Stage) {
                    'boot' {
                        $ui.txtUser.Text = $script:TestUser
                        $ui.txtBaseDir.Text = $script:TestBaseDir
                        $st.Config.BaseDir = $script:TestBaseDir
                        $ui.chkRunAfter.IsChecked = [bool]$script:TestAutoRun
                        $script:Stage = 'searching'
                        Start-GhlSearch
                    }

                    'searching' {
                        if (-not $st.Busy -and $st.AllRepos.Count -gt 0) {
                            $script:RepoCount = $st.AllRepos.Count
                            $script:Stage = 'selecting'
                        } elseif (-not $st.Busy -and $st.LastErrorText) {
                            throw "load failed: $($st.LastErrorText)"
                        }
                    }

                    'selecting' {
                        $row = $null
                        foreach ($r in $st.AllRepos) {
                            if ($r.Name -eq $script:TestRepo -and $r.Owner -eq $script:TestUser) { $row = $r; break }
                        }
                        if (-not $row) { throw "repository '$($script:TestRepo)' missing from the list" }
                        $ui.dgRepos.SelectedItem = $row
                        if (-not $st.SelectedRow -or $st.SelectedRow.FullName -ne $row.FullName) {
                            throw 'selecting a row did not update the details panel'
                        }
                        $script:Stage = 'release'
                    }

                    'release' {
                        if ($st.ReleaseFor -eq ('{0}/{1}' -f $script:TestUser, $script:TestRepo)) {
                            if ($st.CurrentRelease) {
                                $script:ReleaseTag = [string]$st.CurrentRelease.Tag
                                $script:AssetCount = $st.Assets.Count

                                $firstCompatible = $null
                                $sawIncompatibleFirst = $false
                                foreach ($a in $st.Assets) {
                                    if ($a.Compatible -and -not $firstCompatible) { $firstCompatible = $a }
                                    if (-not $a.Compatible -and -not $firstCompatible) { $sawIncompatibleFirst = $true }
                                }

                                if (-not $firstCompatible) { throw 'no compatible asset was offered' }
                                if ($sawIncompatibleFirst) { throw 'incompatible assets must be listed after compatible ones' }
                                if ($firstCompatible.Name -notmatch 'windows') { throw "wrong asset chosen: $($firstCompatible.Name)" }

                                $script:AssetName = $firstCompatible.Name
                                $script:SelectedIndex = $ui.lstAssets.SelectedIndex
                            } else {
                                # repository without releases must fall back to source mode
                                if ($st.Mode -ne 'Source') { throw "expected source mode, got '$($st.Mode)'" }
                                if ($ui.rbModeSource.IsChecked -ne $true) { throw 'the source radio button must be selected' }
                                if ($st.Assets.Count -ne 1 -or -not $st.Assets[0].IsSource) {
                                    throw 'the source archive must be listed as the only asset'
                                }
                                $script:ReleaseTag = '(none)'
                                $script:AssetName = 'source'
                                $script:AssetCount = 1
                            }

                            $script:Stage = 'download'
                            $ui.btnDownload.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                        }
                    }

                    'download' {
                        if (-not $st.Busy -and $st.LastDownloadDir) { $script:Stage = 'verify' }
                        elseif (-not $st.Busy -and $ui.txtStatus.Text -match 'fail|cancel') {
                            throw "download failed: $($ui.txtStatus.Text)"
                        }
                    }

                    'verify' {
                        $dir = [string]$st.LastDownloadDir
                        $script:DestDir = $dir

                        if ($script:TestRepo -eq 'script-tool') {
                            # the archive only contains run.ps1, which must have been started
                            $launched = Join-Path $dir 'launched.txt'
                            if (-not (Test-Path -LiteralPath $launched)) {
                                if ((Get-Date) -gt $script:Deadline) {
                                    throw 'the downloaded script was not launched'
                                }
                                return
                            }
                        }

                        if ($script:TestRepo -eq 'demo-tool') {
                            $exe = Join-Path $dir 'DemoTool.exe'
                            if (-not (Test-Path -LiteralPath $exe)) {
                                $all = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force | ForEach-Object { $_.FullName })
                                throw "DemoTool.exe was not extracted. Files: $($all -join ', ')"
                            }
                            # the installer helper must not be chosen as the launch target
                            $markerPre = Get-Content -LiteralPath (Join-Path $dir '.ghl.json') -Raw | ConvertFrom-Json
                            if ([string]$markerPre.Executable -match 'unins') {
                                throw "the uninstaller was chosen as the launch target: $($markerPre.Executable)"
                            }
                        } elseif ($script:TestRepo -eq 'no-release') {
                            $readme = Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'README.md' -Force
                            if (-not $readme) { throw 'the source archive was not unpacked' }
                        }

                        $script:HasMarker = Test-Path -LiteralPath (Join-Path $dir '.ghl.json')
                        if (-not $script:HasMarker) { throw 'the marker file was not written' }

                        $row = $st.SelectedRow
                        $script:Badge = $row.Status
                        if ($row.Status -ne 'Downloaded') { throw "badge is '$($row.Status)' instead of 'Downloaded'" }

                        $marker = Get-Content -LiteralPath (Join-Path $dir '.ghl.json') -Raw | ConvertFrom-Json
                        $script:MarkerTag = [string]$marker.Tag

                        $script:Stage = 'done'
                    }
                }

                if ((Get-Date) -gt $script:Deadline) { throw "timed out while '$($script:Stage)'" }

                if ($script:Stage -ne $script:LastStage) {
                    $script:LastStage = $script:Stage
                    Write-GhlLog ("mock ui stage -> {0} | busy={1} repos={2} releaseFor='{3}' assets={4}" -f `
                            $script:Stage, $st.Busy, $st.AllRepos.Count, $st.ReleaseFor, $st.Assets.Count) Debug
                }

                if ($script:Stage -eq 'done') {
                    $s.Stop()
                    Save-Result ("OK`nrepos=$($script:RepoCount)`nrelease=$($script:ReleaseTag)`nasset=$($script:AssetName)`nassets=$($script:AssetCount)`nmarkerTag=$($script:MarkerTag)`nbadge=$($script:Badge)`ndir=$($script:DestDir)")
                    $ui.Window.Close()
                }
            } catch {
                $s.Stop()
                Save-Result ("FAIL[$($script:Stage)] $($_.Exception.Message)")
                Write-GhlLog ("mock ui failure at {0}: {1}" -f $script:Stage, $_.Exception.Message) Error
                try { $Global:GhlState.UI.Window.Close() } catch { }
            }
        })

    $script:TestUser = [string]$Global:GhlUiTestUser
    $script:TestRepo = [string]$Global:GhlUiTestRepo
    $script:TestBaseDir = [string]$Global:GhlUiTestBase
    $script:TestAutoRun = [bool]$Global:GhlUiTestAutoRun
    $tick.Start()
}

$configPath = Join-Path $env:LOCALAPPDATA 'GitHubLauncher\config.json'
$configBackup = $null
if (Test-Path -LiteralPath $configPath) { $configBackup = [IO.File]::ReadAllText($configPath) }

try {
    Start-GitHubLauncher -AutomationScript $automation
} finally {
    if ($null -ne $configBackup) { [IO.File]::WriteAllText($configPath, $configBackup) }
}

if (-not (Test-Path -LiteralPath $resultFile)) { throw 'the window produced no result' }
$text = [IO.File]::ReadAllText($resultFile)
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

Write-Host ('   ' + ($text -replace "`n", "`n   ")) -ForegroundColor DarkGray

if (-not $text.StartsWith('OK')) { throw ($text -replace "`r?`n", ' | ') }
exit 0
