[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UiPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# No Application object: the windows carry their own styles now, which also
# proves that StaticResource lookups resolve without Application.Current.

$stylesPath = Join-Path $UiPath 'Styles.xaml'
$stylesText = [IO.File]::ReadAllText($stylesPath, [Text.Encoding]::UTF8)

try {
    $null = [System.Windows.Markup.XamlReader]::Parse($stylesText)
    Write-Host '  [ok] Styles.xaml'
} catch {
    Write-Host "  [!!] Styles.xaml: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# body of the ResourceDictionary, inserted where a window has @@STYLES_DICT@@
$open = $stylesText.IndexOf('>')
$close = $stylesText.LastIndexOf('</ResourceDictionary>')
if ($open -lt 0 -or $close -lt 0 -or $close -le $open) {
    Write-Host '  [!!] Styles.xaml does not look like a ResourceDictionary' -ForegroundColor Red
    exit 1
}
$stylesFragment = $stylesText.Substring($open + 1, $close - $open - 1).Trim()

$failures = 0
foreach ($name in @('MainWindow.xaml', 'PickerWindow.xaml')) {
    try {
        $xaml = [IO.File]::ReadAllText((Join-Path $UiPath $name), [Text.Encoding]::UTF8)
        $marker = '<!-- GHL_STYLES_INJECT -->'
        if ($xaml.IndexOf($marker) -lt 0) {
            throw 'missing the GHL_STYLES_INJECT marker'
        }
        $xaml = $xaml.Replace($marker, $stylesFragment)

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
