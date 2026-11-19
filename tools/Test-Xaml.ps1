[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UiPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

try {
    $styles = [System.Windows.Markup.XamlReader]::Parse(
        [IO.File]::ReadAllText((Join-Path $UiPath 'Styles.xaml'), [Text.Encoding]::UTF8))
    [void]$app.Resources.MergedDictionaries.Add($styles)
    Write-Host '  [ok] Styles.xaml'
} catch {
    Write-Host "  [!!] Styles.xaml: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$failures = 0
foreach ($name in @('MainWindow.xaml', 'PickerWindow.xaml')) {
    try {
        $xaml = [IO.File]::ReadAllText((Join-Path $UiPath $name), [Text.Encoding]::UTF8)
        $obj = [System.Windows.Markup.XamlReader]::Parse($xaml)
        if ($obj -is [System.Windows.Window]) {
            $obj.Close()
        }
        Write-Host "  [ok] ${name}"
    } catch {
        Write-Host "  [!!] ${name}: $($_.Exception.Message)" -ForegroundColor Red
        $failures++
    }
}

if ($failures -gt 0) { exit 1 }
exit 0
