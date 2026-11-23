<#
    Capture-Ui.ps1 - renders the real window against the mock API and saves a PNG.
    Intended for visual review during development.

    powershell -NoProfile -STA -ExecutionPolicy Bypass -File tools\Capture-Ui.ps1
    powershell ... -File tools\Capture-Ui.ps1 -Repo no-release -Out shot.png
#>

[CmdletBinding()]
param(
    [string]$User = 'mockuser',
    [string]$Repo = 'demo-tool',
    [string]$Out = (Join-Path $PSScriptRoot 'ui-screenshot.png'),
    [switch]$AfterDownload,
    [switch]$Settings,
    [string]$SettingsTab = 'General',
    [string]$Theme = '',
    [string]$Favorite = '',
    [string]$Background = ''
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'STA PowerShell required.' }

$root = Split-Path -Parent $PSScriptRoot
$Global:GHL_Root = $root
$Global:GHL_DebugLog = $false

. (Join-Path $root 'tests\MockApi.ps1')
$tempRoot = Join-Path $env:TEMP ('ghl-shot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$mock = Start-GhlMockApi -WorkDir (Join-Path $tempRoot 'server')
$env:GHL_API_BASE = $mock.BaseUrl

foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $file.FullName
}

$Global:GhlShotUser = $User
$Global:GhlShotRepo = $Repo
$Global:GhlShotOut = $Out
$Global:GhlShotDownload = [bool]$AfterDownload
$Global:GhlShotBackground = [string]$Background
$Global:GhlShotSettings = [bool]$Settings
$Global:GhlShotSettingsTab = [string]$SettingsTab
$Global:GhlShotTheme = [string]$Theme
$Global:GhlShotFavorite = [string]$Favorite
$Global:GhlShotBase = Join-Path $env:TEMP ('ghl-shot-downloads-' + [guid]::NewGuid().ToString('N').Substring(0, 6))

$automation = {
    param($window)

    $st = $Global:GhlState
    $ui = $st.UI
    $ui.cbUser.Text = [string]$Global:GhlShotUser
    # isolate the download folder: the UI textbox alone is not enough, all paths
    # are resolved from $st.Config.BaseDir, so set both
    $ui.txtBaseDir.Text = [string]$Global:GhlShotBase
    $st.Config.BaseDir = [string]$Global:GhlShotBase
    $ui.txtFooterInfo.Text = "Downloads: $($Global:GhlShotBase)"
    $ui.txtBg.Text = ''
    $ui.chkRunAfter.IsChecked = $false

    if ($Global:GhlShotTheme) { $ui.cbTheme.SelectedItem = [string]$Global:GhlShotTheme }

    if ($Global:GhlShotBackground) {
        $ui.txtBg.Text = [string]$Global:GhlShotBackground
        Apply-GhlBackgroundSource -Source ([string]$Global:GhlShotBackground)
    }

    $script:Stage = 'search'
    $script:Deadline = (Get-Date).AddSeconds(90)

    $tick = New-Object Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds(150)

    $tick.Add_Tick({
            param($s, $e)
            try {
                $st = $Global:GhlState
                $ui = $st.UI

                switch ($script:Stage) {
                    'search' {
                        $script:Stage = 'wait-repos'
                        Start-GhlSearch
                    }
                    'wait-repos' {
                        if (-not $st.Busy -and $st.AllRepos.Count -gt 0) {
                            foreach ($r in $st.AllRepos) {
                                if ($r.Name -eq $Global:GhlShotRepo) { $ui.dgRepos.SelectedItem = $r; break }
                            }
                            $script:Stage = 'wait-release'
                        }
                    }
                    'wait-release' {
                        if ($st.CurrentRelease -or ($st.ReleaseFor -and -not $st.Busy)) {
                            if ($Global:GhlShotDownload) {
                                $script:Stage = 'downloading'
                                $ui.chkRunAfter.IsChecked = $false
                                $ui.btnDownload.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                            } else {
                                $script:Stage = 'settle'
                                $script:SettleUntil = (Get-Date).AddMilliseconds(1200)
                            }
                        }
                    }
                    'downloading' {
                        if (-not $st.Busy -and $st.LastDownloadDir) {
                            $script:Stage = 'settle'
                            $script:SettleUntil = (Get-Date).AddMilliseconds(1400)
                        }
                    }
                    'settle' {
                        if ((Get-Date) -ge $script:SettleUntil) {
                            if ($Global:GhlShotSettings -and -not $script:SettingsShown) {
                                # give the overlay a layout pass before rendering
                                $script:SettingsShown = $true
                                Show-GhlSettings -Show $true
                                Select-GhlSettingsTab -Name ([string]$Global:GhlShotSettingsTab)
                                $script:SettleUntil = (Get-Date).AddMilliseconds(700)
                                return
                            }
                            $ui.Window.Topmost = $true
                            $ui.Window.Activate() | Out-Null
                            Start-Sleep -Milliseconds 250

                            # render the window itself: no DPI or occlusion surprises
                            $win = $ui.Window

                            # pending bindings and selection visuals are only applied
                            # during a layout pass; without this the capture shows
                            # stale text and unhighlighted rows
                            $win.UpdateLayout()
                            $win.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)
                            $win.UpdateLayout()

                            $width = [int][Math]::Ceiling($win.ActualWidth)
                            $height = [int][Math]::Ceiling($win.ActualHeight)
                            if ($width -lt 10 -or $height -lt 10) { throw "window has no size ($width x $height)" }

                            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
                                $width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                            # render twice: the first pass can catch the compositor
                            # mid-update and produces torn text in the capture
                            $rtb.Render($win)
                            $rtb.Render($win)

                            $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
                            [void]$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                            $stream = [IO.File]::Create([string]$Global:GhlShotOut)
                            try { $encoder.Save($stream) } finally { $stream.Dispose() }

                            $ui.Window.Topmost = $false
                            $script:Stage = 'done'
                        }
                    }                }

                if ((Get-Date) -gt $script:Deadline) {
                    $s.Stop()
                    Write-Host 'capture timed out' -ForegroundColor Red
                    $ui.Window.Close()
                }
                if ($script:Stage -eq 'done') {
                    $s.Stop()
                    $ui.Window.Close()
                }
            } catch {
                $s.Stop()
                Write-Host "capture failed: $($_.Exception.Message)" -ForegroundColor Red
                try { $Global:GhlState.UI.Window.Close() } catch { }
            }
        })
    $tick.Start()
}

# never touch the user's real settings: point the app at a throwaway folder
$env:GHL_CONFIG_DIR = Join-Path $env:TEMP ('ghl-cfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $env:GHL_CONFIG_DIR -Force | Out-Null
$configPath = Join-Path $env:GHL_CONFIG_DIR 'config.json'
$configBackup = $null
if (Test-Path -LiteralPath $configPath) { $configBackup = [IO.File]::ReadAllText($configPath) }

try {
    if ($Global:GhlShotFavorite) {
        # seed the throwaway config so the star and the filter have something to show
        $seed = Get-GhlDefaultConfig
        $seed.FavoriteRepos = @([string]$Global:GhlShotFavorite)
        [void](Save-GhlConfig -Config $seed)
    }
    Start-GitHubLauncher -AutomationScript $automation
} finally {
    try { Remove-Item -LiteralPath $env:GHL_CONFIG_DIR -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    Stop-GhlMockApi -Session $mock
    Remove-Item Env:\GHL_API_BASE -ErrorAction SilentlyContinue
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if ($Global:GhlShotBase -and (Test-Path -LiteralPath $Global:GhlShotBase)) {
        try { Remove-Item -LiteralPath $Global:GhlShotBase -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

if (Test-Path -LiteralPath $Out) {
    Write-Host "Saved $Out ($([Math]::Round((Get-Item -LiteralPath $Out).Length / 1KB)) KB)" -ForegroundColor Green
    exit 0
}
Write-Host 'No screenshot was produced.' -ForegroundColor Red
exit 1
