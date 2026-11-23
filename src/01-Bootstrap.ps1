<#
    01-Bootstrap.ps1
    Environment setup, paths, logging, STA guard.
#>

function Get-GhlAppDir {
    <#
        Returns the app data folder (%LocalAppData%\GitHubLauncher) and creates it.
        GHL_CONFIG_DIR overrides the location, so tests and screenshots can run
        against their own settings instead of the user's real ones.
    #>
    if ($env:GHL_CONFIG_DIR) {
        $dir = $env:GHL_CONFIG_DIR
    } else {
        $dir = Join-Path $env:LOCALAPPDATA 'GitHubLauncher'
    }
    foreach ($sub in @('', 'logs', 'bg', 'tmp')) {
        $p = if ($sub) { Join-Path $dir $sub } else { $dir }
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
    return $dir
}

function Get-GhlRoot {
    <# Root of the source tree. Only meaningful in dev mode; the compiled
       artifact embeds every resource and never needs it. #>
    if ($Global:GHL_Root) { return $Global:GHL_Root }
    if ($PSScriptRoot) { return (Split-Path -Parent $PSScriptRoot) }
    return (Get-Location).Path
}

function Get-GhlXaml {
    param([Parameter(Mandatory)][string]$Name)

    if ($Global:GHL_Xaml -and $Global:GHL_Xaml.ContainsKey($Name)) {
        return $Global:GHL_Xaml[$Name]
    }

    $map = @{
        'Styles'       = 'ui\Styles.xaml'
        'MainWindow'   = 'ui\MainWindow.xaml'
        'PickerWindow' = 'ui\PickerWindow.xaml'
    }
    if (-not $map.ContainsKey($Name)) { throw "Unknown XAML resource '$Name'." }

    $path = Join-Path (Get-GhlRoot) $map[$Name]
    if (-not (Test-Path -LiteralPath $path)) {
        throw "XAML resource '$Name' not found at '$path'. Run Compile.ps1 to build a standalone script."
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
}

function Get-GhlStylesFragment {
    <#
        Returns the body of Styles.xaml (everything inside the ResourceDictionary
        root element) so it can be inlined into a window's own resources.
    #>
    $text = Get-GhlXaml -Name 'Styles'
    $start = $text.IndexOf('>')
    $end = $text.LastIndexOf('</ResourceDictionary>')
    if ($start -lt 0 -or $end -lt 0 -or $end -le $start) {
        throw 'Styles.xaml does not look like a ResourceDictionary.'
    }
    return $text.Substring($start + 1, $end - $start - 1)
}

function Get-GhlWindowXaml {
    <#
        Returns window XAML with the shared styles inlined into Window.Resources.

        Why inline instead of Application.Current.Resources: creating a second
        WPF window in the same PowerShell session fails once Application.Run()
        has shut the dispatcher down ("Cannot create more than one instance of
        System.Windows.Application in the same AppDomain"). A window whose
        StaticResource lookups resolve locally does not need Application at all,
        so the UI can be created repeatedly.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $xaml = Get-GhlXaml -Name $Name

    $marker = '<!-- GHL_STYLES_INJECT -->'
    if ($xaml.IndexOf($marker) -lt 0) {
        throw "The window XAML '$Name' is missing the $marker marker."
    }

    $styles = Get-GhlStylesFragment
    return $xaml.Replace($marker, $styles.Trim())
}

function Get-GhlAssetBytes {
    <# Returns raw bytes for a bundled asset (icon etc.). #>
    param([Parameter(Mandatory)][string]$Name)

    if ($Global:GHL_Assets -and $Global:GHL_Assets.ContainsKey($Name)) {
        return [Convert]::FromBase64String($Global:GHL_Assets[$Name])
    }

    $candidates = @(
        (Join-Path (Get-GhlRoot) "ui\assets\$Name.png"),
        (Join-Path (Get-GhlRoot) "ui\assets\$Name.ico")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return [IO.File]::ReadAllBytes($c) }
    }
    return $null
}

function Write-GhlLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Debug')][string]$Level = 'Info'
    )

    try {
        if ($Level -eq 'Debug' -and -not $Global:GHL_DebugLog) { return }
        # honour GHL_CONFIG_DIR so tests and screenshots never write to the real profile
        $dir = Join-Path (Get-GhlAppDir) 'logs'
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $file = Join-Path $dir 'launcher.log'

        # keep the log from growing without bound
        if (Test-Path -LiteralPath $file) {
            $len = (Get-Item -LiteralPath $file).Length
            if ($len -gt 1MB) {
                $bak = Join-Path $dir 'launcher.1.log'
                Move-Item -LiteralPath $file -Destination $bak -Force -ErrorAction SilentlyContinue
            }
        }

        $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-5}] {2}' -f (Get-Date), $Level, $Message
        [IO.File]::AppendAllText($file, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch {
        # logging must never take the app down
    }
}

function Test-GhlSta {
    return ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
}

function Initialize-GhlEnvironment {
    <#
        Returns $true when the caller may create WPF objects.
        Returns $false when the script has relaunched itself (caller must exit)
        or when the environment simply cannot host WPF.
    #>

    $Global:GHL_DebugLog = [bool]$env:GHL_DEBUG

    # --- assemblies -------------------------------------------------------
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop

    # --- modern TLS + sane defaults --------------------------------------
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    } catch {
        Write-GhlLog "Could not raise TLS level: $($_.Exception.Message)" Warn
    }

    [Net.ServicePointManager]::Expect100Continue = $false

    # --- STA guard --------------------------------------------------------
    if (-not (Test-GhlSta)) {
        Write-GhlLog 'Host is MTA; WPF requires STA.' Warn

        if ($env:GHL_RELAUNCHED -ne '1' -and $PSCommandPath) {
            Write-GhlLog "Relaunching '$PSCommandPath' in an STA process."
            $env:GHL_RELAUNCHED = '1'
            try {
                $psi = New-Object Diagnostics.ProcessStartInfo
                $psi.FileName = (Get-Process -Id $PID).Path
                if (-not $psi.FileName) { $psi.FileName = 'powershell.exe' }
                $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Normal -File "{0}"' -f $PSCommandPath
                $psi.UseShellExecute = $true
                [Diagnostics.Process]::Start($psi) | Out-Null
                return $false
            } catch {
                Write-GhlLog "STA relaunch failed: $($_.Exception.Message)" Error
            }
        }

        [void][Reflection.Assembly]::LoadWithPartialName('PresentationFramework')
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

        $hint = @(
            'GitHub Launcher needs a single-threaded apartment (STA) host, because WPF cannot run on a multi-threaded one.',
            '',
            'You are running it in an MTA shell (PowerShell 7 / pwsh). Use the built-in Windows PowerShell instead:',
            '',
            '    powershell.exe -NoProfile -STA -Command "irm <the same url> | iex"',
            '',
            'Or save the file and start it directly:',
            '',
            '    irm <the same url> -OutFile "$env:TEMP\GitHubLauncher.ps1"',
            '    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$env:TEMP\GitHubLauncher.ps1"',
            '',
            'Windows PowerShell 5.1 (powershell.exe) is STA by default, so the one-liner works there as-is.'
        ) -join [Environment]::NewLine

        if ($env:GHL_HEADLESS) {
            # used by the test suite: never block on a modal dialog
            Write-Host 'GHL: a single-threaded apartment (STA) host is required; refusing to start in MTA.'
            return $false
        }

        [void][Windows.MessageBox]::Show(
            $hint,
            'GitHub Launcher',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Warning)
        return $false
    }

    # --- paths ------------------------------------------------------------
    [void](Get-GhlAppDir)
    Write-GhlLog ('--- session start --- PowerShell ' + $PSVersionTable.PSVersion + ' | ' + [Environment]::OSVersion.VersionString)
    return $true
}

function Show-GhlFatal {
    param([Parameter(Mandatory)][string]$Message, [string]$Title = 'GitHub Launcher')

    Write-GhlLog "FATAL: $Message" Error
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [void][Windows.MessageBox]::Show($Message, $Title,
            [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error)
    } catch {
        Write-Host $Message -ForegroundColor Red
    }
}

function Format-GhlSize {
    <# Culture-invariant so '1.5 MB' never becomes '1,5 MB'. #>
    param([Nullable[double]]$Bytes)

    if ($null -eq $Bytes -or $Bytes -lt 0) { return '' }
    $c = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return [string]::Format($c, '{0:0.00} GB', ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return [string]::Format($c, '{0:0.0} MB', ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return [string]::Format($c, '{0:0.0} KB', ($Bytes / 1KB)) }
    return [string]::Format($c, '{0:0} B', $Bytes)
}

function Format-GhlDuration {
    param([Nullable[double]]$Seconds)

    if ($null -eq $Seconds -or $Seconds -lt 0 -or [double]::IsInfinity($Seconds)) { return '' }
    $c = [Globalization.CultureInfo]::InvariantCulture
    if ($Seconds -lt 60) { return [string]::Format($c, '{0:0}s', $Seconds) }
    if ($Seconds -lt 3600) {
        return [string]::Format($c, '{0:0}m {1:00}s', [Math]::Floor($Seconds / 60), [Math]::Floor($Seconds % 60))
    }
    return [string]::Format($c, '{0:0}h {1:00}m', [Math]::Floor($Seconds / 3600), [Math]::Floor(($Seconds % 3600) / 60))
}
