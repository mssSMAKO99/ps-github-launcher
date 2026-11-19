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

$automation = {
    param($window)

    $st = $Global:GhlState
    $ui = $st.UI
    $ui.txtUser.Text = [string]$Global:GhlShotUser
    $ui.txtBaseDir.Text = (Join-Path $env:TEMP 'ghl-shot-downloads')
    $ui.txtBg.Text = ''
    $ui.chkRunAfter.IsChecked = $false

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
                            $ui.Window.Topmost = $true
                            $ui.Window.Activate() | Out-Null
                            Start-Sleep -Milliseconds 250

                            # render the window itself: no DPI or occlusion surprises
                            $win = $ui.Window
                            $width = [int][Math]::Ceiling($win.ActualWidth)
                            $height = [int][Math]::Ceiling($win.ActualHeight)
                            if ($width -lt 10 -or $height -lt 10) { throw "window has no size ($width x $height)" }

                            $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
                                $width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                            $rtb.Render($win)

                            $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
                            [void]$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                            $stream = [IO.File]::Create([string]$Global:GhlShotOut)
                            try { $encoder.Save($stream) } finally { $stream.Dispose() }

                            $ui.Window.Topmost = $false
                            $script:Stage = 'done'
                        }
                    }
                }

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

$configPath = Join-Path $env:LOCALAPPDATA 'GitHubLauncher\config.json'
$configBackup = $null
if (Test-Path -LiteralPath $configPath) { $configBackup = [IO.File]::ReadAllText($configPath) }

try {
    Start-GitHubLauncher -AutomationScript $automation
} finally {
    if ($null -ne $configBackup) { [IO.File]::WriteAllText($configPath, $configBackup) }
    Stop-GhlMockApi -Session $mock
    Remove-Item Env:\GHL_API_BASE -ErrorAction SilentlyContinue
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

if (Test-Path -LiteralPath $Out) {
    Write-Host "Saved $Out ($([Math]::Round((Get-Item -LiteralPath $Out).Length / 1KB)) KB)" -ForegroundColor Green
    exit 0
}
Write-Host 'No screenshot was produced.' -ForegroundColor Red
exit 1
