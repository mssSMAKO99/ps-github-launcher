<#
    Run-MockUi.ps1 - window-level end-to-end test against the mock API.
    Expects tests\Run-MockTests.ps1 to have exported $env:GHL_API_BASE.
#>

[CmdletBinding()]
param(
    [string]$User = 'mockuser',
    [string]$Repo = 'demo-tool',
    [string]$BaseDir,
    [switch]$AutoRun,
    [string]$BatchRepos = ''
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
$Global:GhlUiTestBatch = $BatchRepos

$resultFile = Join-Path ([IO.Path]::GetTempPath()) ('ghl-mockui-result-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
$script:Stage = 'boot'
$script:LastStage = ''
$script:Deadline = (Get-Date).AddSeconds(120)

function Save-Result {
    param([string]$Text)
    [IO.File]::WriteAllText($resultFile, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-GhlMockRequestCount {
    $log = [string]$env:GHL_MOCK_REQUEST_LOG
    if (-not $log -or -not (Test-Path -LiteralPath $log)) { return -1 }
    try { return @(Get-Content -LiteralPath $log -ErrorAction Stop).Count } catch { return -1 }
}

$script:SelectedVersion = ''
$script:VersionCount = 0
$script:InstalledText = ''

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

                # the launch confirmation is modal: click "Run" for the test
                if ($st.ConfirmWindow) {
                    $win = $st.ConfirmWindow
                    $stack = $win.Content.Child
                    foreach ($child in $stack.Children) {
                        if ($child -is [Windows.Controls.StackPanel]) {
                            foreach ($b in $child.Children) {
                                if ($b -is [Windows.Controls.Button] -and [string]$b.Content -eq 'Run') {
                                    Write-Host 'mock: confirming launch'
                                    $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                                }
                            }
                        }
                    }
                }

                switch ($script:Stage) {
                    'boot' {
                        $ui.cbUser.Text = $script:TestUser
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
                        if ($Global:GhlUiTestBatch) {
                            # multi-select: mark every requested repository and press Download once
                            $wanted = @($Global:GhlUiTestBatch -split ',' | ForEach-Object { $_.Trim() })
                            $ui.dgRepos.SelectedItems.Clear()
                            $found = 0
                            foreach ($name in $wanted) {
                                foreach ($r in $st.AllRepos) {
                                    if ($r.Name -eq $name -and $r.Owner -eq $script:TestUser) {
                                        [void]$ui.dgRepos.SelectedItems.Add($r)
                                        $found++
                                        break
                                    }
                                }
                            }
                            if ($found -ne $wanted.Count) { throw "only $found of $($wanted.Count) repositories were selectable" }
                            $script:Selected = $found
                            $script:Stage = 'batchwait'
                            return
                        }

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

                    'batchwait' {
                        # the batch uses the version shown in the details panel:
                        # wait until its release list has actually arrived
                        if (-not $st.Busy -and $st.ReleaseFor -and $st.SelectedRelease) {
                            $script:BatchTag = [string]$st.SelectedRelease.Tag
                            $script:Stage = 'batch'
                            $ui.btnDownload.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                        }
                    }

                    'batch' {
                        if (-not $st.Busy -and -not $st.Queue) {
                            # everything settled: check each folder
                            $done = 0
                            $skipped = 0
                            foreach ($name in @($Global:GhlUiTestBatch -split ',')) {
                                $n = $name.Trim()
                                $dir = Get-GhlRepoDir -BaseDir $script:TestBaseDir -User $script:TestUser -Repo $n
                                $marker = Join-Path $dir '.ghl.json'
                                if (Test-Path -LiteralPath $marker) {
                                    $done++
                                } else {
                                    $skipped++
                                }
                            }
                            $script:BatchDone = $done
                            $script:BatchSkipped = $skipped
                            $script:Stage = 'verify'
                        }
                    }

                    'release' {
                        if ($st.ReleaseFor -eq ('{0}/{1}' -f $script:TestUser, $script:TestRepo)) {
                            if ($st.Releases.Count -gt 0) {
                                $script:VersionCount = $st.Releases.Count

                                if ($script:TestRepo -eq 'demo-tool') {
                                    if ($script:VersionCount -ne 3) { throw "expected 3 versions, got $($script:VersionCount)" }
                                    if ($ui.cbRelease.Items.Count -ne 2) { throw "expected 2 stable versions in the picker, got $($ui.cbRelease.Items.Count)" }
                                    if (-not $st.SelectedRelease -or $st.SelectedRelease.Tag -ne 'v1.2.0') {
                                        throw "the newest stable version must be selected, got '$($st.SelectedRelease.Tag)'"
                                    }

                                    # pre-release filter must reuse the cache, not hit the network
                                    $before = Get-GhlMockRequestCount
                                    $ui.chkPrerelease.IsChecked = $true
                                    if ($ui.cbRelease.Items.Count -ne 3) { throw "pre-release filter did not add the version: $($ui.cbRelease.Items.Count)" }
                                    $after = Get-GhlMockRequestCount
                                    if ($before -ge 0 -and $after -gt $before) { throw "the pre-release filter made $($after - $before) HTTP request(s)" }
                                    $ui.chkPrerelease.IsChecked = $false
                                    if ($ui.cbRelease.Items.Count -ne 2) { throw 'turning the pre-release filter off did not restore the list' }

                                    # switch to an older version: assets must follow
                                    $oldItem = $ui.cbRelease.Items | Where-Object { $_.Tag -eq 'v1.1.0' } | Select-Object -First 1
                                    if (-not $oldItem) { throw 'v1.1.0 is missing from the version picker' }
                                    $ui.cbRelease.SelectedItem = $oldItem
                                    if (-not $st.SelectedRelease -or $st.SelectedRelease.Tag -ne 'v1.1.0') {
                                        throw "selecting v1.1.0 did not update the current release: '$($st.SelectedRelease.Tag)'"
                                    }
                                    $script:SelectedVersion = 'v1.1.0'
                                    $script:ReleaseTag = 'v1.1.0'
                                } else {
                                    if (-not $st.SelectedRelease) { throw 'no release was auto-selected' }
                                    $script:SelectedVersion = [string]$st.SelectedRelease.Tag
                                    $script:ReleaseTag = [string]$st.SelectedRelease.Tag
                                }

                                $firstCompatible = $null
                                $sawIncompatibleFirst = $false
                                foreach ($a in $st.Assets) {
                                    if ($a.Compatible -and -not $firstCompatible) { $firstCompatible = $a }
                                    if (-not $a.Compatible -and -not $firstCompatible) { $sawIncompatibleFirst = $true }
                                }

                                if (-not $firstCompatible) { throw 'no compatible asset was offered' }
                                if ($sawIncompatibleFirst) { throw 'incompatible assets must be listed after compatible ones' }
                                if ($script:TestRepo -eq 'demo-tool' -and $firstCompatible.Name -notmatch '1\.1\.0') {
                                    throw "assets did not switch to v1.1.0: $($firstCompatible.Name)"
                                }
                                if ($script:TestRepo -ne 'demo-tool' -and $firstCompatible.Name -notmatch 'windows') {
                                    throw "wrong asset chosen: $($firstCompatible.Name)"
                                }

                                $script:AssetName = $firstCompatible.Name
                                $script:AssetCount = $st.Assets.Count
                                $script:SelectedIndex = $ui.lstAssets.SelectedIndex
                            } else {
                                # repository without releases must fall back to source mode
                                if ($st.Mode -ne 'Source') { throw "expected source mode, got '$($st.Mode)'" }
                                if ($ui.rbModeSource.IsChecked -ne $true) { throw 'the source radio button must be selected' }
                                if ($st.Assets.Count -ne 1 -or -not $st.Assets[0].IsSource) {
                                    throw 'the source archive must be listed as the only asset'
                                }
                                $script:VersionCount = 0
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
                        if ($Global:GhlUiTestBatch) {
                            # third-tool only ships a Linux tarball -> must be skipped
                            if ($script:BatchDone -ne 2) { throw "expected 2 downloaded repos, got $($script:BatchDone)" }
                            if ($script:BatchSkipped -ne 1) { throw "expected 1 skipped repo, got $($script:BatchSkipped)" }

                            # every downloaded repo must carry the version chosen in the panel
                            foreach ($name in @('demo-tool', 'second-tool')) {
                                $dir = Get-GhlRepoDir -BaseDir $script:TestBaseDir -User $script:TestUser -Repo $name
                                $m = Get-Content -LiteralPath (Join-Path $dir '.ghl.json') -Raw | ConvertFrom-Json
                                if ([string]$m.Tag -ne [string]$script:BatchTag) {
                                    throw "$name was downloaded as '$($m.Tag)' instead of '$($script:BatchTag)'"
                                }
                            }

                            $badge = ''
                            foreach ($r in $st.AllRepos) {
                                if ($r.Name -eq 'demo-tool') { $badge = $r.Status }
                            }
                            if ($badge -ne 'Downloaded') { throw "badge for demo-tool is '$badge'" }
                            $script:DestDir = $script:TestBaseDir
                            $script:Badge = "$($script:BatchDone) done / $($script:BatchSkipped) skipped"
                            $script:ReleaseTag = "(batch $($script:BatchTag))"
                            $script:AssetName = "$($script:Selected) selected"
                            $script:MarkerTag = [string]$script:BatchTag
                            $script:InstalledText = ''
                            $script:Stage = 'done'
                            return
                        }

                        $dir = [string]$st.LastDownloadDir
                        $script:DestDir = $dir

                        if ($script:TestRepo -eq 'script-tool') {
                            # security property: a downloaded .ps1 carries the zone
                            # mark, so RemoteSigned refuses to run it. The test asserts
                            # that it is *not* silently executed.
                            $launched = Join-Path $dir 'launched.txt'
                            if (Test-Path -LiteralPath $launched) {
                                throw 'a downloaded script with the zone mark must not run under RemoteSigned'
                            }
                            $ps1 = Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.ps1' -Force | Select-Object -First 1
                            if (-not $ps1) { throw 'the script was not extracted' }
                            $zone = @(Get-Content -LiteralPath $ps1.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
                            if (-not $zone) { throw "$($ps1.Name) has no Zone.Identifier stream" }
                            $script:Motw = 'blocked-by-policy'
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
                            # extracted executables must carry the "from the internet" mark
                            $zone = @(Get-Content -LiteralPath $exe -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
                            if (-not $zone) { throw 'DemoTool.exe has no Zone.Identifier stream' }
                            if (($zone -join "`n") -notmatch 'ZoneId=3') { throw 'ZoneId must be 3 (internet)' }
                            $script:Motw = 'yes'
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
                        if ($script:TestRepo -eq 'demo-tool') {
                            if ($script:MarkerTag -ne $script:SelectedVersion) {
                                throw "the marker says '$($script:MarkerTag)' instead of '$($script:SelectedVersion)'"
                            }
                            $script:InstalledText = [string]$ui.txtInstalled.Text
                            if ($script:InstalledText -notmatch [regex]::Escape($script:SelectedVersion)) {
                                throw "the installed hint does not show the version: '$($script:InstalledText)'"
                            }

                            # regression: a second toast must be visible after the first faded out
                            Show-GhlToast -Message 'first toast' -Kind 'info' -Ms 100
                            $script:ToastAt = Get-Date
                            $script:Stage = 'toast'
                        } else {
                            $script:Stage = 'done'
                        }
                    }

                    'toast' {
                        if (((Get-Date) - $script:ToastAt).TotalMilliseconds -ge 700) {
                            Show-GhlToast -Message 'second toast' -Kind 'info' -Ms 5000
                            $script:ToastAt = Get-Date
                            $script:Stage = 'toastcheck'
                        }
                    }

                    'toastcheck' {
                        if (((Get-Date) - $script:ToastAt).TotalMilliseconds -ge 250) {
                            if ([double]$ui.toast.Opacity -lt 0.99) {
                                throw "the second toast is invisible (Opacity=$($ui.toast.Opacity))"
                            }
                            $script:Stage = 'done'
                        }
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
                    Save-Result ("OK`nrepos=$($script:RepoCount)`nversions=$($script:VersionCount)`nrelease=$($script:ReleaseTag)`nasset=$($script:AssetName)`nassets=$($script:AssetCount)`nmarkerTag=$($script:MarkerTag)`ninstalled=$($script:InstalledText)`nbadge=$($script:Badge)`ndir=$($script:DestDir)")
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

# never touch the user's real settings: point the app at a throwaway folder
$env:GHL_CONFIG_DIR = Join-Path $env:TEMP ('ghl-cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $env:GHL_CONFIG_DIR -Force | Out-Null
$configPath = Join-Path $env:GHL_CONFIG_DIR 'config.json'
$configBackup = $null
if (Test-Path -LiteralPath $configPath) { $configBackup = [IO.File]::ReadAllText($configPath) }

try {
    Start-GitHubLauncher -AutomationScript $automation
} finally {
    try { Remove-Item -LiteralPath $env:GHL_CONFIG_DIR -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

if (-not (Test-Path -LiteralPath $resultFile)) { throw 'the window produced no result' }
$text = [IO.File]::ReadAllText($resultFile)
Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

Write-Host ('   ' + ($text -replace "`n", "`n   ")) -ForegroundColor DarkGray

if (-not $text.StartsWith('OK')) { throw ($text -replace "`r?`n", ' | ') }
exit 0
