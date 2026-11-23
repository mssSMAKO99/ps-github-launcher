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

public class GhlReleaseItem
{
    public string Tag { get; set; }
    public string Label { get; set; }
    public bool Prerelease { get; set; }
    public override string ToString() { return Label; }
}

public class GhlCandidate
{
    public string Name { get; set; }
    public string FullPath { get; set; }
    public string RelativePath { get; set; }
    public string SizeText { get; set; }
    public override string ToString() { return RelativePath; }
}

public static class GhlNative
{
    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    public static extern bool DeleteObject(System.IntPtr hObject);
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
        'RootBorder', 'TitleBar', 'btnSettings', 'btnMin', 'btnMax', 'btnClose', 'imgLogo', 'txtBuildTag',
        'bgLayer',
        'settingsOverlay', 'settingsScrim', 'settingsPanel', 'btnSettingsClose', 'btnSettingsDone',
        'txtSettingsSaved', 'chkDebugLog', 'btnOpenLogs', 'btnOpenConfigDir', 'txtAbout',
        'cbUser', 'txtToken', 'chkRememberToken', 'btnSearch', 'txtRateLimit', 'btnFavorite', 'lstFavorites', 'txtFavoritesEmpty', 'btnRemoveFavorite', 'txtBaseDirHint',
        'txtBaseDir', 'btnBrowseBase', 'chkRunAfter', 'chkPrerelease', 'btnOpenBase',
        'txtBg', 'btnBrowseBg', 'txtDimLabel', 'sldDim', 'btnClearBg', 'txtFooterInfo',
        'cbTheme', 'txtThemeHint', 'chkAnimateBg',
        'txtFilter', 'txtFilterPlaceholder', 'spinner', 'btnRefresh', 'txtCount',
        'dgRepos', 'pnlEmpty', 'txtEmptyTitle', 'txtEmptyHint',
        'txtRepoName', 'txtRepoDesc', 'txtRepoMeta',
        'cbRelease', 'btnReleaseRefresh', 'txtInstalled',
        'rbModeRelease', 'rbModeSource', 'txtAssetsCaption', 'lstAssets',
        'btnDownload', 'btnOpenFolder', 'btnRepoPage', 'txtBatchHint',
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

    # a previous fade-out ends with FillBehavior=HoldEnd, which keeps the
    # property pinned at 0; without clearing it the next toast stays invisible
    try { $ui.toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $null) } catch { }
    $ui.toast.Opacity = 0
    try {
        $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation -ArgumentList @(
            0.0, 1.0, (New-Object Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(140))))
        $ui.toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
    } catch {
        $ui.toast.Opacity = 1
    }

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

    # searching is allowed while a repo/release request is in flight (the newer
    # request wins), but never while a download owns the progress UI
    $blockSearch = $Busy -and $state.BusyKind -eq 'Download'
    $ui.btnSearch.IsEnabled = -not $blockSearch
    $ui.btnRefresh.IsEnabled = -not $blockSearch
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

    $text = ''
    if ($ui.txtFilter.Text) { $text = $ui.txtFilter.Text.Trim().ToLowerInvariant() }
    $ui.txtFilterPlaceholder.Visibility = if ($text) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }

    $tokens = @()
    if ($text) { $tokens = @($text.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) }
    $state.FilterTokens = $tokens

    # Filter the default ICollectionView instead of rebuilding the collection:
    # sorting, the current row and the scroll position survive every keystroke.
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView($state.Repos)
    $view.Filter = [Predicate[object]]{
        param($row)
        if ($null -eq $row) { return $false }
        $list = $Global:GhlState.FilterTokens
        if (-not $list -or $list.Count -eq 0) { return $true }
        $hay = ('{0} {1} {2} {3}' -f $row.Name, $row.Owner, $row.Description, $row.Language).ToLowerInvariant()
        foreach ($t in $list) {
            if ($hay.IndexOf($t, [StringComparison]::Ordinal) -lt 0) { return $false }
        }
        return $true
    }
    $view.Refresh()

    $total = $state.AllRepos.Count
    $shown = 0
    foreach ($row in $state.AllRepos) {
        if ($tokens.Count -eq 0) { $shown++; continue }
        $hay = ('{0} {1} {2} {3}' -f $row.Name, $row.Owner, $row.Description, $row.Language).ToLowerInvariant()
        $match = $true
        foreach ($t in $tokens) {
            if ($hay.IndexOf($t, [StringComparison]::Ordinal) -lt 0) { $match = $false; break }
        }
        if ($match) { $shown++ }
    }

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
    $ui = $state.UI

    $state.SuppressSelection = $true
    $all = New-Object System.Collections.Generic.List[GhlRepoRow]
    try {
        $state.Repos.Clear()
        $state.AllRepos = @()

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
            $row.Status = if ($r.PSObject.Properties['Badge'] -and $r.Badge) {
                [string]$r.Badge
            } else {
                Get-GhlRepoBadge -BaseDir $state.Config.BaseDir -User $row.Owner -Repo $row.Name
            }
            [void]$state.Repos.Add($row)
            $all.Add($row)
        }
    } finally {
        $state.SuppressSelection = $false
    }

    $state.AllRepos = $all.ToArray()
    $state.ReleaseCache = @{}
    $ui.dgRepos.SelectedItem = $null
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

    $selectedCount = 0
    try { $selectedCount = [int]$ui.dgRepos.SelectedItems.Count } catch { }

    if ($selectedCount -gt 1) {
        # batch mode resolves each repository's release in the worker; the
        # version comes from the details panel, which still shows the current row
        $ui.btnDownload.IsEnabled = (-not $busy)
    } else {
        $ui.btnDownload.IsEnabled = ($hasRow -and -not $busy -and $state.Mode -eq 'Source') -or
                                    ($hasRow -and -not $busy -and $state.Mode -eq 'Release' -and $null -ne $state.SelectedRelease -and $null -ne $ui.lstAssets.SelectedItem -and $ui.lstAssets.SelectedItem.Compatible)
    }

    $ui.txtBatchHint.Visibility = if ($selectedCount -gt 1) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($selectedCount -gt 1) {
        if ($state.Mode -eq 'Source') {
            $ui.txtBatchHint.Text = 'Source archive for every selected repository'
        } elseif ($state.SelectedRelease) {
            $ui.txtBatchHint.Text = 'Version {0} for all selected repositories' -f $state.SelectedRelease.Tag
        } else {
            $ui.txtBatchHint.Text = 'Latest stable version for all selected repositories'
        }
    }

    $canOpen = $false
    if ($hasRow) {
        $dir = Get-GhlRepoDir -BaseDir $state.Config.BaseDir -User $row.Owner -Repo $row.Name
        $canOpen = Test-Path -LiteralPath $dir
    }
    $ui.btnOpenFolder.IsEnabled = ($canOpen -and -not $busy)
    $ui.btnRepoPage.IsEnabled = ($hasRow -and -not $busy)

    $ui.rbModeRelease.IsEnabled = ($hasRow -and -not $busy -and $null -ne $state.SelectedRelease)
    $ui.rbModeSource.IsEnabled = ($hasRow -and -not $busy)

    if ($selectedCount -gt 1) {
        $ui.btnDownload.Content = "Download $selectedCount selected"
    } elseif ($hasRow) {
        $label = if ($ui.chkRunAfter.IsChecked) { 'Download & run' } else { 'Download' }
        if ($state.Mode -eq 'Release' -and $null -eq $state.SelectedRelease) { $label = 'Select a version' }
        elseif ($state.Mode -eq 'Release' -and $null -eq $ui.lstAssets.SelectedItem) { $label = 'Select an asset' }
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
    $state.SelectedRelease = $null
    $state.Releases = @()
    $state.ReleaseFor = ''
    $state.SourceForced = $false
    $state.Assets.Clear()
    $ui.cbRelease.ItemsSource = @()
    $ui.txtInstalled.Text = 'Not installed'
    $ui.txtBatchHint.Visibility = [Windows.Visibility]::Collapsed
    $ui.txtRepoName.Text = 'No repository selected'
    $ui.txtRepoDesc.Text = ''
    $ui.txtRepoMeta.Text = ''
    $ui.txtAssetsCaption.Text = 'Files'
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
    Update-GhlInstalledInfo -Row $Row

    $key = $Row.FullName
    if ($state.ReleaseCache.ContainsKey($key)) {
        $entry = $state.ReleaseCache[$key]
        if (((Get-Date) - $entry.Ts).TotalMinutes -lt 10) {
            Apply-GhlReleases -Releases $entry.Releases -Row $Row
            return
        }
        $state.ReleaseCache.Remove($key)
    }

    $state.CurrentRelease = $null
    $state.SelectedRelease = $null
    $state.Releases = @()
    $state.ReleaseFor = ''
    $state.Assets.Clear()
    $ui.cbRelease.ItemsSource = @()
    $ui.txtAssetsCaption.Text = 'Loading releases...'
    Update-GhlActionState
    Start-GhlReleaseJob -Row $Row
}

function Compare-GhlTagVersion {
    <# True when $Tag looks newer than $BaseTag (numeric segments are compared). #>
    param([string]$Tag, [string]$BaseTag)

    $a = @([regex]::Matches([string]$Tag, '\d+') | ForEach-Object { [int]$_.Value })
    $b = @([regex]::Matches([string]$BaseTag, '\d+') | ForEach-Object { [int]$_.Value })
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return $false }

    $n = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($x -gt $y) { return $true }
        if ($x -lt $y) { return $false }
    }
    return $false
}

function Update-GhlInstalledInfo {
    <# Shows the marker's version next to the version picker. #>
    param($Row)

    $state = $Global:GhlState
    $ui = $state.UI
    if (-not $ui) { return }

    if (-not $Row) {
        $ui.txtInstalled.Text = 'Not installed'
        return
    }

    $dir = Get-GhlRepoDir -BaseDir $state.Config.BaseDir -User $Row.Owner -Repo $Row.Name
    $marker = Read-GhlMarker -Directory $dir
    if (-not $marker) {
        $ui.txtInstalled.Text = 'Not installed'
        return
    }

    $installed = [string]$marker.Tag
    if (-not $installed) {
        $ui.txtInstalled.Text = 'Installed (version unknown)'
        return
    }

    $selected = if ($state.SelectedRelease) { [string]$state.SelectedRelease.Tag } else { '' }
    if ($selected -and $selected -ine $installed) {
        if (Compare-GhlTagVersion -Tag $selected -BaseTag $installed) {
            $ui.txtInstalled.Text = 'Installed {0} | update available' -f $installed
        } else {
            $ui.txtInstalled.Text = 'Installed {0} | selected {1}' -f $installed, $selected
        }
    } else {
        $ui.txtInstalled.Text = 'Installed {0}' -f $installed
    }
}

function Apply-GhlReleases {
    param($Releases, $Row)

    $state = $Global:GhlState
    $ui = $state.UI

    $previousTag = ''
    if ($state.SelectedRelease) { $previousTag = [string]$state.SelectedRelease.Tag }

    $state.Releases = @(@($Releases) | Where-Object { $_ -and -not $_.Draft })
    $state.ReleaseFor = if ($Row) { $Row.FullName } else { '' }

    $includePre = [bool]$ui.chkPrerelease.IsChecked
    $visible = @($state.Releases | Where-Object { $includePre -or -not $_.Prerelease })

    $items = New-Object System.Collections.Generic.List[GhlReleaseItem]
    foreach ($rel in $visible) {
        $item = New-Object GhlReleaseItem
        $item.Tag = [string]$rel.Tag
        $date = ''
        if ($rel.Published) { $date = ([DateTime]$rel.Published).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        $suffix = if ($rel.Prerelease) { ' (pre)' } else { '' }
        $item.Label = if ($date) { '{0}  |  {1}{2}' -f $rel.Tag, $date, $suffix } else { '{0}{1}' -f $rel.Tag, $suffix }
        $item.Prerelease = [bool]$rel.Prerelease
        $items.Add($item)
    }

    $state.ReleaseItems = $items.ToArray()
    $ui.cbRelease.ItemsSource = $state.ReleaseItems

    $picked = $null
    if ($previousTag) {
        foreach ($i in $state.ReleaseItems) {
            if ($i.Tag -ieq $previousTag) { $picked = $i; break }
        }
    }
    if (-not $picked -and $state.ReleaseItems.Count -gt 0) { $picked = $state.ReleaseItems[0] }

    $state.SuppressReleaseChange = $true
    try { $ui.cbRelease.SelectedItem = $picked } finally { $state.SuppressReleaseChange = $false }

    if ($picked) {
        $state.SelectedRelease = Select-GhlReleaseByTag -Releases $state.Releases -Tag $picked.Tag
    } else {
        $state.SelectedRelease = $null
    }
    $state.CurrentRelease = $state.SelectedRelease

    if ($state.Releases.Count -eq 0) {
        $ui.txtAssetsCaption.Text = 'No releases - source only'
        if ($Row) {
            $state.Mode = 'Source'
            $state.SuppressModeChange = $true
            try { $ui.rbModeSource.IsChecked = $true } finally { $state.SuppressModeChange = $false }
            $state.SourceForced = $true
        }
    } elseif ($state.ReleaseItems.Count -eq 0) {
        $ui.txtAssetsCaption.Text = 'Pre-release only - enable the checkbox'
    } else {
        if (-not $state.Mode -or $state.SourceForced) {
            # this repository does have releases: leave the source-only mode that
            # a previous repository without releases forced on us, but honour the
            # user's saved preference
            $state.Mode = if ($state.PreferredMode) { [string]$state.PreferredMode } else { 'Release' }
            $state.SourceForced = $false
            if ($state.Mode -eq 'Release') {
                $state.SuppressModeChange = $true
                try { $ui.rbModeRelease.IsChecked = $true } finally { $state.SuppressModeChange = $false }
            }
        }
        if ($state.Mode -eq 'Source') {
            $ui.txtAssetsCaption.Text = 'Source archive'
        } else {
            $ui.txtAssetsCaption.Text = 'Files | {0}' -f $picked.Tag
        }
    }

    Update-GhlAssetList
    Update-GhlInstalledInfo -Row $Row
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
    } elseif ($state.SelectedRelease) {
        $list = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($a in @($state.SelectedRelease.Assets)) {
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

    # a download owns the progress UI; searching would fight with it
    if ($state.Busy -and $state.BusyKind -eq 'Download') {
        Show-GhlToast -Message 'Finish or cancel the current download first.' -Kind 'warn'
        return
    }

    $user = ''
    if ($ui.cbUser.Text) { $user = $ui.cbUser.Text.Trim().TrimStart('@') }
    if (-not $user) {
        Show-GhlToast -Message 'Enter a GitHub username first.' -Kind 'warn'
        $ui.cbUser.Focus() | Out-Null
        return
    }

    # a new search always wins: Start-GhlWorker stops the previous Repos job
    $state.ReposRequest++
    $state.LastErrorText = ''
    $state.Sync.Phase = 'repos'
    $state.Sync.StatusText = "Loading repositories of $user..."
    $state.Sync.ProgressPercent = -1.0
    $state.Sync.CancelRequested = $false

    Set-GhlBusy -Busy $true -Text "Loading repositories of $user..."
    Set-GhlStatus -Text "Contacting GitHub..."
    $ui.prgDownload.Value = 0

    Start-GhlWorker -Kind 'Repos' -Arguments @{
        Sync    = $state.Sync
        User    = $user
        Token   = (Get-GhlCurrentToken)
        BaseDir = $state.Config.BaseDir
        Request = [int]$state.ReposRequest
    }
}

function Start-GhlReleaseJob {
    param($Row)

    $state = $Global:GhlState
    $state.ReleaseRequest++
    $state.Sync.Phase = 'release'
    $state.Sync.CancelRequested = $false
    Start-GhlWorker -Kind 'Release' -Arguments @{
        Sync    = $state.Sync
        User    = $Row.Owner
        Repo    = $Row.Name
        Token   = (Get-GhlCurrentToken)
        Request = [int]$state.ReleaseRequest
    }
}

function Start-GhlDownload {
    $state = $Global:GhlState
    $ui = $state.UI

    if ($state.Busy) { return }

    # several rows selected -> sequential batch
    if ($ui.dgRepos.SelectedItems -and $ui.dgRepos.SelectedItems.Count -gt 1) {
        Start-GhlBatchDownload -Rows @($ui.dgRepos.SelectedItems)
        return
    }

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
        if (-not $state.SelectedRelease -or $state.ReleaseFor -ine $row.FullName) {
            Show-GhlToast -Message 'Release information is still loading.' -Kind 'warn'
            return
        }
        $tag = [string]$state.SelectedRelease.Tag
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
        Release  = $(if ($state.Mode -eq 'Release') { $state.SelectedRelease } else { $null })
        Checksums = $null
    }

    $state.BusyKind = 'Download'
    Set-GhlBusy -Busy $true
    Set-GhlStatus -Text "Preparing download of $($job.FileName)..."
    $ui.prgDownload.Value = 0

    Start-GhlWorker -Kind 'Download' -Arguments @{ Sync = $state.Sync; Job = $job }
}

# ---------------------------------------------------------------------------
# Batch download: one repository at a time
# ---------------------------------------------------------------------------

function New-GhlBatchJob {
    param($Row)

    $state = $Global:GhlState

    # Url stays empty: the worker resolves the selected release (or source archive)
    $tag = ''
    if ($state.Mode -eq 'Release' -and $state.SelectedRelease) { $tag = [string]$state.SelectedRelease.Tag }

    return @{
        Url      = ''
        FileName = ''
        DestDir  = (Get-GhlRepoDir -BaseDir $state.Config.BaseDir -User $Row.Owner -Repo $Row.Name)
        Mode     = $state.Mode
        Tag      = $tag
        Token    = (Get-GhlCurrentToken)
        User     = $Row.Owner
        Repo     = $Row.Name
        AutoRun  = [bool]$state.UI.chkRunAfter.IsChecked
        IncludePrerelease = [bool]$state.UI.chkPrerelease.IsChecked
    }
}

function Start-GhlBatchDownload {
    param([object[]]$Rows)

    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $queue = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        if ($null -eq $r) { continue }
        [void]$queue.Add((New-GhlBatchJob -Row $r))
    }
    if ($queue.Count -eq 0) { return }

    # each queued repository costs one API call (the release list)
    $needed = $queue.Count
    $remaining = 0
    try { $remaining = [int]$state.LastRemaining } catch { }
    if ($remaining -gt 0 -and $remaining -lt $needed) {
        Write-GhlLog "Batch of $($queue.Count) needs about $needed API calls, $remaining left." Warn
    }

    $state.Queue = $queue
    $state.QueueTotal = $queue.Count
    $state.QueueDone = 0
    $state.QueueSkipped = 0

    Start-GhlNextQueued
}

function Start-GhlNextQueued {
    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $state.Queue -or $state.Queue.Count -eq 0) {
        # finished
        $summary = '{0} of {1} repositories downloaded' -f $state.QueueDone, $state.QueueTotal
        if ($state.QueueSkipped -gt 0) { $summary += " ($($state.QueueSkipped) skipped)" }
        Set-GhlStatus -Text $summary
        if ($state.QueueDone -gt 0) {
            Show-GhlToast -Message $summary -Kind 'success' -Ms 6000
        }
        $state.Queue = $null
        $state.BusyKind = ''
        Set-GhlBusy -Busy $false
        $ui.prgDownload.Value = 0
        Update-GhlActionState
        return
    }

    $job = $state.Queue[0]
    $index = $state.QueueDone + $state.QueueSkipped + 1
    Set-GhlStatus -Text ('Downloading {0} of {1}: {2}/{3}' -f $index, $state.QueueTotal, $job.User, $job.Repo)

    $state.Sync.CancelRequested = $false
    $state.Sync.BytesReceived = 0L
    $state.Sync.BytesTotal = -1L
    $state.Sync.ProgressPercent = 0.0
    $state.Sync.SpeedBps = 0.0
    $state.Sync.Phase = 'downloading'

    $state.BusyKind = 'Download'
    Set-GhlBusy -Busy $true
    $ui.prgDownload.Value = 0

    Start-GhlWorker -Kind 'Download' -Arguments @{ Sync = $state.Sync; Job = $job }
}

function Complete-GhlQueueStep {
    <# Called after each queued download finishes (ok or not). #>
    param([bool]$Ok, [string]$ErrKind = '', [string]$Message = '')

    $state = $Global:GhlState

    if (-not $state.Queue -or $state.Queue.Count -eq 0) { return $false }

    [void]$state.Queue.RemoveAt(0)

    if ($Ok) {
        $state.QueueDone++
    } elseif ($ErrKind -in @('noasset', 'norelease', 'versionmissing')) {
        $state.QueueSkipped++
        Show-GhlToast -Message $Message -Kind 'warn' -Ms 3500
    } else {
        $state.QueueSkipped++
        Show-GhlToast -Message $Message -Kind 'error' -Ms 5000
    }

    Start-GhlNextQueued
    return $true
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

function Show-GhlLaunchConfirm {
    <#
        Explicit consent before running a downloaded program.
        Returns $true only when the user pressed "Run".

        The dialog is built in code rather than XAML: it is a single prompt and
        adding another document would mean another embedded resource.
    #>
    param(
        [Parameter(Mandatory)][string]$FullPath,
        [string]$RepoName = ''
    )

    $state = $Global:GhlState
    if (-not $state -or -not $state.UI) { return $false }

    try {
        $info = Get-Item -LiteralPath $FullPath
    } catch {
        Show-GhlToast -Message "File not found: $FullPath" -Kind 'error'
        return $false
    }

    $sig = Get-GhlFileSignature -Path $FullPath
    $hash = ''
    try { $hash = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash } catch { }

    $dim = $state.Brushes.TextDim
    $text = $state.Brushes.Text

    $win = New-Object Windows.Window
    $win.Title = 'Run downloaded program'
    $win.Width = 560
    $win.SizeToContent = [Windows.SizeToContent]::Height
    $win.WindowStyle = [Windows.WindowStyle]::None
    $win.AllowsTransparency = $true
    $win.Background = [Windows.Media.Brushes]::Transparent
    $win.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $win.ShowInTaskbar = $false
    $win.ResizeMode = [Windows.ResizeMode]::NoResize

    $root = New-Object Windows.Controls.Border
    $root.Background = $state.Brushes.Bg0
    $root.BorderBrush = $state.Brushes.Border
    $root.BorderThickness = New-Object Windows.Thickness 1
    $root.CornerRadius = New-Object Windows.CornerRadius 12
    $root.Padding = New-Object Windows.Thickness 22

    $stack = New-Object Windows.Controls.StackPanel

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = 'Run this downloaded program?'
    $title.FontSize = 16
    $title.FontWeight = [Windows.FontWeights]::SemiBold
    $title.Foreground = $text
    $title.Margin = New-Object Windows.Thickness -ArgumentList @(0, 0, 0, 12)
    [void]$stack.Children.Add($title)

    $warning = New-Object Windows.Controls.TextBlock
    $warning.Text = 'This file came from the internet. Only run it if you trust its source.'
    $warning.Foreground = $state.Brushes.Warn
    $warning.FontSize = 12
    $warning.TextWrapping = [Windows.TextWrapping]::Wrap
    $warning.Margin = New-Object Windows.Thickness -ArgumentList @(0, 0, 0, 14)
    [void]$stack.Children.Add($warning)

    $rows = @(
        @{ Label = 'File'; Value = $info.Name },
        @{ Label = 'Size'; Value = (Format-GhlSize $info.Length) },
        @{ Label = 'From'; Value = $(if ($RepoName) { $RepoName } else { 'this repository' }) },
        @{ Label = 'SHA-256'; Value = $hash },
        @{ Label = 'Signature'; Value = $sig.StatusText }
    )
    if ($sig.Signer) { $rows += @{ Label = 'Signer'; Value = $sig.Signer } }

    foreach ($row in $rows) {
        $line = New-Object Windows.Controls.Grid
        $line.Margin = New-Object Windows.Thickness -ArgumentList @(0, 0, 0, 6)
        $c1 = New-Object Windows.Controls.ColumnDefinition
        $c1.Width = [Windows.GridLength]::new(90)
        $c2 = New-Object Windows.Controls.ColumnDefinition
        $line.ColumnDefinitions.Add($c1)
        $line.ColumnDefinitions.Add($c2)

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $row.Label
        $label.Foreground = $dim
        $label.FontSize = 11.5
        $value = New-Object Windows.Controls.TextBlock
        $value.Text = [string]$row.Value
        $value.Foreground = $text
        $value.FontSize = 11.5
        $value.TextWrapping = [Windows.TextWrapping]::Wrap
        $value.SetValue([Windows.Controls.Grid]::ColumnProperty, 1)
        if ($row.Label -eq 'Signature' -and -not $sig.IsTrusted) {
            $value.Foreground = $state.Brushes.Warn
        }
        [void]$line.Children.Add($label)
        [void]$line.Children.Add($value)
        [void]$stack.Children.Add($line)
    }

    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = [Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    $buttons.Margin = New-Object Windows.Thickness -ArgumentList @(0, 18, 0, 0)

    $btnCancel = New-Object Windows.Controls.Button
    $btnCancel.Content = 'Cancel'
    $btnCancel.MinWidth = 100
    $btnCancel.Padding = New-Object Windows.Thickness -ArgumentList @(14, 8, 14, 8)
    $btnCancel.Margin = New-Object Windows.Thickness -ArgumentList @(0, 0, 10, 0)
    $btnCancel.Background = $state.Brushes.Bg2
    $btnCancel.Foreground = $text
    $btnCancel.BorderBrush = $state.Brushes.Border
    $btnCancel.Cursor = [Windows.Input.Cursors]::Hand

    $btnRun = New-Object Windows.Controls.Button
    $btnRun.Content = 'Run'
    $btnRun.MinWidth = 110
    $btnRun.Padding = New-Object Windows.Thickness -ArgumentList @(14, 8, 14, 8)
    $btnRun.Background = $state.Brushes.AccentStrong
    $btnRun.Foreground = [Windows.Media.Brushes]::White
    $btnRun.BorderThickness = New-Object Windows.Thickness 0
    $btnRun.FontWeight = [Windows.FontWeights]::SemiBold
    $btnRun.Cursor = [Windows.Input.Cursors]::Hand

    [void]$buttons.Children.Add($btnCancel)
    [void]$buttons.Children.Add($btnRun)
    [void]$stack.Children.Add($buttons)

    $root.Child = $stack
    $win.Content = $root
    $win.Owner = $state.UI.Window

    $script:GhlLaunchConfirmResult = $false
    $btnRun.Add_Click({ param($s, $e) $script:GhlLaunchConfirmResult = $true; $win.Close() })
    $btnCancel.Add_Click({ param($s, $e) $script:GhlLaunchConfirmResult = $false; $win.Close() })
    $win.Add_KeyDown({
            param($s, $e)
            # Enter deliberately does nothing: a downloaded program must never
            # start because a stray key press confirmed the dialog
            if ($e.Key -eq [Windows.Input.Key]::Escape) { $script:GhlLaunchConfirmResult = $false; $win.Close() }
        })

    $state.ConfirmWindow = $win
    try {
        [void]$win.ShowDialog()
    } catch {
        Write-GhlLog "Launch confirmation failed: $($_.Exception.Message)" Error
        return $false
    } finally {
        $state.ConfirmWindow = $null
    }

    return [bool]$script:GhlLaunchConfirmResult
}

function Start-GhlLaunchTarget {
    param([string]$FullPath, [string]$RepoName = '')

    if (-not (Show-GhlLaunchConfirm -FullPath $FullPath -RepoName $RepoName)) {
        Set-GhlStatus -Text 'Launch cancelled.'
        Write-GhlLog "Launch cancelled by the user for '$FullPath'." Info
        return
    }

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
    try {
        $win = [Windows.Markup.XamlReader]::Parse((Get-GhlWindowXaml -Name 'PickerWindow'))
    } catch {
        Write-GhlLog "Picker window failed to load: $($_.Exception.Message)" Error
        return $null
    }

    [void](Set-GhlThemeResources -Window $win -Name ([string]$state.Config.Theme))
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

function Update-GhlRoundedClip {
    <#
        Clips the background layer to the window's rounded corners.

        A Border with CornerRadius does not clip its children - it only paints its
        own background - so the background image used to fill the square corners.
        The clip radius follows RootBorder, which is 12 normally and 0 when
        maximized.
    #>
    param([int]$Radius = -1)

    $state = $Global:GhlState
    if (-not $state -or -not $state.UI) { return }
    $ui = $state.UI

    if (-not $ui.ContainsKey('bgLayer') -or -not $ui.bgLayer) { return }

    if ($Radius -lt 0) {
        $corner = $ui.RootBorder.CornerRadius
        $Radius = [int][Math]::Round($corner.TopLeft)
    }

    try {
        $w = $ui.bgLayer.ActualWidth
        $h = $ui.bgLayer.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }

        # the border itself is drawn 1px inside the window edge
        $rect = New-Object Windows.Rect 0, 0, $w, $h
        $ui.bgLayer.Clip = New-Object Windows.Media.RectangleGeometry($rect, $Radius, $Radius)
    } catch {
        Write-GhlLog "Could not update the background clip: $($_.Exception.Message)" Debug
    }
}

function Set-GhlBackgroundImage {
    param([string]$Path)

    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Stop-GhlGifBackground
        $ui.imgBackground.Source = $null
        $ui.imgBackground.Visibility = [Windows.Visibility]::Collapsed
        $ui.rectDim.Opacity = 0
        return $false
    }

    try {
        # a GIF is played by GDI+ when animation is allowed; Start falls back to
        # $false for single-frame files, which then take the static path below
        if ($Path -match '(?i)\.gif$') {
            if (Start-GhlGifBackground -Path $Path) {
                Update-GhlRoundedClip
                Write-GhlLog "Background animation applied: $Path"
                return $true
            }
        }
        Stop-GhlGifBackground

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
        Update-GhlRoundedClip
        Write-GhlLog "Background image applied: $Path"
        return $true
    } catch {
        Write-GhlLog "Background image could not be loaded: $($_.Exception.Message)" Warn
        Show-GhlToast -Message "Could not load that image: $($_.Exception.Message)" -Kind 'warn'
        Stop-GhlGifBackground
        $ui.imgBackground.Source = $null
        $ui.imgBackground.Visibility = [Windows.Visibility]::Collapsed
        $ui.rectDim.Opacity = 0
        return $false
    }
}

function Apply-GhlBackgroundSource {
    param([string]$Source)

    $state = $Global:GhlState
    $ui = $state.UI

    if (-not $Source) {
        [void](Set-GhlBackgroundImage -Path '')
        return
    }

    if ($Source -match '^https?://') {
        $cached = Get-GhlBackgroundCachePath -Url $Source
        if (Test-Path -LiteralPath $cached) {
            if (Set-GhlBackgroundImage -Path $cached) { return }
            # a truncated cache file would otherwise be retried forever
            try { Remove-Item -LiteralPath $cached -Force -ErrorAction Stop } catch { }
        }
        Show-GhlToast -Message 'Downloading background image...' -Kind 'info' -Ms 2000
        Start-GhlWorker -Kind 'Background' -Arguments @{
            Sync    = $state.SyncBg
            Url     = $Source
            OutFile = $cached
        }
        return
    }

    if (-not (Set-GhlBackgroundImage -Path $Source)) {
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
        Update-GhlRoundedClip -Radius 0
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
        Update-GhlRoundedClip -Radius 12
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
        $newBase = [string]$ui.txtBaseDir.Text
        if ($newBase -and $newBase -ne [string]$cfg.BaseDir) {
            if (Test-GhlWritablePath -Path $newBase) {
                $cfg.BaseDir = $newBase
            } else {
                # never persist an unusable folder; keep the last working one
                $ui.txtBaseDir.Text = [string]$cfg.BaseDir
                $ui.txtFooterInfo.Text = "Downloads: $($cfg.BaseDir)"
                Show-GhlToast -Message "Cannot write to '$newBase'. Keeping the previous folder." -Kind 'error'
            }
        }
        $cfg.BackgroundPath = [string]$ui.txtBg.Text
        $cfg.BackgroundKind = if ($cfg.BackgroundPath -match '^https?://') { 'url' } else { 'file' }
        $cfg.DimmingOpacity = [Math]::Round($ui.sldDim.Value / 100.0, 3)
        $cfg.Theme = Resolve-GhlThemeName -Name ([string]$ui.cbTheme.SelectedItem)
        $cfg.AnimateBackground = [bool]$ui.chkAnimateBg.IsChecked
        $cfg.DownloadMode = if ($ui.rbModeSource.IsChecked) { 'Source' } else { 'Release' }
        $cfg.RunAfterDownload = [bool]$ui.chkRunAfter.IsChecked
        $cfg.IncludePrerelease = [bool]$ui.chkPrerelease.IsChecked
        if ($ui.cbUser.Text) { $cfg.LastUser = [string]$ui.cbUser.Text.Trim() }

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

    # the theme goes first: everything created after this point inherits it
    $ui.cbTheme.ItemsSource = @(Get-GhlThemeNames)
    $state.SuppressThemeChange = $true
    try {
        [void](Set-GhlTheme -Name ([string]$cfg.Theme))
        $ui.cbTheme.SelectedItem = $state.Theme
    } finally {
        $state.SuppressThemeChange = $false
    }

    $state.SuppressAppearanceChange = $true
    try { $ui.chkAnimateBg.IsChecked = [bool]$cfg.AnimateBackground } finally {
        $state.SuppressAppearanceChange = $false
    }

    $ui.cbUser.Text = [string]$cfg.LastUser
    $ui.txtBaseDir.Text = [string]$cfg.BaseDir
    $ui.txtBg.Text = [string]$cfg.BackgroundPath
    $ui.chkRunAfter.IsChecked = [bool]$cfg.RunAfterDownload
    $ui.chkPrerelease.IsChecked = [bool]$cfg.IncludePrerelease

    $state.PreferredMode = if ($cfg.DownloadMode -eq 'Source') { 'Source' } else { 'Release' }
    $state.SuppressModeChange = $true
    try {
        if ($cfg.DownloadMode -eq 'Source') {
            $ui.rbModeSource.IsChecked = $true
            $state.Mode = 'Source'
        } else {
            $ui.rbModeRelease.IsChecked = $true
            $state.Mode = 'Release'
        }
    } finally {
        $state.SuppressModeChange = $false
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
            $wa = [Windows.SystemParameters]::WorkArea
            $w = [double]$cfg.Window.Width
            $h = [double]$cfg.Window.Height
            if ($w -gt 600) { $ui.Window.Width = [Math]::Min($w, $wa.Width) }
            if ($h -gt 400) { $ui.Window.Height = [Math]::Min($h, $wa.Height) }
            if ($cfg.Window.Left -ge 0 -and $cfg.Window.Top -ge 0) {
                # keep a window saved on a monitor that is no longer attached visible
                $left = [Math]::Min([double]$cfg.Window.Left, $wa.Right - $ui.Window.Width)
                $top = [Math]::Min([double]$cfg.Window.Top, $wa.Bottom - $ui.Window.Height)
                $ui.Window.Left = [Math]::Max($wa.Left, $left)
                $ui.Window.Top = [Math]::Max($wa.Top, $top)
            }
        } catch { }
    }

    if ($cfg.Window -and [bool]$cfg.Window.Maximized) {
        Set-GhlMaximized -On $true
    }

    $ui.txtFooterInfo.Text = "Downloads: $($cfg.BaseDir)"
    $ui.chkDebugLog.IsChecked = [bool]$cfg.DebugLog
    $ui.txtAbout.Text = Get-GhlAboutText
    Update-GhlFavoritesUi
    Update-GhlBaseDirHint

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
    $ui = $state.UI
    if (-not $ui) { return }

    # two independent queues: main work (search/release/download) and the
    # background image, so their phases and progress never overwrite each other
    foreach ($sync in @($state.Sync, $state.SyncBg)) {
        if (-not $sync) { continue }
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
    }

    # progress painting
    $sync = $state.Sync
    if (-not $sync) { return }

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
            if ([int]$Event.Request -ne [int]$state.ReposRequest) {
                break   # a newer search has already started
            }
            $state.BusyKind = ''
            Set-GhlBusy -Busy $false
            $state.Sync.Phase = 'idle'
            $ui.prgDownload.Value = 0
            $ui.txtSpeed.Text = ''

            if ($Event.Ok) {
                Set-GhlRepoRows -Data $Event.Data -User $Event.User
                Reset-GhlDetails
                Set-GhlStatus -Text ('Loaded {0} repositories of {1}.' -f $state.AllRepos.Count, $Event.User)
                if ($state.AllRepos.Count -eq 0) {
                    Show-GhlToast -Message "User '$($Event.User)' has no public repositories." -Kind 'warn'
                }
                Update-GhlRateLimit -Remaining $Event.Remaining -ResetAt $Event.ResetAt
                $state.LastRemaining = [int]$Event.Remaining

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
            if ([int]$Event.Request -ne [int]$state.ReleaseRequest) {
                break   # a newer release request has already started
            }
            if ($state.SelectedRow -and $state.SelectedRow.FullName -ine ('{0}/{1}' -f $Event.User, $Event.Repo)) {
                break   # stale response for a previous selection
            }

            if ($Event.Ok) {
                $relList = @($Event.Releases)
                $state.ReleaseCache[[string]$Event.User + '/' + [string]$Event.Repo] = @{ Releases = $relList; Ts = (Get-Date) }
                Apply-GhlReleases -Releases $relList -Row $state.SelectedRow
                Update-GhlRateLimit -Remaining $Event.Remaining -ResetAt $Event.ResetAt
            } elseif ($Event.ErrKind -eq 'norelease') {
                $state.ReleaseCache[[string]$Event.User + '/' + [string]$Event.Repo] = @{ Releases = @(); Ts = (Get-Date) }
                Apply-GhlReleases -Releases @() -Row $state.SelectedRow
                Set-GhlStatus -Text 'No releases - source archive available.'
            } else {
                # never leave the previous repository's release on screen
                $state.CurrentRelease = $null
                $state.SelectedRelease = $null
                $state.Releases = @()
                $state.ReleaseFor = ''
                $state.Assets.Clear()
                $ui.cbRelease.ItemsSource = @()
                $ui.txtAssetsCaption.Text = 'Release lookup failed'
                $state.Mode = 'Source'
                $state.SuppressModeChange = $true
                try { $ui.rbModeSource.IsChecked = $true } finally { $state.SuppressModeChange = $false }
                $state.SourceForced = $true
                Update-GhlAssetList
                Set-GhlStatus -Text 'Release lookup failed.'
                Show-GhlToast -Message ([string]$Event.Message) -Kind 'error' -Ms 6000
            }
        }

        'Download' {
            # in batch mode the queue owns the busy state and the status line
            $inBatch = ($state.Queue -and $state.Queue.Count -gt 0)
            if ([int]$Event.Remaining -ge 0) { Update-GhlRateLimit -Remaining ([int]$Event.Remaining) }
            if (-not $inBatch) {
                $state.BusyKind = ''
                Set-GhlBusy -Busy $false
                $ui.prgDownload.Value = 0
            }
            $ui.txtSpeed.Text = ''
            $state.Sync.Phase = 'idle'
            $state.Sync.SpeedBps = 0.0

            if ($Event.Ok) {
                $state.LastDownloadDir = [string]$Event.DestDir
                Update-GhlRowBadge -User $Event.User -Repo $Event.Repo
                if ($state.SelectedRow -and $state.SelectedRow.Owner -eq $Event.User -and $state.SelectedRow.Name -eq $Event.Repo) {
                    Update-GhlInstalledInfo -Row $state.SelectedRow
                }
                $sizeText = Format-GhlSize $Event.Bytes
                if (-not $inBatch) { Set-GhlStatus -Text ("Downloaded $($Event.Repo) ($sizeText).") }

                $candidates = @($Event.Candidates)
                Write-GhlLog ("download event: autorun={0} candidates={1} dir='{2}' batch={3}" -f `
                        $Event.AutoRun, $candidates.Count, $Event.DestDir, $inBatch) Debug

                if ($inBatch) {
                    # batch runs never launch: the queue would block on a modal dialog
                    [void](Complete-GhlQueueStep -Ok $true)
                } elseif ($Event.AutoRun -and -not [bool]$Event.Launchable) {
                    # .msix/.appx are installed by Windows; launching the file
                    # directly would start an installer instead of the app
                    try { Open-GhlFolder -Path ([string]$Event.DestDir) } catch { }
                    Show-GhlToast -Message 'Downloaded. Windows installs .msix/.appx packages when you open the file.' -Kind 'info' -Ms 6000
                } elseif ($Event.AutoRun) {
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
                            Start-GhlLaunchTarget -FullPath ([string]$launchCandidates[0].FullPath) -RepoName $launchRepo
                        } else {
                            $choice = Show-GhlPickerDialog -Candidates $launchCandidates -RepoName $launchRepo
                            if ($choice) {
                                Start-GhlLaunchTarget -FullPath ([string]$choice.Candidate.FullPath) -RepoName $launchRepo
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
                Update-GhlRowBadge -User $Event.User -Repo $Event.Repo

                if ($Event.ErrKind -eq 'cancelled') {
                    if ($inBatch) {
                        # cancel stops the whole batch
                        $state.Queue = $null
                        Set-GhlStatus -Text 'Batch cancelled.'
                        Set-GhlBusy -Busy $false
                        $ui.prgDownload.Value = 0
                    } else {
                        Set-GhlStatus -Text 'Download cancelled.'
                    }
                    Show-GhlToast -Message 'Download cancelled.' -Kind 'warn'
                } elseif ($inBatch) {
                    [void](Complete-GhlQueueStep -Ok $false -ErrKind ([string]$Event.ErrKind) -Message ([string]$Event.Message))
                } else {
                    Set-GhlStatus -Text 'Download failed.'
                    Show-GhlToast -Message ([string]$Event.Message) -Kind 'error' -Ms 8000
                }
            }

            Update-GhlActionState
        }

        'Background' {
            if ($Event.Ok) {
                if (Set-GhlBackgroundImage -Path $Event.Path) {
                    Show-GhlToast -Message 'Background updated.' -Kind 'success' -Ms 2000
                } else {
                    # a corrupt download must not stay in the cache
                    try { Remove-Item -LiteralPath ([string]$Event.Path) -Force -ErrorAction Stop } catch { }
                }
            } else {
                Show-GhlToast -Message ("Background download failed: " + [string]$Event.Message) -Kind 'warn'
            }
            $state.SyncBg.Phase = 'idle'
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

    $resetText = ''
    if ($ResetAt) {
        try {
            $when = Convert-GhlApiDate -Raw $ResetAt
            if ($when) { $resetText = ' Resets at {0:HH:mm}.' -f ([DateTime]$when).ToLocalTime() }
        } catch { }
    }

    if ($Remaining -le 5) {
        $ui.txtRateLimit.Text = "API calls left: $Remaining (limited).$resetText"
        $ui.txtRateLimit.Foreground = $Global:GhlState.Brushes.Warn
    } else {
        $ui.txtRateLimit.Text = "API calls left this hour: $Remaining.$resetText"
        $ui.txtRateLimit.Foreground = $Global:GhlState.Brushes.TextDim
    }
}

# ---------------------------------------------------------------------------
# Settings overlay + favourites
# ---------------------------------------------------------------------------

function Update-GhlFavoritesUi {
    $state = $Global:GhlState
    $ui = $state.UI

    $favorites = @(Get-GhlFavoriteUsers -Config $state.Config)
    $state.Config.FavoriteUsers = $favorites

    # the combo box doubles as the "last used" field, so keep whatever is typed
    $typed = [string]$ui.cbUser.Text
    $ui.cbUser.ItemsSource = $favorites
    $ui.cbUser.Text = $typed

    $ui.lstFavorites.ItemsSource = $favorites
    $ui.txtFavoritesEmpty.Visibility =
    if ($favorites.Count -eq 0) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

    $ui.btnFavorite.Content = if ($typed -and (Test-GhlFavoriteUser -Config $state.Config -User $typed)) {
        [string][char]0xE734    # filled star
    } else {
        [string][char]0xE735    # outline star
    }
}

function Update-GhlBaseDirHint {
    $state = $Global:GhlState
    $ui = $state.UI
    $ui.txtBaseDirHint.Text = "Saving to: $($state.Config.BaseDir)"
}

function Show-GhlSettings {
    param([bool]$Show = $true)

    $state = $Global:GhlState
    $ui = $state.UI
    $ui.settingsOverlay.Visibility =
    if ($Show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

    if ($Show) {
        Update-GhlFavoritesUi
        $ui.txtSettingsSaved.Text = ''
        $ui.settingsPanel.Focus() | Out-Null
    }
}

function Get-GhlAboutText {
    $state = $Global:GhlState
    $version = if ($Global:GHL_Build) { [string]$Global:GHL_Build.Version } else { 'dev' }
    $built = if ($Global:Ghl_Build) { [string]$Global:GHL_Build.Built } else { '(source)' }
    return @(
        "GitHub Launcher $version",
        "Built $built",
        '',
        "Settings: $(Join-Path (Get-GhlAppDir) 'config.json')",
        '',
        'Downloads land in {base}\{user}\{repo}.'
    ) -join [Environment]::NewLine
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

    # --- settings overlay -------------------------------------------------
    $ui.btnSettings.Add_Click({ param($s, $e) Show-GhlSettings -Show $true })
    $ui.btnSettingsClose.Add_Click({ param($s, $e) Show-GhlSettings -Show $false })
    $ui.btnSettingsDone.Add_Click({
            param($s, $e)
            Save-GhlUiConfig
            $Global:GhlState.UI.txtSettingsSaved.Text = 'Saved.'
            Show-GhlSettings -Show $false
        })
    $ui.settingsScrim.Add_MouseLeftButtonDown({ param($s, $e) Show-GhlSettings -Show $false })

    $ui.chkDebugLog.Add_Checked({
            param($s, $e)
            $st = $Global:GhlState
            $st.Config.DebugLog = $true
            $Global:GHL_DebugLog = $true
        })
    $ui.chkDebugLog.Add_Unchecked({
            param($s, $e)
            $st = $Global:GhlState
            $st.Config.DebugLog = $false
            $Global:GHL_DebugLog = [bool]$env:GHL_DEBUG
        })

    $ui.btnOpenLogs.Add_Click({
            param($s, $e)
            $dir = Join-Path (Get-GhlAppDir) 'logs'
            try { Open-GhlFolder -Path $dir } catch { Show-GhlToast -Message "No logs yet: $dir" -Kind 'warn' }
        })

    $ui.btnOpenConfigDir.Add_Click({
            param($s, $e)
            try { Open-GhlFolder -Path (Get-GhlAppDir) }
            catch { Show-GhlToast -Message 'Could not open the settings folder.' -Kind 'error' }
        })

    # --- favourites -------------------------------------------------------
    $ui.btnFavorite.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            $name = ([string]$st.UI.cbUser.Text).Trim().TrimStart('@')
            if (-not $name) {
                Show-GhlToast -Message 'Type a GitHub username first.' -Kind 'warn'
                return
            }
            if (Test-GhlFavoriteUser -Config $st.Config -User $name) {
                $st.Config.FavoriteUsers = Remove-GhlFavoriteUser -Config $st.Config -User $name
                Show-GhlToast -Message "Removed $name from favourites." -Kind 'info' -Ms 2000
            } else {
                $st.Config.FavoriteUsers = Add-GhlFavoriteUser -Config $st.Config -User $name
                Show-GhlToast -Message "Pinned $name." -Kind 'success' -Ms 2000
            }
            Update-GhlFavoritesUi
            [void](Save-GhlConfig -Config $st.Config)
        })

    $ui.btnRemoveFavorite.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            $picked = [string]$st.UI.lstFavorites.SelectedItem
            if (-not $picked) {
                Show-GhlToast -Message 'Select a favourite first.' -Kind 'warn'
                return
            }
            $st.Config.FavoriteUsers = Remove-GhlFavoriteUser -Config $st.Config -User $picked
            Update-GhlFavoritesUi
            [void](Save-GhlConfig -Config $st.Config)
        })

    $ui.cbUser.Add_LostFocus({
            param($s, $e)
            if ($Global:GhlState.UI.cbUser.IsEditable) { Update-GhlFavoritesUi }
        })

    $ui.lstFavorites.Add_MouseDoubleClick({
            param($s, $e)
            $picked = [string]$s.SelectedItem
            if (-not $picked) { return }
            $st = $Global:GhlState
            $st.UI.cbUser.Text = $picked
            Show-GhlSettings -Show $false
            if (-not $st.Busy) { Start-GhlSearch }
        })

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
    $ui.cbUser.Add_KeyDown({
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

            # with Extended selection the details panel follows the *current* row,
            # not the whole selection (that is what the batch button is for)
            $row = $s.CurrentItem
            if (-not $row) { $row = $s.SelectedItem }
            Show-GhlRepoDetails -Row $row
            Update-GhlActionState
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
            $st = $Global:GhlState
            if ($st.SuppressModeChange) { return }
            $st.Mode = 'Release'
            $st.PreferredMode = 'Release'
            $st.SourceForced = $false
            if ($st.SelectedRelease) { $st.UI.txtAssetsCaption.Text = 'Files | {0}' -f $st.SelectedRelease.Tag }
            Update-GhlAssetList
        })
    $ui.rbModeSource.Add_Checked({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SuppressModeChange) { return }
            $st.Mode = 'Source'
            $st.PreferredMode = 'Source'
            $st.SourceForced = $false
            $st.UI.txtAssetsCaption.Text = 'Source archive'
            Update-GhlAssetList
        })

    # --- release picker ---------------------------------------------------
    $ui.cbRelease.Add_SelectionChanged({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SuppressReleaseChange) { return }
            $picked = $s.SelectedItem
            if (-not $picked) { return }

            $rel = Select-GhlReleaseByTag -Releases $st.Releases -Tag ([string]$picked.Tag)
            $st.SelectedRelease = $rel
            $st.CurrentRelease = $rel
            if ($rel) {
                $st.Mode = 'Release'
                $st.UI.txtAssetsCaption.Text = 'Files | {0}' -f $picked.Tag
                if ($st.UI.rbModeRelease.IsChecked -ne $true) { $st.UI.rbModeRelease.IsChecked = $true }
            }
            Update-GhlAssetList
            Update-GhlInstalledInfo -Row $st.SelectedRow
            Update-GhlActionState
        })

    $ui.btnReleaseRefresh.Add_Click({
            param($s, $e)
            $st = $Global:GhlState
            $row = $st.SelectedRow
            if (-not $row) { return }
            $st.ReleaseCache.Remove($row.FullName)
            $st.Releases = @()
            $st.SelectedRelease = $null
            $st.CurrentRelease = $null
            $st.ReleaseFor = ''
            $st.Assets.Clear()
            $st.UI.cbRelease.ItemsSource = @()
            $st.UI.txtAssetsCaption.Text = 'Loading releases...'
            Update-GhlActionState
            Start-GhlReleaseJob -Row $row
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
            if (-not $st.SelectedRow) { return }
            $key = $st.SelectedRow.FullName
            if ($st.ReleaseCache.ContainsKey($key) -and ((Get-Date) - $st.ReleaseCache[$key].Ts).TotalMinutes -lt 10) {
                # the list is already cached: filter it, no API request
                Apply-GhlReleases -Releases $st.ReleaseCache[$key].Releases -Row $st.SelectedRow
            } else {
                Show-GhlRepoDetails -Row $st.SelectedRow
            }
        })
    $ui.chkPrerelease.Add_Unchecked({
            param($s, $e)
            $st = $Global:GhlState
            if (-not $st.SelectedRow) { return }
            $key = $st.SelectedRow.FullName
            if ($st.ReleaseCache.ContainsKey($key) -and ((Get-Date) - $st.ReleaseCache[$key].Ts).TotalMinutes -lt 10) {
                Apply-GhlReleases -Releases $st.ReleaseCache[$key].Releases -Row $st.SelectedRow
            } else {
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
                Update-GhlInstalledInfo -Row $st.SelectedRow
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
            Update-GhlInstalledInfo -Row $st.SelectedRow
            Update-GhlActionState
        })

    # --- appearance -------------------------------------------------------
    # keep the rounded clip in sync with the window size
    $ui.bgLayer.Add_SizeChanged({
            param($s, $e)
            if ($s.ActualWidth -gt 0 -and $s.ActualHeight -gt 0) { Update-GhlRoundedClip }
        })
    $ui.RootBorder.Add_SizeChanged({
            param($s, $e)
            if ($s.ActualWidth -gt 0 -and $s.ActualHeight -gt 0) { Update-GhlRoundedClip }
        })

    # animation must not run while the window is hidden or minimized
    $win.Add_StateChanged({ param($s, $e) Update-GhlGifPlayback })
    $win.Add_IsVisibleChanged({ param($s, $e) Update-GhlGifPlayback })

    $ui.cbTheme.Add_SelectionChanged({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SuppressThemeChange) { return }
            $name = [string]$s.SelectedItem
            if (-not $name) { return }
            $st.Config.Theme = $name
            [void](Set-GhlTheme -Name $name)
            Show-GhlToast -Message "Theme: $name" -Kind 'info' -Ms 1500
        })

    $ui.chkAnimateBg.Add_Checked({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SuppressAppearanceChange) { return }
            $st.Config.AnimateBackground = $true
            Apply-GhlBackgroundSource -Source ([string]$st.UI.txtBg.Text)
        })
    $ui.chkAnimateBg.Add_Unchecked({
            param($s, $e)
            $st = $Global:GhlState
            if ($st.SuppressAppearanceChange) { return }
            $st.Config.AnimateBackground = $false
            Apply-GhlBackgroundSource -Source ([string]$st.UI.txtBg.Text)
        })

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
            Show-GhlToast -Message 'Background reset to the default theme.' -Kind 'info' -Ms 2000
        })

    # --- keyboard shortcuts ----------------------------------------------
    $win.Add_KeyDown({
            param($s, $e)
            $st = $Global:GhlState
            switch ($e.Key) {
                'Escape' {
                    if ($st.UI.settingsOverlay.Visibility -eq [Windows.Visibility]::Visible) {
                        Show-GhlSettings -Show $false
                        $e.Handled = $true
                    } elseif ($st.Busy -and $st.BusyKind -eq 'Download') {
                        Cancel-GhlDownload
                    }
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
            try { $st.SyncBg.CancelRequested = $true } catch { }
            Stop-GhlGifBackground
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
            Phase            = 'idle'
            StatusText       = ''
            ProgressPercent  = -1.0
            BytesReceived    = 0L
            BytesTotal       = -1L
            SpeedBps         = 0.0
            CancelRequested  = $false
            Events           = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        })
    $syncBg = [hashtable]::Synchronized(@{
            Phase            = 'idle'
            StatusText       = ''
            ProgressPercent  = -1.0
            BytesReceived    = 0L
            BytesTotal       = -1L
            SpeedBps         = 0.0
            CancelRequested  = $false
            Events           = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        })

    # No Application object anywhere. Application.Shutdown() permanently kills the
    # dispatcher of the thread it ran on, and a second Application cannot be created
    # in the same AppDomain - so a second Start-GitHubLauncher in the same session
    # used to fail with a misleading "interface failed to load" (the real cause was
    # that styles never reached Application.Resources, so StaticResource lookups
    # threw). Each window carries its own styles now and is shown with ShowDialog().
    try {
        $window = [Windows.Markup.XamlReader]::Parse((Get-GhlWindowXaml -Name 'MainWindow'))
    } catch {
        Show-GhlFatal -Message ("The interface failed to load.`n`n{0}`n`n{1}" -f `
                $_.Exception.Message, $_.ScriptStackTrace)
        return
    }

    $ui = Get-GhlUiMap -Window $window
    $ui.Window = $window

    $brushes = @{
        Success       = $window.FindResource('SuccessBrush')
        Warn          = $window.FindResource('WarnBrush')
        Danger        = $window.FindResource('DangerBrush')
        Border        = $window.FindResource('BorderBrush')
        TextDim       = $window.FindResource('TextDimBrush')
        Text          = $window.FindResource('TextBrush')
        Accent        = $window.FindResource('AccentBrush')
        AccentStrong  = $window.FindResource('AccentStrongBrush')
        Bg0           = $window.FindResource('Bg0Brush')
        Bg2           = $window.FindResource('Bg2Brush')
    }

    $Global:GhlState = @{
        UI              = $ui
        Config          = $config
        Sync            = $sync
        SyncBg          = $syncBg
        Pool            = $null
        Jobs            = @{}
        Repos           = New-Object System.Collections.ObjectModel.ObservableCollection[GhlRepoRow]
        AllRepos        = @()
        Assets          = New-Object System.Collections.ObjectModel.ObservableCollection[GhlAssetItem]
        Releases        = @()
        ReleaseItems    = @()
        ReleaseCache    = @{}
        SelectedRow     = $null
        CurrentRelease  = $null
        SelectedRelease = $null
        ReleaseFor      = ''
        ReposRequest    = 0
        ReleaseRequest  = 0
        Mode            = 'Release'
        PreferredMode   = $(if ($config.DownloadMode -eq 'Source') { 'Source' } else { 'Release' })
        SourceForced    = $false
        SuppressModeChange = $false
        Busy            = $false
        BusyKind        = ''
        LastErrorText   = ''
        LastDownloadDir = ''
        Maximized       = $false
        RestoreBounds   = $null
        FilterTimer     = $null
        FilterTokens    = @()
        ToastTimer      = $null
        Brushes         = $brushes
        Theme           = 'Midnight'
        Gif             = $null
        SuppressThemeChange      = $false
        SuppressAppearanceChange = $false
        PickerWindow    = $null
        ConfirmWindow   = $null
        SuppressSelection     = $false
        SuppressReleaseChange = $false
        Queue           = $null
        QueueTotal      = 0
        QueueDone       = 0
        QueueSkipped    = 0
        LastRemaining   = -1
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
    try {
        # ShowDialog runs its own message loop on this thread and returns when the
        # window closes - no Application.Run, so nothing global is torn down.
        [void]$window.ShowDialog()
    } catch {
        Show-GhlFatal -Message ("The interface crashed.`n`n{0}" -f $_.Exception.Message)
    }

    if ($Global:GhlState -and $Global:GhlState.Pump) { $Global:GhlState.Pump.Stop() }
    $Global:GhlState = $null
    Write-GhlLog 'Application exited.'
}
