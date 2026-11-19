<#
    08-Main.ps1
    WPF host: window, bindings, state machine, worker dispatch.
    The UI thread is the only thread that touches WPF objects.
#>

# ---------------------------------------------------------------------------
# .NET types used for binding
# ---------------------------------------------------------------------------

function Add-GhlTypeHelpers {
    if ('GhlRepoRow' -as [type]) { return }

    $code = @"
using System;
using System.ComponentModel;

public class GhlRepoRow : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;

    private void Raise(string name)
    {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) { h(this, new PropertyChangedEventArgs(name)); }
    }

    public string Name { get; set; }
    public string Owner { get; set; }
    public string FullName { get; set; }
    public string Description { get; set; }
    public string Language { get; set; }
    public int Stars { get; set; }
    public int Forks { get; set; }
    public DateTime Updated { get; set; }
    public string UpdatedText { get; set; }
    public string Url { get; set; }
    public string DefaultBranch { get; set; }
    public int Files { get; set; }

    private string _status = "Not downloaded";
    public string Status
    {
        get { return _status; }
        set
        {
            if (_status != value) { _status = value; Raise("Status"); }
        }
    }
}

public class GhlAssetItem
{
    public string Name { get; set; }
    public string SizeText { get; set; }
    public long Size { get; set; }
    public string Url { get; set; }
    public bool Compatible { get; set; }
    public bool IsArchive { get; set; }
    public bool IsSource { get; set; }
    public int Score { get; set; }
    public override string ToString() { return Name; }
}

public class GhlCandidate
{
    public string Name { get; set; }
    public string FullPath { get; set; }
    public string RelativePath { get; set; }
    public string SizeText { get; set; }
    public override string ToString() { return RelativePath; }
}
"@

    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Format-GhlRelativeDate {
    param([Nullable[DateTime]]$Value)

    if (-not $Value) { return '' }
    $d = ([DateTime]$Value).ToLocalTime()
    $span = (Get-Date) - $d

    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalMinutes -lt 60) { return ('{0}m ago' -f [int]$span.TotalMinutes) }
    if ($span.TotalHours -lt 24) { return ('{0}h ago' -f [int]$span.TotalHours) }
    if ($span.TotalDays -lt 30) { return ('{0}d ago' -f [int]$span.TotalDays) }
    if ($span.TotalDays -lt 365) { return ('{0}mo ago' -f [int]($span.TotalDays / 30)) }
    return ('{0}y ago' -f [int]($span.TotalDays / 365))
}

function Get-GhlNamedElement {
    param($Root, [string]$Name)

    $el = $Root.FindName($Name)
    if (-not $el) { $el = [Windows.LogicalTreeHelper]::FindLogicalNode($Root, $Name) }
    if (-not $el) { throw "XAML element '$Name' not found." }
    return $el
}

function Get-GhlUiMap {
    param($Window)

    $names = @(
        'RootBorder', 'TitleBar', 'btnMin', 'btnMax', 'btnClose', 'imgLogo', 'txtBuildTag',
        'txtUser', 'txtToken', 'chkRememberToken', 'btnSearch', 'txtRateLimit',
        'txtBaseDir', 'btnBrowseBase', 'chkRunAfter', 'chkPrerelease', 'btnOpenBase',
        'txtBg', 'btnBrowseBg', 'txtDimLabel', 'sldDim', 'btnClearBg', 'txtFooterInfo',
        'txtFilter', 'txtFilterPlaceholder', 'spinner', 'btnRefresh', 'txtCount',
        'dgRepos', 'pnlEmpty', 'txtEmptyTitle', 'txtEmptyHint',
        'txtRepoName', 'txtRepoDesc', 'txtRepoMeta',
        'rbModeRelease', 'rbModeSource', 'txtAssetsCaption', 'lstAssets',
        'btnDownload', 'btnOpenFolder', 'btnRepoPage',
        'prgDownload', 'txtStatus', 'txtSpeed', 'btnCancel', 'btnOpenLast',
        'toast', 'txtToast', 'imgBackground', 'rectDim',
        'rsN', 'rsS', 'rsW', 'rsE', 'rsNW', 'rsNE', 'rsSW', 'rsSE'
    )

    $map = @{}
    foreach ($n in $names) { $map[$n] = Get-GhlNamedElement -Root $Window -Name $n }
    return $map
}

# ---------------------------------------------------------------------------
# Runspace pool
# ---------------------------------------------------------------------------

function New-GhlRunspacePool {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    foreach ($name in (Get-GhlWorkerNames)) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Write-GhlLog "Worker function '$name' is not defined; skipping." Warn
            continue
        }
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $cmd.Definition)
        $iss.Commands.Add($entry)
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
    $pool.Open()
    Write-GhlLog 'Runspace pool opened.'
    return $pool
}

function Start-GhlWorker {
    param(
        [Parameter(Mandatory)][ValidateSet('Repos', 'Release', 'Download', 'Background')][string]$Kind,
        [hashtable]$Arguments = @{}
    )

    $state = $Global:GhlState

    if (-not $state.Pool) {
        Show-GhlToast -Message 'Background workers are not available.' -Kind 'error'
        return
    }

    # one live job per kind - newer request wins
    if ($state.Jobs.ContainsKey($Kind)) {
        try { $state.Jobs[$Kind].PS.Stop() } catch { }
        try { $state.Jobs[$Kind].PS.Dispose() } catch { }
        $state.Jobs.Remove($Kind)
    }

    $body = switch ($Kind) {
        'Repos'      { Get-GhlWorkerRepos }
        'Release'    { Get-GhlWorkerRelease }
        'Download'   { Get-GhlWorkerDownload }
        'Background' { Get-GhlWorkerBackground }
    }
    $text = Join-GhlWorkerScript -Body $body

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $state.Pool
    [void]$ps.AddScript($text)
    foreach ($k in $Arguments.Keys) {
        [void]$ps.AddParameter($k, $Arguments[$k])
    }

    $handle = $ps.BeginInvoke()
    $state.Jobs[$Kind] = @{ PS = $ps; Handle = $handle }
    Write-GhlLog "Worker '$Kind' started." Debug
}

# ---------------------------------------------------------------------------
# Toast / busy / status
# ---------------------------------------------------------------------------

function Stop-GhlToastTimer {
    $state = $Global:GhlState
    if ($state.ToastTimer) {
        $state.ToastTimer.Stop()
        $state.ToastTimer = $null
    }
}

function Show-GhlToast {
    param([string]$Message, [ValidateSet('info', 'success', 'warn', 'error')][string]$Kind = 'info', [int]$Ms = 4200)

    $state = $Global:GhlState
    $ui = $state.UI
    if (-not $ui -or -not $Message) { return }

    $ui.txtToast.Text = $Message
    switch ($Kind) {
        'success' { $ui.toast.BorderBrush = $state.Brushes.Success }
        'warn'    { $ui.toast.BorderBrush = $state.Brushes.Warn }
        'error'   { $ui.toast.BorderBrush = $state.Brushes.Danger }
        default   { $ui.toast.BorderBrush = $state.Brushes.Border }
    }

    $ui.toast.Opacity = 1
    Write-GhlLog "TOAST [$Kind] $Message" Debug

    Stop-GhlToastTimer
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $timer.Add_Tick({
            param($s, $e)
            $st = $Global:GhlState
            $s.Stop()
            $st.ToastTimer = $null
            if (-not $st -or -not $st.UI) { return }
            $anim = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @(
                1.0, 0.0, (New-Object Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(260))))
            try { $st.UI.toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim) } catch { }
        })
    $state.ToastTimer = $timer
    $timer.Start()
}

function Set-GhlBusy {
    param([bool]$Busy, [string]$Text = '')

    $state = $Global:GhlState
    $ui = $state.UI
    $state.Busy = $Busy

    if ($Busy) {
        $ui.spinner.Visibility = [Windows.Visibility]::Visible
        if ($Text) { $ui.txtStatus.Text = $Text }
    } else {
        $ui.spinner.Visibility = [Windows.Visibility]::Collapsed
    }

    $ui.btnSearch.IsEnabled = -not $Busy
    $ui.btnRefresh.IsEnabled = -not $Busy
    Update-GhlActionState
}

function Set-GhlStatus {
    param([string]$Text, [string]$Speed = '')

    $ui = $Global:GhlState.UI
    $ui.txtStatus.Text = $Text
    $ui.txtSpeed.Text = $Speed
}

# ---------------------------------------------------------------------------
# Repository list rendering
# ---------------------------------------------------------------------------

function Update-GhlRepoView {
    $state = $Global:GhlState
    $ui = $state.UI

    $selected = $null
    if ($ui.dgRepos.SelectedItem) { $selected = $ui.dgRepos.SelectedItem.FullName }

    $text = ''
    if ($ui.txtFilter.Text) { $text = $ui.txtFilter.Text.Trim().ToLowerInvariant() }
    $ui.txtFilterPlaceholder.Visibility = if ($text) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }

    $tokens = @()
    if ($text) { $tokens = @($text.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) }

    $state.SuppressSelection = $true
    try {
        $state.Repos.Clear()
        foreach ($row in $state.AllRepos) {
            if ($tokens.Count -gt 0) {
                $hay = ('{0} {1} {2} {3}' -f $row.Name, $row.Owner, $row.Description, $row.Language).ToLowerInvariant()
                $match = $true
                foreach ($t in $tokens) {
                    if ($hay.IndexOf($t, [StringComparison]::Ordinal) -lt 0) { $match = $false; break }
                }
                if (-not $match) { continue }
            }
            [void]$state.Repos.Add($row)
        }

        if ($selected) {
            foreach ($r in $state.Repos) {
                if ($r.FullName -eq $selected) { $ui.dgRepos.SelectedItem = $r; break }
            }
        }
    } finally {
        $state.SuppressSelection = $false
    }

    $total = $state.AllRepos.Count
    $shown = $state.Repos.Count
    if ($total -eq 0) {
        $ui.txtCount.Text = '-'
    } elseif ($shown -eq $total) {
        $ui.txtCount.Text = "$total repos"
    } else {
        $ui.txtCount.Text = "$shown of $total"
    }

    $emptyVisible = if ($shown -eq 0) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $ui.pnlEmpty.Visibility = $emptyVisible
    if ($total -gt 0 -and $shown -eq 0) {
        $ui.txtEmptyTitle.Text = 'Nothing matches the filter'
        $ui.txtEmptyHint.Text = 'Try a different keyword'
    } elseif ($state.LastErrorText) {
        $ui.txtEmptyTitle.Text = 'Could not load repositories'
        $ui.txtEmptyHint.Text = $state.LastErrorText
    } else {
        $ui.txtEmptyTitle.Text = 'No repositories loaded'
        $ui.txtEmptyHint.Text = 'Enter a GitHub username and press Load repositories'
    }
}

function Set-GhlRepoRows {
    param($Data, [string]$User)

    $state = $Global:GhlState
    $list = New-Object System.Collections.Generic.List[GhlRepoRow]

    foreach ($r in @($Data)) {
        if ($null -eq $r) { continue }
        $row = New-Object GhlRepoRow
        $row.Name = [string]$r.Name
        $row.Owner = [string]$r.Owner
        $row.FullName = [string]$r.FullName
        $row.Description = [string]$r.Description
        $row.Language = if ($r.Language) { [string]$r.Language } else { '-' }
        $row.Stars = [int]$r.Stars
        $row.Forks = [int]$r.Forks
        $row.Updated = if ($r.Updated) { [DateTime]$r.Updated } else { [DateTime]::MinValue }
        $row.UpdatedText = Format-GhlRelativeDate $r.Updated
        $row.Url = [string]$r.HtmlUrl
        $row.DefaultBranch = [string]$r.DefaultBranch
        $row.Status = Get-GhlRepoBadge -BaseDir $state.Config.BaseDir -User $row.Owner -Repo $row.Name
        $list.Add($row)
    }

    $state.AllRepos = $list.ToArray()
    $state.ReleaseCache = @{}
    Update-GhlRepoView
}

function Update-GhlRowBadge {
    param([string]$User, [string]$Repo)

    $state = $Global:GhlState
    foreach ($row in $state.AllRepos) {
        if ($row.Owner -eq $User -and $row.Name -eq $Repo) {
            $row.Status = Get-GhlRepoBadge -BaseDir $state.Config.BaseDir -User $User -Repo $Repo
        }
    }
}

function Update-GhlAllBadges {
    $state = $Global:GhlState
    foreach ($row in $state.AllRepos) {
        $row.Status = Get-GhlRepoBadge -BaseDir $state.Config.BaseDir -User $row.Owner -Repo $row.Name
    }
}

# ---------------------------------------------------------------------------
# Details panel
# ---------------------------------------------------------------------------

function Update-GhlActionState {
    $state = $Global:GhlState
    $ui = $state.UI
    if (-not $ui) { return }

    $row = $state.SelectedRow
    $busy = [bool]$state.Busy
    $hasRow = ($null -ne $row)

    $ui.btnDownload.IsEnabled = ($hasRow -and -not $busy -and $state.Mode -eq 'Source') -or
                                ($hasRow -and -not $busy -and $state.Mode -eq 'Release' -and $null -ne $ui.lstAssets.SelectedItem -and $ui.lstAssets.SelectedItem.Compatible)

    $canOpen = $false
    if ($hasRow) {
        $dir = Get-GhlRepoDir -BaseDir $state.Config.BaseDir -User $row.Owner -Repo $row.Name
        $canOpen = Test-Path -LiteralPath $dir
    }
    $ui.btnOpenFolder.IsEnabled = ($canOpen -and -not $busy)
    $ui.btnRepoPage.IsEnabled = ($hasRow -and -not $busy)

    $ui.rbModeRelease.IsEnabled = ($hasRow -and -not $busy -and $null -ne $state.CurrentRelease)
    $ui.rbModeSource.IsEnabled = ($hasRow -and -not $busy)

    if ($hasRow) {
        $label = if ($ui.chkRunAfter.IsChecked) { 'Download & run' } else { 'Download' }
        if ($state.Mode -eq 'Release' -and $null -eq $ui.lstAssets.SelectedItem) { $label = 'Select an asset' }
        $ui.btnDownload.Content = $label
    } else {
        $ui.btnDownload.Content = 'Download'
    }

    $ui.btnCancel.Visibility = if ($state.Busy -and $state.BusyKind -in @('Download')) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $ui.btnOpenLast.Visibility = if ($state.LastDownloadDir) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
}

function Reset-GhlDetails {
    $state = $Global:GhlState
    $ui = $state.UI
    $state.SelectedRow = $null
    $state.CurrentRelease = $null
    $state.ReleaseFor = ''
    $state.Assets.Clear()
    $ui.txtRepoName.Text = 'No repository selected'
    $ui.txtRepoDesc.Text = ''
    $ui.txtRepoMeta.Text = ''
    $ui.txtAssetsCaption.Text = 'Assets'
    Update-GhlActionState
}

function Show-GhlRepoDetails {
    param($Row)

    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $Row) {
        Reset-GhlDetails
        return
    }

    $state.SelectedRow = $Row
    $ui.txtRepoName.Text = $Row.Name
    $ui.txtRepoDesc.Text = if ($Row.Description) { $Row.Description } else { 'No description.' }
    $meta = '{0}  |  {1} stars  |  {2} forks  |  updated {3}' -f $Row.Language, $Row.Stars, $Row.Forks, $Row.UpdatedText
    if ($Row.Owner) { $meta = "$($Row.Owner)  |  $meta" }
    $ui.txtRepoMeta.Text = $meta

    $key = $Row.FullName
    if ($state.ReleaseCache.ContainsKey($key)) {
        $entry = $state.ReleaseCache[$key]
        if (((Get-Date) - $entry.Ts).TotalMinutes -lt 5) {
            Apply-GhlRelease -Release $entry.Release -Row $Row
            return
        }
        $state.ReleaseCache.Remove($key)
    }

    $state.CurrentRelease = $null
    $state.ReleaseFor = ''
    $ui.txtAssetsCaption.Text = 'Loading release information...'
    $state.Assets.Clear()
    Update-GhlActionState
    Start-GhlReleaseJob -Row $Row
}

function Apply-GhlRelease {
    param($Release, $Row)

    $state = $Global:GhlState
    $ui = $state.UI

    $state.CurrentRelease = $Release
    $state.ReleaseFor = if ($Row) { $Row.FullName } else { '' }

    if ($Release) {
        $ui.txtAssetsCaption.Text = 'Assets | {0}' -f $Release.Tag
        if (-not $state.Mode) { $state.Mode = 'Release' }
    } else {
        $ui.txtAssetsCaption.Text = 'No release assets - source only'
        $state.Mode = 'Source'
        $ui.rbModeSource.IsChecked = $true
    }

    Update-GhlAssetList
    Update-GhlActionState
}

function Update-GhlAssetList {
    $state = $Global:GhlState
    $ui = $state.UI

    $previous = ''
    if ($ui.lstAssets.SelectedItem) { $previous = $ui.lstAssets.SelectedItem.Name }

    $state.Assets.Clear()

    if ($state.Mode -eq 'Source') {
        $src = New-Object GhlAssetItem
        $src.Name = 'Source archive (.zip)'
        $src.SizeText = 'branch'
        $src.IsSource = $true
        $src.Compatible = $true
        $src.Score = 1000
        [void]$state.Assets.Add($src)
    } elseif ($state.CurrentRelease) {
        $list = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($a in @($state.CurrentRelease.Assets)) {
            $item = New-Object GhlAssetItem
            $item.Name = [string]$a.Name
            $item.Size = [long]$a.Size
            $item.SizeText = Format-GhlSize $a.Size
            $item.Url = [string]$a.Url
            $item.Compatible = [bool]$a.Compatible
            $item.Score = [int]$a.Score
            $item.IsArchive = [bool]$a.IsArchive
            $item.IsSource = $false
            $list.Add($item)
        }
        # usable packages first, then by relevance, then by size
        foreach ($item in ($list | Sort-Object -Property @{ Expression = 'Compatible'; Descending = $true },
                @{ Expression = 'Score'; Descending = $true },
                @{ Expression = 'Name'; Descending = $false })) {
            [void]$state.Assets.Add($item)
        }
    }

    $ui.lstAssets.ItemsSource = $state.Assets

    # auto-select: the remembered name, otherwise the highest-scoring usable asset
    $index = -1
    $bestScore = [int]::MinValue
    if ($previous) {
        for ($i = 0; $i -lt $state.Assets.Count; $i++) {
            if ($state.Assets[$i].Name -eq $previous -and $state.Assets[$i].Compatible) { $index = $i; break }
        }
    }
    if ($index -lt 0) {
        for ($i = 0; $i -lt $state.Assets.Count; $i++) {
            $a = $state.Assets[$i]
            if (-not $a.Compatible) { continue }
            if ($a.Score -gt $bestScore) { $bestScore = $a.Score; $index = $i }
        }
    }
    $ui.lstAssets.SelectedIndex = $index
    Update-GhlActionState
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Get-GhlCurrentToken {
    $ui = $Global:GhlState.UI
    $token = ''
    if ($ui.txtToken -and $ui.txtToken.Password) { $token = $ui.txtToken.Password }
    if (-not $token) { $token = Get-GhlStoredToken -Config $Global:GhlState.Config }
    return $token
}

function Start-GhlSearch {
    $state = $Global:GhlState
    $ui = $state.UI

    if ($state.Busy) { return }

    $user = ''
    if ($ui.txtUser.Text) { $user = $ui.txtUser.Text.Trim().TrimStart('@') }
    if (-not $user) {
        Show-GhlToast -Message 'Enter a GitHub username first.' -Kind 'warn'
        $ui.txtUser.Focus() | Out-Null
        return
    }

    $state.LastErrorText = ''
    $state.Sync.Phase = 'repos'
    $state.Sync.StatusText = "Loading repositories of $user..."
    $state.Sync.ProgressPercent = -1.0
    $state.Sync.CancelRequested = $false

    Set-GhlBusy -Busy $true -Text "Loading repositories of $user..."
    Set-GhlStatus -Text "Contacting GitHub..."
    $ui.prgDownload.Value = 0

    Start-GhlWorker -Kind 'Repos' -Arguments @{
        Sync  = $state.Sync
        User  = $user
        Token = (Get-GhlCurrentToken)
    }
}

function Start-GhlReleaseJob {
    param($Row)

    $state = $Global:GhlState
    $state.Sync.Phase = 'release'
    $state.Sync.CancelRequested = $false
    Start-GhlWorker -Kind 'Release' -Arguments @{
        Sync              = $state.Sync
        User              = $Row.Owner
        Repo              = $Row.Name
        Token             = (Get-GhlCurrentToken)
        IncludePrerelease = [bool]$state.UI.chkPrerelease.IsChecked
    }
}

function Start-GhlDownload {
    $state = $Global:GhlState
    $ui = $state.UI

    if ($state.Busy) { return }

    $row = $state.SelectedRow
    if (-not $row) {
        Show-GhlToast -Message 'Select a repository first.' -Kind 'warn'
        return
    }

    $asset = $ui.lstAssets.SelectedItem
    if (-not $asset) {
        Show-GhlToast -Message 'Select a file to download.' -Kind 'warn'
        return
    }
    if (-not $asset.Compatible) {
        Show-GhlToast -Message "`"$($asset.Name)`" is not a Windows-executable package." -Kind 'warn'
        return
    }

    $url = $asset.Url
    $fileName = $asset.Name
    $tag = ''

    if ($state.Mode -eq 'Source') {
        $src = New-GhlSourceArchive -User $row.Owner -Repo $row.Name
        $url = $src.Url
        $fileName = $src.FileName
    } else {
        if (-not $state.CurrentRelease -or $state.ReleaseFor -ne $row.FullName) {
            Show-GhlToast -Message 'Release information is still loading.' -Kind 'warn'
            return
        }
        $tag = [string]$state.CurrentRelease.Tag
    }

    $dest = Get-GhlRepoDir -BaseDir $state.Config.BaseDir -User $row.Owner -Repo $row.Name
    $parent = Split-Path -Parent $dest
    if (-not (Test-GhlWritablePath -Path $parent)) {
        Show-GhlToast -Message "Cannot write to '$parent'. Choose another base folder." -Kind 'error'
        return
    }

    # free space guard (only when the size is known)
    if ($asset.Size -gt 0) {
        $free = Get-GhlFreeSpace -Path $parent
        if ($free -gt 0 -and $free -lt ($asset.Size * 1.15)) {
            Show-GhlToast -Message ('Not enough free space: need about {0}, have {1}.' -f (Format-GhlSize $asset.Size), (Format-GhlSize $free)) -Kind 'error'
            return
        }
    }

    $state.Sync.CancelRequested = $false
    $state.Sync.BytesReceived = 0L
    $state.Sync.BytesTotal = [long]$asset.Size
    $state.Sync.ProgressPercent = 0.0
    $state.Sync.SpeedBps = 0.0
    $state.Sync.Phase = 'downloading'

    $job = @{
        Url      = $url
        FileName = (ConvertTo-GhlSafeName -Name $fileName)
        DestDir  = $dest
        Mode     = $state.Mode
        Tag      = $tag
        Token    = (Get-GhlCurrentToken)
        User     = $row.Owner
        Repo     = $row.Name
        AutoRun  = [bool]$ui.chkRunAfter.IsChecked
    }

    $state.BusyKind = 'Download'
    Set-GhlBusy -Busy $true
    Set-GhlStatus -Text "Preparing download of $($job.FileName)..."
    $ui.prgDownload.Value = 0

    Start-GhlWorker -Kind 'Download' -Arguments @{ Sync = $state.Sync; Job = $job }
}

function Cancel-GhlDownload {
    $state = $Global:GhlState
    if (-not $state.Sync) { return }
    $state.Sync.CancelRequested = $true
    Set-GhlStatus -Text 'Cancelling...'
    Write-GhlLog 'Cancel requested by user.'
}

function ConvertTo-GhlCandidateObjects {
    param($Raw)

    $list = New-Object System.Collections.Generic.List[GhlCandidate]
    foreach ($c in @($Raw)) {
        if ($null -eq $c) { continue }
        $item = New-Object GhlCandidate
        $item.Name = [string]$c.Name
        $item.FullPath = [string]$c.FullPath
        $item.RelativePath = [string]$c.RelativePath
        $item.SizeText = [string]$c.SizeText
        $list.Add($item)
    }
    return $list
}

function Start-GhlLaunchTarget {
    param([string]$FullPath)

    try {
        $what = Start-GhlItem -Path $FullPath -WorkingDirectory (Split-Path -Parent $FullPath)
        Show-GhlToast -Message "Launched $what" -Kind 'success'
        Set-GhlStatus -Text "Launched $what"
    } catch {
        Show-GhlToast -Message "Could not start the program: $($_.Exception.Message)" -Kind 'error'
        Write-GhlLog "Launch failed for '$FullPath': $($_.Exception.Message)" Error
    }
}

function Show-GhlPickerDialog {
    param($Candidates, [string]$RepoName)

    $state = $Global:GhlState
    $xaml = Get-GhlXaml -Name 'PickerWindow'
    try {
        $win = [Windows.Markup.XamlReader]::Parse($xaml)
    } catch {
        Write-GhlLog "Picker window failed to load: $($_.Exception.Message)" Error
        return $null
    }

    $win.Owner = $state.UI.Window
    $win.Icon = $state.UI.Window.Icon

    $lst = $win.FindName('lstPicker')
    $txt = $win.FindName('txtPickerFilter')
    $hint = $win.FindName('txtPickerFilterHint')
    $chkAlways = $win.FindName('chkAlways')
    $btnOk = $win.FindName('btnPickerOk')
    $btnCancel = $win.FindName('btnPickerCancel')
    $txtHint = $win.FindName('txtPickerHint')

    $txtHint.Text = "The archive of $RepoName contains more than one runnable file. Pick the one to start."

    $items = ConvertTo-GhlCandidateObjects -Raw $Candidates
    $view = New-Object System.Collections.ObjectModel.ObservableCollection[GhlCandidate]
    foreach ($i in $items) { [void]$view.Add($i) }
    $lst.ItemsSource = $view
    if ($view.Count -gt 0) { $lst.SelectedIndex = 0 }

    $filter = {
        param($s, $e)
        $text = $s.Text
        if ($text) { $hint.Visibility = [Windows.Visibility]::Collapsed } else { $hint.Visibility = [Windows.Visibility]::Visible }
        $text = ([string]$text).Trim().ToLowerInvariant()
        $view.Clear()
        foreach ($i in $items) {
            if (-not $text -or $i.RelativePath.ToLowerInvariant().Contains($text)) { [void]$view.Add($i) }
        }
        if ($view.Count -gt 0) { $lst.SelectedIndex = 0 }
    }
    $txt.Add_TextChanged($filter)
    $txt.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [Windows.Input.Key]::Enter) { $btnOk.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
        })

    $Global:GhlPickerResult = $null

    $btnOk.Add_Click({
            param($s, $e)
            $picked = $lst.SelectedItem
            if (-not $picked) { return }
            $Global:GhlPickerResult = @{
                Candidate = $picked
                Remember  = [bool]$chkAlways.IsChecked
            }
            $win.DialogResult = $true
        })
    $btnCancel.Add_Click({
            param($s, $e)
            $win.DialogResult = $false
        })

    $Global:GhlState.PickerWindow = $win
    try {
        [void]$win.ShowDialog()
    } catch {
        Write-GhlLog "Picker dialog failed: $($_.Exception.Message)" Error
    } finally {
        $Global:GhlState.PickerWindow = $null
        try { $win.Close() } catch { }
    }

    $result = $Global:GhlPickerResult
    $Global:GhlPickerResult = $null
    return $result
}

function Set-GhlRememberedExecutable {
    param([string]$Dir, [string]$RelativePath)

    try {
        $path = Get-GhlMarkerPath -Directory $Dir
        if (-not (Test-Path -LiteralPath $path)) { return }
        $marker = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $marker.Executable = $RelativePath
        $json = $marker | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
        Write-GhlLog "Remembered launcher '$RelativePath' for '$Dir'."
    } catch {
        Write-GhlLog "Could not store launcher choice: $($_.Exception.Message)" Warn
    }
}

# ---------------------------------------------------------------------------
# Background / appearance
# ---------------------------------------------------------------------------

function Get-GhlBackgroundCachePath {
    param([string]$Url)

    $sha = [Security.Cryptography.SHA1]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($Url)
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $sha.Dispose()

    $ext = '.img'
    if ($Url -match '\.(jpg|jpeg|png|bmp|gif|webp)(\?|$)') { $ext = '.' + $Matches[1].ToLowerInvariant() }
    return (Join-Path (Join-Path (Get-GhlAppDir) 'bg') ($hash + $ext))
}

function Set-GhlBackgroundImage {
    param([string]$Path)

    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $ui.imgBackground.Source = $null
        $ui.imgBackground.Visibility = [Windows.Visibility]::Collapsed
        $ui.rectDim.Opacity = 0
        return
    }

    try {
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.UriSource = New-Object Uri($Path, [UriKind]::Absolute)
        $bmp.EndInit()
        $bmp.Freeze()

        $ui.imgBackground.Source = $bmp
        $ui.imgBackground.Visibility = [Windows.Visibility]::Visible
        $ui.rectDim.Opacity = [Math]::Min(0.95, [Math]::Max(0.0, ($ui.sldDim.Value / 100.0)))
        Write-GhlLog "Background image applied: $Path"
    } catch {
        Write-GhlLog "Background image could not be loaded: $($_.Exception.Message)" Warn
        Show-GhlToast -Message "Could not load that image: $($_.Exception.Message)" -Kind 'warn'
        $ui.imgBackground.Source = $null
        $ui.imgBackground.Visibility = [Windows.Visibility]::Collapsed
        $ui.rectDim.Opacity = 0
    }
}

function Apply-GhlBackgroundSource {
    param([string]$Source)

    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $Source) {
        Set-GhlBackgroundImage -Path ''
        return
    }

    if ($Source -match '^https?://') {
        $cached = Get-GhlBackgroundCachePath -Url $Source
        if (Test-Path -LiteralPath $cached) {
            Set-GhlBackgroundImage -Path $cached
            return
        }
        Show-GhlToast -Message 'Downloading background image...' -Kind 'info' -Ms 2000
        Start-GhlWorker -Kind 'Background' -Arguments @{
            Sync    = $state.Sync
            Url     = $Source
            OutFile = $cached
        }
        return
    }

    if (Test-Path -LiteralPath $Source) {
        Set-GhlBackgroundImage -Path $Source
    } else {
        Show-GhlToast -Message "Background image not found: $Source" -Kind 'warn'
    }
}

# ---------------------------------------------------------------------------
# Window chrome
# ---------------------------------------------------------------------------

function Set-GhlMaximized {
    param([bool]$On)

    $state = $Global:GhlState
    $ui = $state.UI
    $win = $ui.Window

    if ($On -and -not $state.Maximized) {
        $state.RestoreBounds = @{ Left = $win.Left; Top = $win.Top; Width = $win.Width; Height = $win.Height }
        $wa = [Windows.SystemParameters]::WorkArea
        $win.Left = $wa.Left
        $win.Top = $wa.Top
        $win.Width = $wa.Width
        $win.Height = $wa.Height
        $state.Maximized = $true
        $ui.RootBorder.CornerRadius = New-Object Windows.CornerRadius 0
        $ui.btnMax.Content = [string][char]0xE923
        $ui.btnMax.ToolTip = 'Restore'
    } elseif (-not $On -and $state.Maximized) {
        $b = $state.RestoreBounds
        if ($b) {
            $win.Left = $b.Left
            $win.Top = $b.Top
            $win.Width = $b.Width
            $win.Height = $b.Height
        }
        $state.Maximized = $false
        $ui.RootBorder.CornerRadius = New-Object Windows.CornerRadius 12
        $ui.btnMax.Content = [string][char]0xE922
        $ui.btnMax.ToolTip = 'Maximize'
    }
}

function Connect-GhlResizeThumb {
    param($Thumb, [string]$Edge)

    $Thumb.Add_DragDelta({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.Maximized) { return }
            $win = $st.UI.Window
            $minW = $win.MinWidth
            $minH = $win.MinHeight
            $h = $e.HorizontalChange
            $v = $e.VerticalChange

            if ($Edge -match 'E') { $win.Width = [Math]::Max($minW, $win.Width + $h) }
            if ($Edge -match 'S') { $win.Height = [Math]::Max($minH, $win.Height + $v) }
            if ($Edge -match 'W') {
                $newLeft = $win.Left + $h
                $newWidth = $win.Width - $h
                if ($newWidth -ge $minW) { $win.Left = $newLeft; $win.Width = $newWidth }
            }
            if ($Edge -match 'N') {
                $newTop = $win.Top + $v
                $newHeight = $win.Height - $v
                if ($newHeight -ge $minH) { $win.Top = $newTop; $win.Height = $newHeight }
            }
        })
}

# ---------------------------------------------------------------------------
# Config <-> UI
# ---------------------------------------------------------------------------

function Save-GhlUiConfig {
    $state = $Global:GhlState
    $ui = $state.UI
    $cfg = $state.Config

    try {
        $cfg.BaseDir = [string]$ui.txtBaseDir.Text
        $cfg.BackgroundPath = [string]$ui.txtBg.Text
        $cfg.BackgroundKind = if ($cfg.BackgroundPath -match '^https?://') { 'url' } else { 'file' }
        $cfg.DimmingOpacity = [Math]::Round($ui.sldDim.Value / 100.0, 3)
        $cfg.DownloadMode = if ($ui.rbModeSource.IsChecked) { 'Source' } else { 'Release' }
        $cfg.RunAfterDownload = [bool]$ui.chkRunAfter.IsChecked
        $cfg.IncludePrerelease = [bool]$ui.chkPrerelease.IsChecked
        if ($ui.txtUser.Text) { $cfg.LastUser = [string]$ui.txtUser.Text.Trim() }

        $token = ''
        if ($ui.txtToken.Password) { $token = $ui.txtToken.Password }
        if ($ui.chkRememberToken.IsChecked -and $token) {
            $cipher = Protect-GhlSecret -PlainText $token
            if ($cipher) {
                $cfg.PatCipher = $cipher
                $cfg.PatPlain = ''
            } else {
                # DPAPI unavailable: store plaintext only when the user asked for it
                $cfg.PatPlain = $token
            }
        } elseif (-not $ui.chkRememberToken.IsChecked) {
            $cfg.PatCipher = ''
            $cfg.PatPlain = ''
        }

        $w = $ui.Window
        if ($state.Maximized -and $state.RestoreBounds) {
            $cfg.Window.Width = [Math]::Round($state.RestoreBounds.Width)
            $cfg.Window.Height = [Math]::Round($state.RestoreBounds.Height)
            $cfg.Window.Left = [Math]::Round($state.RestoreBounds.Left)
            $cfg.Window.Top = [Math]::Round($state.RestoreBounds.Top)
            $cfg.Window.Maximized = $true
        } else {
            $cfg.Window.Width = [Math]::Round($w.Width)
            $cfg.Window.Height = [Math]::Round($w.Height)
            $cfg.Window.Left = [Math]::Round($w.Left)
            $cfg.Window.Top = [Math]::Round($w.Top)
            $cfg.Window.Maximized = $false
        }

        [void](Save-GhlConfig -Config $cfg)
    } catch {
        Write-GhlLog "Could not persist UI state: $($_.Exception.Message)" Error
    }
}

function Initialize-GhlUiFromConfig {
    $state = $Global:GhlState
    $ui = $state.UI
    $cfg = $state.Config

    $ui.txtUser.Text = [string]$cfg.LastUser
    $ui.txtBaseDir.Text = [string]$cfg.BaseDir
    $ui.txtBg.Text = [string]$cfg.BackgroundPath
    $ui.chkRunAfter.IsChecked = [bool]$cfg.RunAfterDownload
    $ui.chkPrerelease.IsChecked = [bool]$cfg.IncludePrerelease

    if ($cfg.DownloadMode -eq 'Source') {
        $ui.rbModeSource.IsChecked = $true
        $state.Mode = 'Source'
    } else {
        $ui.rbModeRelease.IsChecked = $true
        $state.Mode = 'Release'
    }

    $dim = [Math]::Round(([double]$cfg.DimmingOpacity) * 100)
    $ui.sldDim.Value = $dim
    $ui.txtDimLabel.Text = "Dimming: $dim%"

    $token = Get-GhlStoredToken -Config $cfg
    if ($token) {
        $ui.txtToken.Password = $token
        $ui.chkRememberToken.IsChecked = $true
    }

    if ($cfg.Window) {
        try {
            if ($cfg.Window.Width -gt 600) { $ui.Window.Width = [double]$cfg.Window.Width }
            if ($cfg.Window.Height -gt 400) { $ui.Window.Height = [double]$cfg.Window.Height }
            if ($cfg.Window.Left -ge 0 -and $cfg.Window.Top -ge 0) {
                $ui.Window.Left = [double]$cfg.Window.Left
                $ui.Window.Top = [double]$cfg.Window.Top
            }
        } catch { }
    }

    $ui.txtFooterInfo.Text = "Downloads: $($cfg.BaseDir)"
    if ($cfg.BackgroundPath) {
        Apply-GhlBackgroundSource -Source ([string]$cfg.BackgroundPath)
    } else {
        $ui.rectDim.Opacity = 0
    }
}

# ---------------------------------------------------------------------------
# Event pump
# ---------------------------------------------------------------------------

function Receive-GhlEvents {
    $state = $Global:GhlState
    $sync = $state.Sync
    if (-not $sync) { return }

    $evt = $null
    $guard = 0
    while ($guard -lt 200 -and $sync.Events.TryDequeue([ref]$evt)) {
        $guard++
        try {
            Invoke-GhlEvent -Event $evt
        } catch {
            Write-GhlLog "Event handler failed ($($evt.Kind)): $($_.Exception.Message)" Error
        }
        $evt = $null
    }

    # progress painting
    $ui = $state.UI
    if (-not $ui) { return }

    $phase = [string]$sync.Phase
    if ($state.Busy -and ($phase -eq 'downloading' -or $phase -eq 'extracting' -or $phase -eq 'repos')) {
        $pct = -1.0
        try { $pct = [double]$sync.ProgressPercent } catch { $pct = -1.0 }
        if ($pct -lt 0) {
            $ui.prgDownload.Value = 0
        } else {
            $ui.prgDownload.Value = [Math]::Min(100.0, [Math]::Max(0.0, $pct))
        }

        if ($sync.StatusText) { $ui.txtStatus.Text = [string]$sync.StatusText }

        if ($phase -eq 'downloading') {
            $speed = 0.0
            try { $speed = [double]$sync.SpeedBps } catch { $speed = 0.0 }
            if ($speed -gt 0) {
                $ui.txtSpeed.Text = '| {0}/s' -f (Format-GhlSize $speed)
            }
        } else {
            $ui.txtSpeed.Text = ''
        }
    }
}

function Invoke-GhlEvent {
    param($Event)

    $state = $Global:GhlState
    $ui = $state.UI
    $kind = [string]$Event.Kind

    switch ($kind) {
        'Repos' {
            $state.BusyKind = ''
            Set-GhlBusy -Busy $false
            $state.Sync.Phase = 'idle'
            $ui.prgDownload.Value = 0
            $ui.txtSpeed.Text = ''

            if ($Event.Ok) {
                $state.LastUser = [string]$Event.User
                Set-GhlRepoRows -Data $Event.Data -User $Event.User
                Reset-GhlDetails
                Set-GhlStatus -Text ('Loaded {0} repositories of {1}.' -f $state.AllRepos.Count, $Event.User)
                if ($state.AllRepos.Count -eq 0) {
                    Show-GhlToast -Message "User '$($Event.User)' has no public repositories." -Kind 'warn'
                }
                Update-GhlRateLimit -Remaining $Event.Remaining -ResetAt ''

                # persist the last successful user
                $state.Config.LastUser = [string]$Event.User
                [void](Save-GhlConfig -Config $state.Config)
            } else {
                $state.LastErrorText = [string]$Event.Message
                $state.AllRepos = @()
                Update-GhlRepoView
                Update-GhlRateLimit -Remaining $Event.Remaining -ResetAt $Event.ResetAt
                Set-GhlStatus -Text 'Load failed.'
                Show-GhlToast -Message ([string]$Event.Message) -Kind 'error' -Ms 7000

                if ($Event.ErrKind -eq 'auth') {
                    $ui.txtToken.Focus() | Out-Null
                }
                if ($Event.ErrKind -eq 'ratelimit') {
                    $ui.txtToken.Focus() | Out-Null
                }
            }
        }

        'Release' {
            if ($state.SelectedRow -and $state.SelectedRow.FullName -ne ('{0}/{1}' -f $Event.User, $Event.Repo)) {
                break   # stale response for a previous selection
            }

            if ($Event.Ok) {
                $state.ReleaseCache[[string]$Event.User + '/' + [string]$Event.Repo] = @{ Release = $Event.Data; Ts = (Get-Date) }
                Apply-GhlRelease -Release $Event.Data -Row $state.SelectedRow
            } elseif ($Event.ErrKind -eq 'norelease') {
                Apply-GhlRelease -Release $null -Row $state.SelectedRow
                Set-GhlStatus -Text 'No releases - source archive available.'
            } else {
                $ui.txtAssetsCaption.Text = 'Release lookup failed'
                $ui.rbModeSource.IsChecked = $true
                $state.Mode = 'Source'
                Update-GhlAssetList
                Set-GhlStatus -Text 'Release lookup failed.'
                Show-GhlToast -Message ([string]$Event.Message) -Kind 'error' -Ms 6000
            }
        }

        'Download' {
            $state.BusyKind = ''
            Set-GhlBusy -Busy $false
            $ui.prgDownload.Value = 0
            $ui.txtSpeed.Text = ''
            $state.Sync.Phase = 'idle'
            $state.Sync.SpeedBps = 0.0

            if ($Event.Ok) {
                $state.LastDownloadDir = [string]$Event.DestDir
                Update-GhlRowBadge -User $Event.User -Repo $Event.Repo
                $sizeText = Format-GhlSize $Event.Bytes
                Set-GhlStatus -Text ("Downloaded $($Event.Repo) ($sizeText).")

                $candidates = @($Event.Candidates)
                Write-GhlLog ("download event: autorun={0} candidates={1} dir='{2}'" -f `
                        $Event.AutoRun, $candidates.Count, $Event.DestDir) Debug
                if ($Event.AutoRun) {
                    # the picker is modal; dispatch it after the current timer tick
                    # returns so no nested message loop runs inside the pump
                    $launchCandidates = $candidates
                    $launchDir = [string]$Event.DestDir
                    $launchRepo = [string]$Event.Repo
                    $dispatcher = $ui.Window.Dispatcher

                    # GetNewClosure() is required: the delegate runs after this
                    # handler has returned and its locals would be gone.
                    $postDownload = {
                        Write-GhlLog ("post-download launch: candidates={0} dir='{1}'" -f $launchCandidates.Count, $launchDir) Debug
                        if (-not $launchCandidates -or $launchCandidates.Count -eq 0) {
                            try { Open-GhlFolder -Path $launchDir } catch { }
                            Show-GhlToast -Message 'Nothing runnable was found - the folder was opened instead.' -Kind 'warn'
                        } elseif ($launchCandidates.Count -eq 1) {
                            Start-GhlLaunchTarget -FullPath ([string]$launchCandidates[0].FullPath)
                        } else {
                            $choice = Show-GhlPickerDialog -Candidates $launchCandidates -RepoName $launchRepo
                            if ($choice) {
                                Start-GhlLaunchTarget -FullPath ([string]$choice.Candidate.FullPath)
                                if ($choice.Remember) {
                                    Set-GhlRememberedExecutable -Dir $launchDir -RelativePath ([string]$choice.Candidate.RelativePath)
                                }
                            } else {
                                Set-GhlStatus -Text 'Downloaded. Launch cancelled.'
                            }
                        }
                    }.GetNewClosure()

                    $dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action]$postDownload) | Out-Null
                } else {
                    Show-GhlToast -Message "Downloaded $($Event.Repo)." -Kind 'success'
                }
            } else {
                if ($Event.ErrKind -eq 'cancelled') {
                    Set-GhlStatus -Text 'Download cancelled.'
                    Show-GhlToast -Message 'Download cancelled.' -Kind 'warn'
                } else {
                    Set-GhlStatus -Text 'Download failed.'
                    Show-GhlToast -Message ([string]$Event.Message) -Kind 'error' -Ms 8000
                }
                Update-GhlRowBadge -User $Event.User -Repo $Event.Repo
            }

            Update-GhlActionState
        }

        'Background' {
            if ($Event.Ok) {
                Set-GhlBackgroundImage -Path $Event.Path
                Show-GhlToast -Message 'Background updated.' -Kind 'success' -Ms 2000
            } else {
                Show-GhlToast -Message ("Background download failed: " + [string]$Event.Message) -Kind 'warn'
            }
            $state.Sync.Phase = 'idle'
        }
    }
}

function Update-GhlRateLimit {
    param([int]$Remaining = -1, [string]$ResetAt = '')

    $ui = $Global:GhlState.UI
    if ($Remaining -lt 0) {
        $ui.txtRateLimit.Text = ''
        return
    }

    if ($Remaining -le 5) {
        $ui.txtRateLimit.Text = "API calls left: $Remaining (limited)"
        $ui.txtRateLimit.Foreground = $Global:GhlState.Brushes.Warn
    } else {
        $ui.txtRateLimit.Text = "API calls left this hour: $Remaining"
        $ui.txtRateLimit.Foreground = $Global:GhlState.Brushes.TextDim
    }
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

function Connect-GhlEvents {
    $state = $Global:GhlState
    $ui = $state.UI
    $win = $ui.Window

    # --- window chrome ----------------------------------------------------
    $ui.TitleBar.Add_MouseLeftButtonDown({
            param($s, $e)
            $st = $Global:GhlState
            if ($e.ClickCount -eq 2) {
                Set-GhlMaximized -On (-not $st.Maximized)
                return
            }
            if ($st.Maximized) { return }
            try { $st.UI.Window.DragMove() } catch { }
        })

    $ui.btnMin.Add_Click({ param($s, $e) $Global:GhlState.UI.Window.WindowState = [Windows.WindowState]::Minimized })
    $ui.btnMax.Add_Click({ param($s, $e) Set-GhlMaximized -On (-not $Global:GhlState.Maximized) })
    $ui.btnClose.Add_Click({ param($s, $e) $Global:GhlState.UI.Window.Close() })

    Connect-GhlResizeThumb -Thumb $ui.rsN -Edge 'N'
    Connect-GhlResizeThumb -Thumb $ui.rsS -Edge 'S'
    Connect-GhlResizeThumb -Thumb $ui.rsW -Edge 'W'
    Connect-GhlResizeThumb -Thumb $ui.rsE -Edge 'E'
    Connect-GhlResizeThumb -Thumb $ui.rsNW -Edge 'NW'
    Connect-GhlResizeThumb -Thumb $ui.rsNE -Edge 'NE'
    Connect-GhlResizeThumb -Thumb $ui.rsSW -Edge 'SW'
    Connect-GhlResizeThumb -Thumb $ui.rsSE -Edge 'SE'

    # --- search -----------------------------------------------------------
    $ui.btnSearch.Add_Click({ param($s, $e) Start-GhlSearch })
    $ui.btnRefresh.Add_Click({ param($s, $e) Start-GhlSearch })
    $ui.txtUser.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq [Windows.Input.Key]::Enter) { Start-GhlSearch }
        })

    # --- filter -----------------------------------------------------------
    $ui.txtFilter.Add_TextChanged({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.FilterTimer) { $st.FilterTimer.Stop() }
            $timer = New-Object Windows.Threading.DispatcherTimer
            $timer.Interval = [TimeSpan]::FromMilliseconds(250)
            $timer.Add_Tick({
                    param($t, $a)
                    $t.Stop()
                    $Global:GhlState.FilterTimer = $null
                    Update-GhlRepoView
                })
            $st.FilterTimer = $timer
            $timer.Start()
        })

    # --- repo grid --------------------------------------------------------
    $ui.dgRepos.Add_SelectionChanged({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SuppressSelection) { return }
            Show-GhlRepoDetails -Row $s.SelectedItem
        })

    $ui.dgRepos.Add_MouseDoubleClick({
            param($s, $e)
            $st = $Global:GhlState
            $row = $s.SelectedItem
            if (-not $row) { return }
            $dir = Get-GhlRepoDir -BaseDir $st.Config.BaseDir -User $row.Owner -Repo $row.Name
            if (Test-Path -LiteralPath $dir) {
                try { Open-GhlFolder -Path $dir } catch { }
            } else {
                Show-GhlToast -Message 'That repository has not been downloaded yet.' -Kind 'info'
            }
        })

    # --- modes ------------------------------------------------------------
    $ui.rbModeRelease.Add_Checked({
            param($s, $e)
            $Global:GhlState.Mode = 'Release'
            Update-GhlAssetList
        })
    $ui.rbModeSource.Add_Checked({
            param($s, $e)
            $Global:GhlState.Mode = 'Source'
            Update-GhlAssetList
        })

    $ui.lstAssets.Add_SelectionChanged({ param($s, $e) Update-GhlActionState })
    $ui.lstAssets.Add_MouseDoubleClick({
            param($s, $e)
            if ($Global:GhlState.UI.btnDownload.IsEnabled) { Start-GhlDownload }
        })

    $ui.chkRunAfter.Add_Checked({ param($s, $e) Update-GhlActionState })
    $ui.chkRunAfter.Add_Unchecked({ param($s, $e) Update-GhlActionState })

    $ui.chkPrerelease.Add_Checked({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SelectedRow) {
                $key = $st.SelectedRow.FullName
                if ($st.ReleaseCache.ContainsKey($key)) { $st.ReleaseCache.Remove($key) }
                Show-GhlRepoDetails -Row $st.SelectedRow
            }
        })

    # --- actions ----------------------------------------------------------
    $ui.btnDownload.Add_Click({ param($s, $e) Start-GhlDownload })
    $ui.btnCancel.Add_Click({ param($s, $e) Cancel-GhlDownload })

    $ui.btnOpenFolder.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            $row = $st.SelectedRow
            if (-not $row) { return }
            $dir = Get-GhlRepoDir -BaseDir $st.Config.BaseDir -User $row.Owner -Repo $row.Name
            try { Open-GhlFolder -Path $dir }
            catch { Show-GhlToast -Message "Folder not found: $dir" -Kind 'warn' }
        })

    $ui.btnOpenBase.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            $dir = [string]$st.UI.txtBaseDir.Text
            try {
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Open-GhlFolder -Path $dir
            } catch { Show-GhlToast -Message "Could not open '$dir'." -Kind 'error' }
        })

    $ui.btnOpenLast.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.LastDownloadDir) {
                try { Open-GhlFolder -Path $st.LastDownloadDir } catch { }
            }
        })

    $ui.btnRepoPage.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SelectedRow -and $st.SelectedRow.Url) {
                try { Start-Process $st.SelectedRow.Url | Out-Null } catch { }
            }
        })

    # --- base folder ------------------------------------------------------
    $ui.btnBrowseBase.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choose where GitHub repositories are stored'
            $dlg.ShowNewFolderButton = $true
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $st.UI.txtBaseDir.Text = $dlg.SelectedPath
                $st.Config.BaseDir = $dlg.SelectedPath
                $st.UI.txtFooterInfo.Text = "Downloads: $($dlg.SelectedPath)"
                Update-GhlAllBadges
                Update-GhlActionState
            }
            $dlg.Dispose()
        })

    $ui.txtBaseDir.Add_LostFocus({
            param($s, $e)
            $st = $Global:GhlState
            $path = [string]$s.Text
            if (-not $path) { return }
            if (-not (Test-GhlWritablePath -Path $path)) {
                Show-GhlToast -Message "Cannot write to '$path'. Reverting." -Kind 'error'
                $s.Text = [string]$st.Config.BaseDir
                return
            }
            $st.Config.BaseDir = $path
            $st.UI.txtFooterInfo.Text = "Downloads: $path"
            Update-GhlAllBadges
            Update-GhlActionState
        })

    # --- appearance -------------------------------------------------------
    $ui.sldDim.Add_ValueChanged({
            param($s, $e)
            $st = $Global:GhlState
            $val = [int]$s.Value
            $st.UI.txtDimLabel.Text = "Dimming: $val%"
            if ($st.UI.imgBackground.Source) {
                $st.UI.rectDim.Opacity = $val / 100.0
            }
        })

    $ui.btnBrowseBg.Add_Click({
            param($s, $e)
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Choose a background image'
            $dlg.Filter = 'Images|*.jpg;*.jpeg;*.png;*.bmp;*.gif|All files|*.*'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $Global:GhlState.UI.txtBg.Text = $dlg.FileName
                Apply-GhlBackgroundSource -Source $dlg.FileName
            }
            $dlg.Dispose()
        })

    $ui.txtBg.Add_LostFocus({
            param($s, $e)
            Apply-GhlBackgroundSource -Source ([string]$s.Text)
        })

    $ui.btnClearBg.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            $st.UI.txtBg.Text = ''
            $st.Config.BackgroundPath = ''
            Set-GhlBackgroundImage -Path ''
            Show-GhlToast -Message 'Background reset to the default dark theme.' -Kind 'info' -Ms 2000
        })

    # --- keyboard shortcuts ----------------------------------------------
    $win.Add_KeyDown({
            param($s, $e)
            $st = $Global:GhlState
            switch ($e.Key) {
                'Escape' {
                    if ($st.Busy -and $st.BusyKind -eq 'Download') { Cancel-GhlDownload }
                }
                'F5' {
                    Start-GhlSearch
                    $e.Handled = $true
                }
                'F' {
                    if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
                        $st.UI.txtFilter.Focus() | Out-Null
                        $e.Handled = $true
                    }
                }
            }
        })

    # --- shutdown ---------------------------------------------------------
    $win.Add_Closing({
            param($s, $e)
            $st = $Global:GhlState
            Write-GhlLog 'Window closing.'
            try { $st.Sync.CancelRequested = $true } catch { }
            if ($st.FilterTimer) { $st.FilterTimer.Stop() }
            Stop-GhlToastTimer

            foreach ($job in @($st.Jobs.Values)) {
                try { $job.PS.Stop() } catch { }
                try { $job.PS.Dispose() } catch { }
            }
            $st.Jobs.Clear()

            Save-GhlUiConfig

            if ($st.Pool) {
                try { $st.Pool.Close() } catch { }
                try { $st.Pool.Dispose() } catch { }
                $st.Pool = $null
            }
            Write-GhlLog 'Shutdown complete.'
        })
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Start-GitHubLauncher {
    param(
        [switch]$UiSmokeTest,
        [int]$SmokeTestMs = 1500,
        [scriptblock]$AutomationScript
    )

    if (-not (Initialize-GhlEnvironment)) { return }
    Add-GhlTypeHelpers

    $config = Get-GhlConfig
    $sync = [hashtable]::Synchronized(@{
            Busy             = $false
            Phase            = 'idle'
            StatusText       = ''
            ProgressPercent  = -1.0
            BytesReceived    = 0L
            BytesTotal       = -1L
            SpeedBps         = 0.0
            CancelRequested  = $false
            Events           = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
            LastError        = $null
            RepoCache        = @{}
        })

    $app = $null
    if ([Windows.Application]::Current) {
        $app = [Windows.Application]::Current
    } else {
        $app = New-Object Windows.Application
    }
    $app.ShutdownMode = [Windows.ShutdownMode]::OnMainWindowClose

    $styles = [Windows.Markup.XamlReader]::Parse((Get-GhlXaml -Name 'Styles'))
    $app.Resources.MergedDictionaries.Clear()
    [void]$app.Resources.MergedDictionaries.Add($styles)

    try {
        $window = [Windows.Markup.XamlReader]::Parse((Get-GhlXaml -Name 'MainWindow'))
    } catch {
        Show-GhlFatal -Message "The interface failed to load.`n`n$($_.Exception.Message)"
        return
    }
    $app.MainWindow = $window

    $ui = Get-GhlUiMap -Window $window
    $ui.Window = $window

    $brushes = @{
        Success = $app.Resources['SuccessBrush']
        Warn    = $app.Resources['WarnBrush']
        Danger  = $app.Resources['DangerBrush']
        Border  = $app.Resources['BorderBrush']
        TextDim = $app.Resources['TextDimBrush']
        Accent  = $app.Resources['AccentBrush']
    }

    $Global:GhlState = @{
        App             = $app
        UI              = $ui
        Config          = $config
        Sync            = $sync
        Pool            = $null
        Jobs            = @{}
        Repos           = New-Object System.Collections.ObjectModel.ObservableCollection[GhlRepoRow]
        AllRepos        = @()
        Assets          = New-Object System.Collections.ObjectModel.ObservableCollection[GhlAssetItem]
        ReleaseCache    = @{}
        SelectedRow     = $null
        CurrentRelease  = $null
        ReleaseFor      = ''
        Mode            = 'Release'
        Busy            = $false
        BusyKind        = ''
        LastErrorText   = ''
        LastUser        = [string]$config.LastUser
        LastDownloadDir = ''
        Maximized       = $false
        RestoreBounds   = $null
        FilterTimer     = $null
        ToastTimer      = $null
        Brushes         = $brushes
        PickerWindow    = $null
        SuppressSelection = $false
    }

    # icon
    try {
        $iconBytes = Get-GhlAssetBytes -Name 'icon'
        if ($iconBytes) {
            $stream = New-Object IO.MemoryStream -ArgumentList @(, $iconBytes)
            $decoder = [Windows.Media.Imaging.BitmapFrame]::Create(
                $stream,
                [Windows.Media.Imaging.BitmapCreateOptions]::None,
                [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $decoder.Freeze()
            $window.Icon = $decoder
            $ui.imgLogo.Source = $decoder
            $stream.Dispose()
        }
    } catch {
        Write-GhlLog "Icon unavailable: $($_.Exception.Message)" Debug
    }

    $buildLabel = if ($Global:GHL_Build) { [string]$Global:GHL_Build.Version } else { 'dev' }
    $ui.txtBuildTag.Text = $buildLabel

    $ui.dgRepos.ItemsSource = $Global:GhlState.Repos
    $ui.lstAssets.ItemsSource = $Global:GhlState.Assets
    $ui.prgDownload.Value = 0

    Connect-GhlEvents

    try {
        $Global:GhlState.Pool = New-GhlRunspacePool
    } catch {
        Show-GhlFatal -Message "Could not start the background worker pool.`n`n$($_.Exception.Message)"
        return
    }

    # may kick off a background-image download, so the pool must exist already
    Initialize-GhlUiFromConfig

    $pump = New-Object Windows.Threading.DispatcherTimer
    $pump.Interval = [TimeSpan]::FromMilliseconds(120)
    $pump.Add_Tick({ param($s, $e) Receive-GhlEvents })
    $pump.Start()
    $Global:GhlState.Pump = $pump

    $ui.dgRepos.Add_Sorting({
            param($s, $e)
            Write-GhlLog "Sort by $($e.Column.SortMemberPath) $($e.Column.SortDirection)" Debug
        })

    if ($config.LastUser) {
        $window.Add_Loaded({ param($s, $e) Start-GhlSearch })
    }

    if ($AutomationScript) {
        $window.Add_Loaded({ param($s, $e) & $AutomationScript $window })
    }

    if ($UiSmokeTest) {
        $window.Add_Loaded({
                param($s, $e)
                $timer = New-Object Windows.Threading.DispatcherTimer
                $timer.Interval = [TimeSpan]::FromMilliseconds($SmokeTestMs)
                $timer.Add_Tick({
                        param($t, $a)
                        $t.Stop()
                        Write-Host 'SMOKE: window loaded, closing.'
                        $Global:GhlState.UI.Window.Close()
                    })
                $timer.Start()
            })
    }

    Write-GhlLog "Showing window ($([int]$window.Width)x$([int]$window.Height))."
    [void]$app.Run($window)

    if ($Global:GhlState.Pump) { $Global:GhlState.Pump.Stop() }
    $Global:GhlState = $null
    Write-GhlLog 'Application exited.'
}
