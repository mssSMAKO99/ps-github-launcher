$DefaultUser = 'torvalds'   # ник на GitHub, список которого загружается при старте
$BaseDir = 'C:\MyGitHubProjects'
$AppTitle = 'GitHub ZIP Launcher'
$SelfUrl = ''

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Ssl3
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Definition }
if ($script:ScriptPath) {
    try {
        if (-not (Test-Path -LiteralPath $script:ScriptPath -PathType Leaf)) { $script:ScriptPath = $null }
    } catch {
        $script:ScriptPath = $null
    }
}

$script:Token = ''
$script:Busy = $false
$script:BusyControls = @()

function Get-ApiHeaders {
    $headers = @{
        'User-Agent' = 'GitHub-Zip-Launcher/1.0'
        'Accept'     = 'application/vnd.github+json'
    }
    if ($script:Token) {
        $headers['Authorization'] = 'Bearer ' + $script:Token
    }
    return $headers
}

function Set-Status {
    param([string]$Text)
    try {
        $script:lblStatus.Text = $Text
        $script:lblStatus.Refresh()
    } catch { }
    try {
        [void][System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

function Set-Busy {
    param([bool]$Enabled)
    $script:Busy = $Enabled
    foreach ($control in $script:BusyControls) {
        if ($null -ne $control) {
            try { $control.Enabled = -not $Enabled } catch { }
        }
    }
    try {
        $script:form.UseWaitCursor = $Enabled
        $script:listView.UseWaitCursor = $Enabled
    } catch { }
    if (-not $Enabled) {
        try {
            $script:progress.Style = 'Blocks'
            $script:progress.MarqueeAnimationSpeed = 0
            $script:progress.Value = 0
        } catch { }
        try { $script:form.Cursor = [System.Windows.Forms.Cursors]::Default } catch { }
    } else {
        try { $script:form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor } catch { }
    }
    try { [void][System.Windows.Forms.Application]::DoEvents() } catch { }
}

function Get-ErrorStatus {
    param($ErrorRecord)
    $status = 0
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            try { $status = [int]$response.StatusCode } catch {
                try { $status = [int]$response.StatusCode.value__ } catch { $status = 0 }
            }
        }
    } catch { }
    return $status
}

function Get-RateReset {
    param($ErrorRecord)
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response) { return $null }
        $raw = $response.Headers['X-RateLimit-Reset']
        if (-not $raw) { return $null }
        $seconds = [int]$raw
        if ($seconds -le 0) { return $null }
        return ([DateTime]'1970-01-01T00:00:00Z').ToLocalTime().AddSeconds($seconds)
    } catch {
        return $null
    }
}

function Show-ApiError {
    param($ErrorRecord, [string]$Context)
    $status = Get-ErrorStatus $ErrorRecord
    $msg = ''
    switch ($status) {
        401 {
            $msg = 'Неверный токен: GitHub отклонил авторизацию (401).'
        }
        403 {
            $msg = 'Доступ запрещён или исчерпан лимит GitHub API (403). Укажите токен.'
            $reset = Get-RateReset $ErrorRecord
            if ($null -ne $reset) {
                $msg = $msg + ' Лимит сбросится в ' + $reset.ToString('HH:mm') + '.'
            }
        }
        429 {
            $msg = 'Слишком много запросов к GitHub API (429). Подождите и повторите.'
            $reset = Get-RateReset $ErrorRecord
            if ($null -ne $reset) {
                $msg = $msg + ' Лимит сбросится в ' + $reset.ToString('HH:mm') + '.'
            }
        }
        404 {
            if ($Context -eq 'zip') {
                $msg = 'Репозиторий пуст или недоступен (404): нет коммитов либо нет прав. Для приватных репозиториев нужен токен.'
            } else {
                $msg = 'Пользователь или репозиторий не найден (404). Для приватных репозиториев укажите токен.'
            }
        }
        default {
            $detail = ''
            try { $detail = $ErrorRecord.Exception.Message } catch { }
            if ($detail) {
                $msg = 'Ошибка: ' + $detail
            } else {
                $msg = 'Неизвестная ошибка при обращении к GitHub.'
            }
        }
    }
    Set-Status $msg
    return $msg
}

function Get-Repos {
    param([string]$User)
    $user = ''
    if ($User) { $user = $User.Trim() }
    if ([string]::IsNullOrWhiteSpace($user)) {
        throw 'Укажите имя пользователя GitHub.'
    }
    $headers = Get-ApiHeaders
    $collected = New-Object System.Collections.ArrayList
    $limitReached = $false

    if ($script:Token) {
        $page = 1
        while ($page -le 10) {
            $uri = 'https://api.github.com/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=updated&page=' + $page
            $response = @(Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop)
            $response = @($response | Where-Object { $null -ne $_ })
            foreach ($repo in $response) {
                $ownerLogin = ''
                if ($repo.owner) { $ownerLogin = [string]$repo.owner.login }
                if ($ownerLogin -ieq $user) {
                    [void]$collected.Add($repo)
                }
            }
            if ($response.Count -lt 100) { break }
            if ($page -eq 10) { $limitReached = $true }
            $page = $page + 1
        }
    }

    if ($collected.Count -eq 0) {
        $page = 1
        while ($page -le 10) {
            $uri = 'https://api.github.com/users/' + $user + '/repos?per_page=100&page=' + $page + '&sort=updated'
            $response = @(Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop)
            $response = @($response | Where-Object { $null -ne $_ })
            foreach ($repo in $response) {
                [void]$collected.Add($repo)
            }
            if ($response.Count -lt 100) { break }
            if ($page -eq 10) { $limitReached = $true }
            $page = $page + 1
        }
    }

    $reposArray = @($collected)
    return [pscustomobject]@{ Repos = $reposArray; Limit = $limitReached }
}

function Get-RepoPath {
    param($Repo)
    $owner = ''
    if ($Repo.owner) { $owner = [string]$Repo.owner.login }
    if ([string]::IsNullOrWhiteSpace($owner)) { $owner = $script:txtUser.Text.Trim() }
    $name = [string]$Repo.name
    return (Join-Path (Join-Path $BaseDir $owner) $name)
}

function Update-OneRepo {
    param($Repo)
    $owner = ''
    if ($Repo.owner) { $owner = [string]$Repo.owner.login }
    if ([string]::IsNullOrWhiteSpace($owner)) { $owner = $script:txtUser.Text.Trim() }
    $name = [string]$Repo.name
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Не удалось определить имя репозитория.' }
    $target = Join-Path (Join-Path $BaseDir $owner) $name
    $work = Join-Path $env:TEMP ('gh-launcher\' + [guid]::NewGuid().ToString())

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $zip = Join-Path $work 'repo.zip'

        Set-Status ('Скачивание архива: ' + $owner + '/' + $name + ' ...')
        $uri = 'https://api.github.com/repos/' + $owner + '/' + $name + '/zipball'
        try {
            Invoke-WebRequest -Uri $uri -Headers (Get-ApiHeaders) -OutFile $zip -UseBasicParsing
        } catch {
            $status = Get-ErrorStatus $_
            if ($status -eq 404) {
                throw 'Репозиторий пуст или недоступен (404): нет коммитов либо нет прав.'
            }
            throw $_
        }
        if (-not (Test-Path -LiteralPath $zip)) { throw 'Архив не был загружен.' }

        Set-Status ('Распаковка: ' + $owner + '/' + $name + ' ...')
        $extract = Join-Path $work 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

        $root = @(Get-ChildItem -LiteralPath $extract -Force -Directory)
        if ($root.Count -ne 1) {
            throw 'Неожиданная структура архива GitHub.'
        }
        $source = $root[0].FullName

        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $target | Out-Null

        Set-Status ('Размещение файлов: ' + $owner + '/' + $name + ' ...')
        try {
            Get-ChildItem -LiteralPath $source -Force | Move-Item -Destination $target -Force
        } catch {
            $inner = Join-Path $source '*'
            Copy-Item -Path $inner -Destination $target -Recurse -Force
        }
    } finally {
        $ErrorActionPreference = $previous
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Launcher {
    $destDir = Join-Path $BaseDir '_Launcher'
    $dest = Join-Path $destDir 'Launcher.ps1'
    $source = $script:ScriptPath

    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $source = $null
        if ($SelfUrl) {
            $temp = Join-Path $env:TEMP ('Launcher-' + [guid]::NewGuid().ToString() + '.ps1')
            Invoke-WebRequest -Uri $SelfUrl -OutFile $temp -UseBasicParsing
            $source = $temp
        }
    }
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw 'Запустите скрипт из файла .ps1, чтобы установить лаунчер.'
    }

    if (-not (Test-Path -LiteralPath $BaseDir)) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    $sourceFull = ''
    $destFull = ''
    try { $sourceFull = [System.IO.Path]::GetFullPath($source) } catch { }
    try { $destFull = [System.IO.Path]::GetFullPath($dest) } catch { }
    if ($sourceFull -ne $destFull) {
        Copy-Item -LiteralPath $source -Destination $dest -Force
    }

    $exe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'Не удалось найти папку рабочего стола.' }
    $lnk = Join-Path $desktop 'GitHub Launcher.lnk'

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($lnk)
        $shortcut.TargetPath = $exe
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $dest + '"'
        $shortcut.WorkingDirectory = $BaseDir
        $shortcut.IconLocation = $exe + ',0'
        $shortcut.Description = $AppTitle
        $shortcut.Save()
    } finally {
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
    }

    return ('Лаунчер установлен: ' + $dest + [Environment]::NewLine + 'Ярлык: ' + $lnk)
}

function Update-AllStatus {
    $items = $script:listView.Items
    foreach ($item in $items) {
        $state = 'Не скачан'
        $repo = $item.Tag
        if ($null -ne $repo) {
            try {
                $path = Get-RepoPath $repo
                if (Test-Path -LiteralPath $path) { $state = 'Установлен' }
            } catch { }
        }
        if ($item.SubItems.Count -gt 1) {
            $item.SubItems[1].Text = $state
        }
    }
}

function Load-RepoList {
    if ($script:Busy) { return }
    $user = $script:txtUser.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($user)) {
        Set-Status 'Укажите имя пользователя GitHub.'
        return
    }
    $script:Token = $script:txtToken.Text

    $checkedNames = @()
    foreach ($item in $script:listView.Items) {
        if ($item.Checked) { $checkedNames += $item.Text }
    }

    Set-Busy $true
    try {
        $script:progress.Style = 'Marquee'
        $script:progress.MarqueeAnimationSpeed = 30
    } catch { }
    Set-Status ('Получение списка репозиториев: ' + $user + ' ...')

    try {
        $result = Get-Repos -User $user
        $repos = @($result.Repos)
        $limitReached = [bool]$result.Limit

        $script:listView.BeginUpdate()
        try {
            $script:listView.Items.Clear()
            foreach ($repo in $repos) {
                $item = New-Object System.Windows.Forms.ListViewItem([string]$repo.name)
                [void]$item.SubItems.Add('')
                [void]$item.SubItems.Add([string]$repo.stargazers_count)
                $branch = ''
                if ($repo.default_branch) { $branch = [string]$repo.default_branch }
                [void]$item.SubItems.Add($branch)
                $description = ''
                if ($repo.description) { $description = [string]$repo.description }
                $description = $description -replace '[\r\n\t]+', ' '
                [void]$item.SubItems.Add($description)
                $item.Tag = $repo
                if ($description) { $item.ToolTipText = $description }
                [void]$script:listView.Items.Add($item)
            }
        } finally {
            $script:listView.EndUpdate()
        }

        $script:chkAll.Checked = $false
        Update-AllStatus
        if ($checkedNames.Count -gt 0) {
            foreach ($item in $script:listView.Items) {
                if ($checkedNames -contains $item.Text) { $item.Checked = $true }
            }
        }
        $script:listView.Refresh()

        $summary = 'Репозиториев: ' + $repos.Count + '.'
        if ($repos.Count -eq 0) {
            $summary = 'Репозитории не найдены. Проверьте никнейм и токен.'
        } elseif ($limitReached) {
            $summary = $summary + ' Показаны первые 1000 (лимит пагинации).'
        }
        Set-Status $summary
    } catch {
        $message = Show-ApiError $_ 'list'
        Set-Status $message
    } finally {
        Set-Busy $false
    }
}

function Start-Download {
    if ($script:Busy) { return }
    $checked = @($script:listView.CheckedItems)
    if ($checked.Count -eq 0) {
        Set-Status 'Ничего не выбрано: отметьте репозитории в списке.'
        return
    }
    $script:Token = $script:txtToken.Text

    $existing = 0
    foreach ($item in $checked) {
        $repo = $item.Tag
        if ($null -ne $repo) {
            try {
                if (Test-Path -LiteralPath (Get-RepoPath $repo)) { $existing = $existing + 1 }
            } catch { }
        }
    }
    if ($existing -gt 0) {
        $question = 'Будут заменены N репозиториев. Локальные изменения будут потеряны.' -replace 'N', [string]$existing
        $answer = [System.Windows.Forms.MessageBox]::Show($question, $AppTitle, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Set-Status 'Скачивание отменено.'
            return
        }
    }

    Set-Busy $true
    $ok = 0
    $failed = 0
    $index = 0
    try {
        $script:progress.Style = 'Blocks'
        $script:progress.MarqueeAnimationSpeed = 0
        $script:progress.Minimum = 0
        $script:progress.Maximum = $checked.Count
        $script:progress.Value = 0
        try { $script:form.Refresh() } catch { }

        foreach ($item in $checked) {
            $repo = $item.Tag
            $index = $index + 1
            $label = [string]$item.Text
            if ($null -ne $repo) {
                $ownerLogin = $script:txtUser.Text.Trim()
                if ($repo.owner) { $ownerLogin = [string]$repo.owner.login }
                $label = $ownerLogin + '/' + [string]$repo.name
            }
            try { $script:progress.Value = $index } catch { }
            Set-Status ('[' + $index + '/' + $checked.Count + '] ' + $label)

            try {
                Update-OneRepo $repo
                $ok = $ok + 1
                if ($item.SubItems.Count -gt 1) { $item.SubItems[1].Text = 'Установлен' }
                $item.Checked = $false
            } catch {
                $failed = $failed + 1
                $message = Show-ApiError $_ 'zip'
                if ($item.SubItems.Count -gt 1) { $item.SubItems[1].Text = 'Не скачан' }
                Set-Status ('Ошибка ' + $label + ': ' + $message)
            }
            try { $script:listView.Refresh() } catch { }
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
        }
    } finally {
        Set-Busy $false
        Update-AllStatus
        $script:chkAll.Checked = $false
        $script:listView.Refresh()
        Set-Status ('Готово. Скачано: ' + $ok + ', ошибок: ' + $failed + '.')
    }
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = $AppTitle
$script:form.ClientSize = New-Object System.Drawing.Size(1040, 660)
$script:form.MinimumSize = New-Object System.Drawing.Size(840, 500)
$script:form.StartPosition = 'CenterScreen'
$script:form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$script:topPanel = New-Object System.Windows.Forms.TableLayoutPanel
$script:topPanel.Dock = 'Top'
$script:topPanel.AutoSize = $true
$script:topPanel.AutoSizeMode = 'GrowAndShrink'
$script:topPanel.ColumnCount = 6
$script:topPanel.RowCount = 2
$script:topPanel.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)

[void]$script:topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$script:topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$script:topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$script:topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$script:topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$script:topPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$script:topPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$script:topPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))

$labelUser = New-Object System.Windows.Forms.Label
$labelUser.Text = 'GitHub Username'
$labelUser.AutoSize = $true
$labelUser.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$labelUser.Margin = New-Object System.Windows.Forms.Padding(4, 4, 12, 2)
$script:topPanel.Controls.Add($labelUser, 0, 0)

$script:txtUser = New-Object System.Windows.Forms.TextBox
$script:txtUser.Width = 190
$script:txtUser.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:txtUser.Margin = New-Object System.Windows.Forms.Padding(4, 0, 12, 6)
$script:topPanel.Controls.Add($script:txtUser, 0, 1)

$labelToken = New-Object System.Windows.Forms.Label
$labelToken.Text = 'GitHub Token'
$labelToken.AutoSize = $true
$labelToken.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$labelToken.Margin = New-Object System.Windows.Forms.Padding(4, 4, 12, 2)
$script:topPanel.Controls.Add($labelToken, 1, 0)

$script:txtToken = New-Object System.Windows.Forms.TextBox
$script:txtToken.Width = 250
$script:txtToken.UseSystemPasswordChar = $true
$script:txtToken.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:txtToken.Margin = New-Object System.Windows.Forms.Padding(4, 0, 12, 6)
$script:topPanel.Controls.Add($script:txtToken, 1, 1)

$script:btnLoad = New-Object System.Windows.Forms.Button
$script:btnLoad.Text = 'Загрузить / Обновить список'
$script:btnLoad.AutoSize = $true
$script:btnLoad.AutoSizeMode = 'GrowAndShrink'
$script:btnLoad.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:btnLoad.Margin = New-Object System.Windows.Forms.Padding(6, 14, 6, 6)
$script:topPanel.Controls.Add($script:btnLoad, 2, 0)
$script:topPanel.SetRowSpan($script:btnLoad, 2)

$script:btnOpen = New-Object System.Windows.Forms.Button
$script:btnOpen.Text = 'Открыть папку'
$script:btnOpen.AutoSize = $true
$script:btnOpen.AutoSizeMode = 'GrowAndShrink'
$script:btnOpen.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:btnOpen.Margin = New-Object System.Windows.Forms.Padding(6, 14, 6, 6)
$script:topPanel.Controls.Add($script:btnOpen, 3, 0)
$script:topPanel.SetRowSpan($script:btnOpen, 2)

$script:listPanel = New-Object System.Windows.Forms.Panel
$script:listPanel.Dock = 'Fill'
$script:listPanel.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 2)

$script:listView = New-Object System.Windows.Forms.ListView
$script:listView.Dock = 'Fill'
$script:listView.View = 'Details'
$script:listView.CheckBoxes = $true
$script:listView.FullRowSelect = $true
$script:listView.MultiSelect = $true
$script:listView.GridLines = $true
$script:listView.HideSelection = $false
$script:listView.ShowItemToolTips = $true
$script:listView.UseCompatibleStateImageBehavior = $false
[void]$script:listView.Columns.Add('Репозиторий', 220)
[void]$script:listView.Columns.Add('Статус', 110)
[void]$script:listView.Columns.Add('Звезды', 70)
[void]$script:listView.Columns.Add('Ветка', 120)
[void]$script:listView.Columns.Add('Описание', 480)

$script:chkAll = New-Object System.Windows.Forms.CheckBox
$script:chkAll.Text = 'Выбрать все'
$script:chkAll.Dock = 'Top'
$script:chkAll.AutoSize = $true
$script:chkAll.Padding = New-Object System.Windows.Forms.Padding(2, 4, 0, 6)

$script:listPanel.Controls.Add($script:listView)
$script:listPanel.Controls.Add($script:chkAll)

$script:bottomPanel = New-Object System.Windows.Forms.Panel
$script:bottomPanel.Dock = 'Bottom'
$script:bottomPanel.Height = 86
$script:bottomPanel.Padding = New-Object System.Windows.Forms.Padding(8)

$script:bottomLayout = New-Object System.Windows.Forms.TableLayoutPanel
$script:bottomLayout.Dock = 'Fill'
$script:bottomLayout.ColumnCount = 2
$script:bottomLayout.RowCount = 2
[void]$script:bottomLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$script:bottomLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$script:bottomLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 50)))
[void]$script:bottomLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 50)))

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = 'Готов к работе.'
$script:lblStatus.Dock = 'Fill'
$script:lblStatus.AutoSize = $false
$script:lblStatus.AutoEllipsis = $true
$script:lblStatus.TextAlign = 'MiddleLeft'
$script:lblStatus.Margin = New-Object System.Windows.Forms.Padding(4, 0, 12, 2)

$script:progress = New-Object System.Windows.Forms.ProgressBar
$script:progress.Dock = 'Fill'
$script:progress.Minimum = 0
$script:progress.Maximum = 100
$script:progress.Value = 0
$script:progress.Style = 'Blocks'
$script:progress.Margin = New-Object System.Windows.Forms.Padding(4, 4, 12, 4)

$script:btnDownload = New-Object System.Windows.Forms.Button
$script:btnDownload.Text = 'Скачать / Обновить выбранное'
$script:btnDownload.AutoSize = $true
$script:btnDownload.AutoSizeMode = 'GrowAndShrink'
$script:btnDownload.MinimumSize = New-Object System.Drawing.Size(230, 30)
$script:btnDownload.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:btnDownload.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)

$script:btnInstall = New-Object System.Windows.Forms.Button
$script:btnInstall.Text = 'Установить лаунчер на ПК'
$script:btnInstall.AutoSize = $true
$script:btnInstall.AutoSizeMode = 'GrowAndShrink'
$script:btnInstall.MinimumSize = New-Object System.Drawing.Size(230, 30)
$script:btnInstall.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:btnInstall.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)

$script:bottomLayout.Controls.Add($script:lblStatus, 0, 0)
$script:bottomLayout.Controls.Add($script:progress, 0, 1)
$script:bottomLayout.Controls.Add($script:btnDownload, 1, 0)
$script:bottomLayout.Controls.Add($script:btnInstall, 1, 1)
$script:bottomPanel.Controls.Add($script:bottomLayout)

$script:form.Controls.Add($script:listPanel)
$script:form.Controls.Add($script:topPanel)
$script:form.Controls.Add($script:bottomPanel)

$script:BusyControls = @(
    $script:txtUser,
    $script:txtToken,
    $script:btnLoad,
    $script:btnOpen,
    $script:btnDownload,
    $script:btnInstall,
    $script:listView,
    $script:chkAll
)

$script:btnLoad.add_Click({ Load-RepoList })

$script:btnOpen.add_Click({
    if ($script:Busy) { return }
    try {
        if (-not (Test-Path -LiteralPath $BaseDir)) {
            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $BaseDir + '"')
        Set-Status ('Открыта папка ' + $BaseDir)
    } catch {
        Set-Status ('Не удалось открыть папку: ' + $_.Exception.Message)
    }
})

$script:btnDownload.add_Click({ Start-Download })

$script:btnInstall.add_Click({
    if ($script:Busy) { return }
    Set-Busy $true
    Set-Status 'Установка лаунчера ...'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        $message = Install-Launcher
        Set-Status 'Лаунчер установлен.'
        [System.Windows.Forms.MessageBox]::Show($message, $AppTitle, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        $text = $_.Exception.Message
        Set-Status ('Установка не удалась: ' + $text)
        [System.Windows.Forms.MessageBox]::Show($text, $AppTitle, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $ErrorActionPreference = $previous
        Set-Busy $false
    }
})

$script:chkAll.add_CheckedChanged({
    $state = $script:chkAll.Checked
    $script:listView.BeginUpdate()
    try {
        foreach ($item in $script:listView.Items) {
            $item.Checked = $state
        }
    } finally {
        $script:listView.EndUpdate()
    }
})

$script:txtUser.add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') {
        $eventArgs.SuppressKeyPress = $true
        Load-RepoList
    }
})

$script:txtToken.add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') {
        $eventArgs.SuppressKeyPress = $true
        Load-RepoList
    }
})

$script:autoTimer = New-Object System.Windows.Forms.Timer
$script:autoTimer.Interval = 250
$script:autoTimer.add_Tick({
    $timer = $script:autoTimer
    $timer.Stop()
    if (-not [string]::IsNullOrWhiteSpace($script:txtUser.Text) -or -not [string]::IsNullOrWhiteSpace($DefaultUser)) {
        if ([string]::IsNullOrWhiteSpace($script:txtUser.Text)) { $script:txtUser.Text = $DefaultUser }
        Load-RepoList
    }
})

$script:form.add_Shown({
    if (-not [string]::IsNullOrWhiteSpace($DefaultUser)) {
        $script:txtUser.Text = $DefaultUser
        $script:autoTimer.Start()
    } else {
        Set-Status 'Введите ник GitHub и нажмите «Загрузить / Обновить список».'
    }
})

$script:form.add_FormClosing({
    param($sender, $eventArgs)
    if ($script:Busy) {
        $eventArgs.Cancel = $true
        Set-Status 'Дождитесь завершения текущей операции.'
    }
})

[void]$script:form.ShowDialog()
