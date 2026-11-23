<#
    09-Appearance.ps1
    Colour themes and animated GIF backgrounds.

    Themes work through DynamicResource: every brush key lives in the window's
    own ResourceDictionary and every style refers to it dynamically, so replacing
    a brush entry recolours the live window without rebuilding it.

    Animated GIFs are decoded by GDI+ (System.Drawing), which composites the
    frames and their disposal methods for us. WPF itself only shows the first
    frame. Frames are converted one at a time, never kept as a list, so a long
    animation does not multiply memory.
#>

$Global:GHL_Themes = [ordered]@{
    Midnight = [ordered]@{
        Bg0Brush             = '#0D1117'
        Bg1Brush             = '#161B22'
        Bg2Brush             = '#21262D'
        BorderBrush          = '#30363D'
        BorderWeakBrush      = '#2D333B'
        BorderStrongBrush    = '#3D444D'
        AccentBrush          = '#58A6FF'
        AccentStrongBrush    = '#1F6FEB'
        AccentHoverBrush     = '#388BFD'
        AccentPressedBrush   = '#1158C7'
        OnAccentBrush        = '#FFFFFF'
        SuccessBrush         = '#3FB950'
        SuccessSoftBrush     = '#12351F'
        DangerBrush          = '#F85149'
        DangerSoftBrush      = '#3D1518'
        DangerBorderBrush    = '#6E2A2A'
        DangerTextBrush      = '#FF9B95'
        DangerPressedBrush   = '#C42B1C'
        WarnBrush            = '#D29922'
        WarnSoftBrush        = '#3A2A0D'
        TextBrush            = '#E6EDF3'
        TextDimBrush         = '#8B949E'
        TextFaintBrush       = '#5B6470'
        TextGhostBrush       = '#454C55'
        HoverBrush           = '#1C2128'
        SelectedBrush        = '#1F3550'
        AccentSoftBrush      = '#1B3A5C'
        PanelBrush           = '#CC161B22'
        FooterBrush          = '#B3161B22'
        ScrimBrush           = '#9E000000'
        ToastBrush           = '#F021262D'
        SliderThumbHoverBrush = '#5A636E'
    }

    Graphite = [ordered]@{
        Bg0Brush             = '#111114'
        Bg1Brush             = '#17171C'
        Bg2Brush             = '#212127'
        BorderBrush          = '#33333C'
        BorderWeakBrush      = '#2A2A32'
        BorderStrongBrush    = '#42424C'
        AccentBrush          = '#A78BFA'
        AccentStrongBrush    = '#7C3AED'
        AccentHoverBrush     = '#8B5CF6'
        AccentPressedBrush   = '#6D28D9'
        OnAccentBrush        = '#FFFFFF'
        SuccessBrush         = '#4ADE80'
        SuccessSoftBrush     = '#16321F'
        DangerBrush          = '#F87171'
        DangerSoftBrush      = '#3A1A1D'
        DangerBorderBrush    = '#6E3038'
        DangerTextBrush      = '#FCA5A5'
        DangerPressedBrush   = '#B91C1C'
        WarnBrush            = '#FBBF24'
        WarnSoftBrush        = '#3A2C0D'
        TextBrush            = '#ECECF1'
        TextDimBrush         = '#9A9AA5'
        TextFaintBrush       = '#6E6E7A'
        TextGhostBrush       = '#4E4E58'
        HoverBrush           = '#1D1D24'
        SelectedBrush        = '#2B2440'
        AccentSoftBrush      = '#2A2350'
        PanelBrush           = '#CC17171C'
        FooterBrush          = '#B317171C'
        ScrimBrush           = '#9E000000'
        ToastBrush           = '#F0212127'
        SliderThumbHoverBrush = '#5F5F6B'
    }

    Ocean = [ordered]@{
        Bg0Brush             = '#081A21'
        Bg1Brush             = '#0D2430'
        Bg2Brush             = '#12303C'
        BorderBrush          = '#1E4354'
        BorderWeakBrush      = '#183848'
        BorderStrongBrush    = '#2A5568'
        AccentBrush          = '#2DD4BF'
        AccentStrongBrush    = '#0D9488'
        AccentHoverBrush     = '#14B8A6'
        AccentPressedBrush   = '#0F766E'
        OnAccentBrush        = '#FFFFFF'
        SuccessBrush         = '#34D399'
        SuccessSoftBrush     = '#0F3527'
        DangerBrush          = '#FB7185'
        DangerSoftBrush      = '#3A1B24'
        DangerBorderBrush    = '#6E3542'
        DangerTextBrush      = '#FDA4AF'
        DangerPressedBrush   = '#BE123C'
        WarnBrush            = '#F59E0B'
        WarnSoftBrush        = '#3A2A0B'
        TextBrush            = '#E0F2FE'
        TextDimBrush         = '#7FA6B8'
        TextFaintBrush       = '#5C8294'
        TextGhostBrush       = '#436473'
        HoverBrush           = '#0F2A36'
        SelectedBrush        = '#10404D'
        AccentSoftBrush      = '#0E3D46'
        PanelBrush           = '#CC0D2430'
        FooterBrush          = '#B30D2430'
        ScrimBrush           = '#9E001018'
        ToastBrush           = '#F012303C'
        SliderThumbHoverBrush = '#4F7285'
    }

    Light = [ordered]@{
        Bg0Brush             = '#F5F7FA'
        Bg1Brush             = '#FFFFFF'
        Bg2Brush             = '#EAEEF4'
        BorderBrush          = '#D3DAE3'
        BorderWeakBrush      = '#E1E7EE'
        BorderStrongBrush    = '#B9C3CF'
        AccentBrush          = '#0969DA'
        AccentStrongBrush    = '#0550AE'
        AccentHoverBrush     = '#0A7BE0'
        AccentPressedBrush   = '#033D8B'
        OnAccentBrush        = '#FFFFFF'
        SuccessBrush         = '#1A7F37'
        SuccessSoftBrush     = '#DDF3E4'
        DangerBrush          = '#CF222E'
        DangerSoftBrush      = '#FFE3E3'
        DangerBorderBrush    = '#F0B3B6'
        DangerTextBrush      = '#A40E26'
        DangerPressedBrush   = '#A40E26'
        WarnBrush            = '#9A6700'
        WarnSoftBrush        = '#FFF3C4'
        TextBrush            = '#1B2430'
        TextDimBrush         = '#4C5765'
        TextFaintBrush       = '#6C7886'
        TextGhostBrush       = '#8C98A6'
        HoverBrush           = '#E9EEF4'
        SelectedBrush        = '#DDEBFA'
        AccentSoftBrush      = '#D9EAFD'
        PanelBrush           = '#E6FFFFFF'
        FooterBrush          = '#E6FFFFFF'
        ScrimBrush           = '#66000000'
        ToastBrush           = '#F7FFFFFF'
        SliderThumbHoverBrush = '#8A96A3'
    }
}

function Get-GhlThemeNames {
    return @($Global:GHL_Themes.Keys)
}

function Resolve-GhlThemeName {
    <# Falls back to Midnight for an empty or unknown name. #>
    param([string]$Name)

    $wanted = ([string]$Name).Trim()
    foreach ($key in $Global:GHL_Themes.Keys) {
        if ($key -ieq $wanted) { return $key }
    }
    return 'Midnight'
}

function Get-GhlTheme {
    param([string]$Name)
    return $Global:GHL_Themes[(Resolve-GhlThemeName -Name $Name)]
}

function Convert-GhlThemeBrush {
    <#
        BrushConverter understands #RRGGBB and #AARRGGBB. A SolidColorBrush
        constructed from an object-typed Color value ends up stored as a colour
        string, which WPF refuses when the resource is applied.
    #>
    param([Parameter(Mandatory)][string]$Value)

    if (-not $Global:GHL_BrushConverter) {
        $Global:GHL_BrushConverter = New-Object Windows.Media.BrushConverter
    }
    return $Global:GHL_BrushConverter.ConvertFromString($Value)
}

function Set-GhlThemeResources {
    <#
        Replaces every palette brush in one window's resources. Styles reference
        them through DynamicResource, so already-created elements follow the
        change immediately.
    #>
    param($Window, [string]$Name)

    if (-not $Window -or -not $Window.Resources) { return $null }

    $palette = Get-GhlTheme -Name $Name
    $applied = @{}
    foreach ($key in $palette.Keys) {
        try {
            $brush = Convert-GhlThemeBrush -Value $palette[$key]
            try { $brush.Freeze() } catch { }
            $Window.Resources[$key] = $brush
            $applied[$key] = $brush
        } catch {
            Write-GhlLog "Theme brush '$key' could not be applied: $($_.Exception.Message)" Warn
        }
    }
    return $applied
}

function Set-GhlTheme {
    <#
        Applies a theme to the main window, refreshes the brush cache used by
        code-built dialogs and remembers the choice in the state.
    #>
    param([string]$Name)

    $state = $Global:GhlState
    if (-not $state -or -not $state.UI) { return }

    $resolved = Resolve-GhlThemeName -Name $Name
    $state.Theme = $resolved
    $applied = Set-GhlThemeResources -Window $state.UI.Window -Name $resolved

    if ($applied) {
        $b = $state.Brushes
        $b.Success = $applied['SuccessBrush']
        $b.Warn = $applied['WarnBrush']
        $b.Danger = $applied['DangerBrush']
        $b.Border = $applied['BorderBrush']
        $b.TextDim = $applied['TextDimBrush']
        $b.Text = $applied['TextBrush']
        $b.Accent = $applied['AccentBrush']
        $b.AccentStrong = $applied['AccentStrongBrush']
        $b.Bg0 = $applied['Bg0Brush']
        $b.Bg1 = $applied['Bg1Brush']
        $b.Bg2 = $applied['Bg2Brush']
        $b.Panel = $applied['PanelBrush']
        $b.OnAccent = $applied['OnAccentBrush']
    }

    Write-GhlLog "Theme applied: $resolved"
    return $resolved
}

# ---------------------------------------------------------------------------
# Animated GIF background
# ---------------------------------------------------------------------------

function Stop-GhlGifBackground {
    <# Stops the timer and releases the GDI+ image. Safe to call repeatedly. #>
    $state = $Global:GhlState
    if (-not $state -or -not $state.Gif) { return }

    $gif = $state.Gif
    if ($gif.Timer) {
        try { $gif.Timer.Stop() } catch { }
    }
    if ($gif.Image) {
        try { $gif.Image.Dispose() } catch { }
    }
    $state.Gif = $null
}

function Show-GhlGifFrame {
    <# Renders the current frame into the existing Image element. UI thread only. #>
    $state = $Global:GhlState
    $ui = $state.UI
    $gif = $state.Gif
    if (-not $gif -or -not $gif.Image -or -not $ui) { return }

    $handle = [IntPtr]::Zero
    try {
        [void]$gif.Image.SelectActiveFrame($gif.FrameDimension, $gif.Index)
        # transparent fill keeps GIF transparency instead of drawing a box
        $handle = $gif.Image.GetHbitmap([Drawing.Color]::FromArgb(0, 0, 0, 0))
        $frame = [Windows.Interop.Imaging]::CreateBitmapSourceFromHBitmap(
            $handle, [IntPtr]::Zero, [Windows.Int32Rect]::Empty,
            [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $frame.Freeze()
        $ui.imgBackground.Source = $frame
        $gif.Shown = [int]$gif.Shown + 1
    } catch {
        Write-GhlLog "GIF frame failed: $($_.Exception.Message)" Warn
        Stop-GhlGifBackground
        return
    } finally {
        if ($handle -ne [IntPtr]::Zero) {
            try { [GhlNative]::DeleteObject($handle) | Out-Null } catch { }
        }
    }

    $gif.Index = ($gif.Index + 1) % $gif.Frames
    $delay = $gif.Delays[$gif.Index]
    if ($delay -lt 20) { $delay = 100 }
    $gif.Timer.Interval = [TimeSpan]::FromMilliseconds($delay)
}

function Start-GhlGifBackground {
    <#
        Starts playing an animated GIF. Returns $false when the file is not an
        animation (the caller then falls back to a static BitmapImage).
    #>
    param([string]$Path)

    $state = $Global:GhlState
    $ui = $state.UI

    Stop-GhlGifBackground
    if (-not $state.Config.AnimateBackground) { return $false }

    $image = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $image = [Drawing.Image]::FromFile($Path)

        if (-not $image.FrameDimensionsList -or $image.FrameDimensionsList.Length -eq 0) {
            $image.Dispose()
            return $false
        }

        # a wall-sized animation would copy tens of megabytes per frame
        if ([double]$image.Width * [double]$image.Height -gt 8294400) {
            Write-GhlLog "GIF is too large to animate ($($image.Width)x$($image.Height)); showing the first frame." Debug
            $image.Dispose()
            return $false
        }

        $timeDimension = New-Object Drawing.Imaging.FrameDimension($image.FrameDimensionsList[0])
        $frames = [int]$image.GetFrameCount($timeDimension)
        if ($frames -le 1) {
            $image.Dispose()
            return $false
        }

        # PropertyTagFrameDelay is an array of hundredths of a second
        $delays = New-Object int[] $frames
        for ($i = 0; $i -lt $frames; $i++) { $delays[$i] = 100 }
        try {
            $prop = $image.GetPropertyItem(0x5100)
            if ($prop -and $prop.Value -and $prop.Value.Length -ge $frames * 4) {
                for ($i = 0; $i -lt $frames; $i++) {
                    $centis = [BitConverter]::ToInt32($prop.Value, $i * 4)
                    if ($centis -gt 0) { $delays[$i] = [Math]::Max(20, $centis * 10) }
                }
            }
        } catch {
            # no timing block: the 100 ms default is fine
        }

        $gif = @{
            Image          = $image
            FrameDimension = $timeDimension
            Frames         = $frames
            Index          = 0
            Shown          = 0
            Delays         = $delays
            Timer          = $null
        }
        $state.Gif = $gif

        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds($delays[0])
        $timer.Add_Tick({ param($s, $e) Show-GhlGifFrame })
        $gif.Timer = $timer

        $ui.imgBackground.Visibility = [Windows.Visibility]::Visible
        $ui.rectDim.Opacity = [Math]::Min(0.95, [Math]::Max(0.0, ($ui.sldDim.Value / 100.0)))
        Show-GhlGifFrame
        if (-not $state.Gif) {
            # the first frame failed; do not keep a timer that can never paint
            try { $timer.Stop() } catch { }
            return $false
        }
        $timer.Start()

        Write-GhlLog "Animated GIF background: $Path ($frames frames)"
        return $true
    } catch {
        Write-GhlLog "GIF could not be animated: $($_.Exception.Message)" Warn
        if ($image) { try { $image.Dispose() } catch { } }
        $state.Gif = $null
        return $false
    }
}

function Update-GhlGifPlayback {
    <#
        A hidden or minimized window must not burn CPU on animation.
    #>
    $state = $Global:GhlState
    if (-not $state -or -not $state.Gif -or -not $state.Gif.Timer) { return }

    $window = $state.UI.Window
    $paused = ([string]$window.WindowState -eq 'Minimized') -or (-not $window.IsVisible)
    if ($paused) {
        $state.Gif.Timer.Stop()
    } elseif (-not $state.Gif.Timer.IsEnabled) {
        $state.Gif.Timer.Start()
    }
}