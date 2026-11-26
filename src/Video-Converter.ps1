<#
.SYNOPSIS
    Video Converter - Check which videos will play on your TV, phone or media server, and convert only the ones that won't.

.DESCRIPTION
    PowerShell/WPF tool for checking videos and converting them to play on a chosen TV or device with FFmpeg.

    Add videos (or whole folders) and pick what they should play on: a TV (the Sony BRAVIA XR-42A90K
    to begin with, or another make), phones and tablets, Plex/Jellyfin/Emby, or your own choice of file
    type, video and sound. Each video is checked with ffprobe and marked Plays, Quick fix (a new file
    type only), Sound fix or Convert, with the reasons. Convert then does only what's needed: a picture
    that already plays is copied across untouched, and only the sound or the file type is changed.
    Subtitles, sound tracks in other languages and chapters are kept wherever the new file can hold them.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               "Video Converter v<version>\" release folders, their zips and
                                        "Video Converter.lnk", made by Build.cmd (no exe)
    Settings and data: %APPDATA%\Video Converter

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it). Needs FFmpeg (ffmpeg.exe and ffprobe.exe).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Video Converter v<version>".
$script:AppName     = 'Video Converter'
$script:AppVersion  = '1.02'
$script:Description = 'PowerShell/WPF tool for checking videos and converting them to play on a chosen TV or device with FFmpeg'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Video-Converter'
$script:IsPrivate   = $false   # public tool: settings and data in %APPDATA%\<App Name>
$script:AppId       = 'jason4bury.Video-Converter'   # taskbar ID; the shortcut made by New-VideoConverterShortcut.ps1 uses the same one

# ---------------------------------------------------------------------------
#  Where is everything? No exe: this script runs from Source\src\ (while
#  developing) or from a release folder, Builds\Video Converter v<version>\ (or
#  wherever the release zip was unpacked), with assets\ beside it.
# ---------------------------------------------------------------------------
# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One taskbar button with the tool's own icon (not PowerShell's), and pinning it pins the tool.
try {
    Add-Type -Namespace 'HomeTool' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    [void][HomeTool.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = @((Join-Path $script:ProgramDir 'assets'), (Join-Path (Split-Path -Parent $script:ProgramDir) 'assets')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $script:AssetsDir) { $script:AssetsDir = Join-Path $script:ProgramDir 'assets' }

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or a release folder (each version has its own, so data kept
       there would be left behind by the next version). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    $up = Split-Path -Parent $script:ProgramDir
    if (@('Source', 'Builds') -contains (Split-Path -Leaf $up)) { return (Join-Path (Split-Path -Parent $up) 'Data') }
    return (Join-Path $script:ProgramDir 'Data')
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
$script:TempDir      = Join-Path ([IO.Path]::GetTempPath()) $script:AppName    # preview pictures and 20-second samples
foreach ($d in $script:DataDir, $script:TempDir) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
$script:Dot = [string][char]0x00B7     # the middle dot between details
$script:Arrow = [string][char]0x2192   # the arrow in "what will be done"

function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-ImageFromFile {
    <# A frozen BitmapImage that doesn't keep the file open, or $null. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.StreamSource = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($Path))
        $img.CacheOption  = 'OnLoad'
        $img.EndInit(); $img.Freeze()
        return $img
    } catch { return $null }
}
function Get-AssetImage([string]$Name) { return (Get-ImageFromFile (Join-Path $script:AssetsDir $Name)) }

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f [math]::Max(1, [math]::Ceiling($Bytes / 1KB))
}

function Format-Length([double]$Seconds) {
    if ($Seconds -le 0) { return '' }
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    return '{0}m {1:00}s' -f $t.Minutes, $t.Seconds
}

function Format-TimeLeft([double]$Seconds) {
    if ($Seconds -lt 60) { return 'less than a minute left' }
    $m = [int][math]::Ceiling($Seconds / 60)
    if ($m -lt 60) { return "about $m min left" }
    return 'about {0} h {1} min left' -f [int][math]::Floor($m / 60), ($m % 60)
}

# ---------------------------------------------------------------------------
#  Settings: settings.json in the data folder
# ---------------------------------------------------------------------------
$script:DefaultTarget = 'Sony BRAVIA XR-42A90K (2022)'
function Get-AppSetting {
    $s = [ordered]@{
        Look = 'Light'; Target = $script:DefaultTarget; Quality = 'Balanced'; FileType = 'Auto'; VideoOut = 'Auto'
        SaveTo = 'Beside'; OutFolder = ''; Originals = 'Keep'; Srt = $true; Gpu = $true; FFmpeg = ''; LastFolder = ''
        SendMode = 'Off'; SendFolder = ''; Notify = $true
        CustomType = 'mp4'; CustomVideo = 'h264'; CustomSound = 'aac'; CustomSize = '2160'
    }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if (-not $s.Contains($p.Name)) { continue }
                if ($p.Name -in 'Srt', 'Gpu', 'Notify') { $s[$p.Name] = [bool]$p.Value } else { $s[$p.Name] = [string]$p.Value }
            }
        } catch { Write-AppLog "settings.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Save-AppSetting {
    try { [pscustomobject]$script:Settings | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 }
    catch { Write-AppLog "settings.json couldn't be saved: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
#  Look: Light, Dark or System (follow Windows). Used from the next start.
# ---------------------------------------------------------------------------
$script:Settings = Get-AppSetting
function Test-DarkLook {
    switch ($script:Settings.Look) {
        'Dark' { return $true }
        'System' {
            try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) }
            catch { return $false }
        }
        default { return $false }
    }
}
$script:Dark = Test-DarkLook
$script:Palette = if ($script:Dark) {
    @{ Page = '#1A1715'; Card = '#23201D'; Line = '#3A3430'; Ink = '#EEE8E4'; Soft = '#A89F98'; Accent = '#D2602E'; AccentInk = '#FFFFFF'
       Field = '#181513'; Hover = '#2E2925'; Select = '#4A2E20'; Good = '#4CC38A'; Warn = '#E0A040'; Bad = '#F07178'; Shade = '#000000' }
} else {
    @{ Page = '#F7F4F1'; Card = '#FFFFFF'; Line = '#E3DCD6'; Ink = '#262220'; Soft = '#6A615B'; Accent = '#B8461B'; AccentInk = '#FFFFFF'
       Field = '#FFFFFF'; Hover = '#F8EDE6'; Select = '#F5DCCF'; Good = '#1E8A57'; Warn = '#9A5B00'; Bad = '#B3261E'; Shade = '#1E1A18' }
}
$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Key) { return $script:BrushConv.ConvertFromString($script:Palette[$Key]) }

function Set-TitleBar([Windows.Window]$Window) {
    <# A dark title bar in the dark look (Windows 10 20H1 and later; older Windows ignores it). #>
    if (-not $script:Dark) { return }
    try {
        if (-not ('VcDwm' -as [type])) { Add-Type -Namespace '' -Name 'VcDwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);' }
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).EnsureHandle()
        $on = 1; [void][VcDwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
    } catch { Write-Verbose 'no dark title bar' }
}

function Expand-Xaml([string]$Xaml) {
    <# Puts the look's colours into a window's XAML ({Page}, {Ink} ...). #>
    foreach ($k in $script:Palette.Keys) { $Xaml = $Xaml.Replace("{$k}", $script:Palette[$k]) }
    return $Xaml
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml, [Windows.Window]$Owner)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Expand-Xaml $Xaml))))
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    $w.Add_SourceInitialized({ Set-TitleBar $this })
    return $w
}

# Shared styles: rounded buttons (normal and accent), slim scroll bars, text boxes, tick boxes,
# drop-down lists, list rows and the pill buttons that filter the list.
$script:Styles = @'
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Background" Value="{Card}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="Padding" Value="14,6"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Select}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Accent" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{Accent}"/><Setter Property="Foreground" Value="{AccentInk}"/><Setter Property="BorderBrush" Value="{Accent}"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="6" Padding="{TemplateBinding Padding}" RenderTransformOrigin="0.5,0.5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="B" Property="Opacity" Value="0.7"/>
            <Setter TargetName="B" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.96" ScaleY="0.96"/></Setter.Value></Setter>
          </Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuThumb" TargetType="Thumb">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
        <Border x:Name="T" CornerRadius="4" Background="{Line}"/>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{Soft}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="BuPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Width" Value="12"/><Setter Property="MinWidth" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Width="6" HorizontalAlignment="Center" Margin="0,3">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Width" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="12"/><Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Height="6" VerticalAlignment="Center" Margin="3,0">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource BuThumb}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource BuPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="PART_Track" Property="Height" Value="9"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{Field}"/><Setter Property="Foreground" Value="{Ink}"/><Setter Property="BorderBrush" Value="{Line}"/>
      <Setter Property="CaretBrush" Value="{Ink}"/><Setter Property="Padding" Value="8,0"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,10,0,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <Grid Background="Transparent">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" Background="{Field}" BorderBrush="{Line}" BorderThickness="1" VerticalAlignment="Top" Margin="0,1,0,0">
            <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="{AccentInk}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
          </Border>
          <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
            <ContentPresenter.Resources><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></ContentPresenter.Resources>
          </ContentPresenter>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{Accent}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="Box" Property="Background" Value="{Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{Accent}"/>
            <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="ComboToggle" TargetType="ToggleButton">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
        <Border x:Name="B" Background="{Field}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="6">
          <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{Soft}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Height" Value="32"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton Style="{StaticResource ComboToggle}" Focusable="False" ClickMode="Press"
                        IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
          <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,32,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
            <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="6" Padding="4" Margin="0,4,0,0"
                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
              <ScrollViewer MaxHeight="420" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="B" Background="Transparent" Padding="10,7" CornerRadius="4"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Foreground" Value="{Ink}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="B" Background="Transparent" Padding="10,7" CornerRadius="6"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{Select}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Margin" Value="0,0,6,6"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="B" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="15" Padding="13,5"><ContentPresenter VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="B" Property="Background" Value="{Accent}"/><Setter TargetName="B" Property="BorderBrush" Value="{Accent}"/>
            <Setter Property="Foreground" Value="{AccentInk}"/>
          </Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ContextMenu">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContextMenu">
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="6" Padding="4"><StackPanel IsItemsHost="True"/></Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Foreground" Value="{Ink}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem">
        <Border x:Name="B" Background="Transparent" Padding="12,7" CornerRadius="4"><ContentPresenter ContentSource="Header"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{Hover}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,16,0,2"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{Soft}"/><Setter Property="Margin" Value="0,10,0,0"/>
    </Style>
'@

#region MESSAGES
# ---------------------------------------------------------------------------
#  Messages and questions in the app's own look (not Windows' grey MessageBox)
# ---------------------------------------------------------------------------
$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="Height" Width="500" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="14" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22,18,22,16">
    <ScrollViewer MaxHeight="420" VerticalScrollBarVisibility="Auto"><TextBlock x:Name="MsgText" TextWrapping="Wrap" LineHeight="21"/></ScrollViewer>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="MsgYes" Style="{StaticResource Accent}" MinWidth="80" IsDefault="True"/>
      <Button x:Name="MsgNo" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-AppMessage {
    <# A message, or a question (with -NoText: $true for the first button). #>
    param([Parameter(Mandatory)][string]$Text, [string]$Title = $script:AppName, [string]$YesText = 'OK', [string]$NoText,
          [Windows.Window]$Owner = $script:Window)
    $w = New-XamlWindow $script:MessageXaml $Owner
    if ($script:Zoom -gt 1.01) { $w.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $script:Zoom, $script:Zoom; $w.Width *= $script:Zoom }
    $w.Title = $Title
    $w.FindName('MsgText').Text = $Text
    $yes = $w.FindName('MsgYes'); $no = $w.FindName('MsgNo')
    $yes.Content = $YesText
    if ($NoText) { $no.Content = $NoText } else { $no.Visibility = 'Collapsed'; $yes.Margin = '0'; $yes.IsCancel = $true }
    $script:MsgAnswer = $false
    $yes.Add_Click({ $script:MsgAnswer = $true; [Windows.Window]::GetWindow($this).Close() })
    $no.Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
    return $script:MsgAnswer
}
#endregion MESSAGES

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style): logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <StackPanel Margin="22" MaxWidth="460">
    <StackPanel Orientation="Horizontal">
      <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="AboutVersion" Foreground="{Soft}"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,14,0,0"/>
    <TextBlock x:Name="AboutFfmpeg" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{Soft}"/>
    <TextBlock x:Name="AboutData" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="{Soft}"/>
    <TextBlock Margin="0,10,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{Accent}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
    <TextBlock x:Name="AboutCopyright" Margin="0,4,0,0" Foreground="{Soft}"/>
    <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,16,0,0" IsDefault="True" IsCancel="True"/>
  </StackPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml $Owner
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Video-Converter.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutFfmpeg').Text       = if ($script:FFmpeg) { "FFmpeg: $script:FFmpeg" } else { 'FFmpeg: not found yet' }
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  $script:Dot  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

#region ENGINE
# ---------------------------------------------------------------------------
#  Background work in C#: ffprobe on four files at a time, and one ffmpeg run
#  (a conversion, a preview picture or a 20-second sample) with its progress.
# ---------------------------------------------------------------------------
if (-not ('VcRun' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

// One video in the list. The properties the list shows tell it when they change.
public class VcItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void N(string n) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    string status = "", details = ""; double progress; object pill;
    public string Path { get; set; }
    public string Name { get; set; }
    public string Folder { get; set; }
    public string Details { get { return details; } set { details = value; N("Details"); } }
    public string Status { get { return status; } set { status = value; N("Status"); } }
    public object Pill { get { return pill; } set { pill = value; N("Pill"); } }
    public double Progress { get { return progress; } set { progress = value; N("Progress"); N("ProgressShown"); } }
    public string ProgressShown { get { return progress > 0 && progress < 100 ? "Visible" : "Collapsed"; } }
    public object Info;                     // what ffprobe found (a PowerShell hashtable)
    public string Error = "";              // why it couldn't be read or converted
    public string State = "";              // Checking, Plays, Needs, Done, Failed, Error
    public string OutPath = "";            // the converted file
    public object Verdict;                 // whether it plays as it is (a PowerShell hashtable)
}

// ffprobe on many files, four at a time. Folders are searched (all the folders inside them too)
// for video files first. Results (path, JSON, error) wait in Results for the window to collect.
public static class VcProbe {
    public static ConcurrentQueue<string[]> Results = new ConcurrentQueue<string[]>();
    static int busy;
    public static int Busy { get { return busy; } }
    public static volatile bool Cancel;

    static void Find(string dir, HashSet<string> exts, List<string> into) {
        var stack = new Stack<string>(); stack.Push(dir);
        while (stack.Count > 0) {
            string d = stack.Pop();
            try { foreach (var f in Directory.GetFiles(d)) { if (exts.Contains(System.IO.Path.GetExtension(f).ToLowerInvariant()) && f.IndexOf(".converting.", StringComparison.OrdinalIgnoreCase) < 0) into.Add(f); } } catch (Exception) { }
            try { foreach (var s in Directory.GetDirectories(d)) { var a = new DirectoryInfo(s).Attributes; if ((a & FileAttributes.Hidden) == 0 && (a & FileAttributes.System) == 0) stack.Push(s); } } catch (Exception) { }
        }
    }

    public static string Run(string exe, string args, int waitMs, out string err) {
        var psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
        using (var p = Process.Start(psi)) {
            var e = p.StandardError.ReadToEndAsync();
            string o = p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(waitMs)) { try { p.Kill(); } catch (Exception) { } err = "timed out"; return ""; }
            err = e.Result.Trim();
            return o;
        }
    }

    public static void Start(string ffprobe, string[] paths, string[] extensions) {
        Interlocked.Increment(ref busy);
        Cancel = false;
        Task.Factory.StartNew(() => {
            try {
                var exts = new HashSet<string>(extensions, StringComparer.OrdinalIgnoreCase);
                var files = new List<string>();
                foreach (var p in paths) {
                    if (Directory.Exists(p)) Find(p, exts, files);
                    else if (File.Exists(p)) files.Add(p);
                }
                var opt = new ParallelOptions(); opt.MaxDegreeOfParallelism = 4;
                Parallel.ForEach(files, opt, f => {
                    if (Cancel) return;
                    string json = "", err = "";
                    try {
                        json = Run(ffprobe, "-v error -print_format json -show_format -show_streams \"" + f + "\"", 90000, out err);
                    } catch (Exception ex) { err = ex.Message; }
                    Results.Enqueue(new string[] { f, json, err });
                });
            } finally { Interlocked.Decrement(ref busy); }
        });
    }
}

// Which graphics-card encoders work on this PC: each is test-run once on a tiny made-up picture, in the
// background. Listed in ffmpeg isn't enough: an encoder can be built in with no card (or driver) to run it.
public static class VcGpu {
    public static volatile bool Ready;
    public static string H264 = "", Hevc = "", Name = "";
    public static bool HevcTen;
    static bool Works(string ffmpeg, string enc, string pix) {
        try {
            var psi = new ProcessStartInfo(ffmpeg, "-hide_banner -loglevel error -f lavfi -i color=c=gray:s=640x360:r=25:d=0.4 -frames:v 8 -pix_fmt " + pix + " -c:v " + enc + " -f null -");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardError = true; psi.RedirectStandardOutput = true;
            using (var p = Process.Start(psi)) {
                p.StandardOutput.ReadToEndAsync(); p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(20000)) { try { p.Kill(); } catch (Exception) { } return false; }
                return p.ExitCode == 0;
            }
        } catch (Exception) { return false; }
    }
    public static void Start(string ffmpeg) {
        Ready = false; H264 = ""; Hevc = ""; Name = ""; HevcTen = false;
        Task.Factory.StartNew(() => {
            try {
                string[][] makers = { new[] { "nvenc", "NVIDIA (NVENC)" }, new[] { "qsv", "Intel (Quick Sync)" }, new[] { "amf", "AMD (AMF)" } };
                foreach (var m in makers) {
                    string h = Works(ffmpeg, "h264_" + m[0], "nv12") ? "h264_" + m[0] : "";
                    string e = Works(ffmpeg, "hevc_" + m[0], "nv12") ? "hevc_" + m[0] : "";
                    if (h.Length > 0 || e.Length > 0) {
                        H264 = h; Hevc = e; Name = m[1];
                        if (e.Length > 0) HevcTen = Works(ffmpeg, e, "p010le");
                        break;
                    }
                }
            } catch (Exception) { }
            Ready = true;
        });
    }
}

// Copies (or moves) a finished video to another folder in the background, so a slow NAS doesn't freeze the window.
public class VcCopy {
    public volatile bool Done;
    public string Error = "";
    public long Total, Copied;
    public void Start(string from, string to, bool move) {
        Task.Factory.StartNew(() => {
            try {
                Total = new FileInfo(from).Length;
                if (move && string.Equals(System.IO.Path.GetPathRoot(from), System.IO.Path.GetPathRoot(to), StringComparison.OrdinalIgnoreCase)) {
                    File.Move(from, to); Copied = Total;
                } else {
                    var buf = new byte[4 * 1024 * 1024];
                    using (var a = new FileStream(from, FileMode.Open, FileAccess.Read, FileShare.Read))
                    using (var b = new FileStream(to + ".copying", FileMode.Create, FileAccess.Write)) {
                        int n;
                        while ((n = a.Read(buf, 0, buf.Length)) > 0) { b.Write(buf, 0, n); Copied += n; }
                    }
                    File.Move(to + ".copying", to);
                    if (move) File.Delete(from);
                }
            } catch (Exception ex) {
                Error = ex.Message;
                try { File.Delete(to + ".copying"); } catch (Exception) { }
            }
            Done = true;
        });
    }
}

// One ffmpeg run, with how far it has got (from -progress pipe:1), pause, resume and stop.
public class VcRun {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    Process p;
    readonly LinkedList<string> tail = new LinkedList<string>();
    public double OutSeconds;      // how much of the video is done (seconds of video)
    public volatile bool Done;
    public volatile bool Paused;
    public int ExitCode = -1;
    public string Tail { get { lock (tail) { return string.Join("\n", tail); } } }

    // Keeps the PC awake while converting (the screen may still turn off).
    public static void KeepAwake(bool on) { SetThreadExecutionState(on ? 0x80000001u : 0x80000000u); }

    public void Start(string exe, string args) {
        var psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true; psi.RedirectStandardError = true; psi.RedirectStandardInput = true;
        psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
        p = new Process(); p.StartInfo = psi;
        p.OutputDataReceived += (s, e) => { if (e.Data != null) Line(e.Data); };
        p.ErrorDataReceived += (s, e) => { if (e.Data != null && e.Data.Trim().Length > 0) lock (tail) { tail.AddLast(e.Data.Trim()); if (tail.Count > 40) tail.RemoveFirst(); } };
        p.Start();
        try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
        p.BeginOutputReadLine(); p.BeginErrorReadLine();
        var t = new Thread(() => { try { p.WaitForExit(); ExitCode = p.ExitCode; } catch (Exception) { ExitCode = -2; } Done = true; });
        t.IsBackground = true; t.Start();
    }

    void Line(string s) {
        if (s.StartsWith("out_time_us=") || s.StartsWith("out_time_ms=")) {
            long us;
            if (long.TryParse(s.Substring(12), NumberStyles.Integer, CultureInfo.InvariantCulture, out us) && us > 0) OutSeconds = us / 1000000.0;
        }
    }

    public void Pause() { try { if (p != null && !Done && !Paused) { NtSuspendProcess(p.Handle); Paused = true; } } catch (Exception) { } }
    public void Resume() { try { if (p != null && !Done && Paused) { NtResumeProcess(p.Handle); Paused = false; } } catch (Exception) { } }
    public void Stop() { try { if (p != null && !Done) { if (Paused) Resume(); p.Kill(); } } catch (Exception) { } }
}
'@
}
#endregion ENGINE

#region FFMPEG
# ---------------------------------------------------------------------------
#  Finding FFmpeg: the one chosen in the app, else on the PATH, else where
#  winget, scoop or Chocolatey put it. ffprobe is taken from the same folder.
# ---------------------------------------------------------------------------
$script:VideoExt = @('.mkv', '.mp4', '.m4v', '.avi', '.mov', '.wmv', '.ts', '.m2ts', '.mts', '.webm', '.mpg', '.mpeg', '.vob', '.flv', '.divx', '.ogm', '.3gp', '.3g2', '.asf', '.m2t', '.mpe', '.rm', '.rmvb', '.f4v')

function Find-FFmpeg {
    if ($script:Settings.FFmpeg -and (Test-Path -LiteralPath $script:Settings.FFmpeg)) { return $script:Settings.FFmpeg }
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe", "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe", "$env:USERPROFILE\scoop\shims\ffmpeg.exe", "$env:ProgramData\chocolatey\bin\ffmpeg.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wg) {
        $hit = Get-ChildItem -LiteralPath $wg -Directory -Filter '*FFmpeg*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Initialize-FFmpeg {
    <# Finds ffmpeg and ffprobe, and what this FFmpeg can do (x265, the zscale filter for HDR). #>
    $script:FFmpeg = Find-FFmpeg
    $script:FFprobe = $null
    $script:Can = @{ X265 = $false; X264 = $false; Zscale = $false }
    if (-not $script:FFmpeg) { return $false }
    $probe = Join-Path (Split-Path -Parent $script:FFmpeg) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $probe)) { $c = Get-Command ffprobe.exe -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $probe = $c.Source } else { $probe = $null } }
    $script:FFprobe = $probe
    if (-not $probe) { return $false }
    try {
        $err = ''
        $enc = [VcProbe]::Run($script:FFmpeg, '-hide_banner -encoders', 20000, [ref]$err)
        $fil = [VcProbe]::Run($script:FFmpeg, '-hide_banner -filters', 20000, [ref]$err)
        $script:Can.X264 = $enc -match '\blibx264\b'
        $script:Can.X265 = $enc -match '\blibx265\b'
        $script:Can.Zscale = $fil -match '\bzscale\b'
    } catch { Write-AppLog "Couldn't ask FFmpeg what it can do: $($_.Exception.Message)" }
    Write-AppLog "FFmpeg $script:FFmpeg (x264 $($script:Can.X264), x265 $($script:Can.X265), zscale $($script:Can.Zscale))"
    return $true
}
#endregion FFMPEG

#region TARGETS
# ---------------------------------------------------------------------------
#  What each TV or device plays. A "line" is a file type with the video and
#  sound it can hold and the biggest picture (as ffprobe names them; pcm_* is
#  any PCM). A video plays when a line has its file type, video and size, and
#  its main sound track.
# ---------------------------------------------------------------------------
function New-Line([string]$Ext, [string]$Video, [string]$Sound, [int]$Wide = 3840, [int]$High = 2160) {
    return @{ Ext = $Ext; Video = $Video; Sound = $Sound; Wide = $Wide; High = $High }
}

# The Sony line is from Sony's Help Guide for the XR-42A90K, "Supported files and formats > Videos"
# (USB / home network): https://helpguide.sony.net/tv/jaep1/v1/en/04-01-03_03.html - one line here for each
# line there. The others are general guides from the makers' published lists; check your own model.
$script:Targets = [ordered]@{
    'Sony BRAVIA XR-42A90K (2022)' = @{
        Lines = @(
            (New-Line 'mpg mpe mpeg' 'mpeg1video' 'mp2' 1920 1080)
            (New-Line 'mpg mpe mpeg' 'mpeg2video' 'mp1 mp2 pcm_* ac3' 1920 1080)
            (New-Line 'm2t' 'mpeg2video' 'mp1 mp2 aac ac3 eac3' 1920 1080)
            (New-Line 'm2ts mts' 'h264' 'mp1 mp2 aac ac3 eac3' 1920 1080)
            (New-Line 'mp4' 'h264' 'aac ac3 eac3 ac4 mp1 mp2' 1920 1080)
            (New-Line 'mp4' 'mpeg4' 'aac ac3 eac3 mp1 mp2' 1920 1080)
            (New-Line 'mp4' 'h264' 'aac ac3 eac3 ac4 pcm_*' 3840 2160)
            (New-Line 'mp4' 'hevc' 'aac ac3 eac3 ac4' 3840 2160)
            (New-Line 'avi' 'mpeg4' 'mp1 mp2 mp3 ac3 eac3' 1920 1080)
            (New-Line 'avi' 'mjpeg' 'pcm_mulaw pcm_u8 pcm_s16le' 1280 720)
            (New-Line 'asf wmv' 'vc1 wmv3' 'wmav2' 1920 1080)
            (New-Line 'mkv' 'mpeg4' 'dts aac ac3 eac3 mp1 mp2 vorbis' 1920 1080)
            (New-Line 'mkv' 'h264' 'dts aac ac3 eac3 mp1 mp2 vorbis' 1920 1080)
            (New-Line 'mkv' 'vp8' 'dts aac ac3 eac3 mp1 mp2 vorbis' 1920 1080)
            (New-Line 'mkv' 'vp9' 'dts aac ac3 eac3 mp1 mp2 vorbis' 3840 2160)
            (New-Line 'mkv' 'h264' 'dts aac ac3 eac3' 3840 2160)
            (New-Line 'mkv' 'hevc' 'dts aac ac3 eac3' 3840 2160)
            (New-Line '3gp 3g2' 'mpeg4 h264' 'aac ac3 eac3 mp1 mp2' 1920 1080)
            (New-Line 'mov' 'h264 mpeg4' 'aac ac3 eac3 mp1 mp2 pcm_*' 1920 1080)
            (New-Line 'mov' 'mjpeg' 'aac ac3 eac3 mp1 mp2 pcm_*' 1280 720)
            (New-Line 'webm' 'vp8' 'vorbis' 1920 1080)
            (New-Line 'webm' 'vp9' 'vorbis' 3840 2160)
        )
        Out = 'mp4'; Hevc10 = $true; Hdr = $true; Dv = $true; Surround = 'eac3'; SubsIn = 'mkv'; MaxW = 3840; MaxH = 2160
        Note = "From Sony's Help Guide for this TV (its own player, over USB or the home network). It shows subtitles from inside MKV files only, or from .srt files beside the video. Apps on the TV, such as Plex, may play more."
    }
    'Samsung TV (2018 on)' = @{
        Lines = @(
            (New-Line 'mp4 m4v mov mkv ts m2ts mts 3gp' 'h264 hevc vp9 vp8 mpeg4 mpeg2video' 'aac ac3 eac3 mp3 mp2 pcm_* flac vorbis')
            (New-Line 'webm' 'vp8 vp9' 'vorbis opus')
            (New-Line 'avi' 'mpeg4 h264' 'mp3 ac3 pcm_*' 1920 1080)
            (New-Line 'wmv asf' 'vc1 wmv3' 'wmav2' 1920 1080)
        )
        Out = 'mp4'; Hevc10 = $true; Hdr = $true; Dv = $false; Surround = 'eac3'; SubsIn = 'mkv mp4'; MaxW = 3840; MaxH = 2160
        Note = 'A general guide from Samsung''s published lists. Samsung TVs from 2018 on play no DTS sound and no Dolby Vision. Check your own model''s manual.'
    }
    'LG TV (2018 on)' = @{
        Lines = @(
            (New-Line 'mp4 m4v mov mkv ts m2ts mts 3gp' 'h264 hevc vp9 vp8 mpeg4 mpeg2video' 'aac ac3 eac3 mp3 mp2 pcm_* flac vorbis')
            (New-Line 'webm' 'vp8 vp9' 'vorbis opus')
            (New-Line 'avi' 'mpeg4 h264' 'mp3 ac3 pcm_*' 1920 1080)
        )
        Out = 'mp4'; Hevc10 = $true; Hdr = $true; Dv = $true; Surround = 'eac3'; SubsIn = 'mkv'; MaxW = 3840; MaxH = 2160
        Note = 'A general guide from LG''s published lists. DTS sound is left out because many LG TVs (2020 to 2022) dropped it. Check your own model''s manual.'
    }
    'Any 4K smart TV (safe choice)' = @{
        Lines = @( (New-Line 'mp4 m4v mkv' 'h264 hevc' 'aac ac3 eac3 mp3') )
        Out = 'mp4'; Hevc10 = $true; Hdr = $true; Dv = $false; Surround = 'ac3'; SubsIn = 'mkv'; MaxW = 3840; MaxH = 2160
        Note = 'What almost every 4K TV from 2016 on plays: H.264 or HEVC video with AAC or Dolby Digital sound, in MP4 or MKV files.'
    }
    'Older HD TV (1080p, before 2016)' = @{
        Lines = @( (New-Line 'mp4 m4v mkv' 'h264' 'aac ac3 mp3' 1920 1080), (New-Line 'avi' 'mpeg4' 'mp3 ac3' 1920 1080) )
        Out = 'mp4'; Hevc10 = $false; Hdr = $false; Dv = $false; Surround = 'ac3'; SubsIn = 'mkv'; MaxW = 1920; MaxH = 1080
        Note = 'H.264 video up to 1080p with AAC or Dolby Digital sound: what most HD TVs before 2016 play. 4K and HDR videos are made 1080p with normal colours.'
    }
    'Phones and tablets' = @{
        Lines = @( (New-Line 'mp4 m4v mov' 'h264' 'aac mp3' 1920 1080) )
        Out = 'mp4'; Hevc10 = $false; Hdr = $false; Dv = $false; Surround = 'stereo'; SubsIn = 'mp4 m4v mov'; MaxW = 1920; MaxH = 1080
        Note = 'H.264 and AAC in MP4, up to 1080p, with stereo sound: plays on iPhone, iPad and Android alike, and in most apps.'
    }
    'Plex, Jellyfin or Emby (direct play)' = @{
        Lines = @( (New-Line 'mp4 m4v' 'h264' 'aac' 1920 1080) )
        Out = 'mp4'; Hevc10 = $false; Hdr = $false; Dv = $false; Surround = 'aac'; SubsIn = 'mp4 m4v'; MaxW = 1920; MaxH = 1080
        Note = 'H.264 and AAC in MP4, up to 1080p: the mix nearly every Plex, Jellyfin and Emby app plays directly, so the server never has to convert it. Subtitles work best as .srt files beside the video.'
    }
    'My own choice' = @{ Custom = $true }
}

function Get-Target {
    <# The chosen target; "My own choice" is built from its four settings. #>
    $name = [string]$script:Settings.Target
    if (-not $script:Targets.Contains($name)) { $name = $script:DefaultTarget }
    $t = $script:Targets[$name]
    if (-not $t.Custom) { return $t }
    $s = $script:Settings
    $h = [int]$s.CustomSize; $w = [int][math]::Round($h * 16 / 9)
    $type = if ($s.CustomType -eq 'mkv') { 'mkv' } else { 'mp4 m4v' }
    return @{
        Lines = @( (New-Line $type $s.CustomVideo $s.CustomSound $w $h) )
        Out = $(if ($s.CustomType -eq 'mkv') { 'mkv' } else { 'mp4' }); Hevc10 = ($s.CustomVideo -eq 'hevc'); Hdr = ($s.CustomVideo -eq 'hevc'); Dv = $false
        Surround = $s.CustomSound; AllSound = $true; SubsIn = $type; MaxW = $w; MaxH = $h; Custom = $true
        Note = 'Every video is checked against exactly these choices, and converted to them when it doesn''t match.'
    }
}
#endregion TARGETS

#region CHECK
# ---------------------------------------------------------------------------
#  Reading ffprobe's answer, and deciding whether a video plays
# ---------------------------------------------------------------------------
$script:CodecNames = @{ h264 = 'H.264'; hevc = 'HEVC'; av1 = 'AV1'; vp9 = 'VP9'; vp8 = 'VP8'; mjpeg = 'Motion JPEG'; mpeg4 = 'MPEG-4 (XviD/DivX)'; msmpeg4v3 = 'DivX 3'; msmpeg4v2 = 'MPEG-4 v2'
                        mpeg2video = 'MPEG-2'; mpeg1video = 'MPEG-1'; vc1 = 'VC-1'; wmv3 = 'WMV 9'; wmv2 = 'WMV 8'; wmv1 = 'WMV 7'; theora = 'Theora'; rv40 = 'RealVideo'; flv1 = 'Flash video'; prores = 'ProRes'
                        aac = 'AAC'; ac3 = 'Dolby Digital'; eac3 = 'Dolby Digital Plus'; dts = 'DTS'; truehd = 'TrueHD'; flac = 'FLAC'; mp3 = 'MP3'; mp2 = 'MP2'; opus = 'Opus'; vorbis = 'Vorbis'; wmav2 = 'WMA'; wmapro = 'WMA Pro'; alac = 'ALAC'; ac4 = 'AC-4'
                        subrip = 'SRT'; ass = 'ASS'; ssa = 'SSA'; mov_text = 'MP4 text'; webvtt = 'WebVTT'; hdmv_pgs_subtitle = 'PGS'; dvd_subtitle = 'VobSub'; dvb_subtitle = 'DVB' }
function Get-CodecName([string]$c) {
    if ($script:CodecNames.ContainsKey($c)) { return $script:CodecNames[$c] }
    if ($c -like 'pcm_*') { return 'PCM' }
    return $c.ToUpper()
}
$script:TextSubs = @('subrip', 'ass', 'ssa', 'mov_text', 'webvtt', 'text')

function Get-ResLabel([int]$w, [int]$h) {
    if ($w -ge 3200 -or $h -ge 1800) { return '4K' }
    if ($w -ge 1800 -or $h -ge 1000) { return '1080p' }
    if ($w -ge 1200 -or $h -ge 700) { return '720p' }
    if ($w -gt 0) { return 'SD' }
    return ''
}

function Get-ChannelLabel([int]$Ch) {
    switch ($Ch) { 1 { return '1.0' } 2 { return '2.0' } 6 { return '5.1' } 8 { return '7.1' } default { if ($Ch) { return "$Ch ch" } else { return '' } } }
}

function Get-SoundName($a) {
    $n = Get-CodecName $a.Codec
    if ($a.Codec -eq 'dts' -and $a.Profile -match 'MA') { $n = 'DTS-HD MA' } elseif ($a.Codec -eq 'dts' -and $a.Profile -match 'HRA|HD') { $n = 'DTS-HD' }
    if ($a.Profile -match 'Atmos') { $n += ' Atmos' }
    return ("$n $(Get-ChannelLabel $a.Ch)").Trim()
}

function Get-VideoName($i) {
    return (Get-CodecName $i.VCodec) + $(if ($i.Bits -gt 8) { " $($i.Bits)-bit" }) + $(if ($i.Hdr) { " $($i.Hdr)" })
}

function ConvertFrom-Probe([string]$Path, [string]$Json) {
    <# What's in a video, from ffprobe's JSON. #>
    $j = $Json | ConvertFrom-Json
    $streams = @($j.streams)
    $i = @{ Ext = [IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant(); Bytes = 0; Seconds = 0.0; VIndex = -1; VCodec = ''; Width = 0; Height = 0; Bits = 8; Hdr = ''; DvProfile = 0
            Transfer = ''; Interlaced = $false; Audio = @(); Subs = @(); Attach = 0 }
    try { $i.Bytes = (Get-Item -LiteralPath $Path).Length } catch { $i.Bytes = [double]$j.format.size }
    $i.Seconds = [double]$j.format.duration
    $v = $streams | Where-Object { $_.codec_type -eq 'video' -and -not $_.disposition.attached_pic -and $_.codec_name -notin 'png', 'bmp', 'gif' } | Select-Object -First 1
    if ($v) {
        $i.VIndex = [int]$v.index; $i.VCodec = [string]$v.codec_name
        $i.Width = [int]$v.width; $i.Height = [int]$v.height
        $i.Bits = if ([string]$v.pix_fmt -match '12') { 12 } elseif ([string]$v.pix_fmt -match '10') { 10 } else { 8 }
        if (-not $i.Seconds -and $v.duration) { $i.Seconds = [double]$v.duration }
        $sides = @($v.side_data_list)
        $dovi = $sides | Where-Object { [string]$_.side_data_type -match 'DOVI' } | Select-Object -First 1
        $i.Transfer = [string]$v.color_transfer
        if ($dovi) { $i.Hdr = 'Dolby Vision'; $i.DvProfile = [int]$dovi.dv_profile }
        elseif (@($sides | Where-Object { [string]$_.side_data_type -match 'HDR Dynamic Metadata|HDR10\+' }).Count) { $i.Hdr = 'HDR10+' }
        elseif ($i.Transfer -eq 'smpte2084') { $i.Hdr = 'HDR10' }
        elseif ($i.Transfer -eq 'arib-std-b67') { $i.Hdr = 'HLG' }
        $i.Interlaced = [string]$v.field_order -in 'tt', 'bb', 'tb', 'bt'
    }
    $i.Audio = @($streams | Where-Object { $_.codec_type -eq 'audio' } | ForEach-Object {
        @{ Index = [int]$_.index; Codec = [string]$_.codec_name; Profile = [string]$_.profile; Ch = [int]$_.channels; Lang = [string]$_.tags.language; Title = [string]$_.tags.title; Default = ([int]$_.disposition.default -eq 1) }
    })
    $i.Subs = @($streams | Where-Object { $_.codec_type -eq 'subtitle' } | ForEach-Object {
        @{ Index = [int]$_.index; Codec = [string]$_.codec_name; Lang = [string]$_.tags.language; Forced = ([int]$_.disposition.forced -eq 1); Text = ([string]$_.codec_name -in $script:TextSubs) }
    })
    $i.Attach = @($streams | Where-Object { $_.codec_type -eq 'attachment' }).Count
    return $i
}

function Get-MainSound($i) {
    $d = @($i.Audio | Where-Object { $_.Default }) | Select-Object -First 1
    if ($d) { return $d }
    return (@($i.Audio) | Select-Object -First 1)
}

function Test-SoundIn([string]$Codec, [string[]]$Sounds) {
    foreach ($s in $Sounds) { if ($Codec -like $s) { return $true } }
    return $false
}

function Get-LinesFor($t, [string]$Ext, [string]$VCodec) {
    <# The target's lines for a file type (and a video format, if given). #>
    return @($t.Lines | Where-Object { ($_.Ext -split ' ') -contains $Ext -and (-not $VCodec -or ($_.Video -split ' ') -contains $VCodec) })
}

function Test-Fits($Line, [int]$W, [int]$H) {
    $long = [math]::Max($W, $H); $short = [math]::Min($W, $H)
    return ($long -le $Line.Wide -and $short -le $Line.High + 8)    # + 8: 1080p is often stored as 1088 lines
}

function Test-PictureOk($i, $t, [string]$Ext) {
    <# $null if the picture plays as it is in that file type, else why not. #>
    $type = Get-LinesFor $t $Ext
    $lines = Get-LinesFor $t $Ext $i.VCodec
    $name = Get-CodecName $i.VCodec
    if (-not $lines.Count) {
        if (-not @($t.Lines | Where-Object { ($_.Video -split ' ') -contains $i.VCodec }).Count) { return "$name video isn't on its list" }
        if ($type.Count) { return "$name video isn't played from .$Ext files" }
        return $null    # the file type's own reason covers it
    }
    $fit = @($lines | Where-Object { Test-Fits $_ $i.Width $i.Height })
    if (-not $fit.Count) {
        $most = $lines | Sort-Object { $_.Wide } -Descending | Select-Object -First 1
        return "$($i.Width)x$($i.Height) picture is bigger than it plays ($($most.Wide)x$($most.High) for $name)"
    }
    if ($i.VCodec -eq 'h264' -and $i.Bits -gt 8) { return "$($i.Bits)-bit H.264 hardly ever plays on TVs and phones" }
    if ($i.VCodec -eq 'hevc' -and $i.Bits -gt 10) { return "$($i.Bits)-bit HEVC isn't on its list" }
    if ($i.VCodec -eq 'hevc' -and $i.Bits -gt 8 -and -not $t.Hevc10) { return '10-bit HEVC isn''t on its list' }
    if ($i.Hdr -eq 'Dolby Vision' -and -not $t.Dv -and $i.DvProfile -eq 5) { return 'Dolby Vision (profile 5) shows purple and green colours on players without Dolby Vision' }
    if ($i.Hdr -and -not $t.Hdr) { return "$($i.Hdr) picture: its colours would look washed out" }
    return $null
}

function Get-SoundsFor($t, [string]$Ext, [string]$VCodec) {
    $lines = Get-LinesFor $t $Ext $VCodec
    if (-not $lines.Count) { $lines = Get-LinesFor $t $Ext }
    if (-not $lines.Count) { $lines = @($t.Lines | Where-Object { ($_.Video -split ' ') -contains $VCodec }) }
    if (-not $lines.Count) { $lines = @($t.Lines) }    # a file type it doesn't play: judge the sound by everything it does
    return @($lines | ForEach-Object { $_.Sound -split ' ' } | Select-Object -Unique)
}

function Test-Video($i, $t) {
    <# Whether it plays as it is: @{ Ok; Reasons; Notes }. #>
    $r = New-Object Collections.Generic.List[string]
    $n = New-Object Collections.Generic.List[string]
    if (-not $i.VCodec) { $r.Add('No video found in it'); return @{ Ok = $false; Reasons = $r; Notes = $n } }
    if (-not (Get-LinesFor $t $i.Ext).Count) { $r.Add(".$($i.Ext) files aren't on its list") }
    $why = Test-PictureOk $i $t $i.Ext
    if ($why) { $r.Add($why) }
    if ($i.Hdr -eq 'Dolby Vision' -and -not $t.Dv -and $i.DvProfile -ne 5) { $n.Add('Dolby Vision: it shows the HDR10 picture underneath instead') }
    $sounds = Get-SoundsFor $t $i.Ext $i.VCodec
    $main = Get-MainSound $i
    if (-not $main) { $n.Add('No sound track') }
    else {
        if (-not (Test-SoundIn $main.Codec $sounds)) { $r.Add("$(Get-SoundName $main) sound isn't on its list, so it may play with no sound") }
        $other = @($i.Audio | Where-Object { $_.Index -ne $main.Index -and -not (Test-SoundIn $_.Codec $sounds) })
        if ($other.Count) { $n.Add("Other sound tracks it can't play: $((@($other | ForEach-Object { Get-SoundName $_ }) | Select-Object -Unique) -join ', ')") }
    }
    $text = @($i.Subs | Where-Object { $_.Text })
    if ($i.Subs.Count -and -not (($t.SubsIn -split ' ') -contains $i.Ext)) {
        $n.Add("Subtitles inside a .$($i.Ext) file may not show on it. Converting can save them as .srt files beside the video.")
    } elseif ($i.Subs.Count -and -not $text.Count -and -not $t.Custom -and $t.Out -eq 'mp4' -and $t.SubsIn -notmatch 'mkv') {
        $n.Add('Picture subtitles (PGS or VobSub) only: a media server may have to burn them in')
    }
    return @{ Ok = ($r.Count -eq 0); Reasons = $r; Notes = $n }
}
#endregion CHECK

#region PLAN
# ---------------------------------------------------------------------------
#  What converting will do to a video, as steps to show and FFmpeg's arguments
# ---------------------------------------------------------------------------
function Join-Args([string[]]$List) {
    <# One command line, each argument quoted when it needs to be. #>
    return (@($List | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' ')
}

function Get-Plan($i, $t) {
    $s = $script:Settings
    $steps = New-Object Collections.Generic.List[string]
    $q = [string]$s.Quality

    # File type: keep MP4 or MKV when the target plays that type, else the target's own (unless chosen).
    if ($t.Custom) { $out = $t.Out }
    elseif ($s.FileType -in 'mp4', 'mkv') { $out = $s.FileType }
    elseif ($i.Ext -in 'mkv', 'mp4', 'm4v' -and (Get-LinesFor $t $i.Ext).Count) { $out = $i.Ext }
    else {
        # The target's own type, unless the other one (MP4 or MKV) lets the picture be copied untouched.
        $out = $t.Out
        foreach ($c in @($t.Out) + @('mp4', 'mkv' | Where-Object { $_ -ne $t.Out })) {
            if ((Get-LinesFor $t $c $i.VCodec).Count -and -not (Test-PictureOk $i $t $c)) { $out = $c; break }
        }
    }
    $mp4 = $out -in 'mp4', 'm4v'
    if ($out -ne $i.Ext) { $steps.Add("File: .$($i.Ext) $script:Arrow .$out") } else { $steps.Add("File type stays .$out") }

    # Picture: copied untouched when it already plays in the new file, else converted.
    $vArgs = @(); $vf = @()
    $why = Test-PictureOk $i $t $out
    $typeOk = (Get-LinesFor $t $out $i.VCodec).Count -gt 0
    $encode = [bool]$why -or -not $typeOk
    $res = Get-ResLabel $i.Width $i.Height
    $newCodec = $i.VCodec
    if (-not $encode) {
        $vArgs += '-c:v', 'copy'
        if ($i.VCodec -eq 'hevc' -and $mp4) { $vArgs += '-tag:v', 'hvc1' }
        $steps.Add("Picture: $(Get-VideoName $i) $res kept as it is (no quality lost)")
    } else {
        $gpuOn = $s.Gpu -and -not $script:GpuBroken -and [VcGpu]::Ready
        $hevcOk = (Get-LinesFor $t $out 'hevc').Count -gt 0 -and ($script:Can.X265 -or ($gpuOn -and [VcGpu]::Hevc))
        $big = $i.Width -gt 1920 -or $i.Height -gt 1088
        $newCodec = switch ($s.VideoOut) {
            'hevc'  { if ($hevcOk) { 'hevc' } else { 'h264' } }
            'h264'  { 'h264' }
            default { if ($hevcOk -and ($big -or $i.Hdr)) { 'hevc' } else { 'h264' } }
        }
        if ($t.Custom) { $newCodec = $s.CustomVideo; if ($newCodec -eq 'hevc' -and -not $script:Can.X265 -and -not ($gpuOn -and [VcGpu]::Hevc)) { $newCodec = 'h264' } }
        # Bigger than the target plays: made smaller, keeping its shape.
        $w = $i.Width; $h = $i.Height
        $maxW = $t.MaxW; $maxH = $t.MaxH
        $newLine = Get-LinesFor $t $out $newCodec | Sort-Object { $_.Wide } -Descending | Select-Object -First 1
        if ($newLine) { $maxW = [math]::Min($maxW, $newLine.Wide); $maxH = [math]::Min($maxH, $newLine.High) }
        if ($i.Interlaced) { $vf += 'yadif' }
        $newRes = $res
        if ($h -gt $w) { $tmp = $maxW; $maxW = $maxH; $maxH = $tmp }    # an upright (portrait) video: the box turns too
        if ($w -gt $maxW + 8 -or $h -gt $maxH + 8) {
            $vf += "scale=${maxW}:${maxH}:force_original_aspect_ratio=decrease:force_divisible_by=2"
            $newRes = Get-ResLabel $maxW $maxH
        }
        $keepHdr = $i.Hdr -and $i.Hdr -ne 'Dolby Vision' -and $newCodec -eq 'hevc' -and $t.Hdr
        if ($i.Hdr -eq 'Dolby Vision' -and $newCodec -eq 'hevc' -and $t.Hdr -and $i.DvProfile -ne 5) { $keepHdr = $true }
        $toneMapped = $false
        if ($i.Hdr -and -not $keepHdr) {
            if ($script:Can.Zscale -and $i.Transfer -in 'smpte2084', 'arib-std-b67') {
                $vf += 'zscale=t=linear:npl=100', 'format=gbrpf32le', 'zscale=p=bt709', 'tonemap=tonemap=hable:desat=0', 'zscale=t=bt709:m=bt709:r=tv'
                $toneMapped = $true
            }
        }
        $crf = if ($newCodec -eq 'hevc') { @{ Best = 20; Balanced = 23; Smaller = 26 }[$q] } else { @{ Best = 18; Balanced = 21; Smaller = 24 }[$q] }
        if (-not $crf) { $crf = if ($newCodec -eq 'hevc') { 23 } else { 21 } }
        # The graphics card, when it has an encoder for this that works (10-bit HEVC needs one that can do 10-bit).
        $ten = $newCodec -eq 'hevc' -and ($keepHdr -or ($i.Bits -gt 8 -and $t.Hevc10))
        $gpu = $null
        if ($gpuOn) {
            $enc = if ($newCodec -eq 'hevc') { [VcGpu]::Hevc } else { [VcGpu]::H264 }
            if ($enc -and (-not $ten -or [VcGpu]::HevcTen)) { $gpu = $enc }
        }
        if (-not $gpu -and $newCodec -eq 'hevc' -and -not $script:Can.X265) { $newCodec = 'h264'; $ten = $false; $keepHdr = $false }
        $trc = if ($i.Transfer -eq 'arib-std-b67') { 'arib-std-b67' } else { 'smpte2084' }
        if ($gpu) {
            $cq = if ($newCodec -eq 'hevc') { @{ Best = 21; Balanced = 25; Smaller = 29 }[$q] } else { @{ Best = 19; Balanced = 23; Smaller = 27 }[$q] }
            if (-not $cq) { $cq = 24 }
            $pix = if ($ten) { 'p010le' } else { 'nv12' }
            switch -Wildcard ($gpu) {
                '*_nvenc' { $vArgs += '-c:v', $gpu, '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', "$cq", '-b:v', '0', '-pix_fmt', $pix }
                '*_qsv'   { $vArgs += '-c:v', $gpu, '-preset', 'medium', '-global_quality', "$cq", '-pix_fmt', $pix }
                '*_amf'   { $vArgs += '-c:v', $gpu, '-quality', 'quality', '-rc', 'cqp', '-qp_i', "$cq", '-qp_p', "$cq", '-pix_fmt', $pix; if ($gpu -eq 'h264_amf') { $vArgs += '-qp_b', "$cq" } }
            }
            if ($newCodec -eq 'h264') { $vArgs += '-profile:v', 'high' } elseif ($ten) { $vArgs += '-profile:v', 'main10' }
            if ($keepHdr) { $vArgs += '-color_primaries', 'bt2020', '-color_trc', $trc, '-colorspace', 'bt2020nc' }
            if ($newCodec -eq 'hevc' -and $mp4) { $vArgs += '-tag:v', 'hvc1' }
        } elseif ($newCodec -eq 'hevc') {
            $vArgs += '-c:v', 'libx265', '-preset', 'medium', '-crf', "$crf"
            $x = 'log-level=error'
            if ($keepHdr) {
                $vArgs += '-pix_fmt', 'yuv420p10le', '-color_primaries', 'bt2020', '-color_trc', $trc, '-colorspace', 'bt2020nc'
                $x += ":hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=${trc}:colormatrix=bt2020nc"
            } elseif ($i.Bits -gt 8 -and $t.Hevc10) { $vArgs += '-pix_fmt', 'yuv420p10le' }
            else { $vArgs += '-pix_fmt', 'yuv420p' }
            $vArgs += '-x265-params', $x
            if ($mp4) { $vArgs += '-tag:v', 'hvc1' }
        } else {
            $preset = if ($q -eq 'Best') { 'slow' } else { 'medium' }
            $vArgs += '-c:v', 'libx264', '-preset', $preset, '-crf', "$crf", '-pix_fmt', 'yuv420p', '-profile:v', 'high'
            if ($maxW -le 1920) { $vArgs += '-level:v', '4.1' }
        }
        if ($toneMapped) { $vArgs += '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709' }
        if ($vf.Count) {
            if ($toneMapped -or $newCodec -eq 'h264') { $vf += 'format=yuv420p' }
            $vArgs += '-vf', ($vf -join ',')
        }
        $label = @{ Best = 'best quality'; Balanced = 'balanced quality'; Smaller = 'smaller file' }[$q]
        $steps.Add("Picture: $(Get-VideoName $i) $res $script:Arrow $(Get-CodecName $newCodec)$(if ($keepHdr) { " $($i.Hdr -replace 'Dolby Vision','HDR10')" }) $newRes ($label$(if ($gpu) { ', on the graphics card' }))")
        if ($i.Hdr -and -not $keepHdr) {
            if ($toneMapped) { $steps.Add("$($i.Hdr) turned into normal colours (SDR), so it doesn't look washed out") }
            else { $steps.Add("$($i.Hdr) can't be turned into normal colours by this FFmpeg (it has no zscale filter), so colours may look washed out") }
        }
        if ($i.Hdr -eq 'Dolby Vision' -and $keepHdr) { $steps.Add('Dolby Vision becomes plain HDR10 (FFmpeg can''t write Dolby Vision)') }
        if ($i.Interlaced) { $steps.Add('Interlaced picture made smooth (de-interlaced)') }
    }

    # Sound: each track copied when the target plays it in the new file, else converted. Languages kept.
    $sounds = Get-SoundsFor $t $out $newCodec
    $aArgs = @(); $n = 0; $soundChanged = $false
    foreach ($a in $i.Audio) {
        $lang = if ($a.Lang -and $a.Lang -ne 'und') { " ($($a.Lang))" } else { '' }
        if (-not $t.AllSound -and (Test-SoundIn $a.Codec $sounds) -or ($t.AllSound -and $a.Codec -eq $t.Surround)) {
            $aArgs += "-c:a:$n", 'copy'
            $steps.Add("Sound: $(Get-SoundName $a)$lang kept as it is")
        } else {
            $soundChanged = $true
            $ch = [int]$a.Ch; if ($ch -lt 1) { $ch = 2 }
            $codec = if ($t.AllSound) { $t.Surround } elseif ($ch -gt 2 -and $t.Surround -ne 'stereo') { $t.Surround } else { 'aac' }
            if (-not (Test-SoundIn $codec $sounds)) { $codec = 'aac' }
            $outCh = $ch
            if ($t.Surround -eq 'stereo' -and $ch -gt 2) { $outCh = 2 }
            if ($codec -in 'ac3', 'eac3' -and $ch -gt 6) { $outCh = 6 }
            $rate = if ($codec -in 'ac3', 'eac3') {
                if ($outCh -gt 2) { @{ Best = '640k'; Balanced = '640k'; Smaller = '448k' }[$q] } else { @{ Best = '256k'; Balanced = '224k'; Smaller = '192k' }[$q] }
            } elseif ($outCh -gt 2) { @{ Best = '512k'; Balanced = '384k'; Smaller = '256k' }[$q] }
            elseif ($outCh -eq 1) { @{ Best = '128k'; Balanced = '96k'; Smaller = '80k' }[$q] }
            else { @{ Best = '256k'; Balanced = '192k'; Smaller = '128k' }[$q] }
            $aArgs += "-c:a:$n", $codec, "-b:a:$n", $rate
            if ($outCh -ne $ch) { $aArgs += "-ac:a:$n", "$outCh" }
            $steps.Add("Sound: $(Get-SoundName $a)$lang $script:Arrow $(Get-CodecName $codec) $(Get-ChannelLabel $outCh)")
        }
        $n++
    }
    if (-not $i.Audio.Count) { $steps.Add('No sound track') }

    # Subtitles: text ones kept (as MP4 text in MP4); picture ones only fit in MKV.
    $sArgs = @(); $sMaps = @(); $k = 0; $dropped = 0
    foreach ($sub in $i.Subs) {
        if ($mp4) {
            if ($sub.Text) { $sMaps += $sub.Index; $sArgs += "-c:s:$k", 'mov_text'; $k++ } else { $dropped++ }
        } else {
            $sMaps += $sub.Index
            $sArgs += "-c:s:$k", $(if ($sub.Codec -eq 'mov_text') { 'srt' } else { 'copy' }); $k++
        }
    }
    if ($k) { $steps.Add("Subtitles: $k kept inside the file") }
    if ($dropped) { $steps.Add("$dropped picture subtitle track$(if ($dropped -gt 1) { 's' }) (PGS or VobSub) left out: MP4 files can't hold them. Choose MKV as the file type to keep them.") }
    $srt = @()
    if ($s.Srt) { $srt = @($i.Subs | Where-Object { $_.Text }) }
    if ($srt.Count) { $steps.Add("Subtitles: $($srt.Count) saved as .srt file$(if ($srt.Count -gt 1) { 's' }) beside the video too") }
    $steps.Add('Chapters and titles kept')

    $action = if ($encode) { 'Convert' } elseif ($soundChanged) { 'Sound' } else { 'Rewrap' }
    return @{ Gpu = $(if ($encode) { $gpu } else { $null }); Action = $action; Out = $out; Mp4 = $mp4; VArgs = $vArgs; AArgs = $aArgs; SArgs = $sArgs; SubMaps = $sMaps; Srt = $srt; Steps = $steps; NewCodec = $newCodec }
}

function Get-FfmpegArgs($i, $Plan, [string]$In, [string]$Out, [double]$SampleStart = -1, [string[]]$SrtPaths) {
    $a = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error')
    if ($SampleStart -ge 0) { $a += '-ss', ('{0:0.###}' -f $SampleStart).Replace(',', '.'), '-t', '20' }
    $a += '-i', $In, '-map', "0:$($i.VIndex)"
    foreach ($x in $i.Audio) { $a += '-map', "0:$($x.Index)" }
    foreach ($x in $Plan.SubMaps) { $a += '-map', "0:$x" }
    if (-not $Plan.Mp4 -and $i.Attach -and $SampleStart -lt 0) { $a += '-map', '0:t?' }
    $a += '-map_metadata', '0'
    $a += '-map_chapters', $(if ($SampleStart -ge 0) { '-1' } else { '0' })
    $a += $Plan.VArgs + $Plan.AArgs + $Plan.SArgs
    if ($Plan.Mp4) { $a += '-movflags', '+faststart' }
    $a += '-max_muxing_queue_size', '4096', '-progress', 'pipe:1', '-nostats', $Out
    if ($SrtPaths) {
        for ($k = 0; $k -lt $Plan.Srt.Count; $k++) { $a += '-map', "0:$($Plan.Srt[$k].Index)", '-c:s', 'srt', $SrtPaths[$k] }
    }
    return (Join-Args $a)
}
#endregion PLAN

# ---------------------------------------------------------------------------
#  Help
# ---------------------------------------------------------------------------
$script:HelpText = @'
WHAT IT DOES
Video Converter checks which of your videos will play on your TV, phone or media server, and converts only the ones that won't. It only does what's needed: when the picture already plays, it is copied across untouched (no quality lost, and done in seconds), and only the sound or the file type is changed. Your original videos are never changed.

WHAT IT NEEDS
FFmpeg, which is free. If it isn't found, the app shows how to get it: press Install FFmpeg (it runs winget install Gyan.FFmpeg in a window) and then Look again, or press Choose ffmpeg.exe... if you already have it somewhere.

1. PICK WHAT IT SHOULD PLAY ON
"Make them play on" at the top: the Sony BRAVIA XR-42A90K to begin with, or Samsung, LG, any 4K smart TV, an older HD TV, phones and tablets, Plex/Jellyfin/Emby, or My own choice (you pick the file type, picture, sound and largest size). The line under it says where that list comes from. Changing it checks every video again straight away.

2. ADD VIDEOS
Drop videos or whole folders onto the window, or use Add videos... and Add folder... (every folder inside it is searched too). Each video is checked with ffprobe and marked:
- Plays: it should play as it is. Nothing to do.
- Quick fix: only the file type changes (a new "box" for the same picture and sound). Takes seconds.
- Sound fix: the picture is kept as it is and only the sound is converted. Takes a minute or two.
- Convert: the picture has to be converted too. This takes a while (roughly as long as the film for HD, longer for 4K).
- Can't read: the file is damaged or isn't a video.
Click a video to see why on the right, and what converting will do to it.

3. PREVIEW
The right-hand side shows a picture from the video, what's in it (picture, sound tracks, subtitles) and the reasons it won't play. Play opens it in your usual player. Try 20 seconds converts a short piece from the middle with your current choices and opens it, so you can check the picture and sound first; it also tells you about how big the whole file will be. Open folder shows it in Explorer.

4. CONVERT
Convert does every video that needs it, one after another. Each shows its progress, and the bar at the bottom shows how far the whole list has got and about how long is left. Pause stops for a while (your PC is then free for other things) and Resume carries on. Stop ends it: the video being converted is left unfinished and its part-made file is deleted. While converting, the PC isn't allowed to go to sleep. Each new file is checked when it's done (it must be as long as the original), and only then is anything else done.

QUALITY
Best: the nearest to the original, bigger files. Balanced: what most people use, hard to tell from the original. Smaller: smaller files, a little softer. Only matters when the picture or sound is converted.

FILE TYPE
"Keep MP4 or MKV when it plays" changes the file type only when it must, so an MKV with sound the TV can't play stays an MKV (keeping every subtitle) with the sound converted. MP4 or MKV makes every new file that type. MP4 plays on more things; MKV can hold every kind of subtitle, including picture ones (PGS and VobSub) that MP4 can't.

PICTURE FORMAT
Automatic uses H.264 for HD videos and HEVC for 4K and HDR (when the target plays it), as HEVC makes 4K files about half the size. H.264 plays on more things. HEVC makes smaller files but converts more slowly.

THE GRAPHICS CARD
When "Use the graphics card when it can" is ticked (as it is to begin with), a picture that has to be converted is converted on the graphics card if it has an encoder that works: NVIDIA (NVENC, GTX 900 series or later), Intel (Quick Sync) or AMD (AMF). That's several times faster, and files come out a little bigger for the same quality. When the app starts it tries each one on a tiny made-up picture, and the line under the tick says what it found. Without one, or with the tick off, the processor (CPU) does it. If the graphics card ever fails on a video, that video is done again on the processor straight away, and the processor is used until the app is started again. Only converting the picture uses it; sound fixes and quick fixes don't need it.

HDR
HDR10 and HLG videos stay HDR when the target shows HDR. For targets that don't (phones, older TVs, Plex direct play), the picture is turned into normal colours so it doesn't look washed out. Dolby Vision is kept as it is when only the sound or file type changes; if the picture has to be converted it becomes HDR10, as FFmpeg can't write Dolby Vision.

SOUND
Sound tracks the target plays are kept as they are. Others are converted: surround (5.1 and 7.1) to Dolby Digital Plus for the Sony and other TVs that play it, or Dolby Digital or AAC; stereo to AAC. Phones and tablets get stereo. Every track is kept with its language, so films with several languages keep them all.

SUBTITLES
Subtitles inside the video are kept: text ones (SRT, ASS) in MP4 and MKV, picture ones (PGS, VobSub) only in MKV. "Also save subtitles as .srt files" writes each text subtitle track as its own .srt file beside the new video too (named like Film.eng.srt), which is how the Sony shows subtitles from MP4 files, and what Plex, Jellyfin and Emby like best. .srt and other subtitle files already beside the original are copied with it when the new file goes to another folder.

WHERE THE NEW FILES GO
"Next to the original" saves each new video in the same folder, with the same name and its new file type. If that name is taken (an MP4 made from an MP4), it's called "Name (converted).mp4". "A folder I choose" puts them all in one folder.

THE ORIGINALS
"Keep the originals" leaves them where they are. "Send them to the Recycle Bin" does that once the new file has been made and checked, and then gives the new file the original's name if it had to use "(converted)". You can get them back from the Recycle Bin.

UTILITIES
Click a video, then Utilities... for other things it can do to that one video. Each saves a new file named after the original with what was done in brackets, such as "Film (trimmed).mkv", where the new videos go (next to the original, or your chosen folder); the original is never changed. New videos made here are added to the list, so they're checked too.
- Sound and subtitle tracks: untick the tracks you don't want (a language you never use, a commentary) and pick the main sound track, then Save a copy with these tracks. Nothing is converted, so it takes seconds.
- Trim: keep only the part between two times (hours:minutes:seconds). Nothing is converted, so the cut is at the nearest key frame and may start a second or two early.
- Save the sound: one sound track as an audio file, as it is (an AAC track becomes .m4a, Dolby Digital .ac3 and so on), or tick As MP3.
- Save the subtitles as files: text subtitles as .srt files, PGS ones as .sup files.
- Save the picture at: a still picture (PNG) from that time. It's shown to you first, then you choose where to save it (or don't).
- Make it louder: evens out quiet or uneven sound to a steady TV level (EBU R128). The sound is converted (surround to Dolby Digital Plus, stereo to AAC); the picture isn't touched.
- Turn it: for sideways or upside-down videos. With FFmpeg 6 or later only a tag is changed, so it's instant; older FFmpeg converts the picture.
- Remove tags: removes the title, comments and other tags saved in the file (some TVs show the title instead of the file name). Languages and chapters stay.
- Make a GIF or a small clip: from the part between the two Trim times. The GIF has no sound (a minute at most), and is shown to you before you choose where to save it; the clip is a small MP4 for sharing, cut exactly.
- Sound out of step: moves the sound later or earlier by the seconds you type, when lips and voices don't match. Nothing is converted.
- Split into parts: every so many minutes, or at each chapter, as (part 01), (part 02) and so on. Nothing is converted.
- Shrink for sharing: an MP4 copy under the size you type (25 MB, say) for email, WhatsApp or Discord, with the main sound only. Very small sizes are made smaller in picture too.
- Contact sheet: one picture with a grid of frames from all through the video. It's shown to you first, then you choose where to save it (or don't).
- Old tapes and DVDs: smooths an interlaced picture, takes out grain and noise, and makes it 1080p with a light sharpen for a big TV. The picture is converted; sound and subtitles are kept.
- Cover and title: a copy with a cover picture (JPG or PNG) and a title inside it, which Plex, Jellyfin, Emby, Windows and many TVs show.
Stop ends one early and deletes its part-made file.

MORE (FOR THE WHOLE LIST)
- Join the selected videos: select two or more in the list (Ctrl+click), and they're joined in name order, so Part 1 comes before Part 2. When they're all the same kind they're joined as they are in seconds; otherwise they're converted to one H.264 MP4 the size of the first.
- Find duplicates: the same film more than once in the list (by name, leaving out words such as 1080p, x265 or BluRay, or by having the same length), best copy first. Nothing is deleted: Select the extra copies picks them in the list.
- Stats: what's in the list (picture and sound formats, sizes, file types, the biggest videos, how many play), and everything converted so far, with the space saved.
- Save a report: the whole list, as a CSV for Excel (names such as 1917 stay as typed) or as a web page to open, print or share.
- Save the list and Open a list: keep a big job and carry on another day. The app always starts with an empty list.
- Convert at a set time: starts converting at the time you type, such as 01:00, as long as the app is left open. Cancel stops the wait.

WHEN IT'S DONE
"When each video is done" can copy or move each new video to a folder, such as your NAS films share, with its .srt files (in the background, before the next one starts). "When the whole list is done" can put the PC to sleep or shut it down, after 60 seconds you can cancel; it goes back to Nothing else each time, so it never catches you out. "Tell me when it's done" shows a Windows notification and plays a sound.

THE LIST
The buttons above the list show one kind at a time. Remove takes the selected videos off the list (nothing on the disk is touched), and Clear list empties it.

LOOK
The Look button switches between Light, Dark and the same as Windows, from the next start.
'@

function Show-Help {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="700" Height="680" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="14" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,18,22,16">
    <Button x:Name="HelpClose" DockPanel.Dock="Bottom" Content="Close" HorizontalAlignment="Right" MinWidth="80" Margin="0,14,0,0" IsCancel="True" IsDefault="True"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="HelpText" TextWrapping="Wrap" LineHeight="21" Margin="0,0,8,0"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    if ($script:Zoom -gt 1.01) { $w.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $script:Zoom, $script:Zoom; $w.Width *= $script:Zoom; $w.Height = [math]::Min($w.Height * $script:Zoom, [Windows.SystemParameters]::WorkArea.Height * 0.9) }
    $w.Title = "$script:AppName Help"
    # Headings in bold: the lines written in capitals.
    $tb = $w.FindName('HelpText')
    foreach ($line in ($script:HelpText -split "`r?`n")) {
        if ($tb.Inlines.Count) { $tb.Inlines.Add((New-Object Windows.Documents.LineBreak)) }
        $run = New-Object Windows.Documents.Run $line
        if ($line -cmatch '^[0-9. ]*[A-Z][A-Z ]+$') { $run.FontWeight = 'SemiBold'; $run.Foreground = Get-Brush 'Accent' }
        $tb.Inlines.Add($run)
    }
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1280" Height="800" MinWidth="1000" MinHeight="600" WindowStartupLocation="CenterScreen" AllowDrop="True"
        FontFamily="Segoe UI" FontSize="14" Background="{Page}" Foreground="{Ink}">
  <Window.TaskbarItemInfo><TaskbarItemInfo/></Window.TaskbarItemInfo>
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel x:Name="Root">
    <Border DockPanel.Dock="Bottom" Background="{Card}" BorderBrush="{Line}" BorderThickness="0,1,0,0" Padding="18,12" MinHeight="64">
      <DockPanel VerticalAlignment="Center">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnPause" Content="Pause" Visibility="Collapsed" MinWidth="86"/>
          <Button x:Name="BtnStop" Content="Stop" Visibility="Collapsed" MinWidth="70" Margin="0,0,20,0"/>
          <Button x:Name="BtnLook"/>
          <Button x:Name="BtnHelp" Content="Help"/>
          <Button x:Name="BtnAbout" Content="About" Margin="0"/>
        </StackPanel>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" TextWrapping="Wrap" LineHeight="20" Foreground="{Soft}" Margin="0,0,16,0"/>
      </DockPanel>
    </Border>
    <ProgressBar x:Name="Progress" DockPanel.Dock="Bottom" Height="4" Foreground="{Accent}" Background="{Line}" BorderThickness="0" Visibility="Hidden" Maximum="100"/>
    <Grid Margin="18,16,18,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="460"/></Grid.ColumnDefinitions>

      <!-- Left: the videos -->
      <DockPanel>
        <DockPanel DockPanel.Dock="Top">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnMore" Content="More..." ToolTip="Join, find duplicates, stats, reports, save or open the list, convert at a set time"/>
            <Button x:Name="BtnAddFiles" Content="Add videos..."/>
            <Button x:Name="BtnAddFolder" Content="Add folder..."/>
            <Button x:Name="BtnConvert" Content="Convert" Style="{StaticResource Accent}" MinWidth="120" Margin="0" IsEnabled="False"/>
          </StackPanel>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Videos" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtSummary" Foreground="{Soft}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </DockPanel>
        <Border DockPanel.Dock="Top" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,14,0,0">
          <DockPanel>
            <TextBlock Text="Make them play on" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,14,0" DockPanel.Dock="Left"/>
            <ComboBox x:Name="CmbTarget" DockPanel.Dock="Left" Width="340" Margin="0"/>
            <TextBlock x:Name="TxtTargetNote" Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Margin="14,0,0,0" LineHeight="17"/>
          </DockPanel>
        </Border>
        <Border x:Name="PanelNoFfmpeg" DockPanel.Dock="Top" Background="{Card}" BorderBrush="{Warn}" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,10,0,0" Visibility="Collapsed">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnInstall" Content="Install FFmpeg" Style="{StaticResource Accent}"/>
              <Button x:Name="BtnFindFfmpeg" Content="Choose ffmpeg.exe..."/>
              <Button x:Name="BtnLookAgain" Content="Look again" Margin="0"/>
            </StackPanel>
            <TextBlock TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,14,0" Text="FFmpeg isn't installed (or wasn't found). It's free, and Video Converter needs it to read and convert videos. Install FFmpeg runs winget install Gyan.FFmpeg in a window; when it's finished, press Look again."/>
          </DockPanel>
        </Border>
        <DockPanel DockPanel.Dock="Top" Margin="0,14,0,4">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
            <Button x:Name="BtnRemove" Content="Remove" IsEnabled="False"/>
            <Button x:Name="BtnClear" Content="Clear list" Margin="0" IsEnabled="False"/>
          </StackPanel>
          <WrapPanel VerticalAlignment="Center" Margin="0,0,10,0">
            <RadioButton x:Name="PillAll" Style="{StaticResource Pill}" GroupName="Kind" Tag="" IsChecked="True" Content="All"/>
            <RadioButton x:Name="PillNeeds" Style="{StaticResource Pill}" GroupName="Kind" Tag="Needs" Content="Needs work"/>
            <RadioButton x:Name="PillPlays" Style="{StaticResource Pill}" GroupName="Kind" Tag="Plays" Content="Plays"/>
            <RadioButton x:Name="PillDone" Style="{StaticResource Pill}" GroupName="Kind" Tag="Done" Content="Done"/>
          </WrapPanel>
        </DockPanel>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="6">
          <Grid>
            <StackPanel x:Name="PanelEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="40">
              <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="40" Foreground="{Soft}" HorizontalAlignment="Center"/>
              <TextBlock x:Name="TxtEmpty" Foreground="{Soft}" FontSize="15" TextWrapping="Wrap" TextAlignment="Center" Margin="0,12,0,0" Text="Drop videos or folders here, or use Add videos... and Add folder..."/>
            </StackPanel>
            <ListBox x:Name="LstVideos" BorderThickness="0" Background="Transparent" ScrollViewer.HorizontalScrollBarVisibility="Disabled" SelectionMode="Extended"
                     VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
              <ListBox.ItemTemplate><DataTemplate>
                <DockPanel>
                  <Border DockPanel.Dock="Right" BorderBrush="{Binding Pill}" BorderThickness="1.5" CornerRadius="12" Padding="11,3" VerticalAlignment="Center" Margin="12,0,4,0">
                    <TextBlock Text="{Binding Status}" Foreground="{Binding Pill}" FontSize="12" FontWeight="SemiBold"/>
                  </Border>
                  <StackPanel>
                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Details}" Foreground="{Soft}" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                    <ProgressBar Value="{Binding Progress}" Height="3" Margin="0,6,0,1" Foreground="{Accent}" Background="{Line}" BorderThickness="0" Visibility="{Binding ProgressShown}"/>
                  </StackPanel>
                </DockPanel>
              </DataTemplate></ListBox.ItemTemplate>
            </ListBox>
          </Grid>
        </Border>
      </DockPanel>

      <!-- Right: preview and choices -->
      <Border Grid.Column="1" Margin="14,0,0,0" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="18,14,18,18">
            <TextBlock Text="Preview" Style="{StaticResource Head}" Margin="0,0,0,8"/>
            <Border Background="{Shade}" CornerRadius="6" Height="236" ClipToBounds="True">
              <Grid>
                <TextBlock x:Name="TxtNoPicture" Text="Click a video to see it here" Foreground="#B8B0AA" HorizontalAlignment="Center" VerticalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center" Margin="20"/>
                <Image x:Name="ImgPreview" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
              </Grid>
            </Border>
            <TextBlock x:Name="TxtPrvName" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,10,0,0"/>
            <TextBlock x:Name="TxtPrvFacts" Foreground="{Soft}" FontSize="13" TextWrapping="Wrap" LineHeight="19" Margin="0,4,0,0"/>
            <WrapPanel Margin="0,10,0,0">
              <Button x:Name="BtnPlay" Content="Play" IsEnabled="False" Margin="0,0,8,6"/>
              <Button x:Name="BtnSample" Content="Try 20 seconds" IsEnabled="False" Margin="0,0,8,6" ToolTip="Convert 20 seconds from the middle with your choices below, and play it"/>
              <Button x:Name="BtnFolder" Content="Open folder" IsEnabled="False" Margin="0,0,8,6"/>
              <Button x:Name="BtnUtils" Content="Utilities..." IsEnabled="False" Margin="0,0,0,6" ToolTip="Remove sound or subtitle tracks, trim, save the sound, subtitles or a picture, make it louder, turn it, remove tags"/>
            </WrapPanel>
            <TextBlock x:Name="TxtVerdict" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,8,0,0"/>
            <TextBlock x:Name="TxtReasons" TextWrapping="Wrap" LineHeight="19" FontSize="13" Margin="0,4,0,0"/>
            <TextBlock x:Name="TxtStepsHead" Text="What converting will do" FontWeight="SemiBold" Margin="0,12,0,0" Visibility="Collapsed"/>
            <TextBlock x:Name="TxtSteps" TextWrapping="Wrap" LineHeight="19" FontSize="13" Foreground="{Soft}" Margin="0,4,0,0"/>

            <Border Height="1" Background="{Line}" Margin="0,18,0,0"/>
            <TextBlock Text="Converting" Style="{StaticResource Head}"/>
            <StackPanel x:Name="PanelCustom" Visibility="Collapsed">
              <TextBlock Text="My own choice: file type" Style="{StaticResource Label}"/>
              <ComboBox x:Name="CmbCType">
                <ComboBoxItem Tag="mp4" Content="MP4"/><ComboBoxItem Tag="mkv" Content="MKV"/>
              </ComboBox>
              <TextBlock Text="Picture" Style="{StaticResource Label}"/>
              <ComboBox x:Name="CmbCVideo">
                <ComboBoxItem Tag="h264" Content="H.264 (plays on nearly everything)"/><ComboBoxItem Tag="hevc" Content="HEVC (smaller files, newer players)"/>
              </ComboBox>
              <TextBlock Text="Sound" Style="{StaticResource Label}"/>
              <ComboBox x:Name="CmbCSound">
                <ComboBoxItem Tag="aac" Content="AAC"/><ComboBoxItem Tag="ac3" Content="Dolby Digital (AC-3)"/><ComboBoxItem Tag="eac3" Content="Dolby Digital Plus (E-AC-3)"/>
              </ComboBox>
              <TextBlock Text="Largest picture" Style="{StaticResource Label}"/>
              <ComboBox x:Name="CmbCSize">
                <ComboBoxItem Tag="2160" Content="4K (3840 x 2160)"/><ComboBoxItem Tag="1080" Content="1080p (1920 x 1080)"/><ComboBoxItem Tag="720" Content="720p (1280 x 720)"/>
              </ComboBox>
            </StackPanel>
            <TextBlock Text="Quality" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbQuality">
              <ComboBoxItem Tag="Best" Content="Best (bigger files)"/>
              <ComboBoxItem Tag="Balanced" Content="Balanced"/>
              <ComboBoxItem Tag="Smaller" Content="Smaller files"/>
            </ComboBox>
            <StackPanel x:Name="PanelFormat">
              <TextBlock Text="File type" Style="{StaticResource Label}"/>
              <ComboBox x:Name="CmbFileType">
                <ComboBoxItem Tag="Auto" Content="Keep MP4 or MKV when it plays"/>
                <ComboBoxItem Tag="mp4" Content="MP4 (plays on more things)"/>
                <ComboBoxItem Tag="mkv" Content="MKV (keeps every subtitle)"/>
              </ComboBox>
              <TextBlock Text="Picture format, when it has to be converted" Style="{StaticResource Label}"/>
              <ComboBox x:Name="CmbVideo">
                <ComboBoxItem Tag="Auto" Content="Automatic (H.264, or HEVC for 4K and HDR)"/>
                <ComboBoxItem Tag="h264" Content="H.264 (plays on nearly everything)"/>
                <ComboBoxItem Tag="hevc" Content="HEVC (smaller files, slower)"/>
              </ComboBox>
            </StackPanel>
            <TextBlock Text="Save the new videos" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbSave">
              <ComboBoxItem Tag="Beside" Content="Next to the original"/>
              <ComboBoxItem Tag="Folder" Content="In a folder I choose"/>
            </ComboBox>
            <DockPanel x:Name="PanelOut" Margin="0,8,0,0">
              <Button x:Name="BtnOut" DockPanel.Dock="Right" Content="Choose..." Margin="8,0,0,0"/>
              <TextBox x:Name="TxtOut" Height="32" IsReadOnly="True"/>
            </DockPanel>
            <TextBlock Text="The originals" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbOriginals">
              <ComboBoxItem Tag="Keep" Content="Keep them"/>
              <ComboBoxItem Tag="Recycle" Content="Send them to the Recycle Bin when done"/>
            </ComboBox>
            <CheckBox x:Name="ChkSrt" Content="Also save subtitles as .srt files beside the video" Margin="0,14,0,0"/>
            <CheckBox x:Name="ChkGpu" Content="Use the graphics card when it can (much faster, files a little bigger)" Margin="0,12,0,0"/>
            <TextBlock x:Name="TxtGpu" Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Margin="28,4,0,0"/>
            <TextBlock Text="When each video is done" Style="{StaticResource Label}" Margin="0,14,0,0"/>
            <ComboBox x:Name="CmbSend">
              <ComboBoxItem Tag="Off" Content="Leave it where it was saved"/>
              <ComboBoxItem Tag="Copy" Content="Copy it to a folder too"/>
              <ComboBoxItem Tag="Move" Content="Move it to a folder"/>
            </ComboBox>
            <DockPanel x:Name="PanelSend" Margin="0,8,0,0">
              <Button x:Name="BtnSend" DockPanel.Dock="Right" Content="Choose..." Margin="8,0,0,0"/>
              <TextBox x:Name="TxtSend" Height="32" IsReadOnly="True"/>
            </DockPanel>
            <TextBlock Text="When the whole list is done" Style="{StaticResource Label}"/>
            <ComboBox x:Name="CmbWhenDone">
              <ComboBoxItem Tag="Nothing" Content="Nothing else" IsSelected="True"/>
              <ComboBoxItem Tag="Sleep" Content="Put the PC to sleep"/>
              <ComboBoxItem Tag="Shutdown" Content="Shut the PC down"/>
            </ComboBox>
            <CheckBox x:Name="ChkNotify" Content="Tell me when it's done (a notification and a sound)"/>
            <DockPanel Margin="0,16,0,0">
              <Button x:Name="BtnFfmpeg" DockPanel.Dock="Right" Content="Change..." Padding="10,3" Margin="8,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TxtFfmpeg" Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/>
            </DockPanel>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)

$script:Items = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:Zoom = 1.0
$script:Run = $null        # the conversion list while it runs
$script:Thumb = $null      # the preview picture being made
$script:Sample = $null     # the 20-second sample being made
$script:Filter = ''

function Set-Status([string]$Text, [string]$Tone = 'Soft') {
    $script:UI.TxtStatus.Text = $Text
    $script:UI.TxtStatus.Foreground = Get-Brush $Tone
}

function Invoke-Safely([scriptblock]$Action) {
    try { & $Action }
    catch { Write-AppLog "Error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"; [void](Show-AppMessage "Something went wrong:`n$($_.Exception.Message)`n`nDetails are in $script:LogPath") }
}

function Select-ComboTag($Combo, [string]$Tag) {
    foreach ($it in $Combo.Items) { if ([string]$it.Tag -eq $Tag) { $Combo.SelectedItem = $it; return } }
    $Combo.SelectedIndex = 0
}

#region LIST
# ---------------------------------------------------------------------------
#  The list of videos
# ---------------------------------------------------------------------------
function Set-ItemLook($it) {
    <# Status pill and details line for one video, from its check against the target. #>
    $t = $script:Target
    switch ($it.State) {
        'Checking' { $it.Status = 'Checking'; $it.Pill = Get-Brush 'Soft'; return }
        'Error'    { $it.Status = "Can't read"; $it.Pill = Get-Brush 'Bad'; return }
        'Working'  { return }
        'Done'     { $it.Status = 'Done'; $it.Pill = Get-Brush 'Good'; return }
        'Failed'   { $it.Status = 'Failed'; $it.Pill = Get-Brush 'Bad'; return }
    }
    $i = $it.Info
    $v = Test-Video $i $t
    $it.Verdict = $v
    if ($v.Ok) { $it.State = 'Plays'; $it.Status = 'Plays'; $it.Pill = Get-Brush 'Good'; return }
    $it.State = 'Needs'
    $p = Get-Plan $i $t
    switch ($p.Action) {
        'Rewrap'  { $it.Status = 'Quick fix'; $it.Pill = Get-Brush 'Accent' }
        'Sound'   { $it.Status = 'Sound fix'; $it.Pill = Get-Brush 'Warn' }
        default   { $it.Status = 'Convert'; $it.Pill = Get-Brush 'Bad' }
    }
}

function Get-ItemDetails($i) {
    $bits = @()
    if ($i.VCodec) { $bits += ("$(Get-VideoName $i) $(Get-ResLabel $i.Width $i.Height)").Trim() }
    $main = Get-MainSound $i
    if ($main) { $bits += (Get-SoundName $main) + $(if ($i.Audio.Count -gt 1) { " (+$($i.Audio.Count - 1) more)" }) }
    if ($i.Subs.Count) { $bits += "$($i.Subs.Count) subtitle$(if ($i.Subs.Count -gt 1) { 's' })" }
    $bits += $i.Ext.ToUpper()
    if ($i.Seconds) { $bits += Format-Length $i.Seconds }
    if ($i.Bytes) { $bits += Format-Size $i.Bytes }
    return ($bits -join "  $script:Dot  ")
}

function Update-Summary {
    $all = @($script:Items)
    $ui = $script:UI
    $ui.PanelEmpty.Visibility = if ($all.Count) { 'Collapsed' } else { 'Visible' }
    $ui.BtnClear.IsEnabled = $all.Count -gt 0 -and -not $script:Run
    $needs = @($all | Where-Object { $_.State -eq 'Needs' })
    $plays = @($all | Where-Object { $_.State -eq 'Plays' }).Count
    $done = @($all | Where-Object { $_.State -eq 'Done' }).Count
    $bad = @($all | Where-Object { $_.State -in 'Error', 'Failed' }).Count
    $checking = @($all | Where-Object { $_.State -eq 'Checking' }).Count
    $working = @($all | Where-Object { $_.State -eq 'Working' }).Count
    if (-not $all.Count) { $ui.TxtSummary.Text = 'Add some videos to check them' }
    else {
        $p = @("$($all.Count) video$(if ($all.Count -ne 1) { 's' })")
        if ($checking) { $p += "$checking being checked" }
        if ($plays) { $p += "$plays play$(if ($plays -eq 1) { 's' })" }
        if ($working) { $p += 'converting 1' }
        if ($needs.Count) { $p += "$($needs.Count) need$(if ($needs.Count -eq 1) { 's' }) work" }
        if ($done) { $p += "$done done" }
        if ($bad) { $p += "$bad can't be read or failed" }
        $ui.TxtSummary.Text = $p -join "  $script:Dot  "
    }
    $ui.PillNeeds.Content = "Needs work ($($needs.Count))"
    $ui.PillPlays.Content = "Plays ($plays)"
    $ui.PillDone.Content = "Done ($done)"
    $ui.BtnConvert.Content = if ($needs.Count) { "Convert $($needs.Count)" } else { 'Convert' }
    $ui.BtnConvert.IsEnabled = $needs.Count -gt 0 -and -not $script:Run -and -not $script:StartAt -and [bool]$script:FFprobe
    if ($script:Filter -and $script:View) { $script:View.Refresh() }
}

function Update-Filter {
    $script:View.Refresh()
}

function Add-Paths([string[]]$Paths) {
    if (-not $script:FFprobe) { [void](Show-AppMessage 'FFmpeg is needed to check videos. Install it first (the box at the top shows how), then add the videos again.'); return }
    $Paths = @($Paths | Where-Object { $_ })
    if (-not $Paths.Count) { return }
    [VcProbe]::Start($script:FFprobe, [string[]]$Paths, [string[]]$script:VideoExt)
    $script:UI.Progress.IsIndeterminate = $true
    $script:UI.Progress.Visibility = 'Visible'
    Set-Status 'Checking the videos...'
}

function Receive-Checks {
    <# Takes what ffprobe found (from the background) into the list. #>
    $r = $null; $got = 0
    while ($got -lt 60 -and [VcProbe]::Results.TryDequeue([ref]$r)) {
        $got++
        $path = $r[0]
        if (@($script:Items | Where-Object { $_.Path -eq $path }).Count) { continue }    # already in the list
        $it = New-Object VcItem
        $it.Path = $path; $it.Name = [IO.Path]::GetFileName($path); $it.Folder = [IO.Path]::GetDirectoryName($path)
        if ($r[1]) {
            try {
                $it.Info = ConvertFrom-Probe $path $r[1]
                $it.Details = Get-ItemDetails $it.Info
                $it.State = if ($it.Info.VCodec) { '' } else { 'Error' }
                if (-not $it.Info.VCodec) { $it.Error = 'No video found in it' }
            } catch { $it.State = 'Error'; $it.Error = $_.Exception.Message; $it.Details = $it.Folder }
        } else {
            $it.State = 'Error'
            $it.Error = if ($r[2]) { ($r[2] -split "`n")[-1] } else { 'ffprobe could not read it' }
            $it.Details = "$($it.Folder)  $script:Dot  $($it.Error)"
        }
        Set-ItemLook $it
        $back = $script:Restore[$path]
        if ($back) {
            $script:Restore.Remove($path)
            if ($back.State -eq 'Done' -and $back.OutPath -and (Test-Path -LiteralPath $back.OutPath)) {
                $it.OutPath = $back.OutPath; $it.State = 'Done'; Set-ItemLook $it
                $it.Details = "$script:Arrow $([IO.Path]::GetFileName($back.OutPath))  $script:Dot  $(Format-Size (Get-Item -LiteralPath $back.OutPath).Length) (was $(Format-Size $it.Info.Bytes))"
            }
        }
        $script:Items.Add($it)
    }
    if ($got) { Update-Summary }
    if (-not [VcProbe]::Busy -and [VcProbe]::Results.IsEmpty -and $script:UI.Progress.IsIndeterminate) {
        $script:UI.Progress.IsIndeterminate = $false
        if (-not $script:Run) { $script:UI.Progress.Visibility = 'Hidden' }
        $needs = @($script:Items | Where-Object { $_.State -eq 'Needs' }).Count
        if (-not $script:Items.Count) { Set-Status 'No videos found there.' 'Warn' }
        elseif ($needs) { Set-Status "Checked. $needs video$(if ($needs -ne 1) { 's' }) won't play as they are: click one to see why, or press Convert." }
        else { Set-Status 'Checked. Everything in the list should play as it is.' 'Good' }
        if (-not $script:UI.LstVideos.SelectedItem -and $script:Items.Count) { $script:UI.LstVideos.SelectedIndex = 0 }
    }
}

function Update-AllChecks {
    <# The target or a choice changed: check every video again. #>
    $script:Target = Get-Target
    foreach ($it in $script:Items) {
        if ($it.State -in 'Plays', 'Needs') { $it.State = ''; Set-ItemLook $it }
    }
    Update-Summary
    Update-Filter
    Show-Preview
    if ($script:Items.Count -and -not $script:Run -and -not [VcProbe]::Busy) {
        $needs = @($script:Items | Where-Object { $_.State -eq 'Needs' }).Count
        if ($needs) { Set-Status "Checked again for $($script:Settings.Target): $needs video$(if ($needs -ne 1) { 's' }) won't play as they are." }
        else { Set-Status "Checked again for $($script:Settings.Target): everything left in the list should play." 'Good' }
    }
}

function Remove-Selected {
    $sel = @($script:UI.LstVideos.SelectedItems)
    foreach ($it in $sel) { if ($it.State -ne 'Working') { [void]$script:Items.Remove($it) } }
    Update-Summary
    Show-Preview
}
#endregion LIST

#region PREVIEW
# ---------------------------------------------------------------------------
#  The right-hand side: a picture from the video, what's in it, and why
# ---------------------------------------------------------------------------
function Get-ThumbPath([string]$Path) {
    $fi = Get-Item -LiteralPath $Path
    $md5 = [Security.Cryptography.MD5]::Create()
    $key = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Path|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"))).Replace('-', '')
    $dir = Join-Path $script:TempDir 'previews'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir "$key.jpg")
}

function Show-Preview {
    $ui = $script:UI
    $it = $ui.LstVideos.SelectedItem
    $ui.BtnPlay.IsEnabled = [bool]$it; $ui.BtnFolder.IsEnabled = [bool]$it
    $ui.BtnUtils.IsEnabled = [bool]($it -and $it.Info -and $it.Info.VCodec -and $it.State -ne 'Working' -and [bool]$script:FFmpeg)
    $ui.BtnSample.IsEnabled = [bool]($it -and $it.State -eq 'Needs' -and -not $script:Run -and -not $script:Sample)
    $ui.BtnRemove.IsEnabled = $ui.LstVideos.SelectedItems.Count -gt 0
    if (-not $it) {
        $ui.ImgPreview.Source = $null; $ui.TxtNoPicture.Text = 'Click a video to see it here'; $ui.TxtNoPicture.Visibility = 'Visible'
        foreach ($n in 'TxtPrvName', 'TxtPrvFacts', 'TxtVerdict', 'TxtReasons', 'TxtSteps') { $ui[$n].Text = '' }
        $ui.TxtStepsHead.Visibility = 'Collapsed'
        return
    }
    $ui.TxtPrvName.Text = $it.Name
    $i = $it.Info
    # Facts: picture, each sound track and the subtitles
    if ($i -and $i.VCodec) {
        $facts = @("Picture: $(Get-VideoName $i), $($i.Width)x$($i.Height)$(if ($i.Interlaced) { ', interlaced' })")
        $k = 1
        foreach ($a in $i.Audio) {
            $facts += "Sound $(if ($i.Audio.Count -gt 1) { "$k" }): $(Get-SoundName $a)$(if ($a.Lang -and $a.Lang -ne 'und') { ", $($a.Lang)" })$(if ($a.Title) { ", $($a.Title)" })".Replace('Sound :', 'Sound:')
            $k++
        }
        if ($i.Subs.Count) { $facts += "Subtitles: " + ((@($i.Subs | ForEach-Object { "$(Get-CodecName $_.Codec)$(if ($_.Lang -and $_.Lang -ne 'und') { " $($_.Lang)" })$(if ($_.Forced) { ' (forced)' })" })) -join ', ') }
        $facts += "File: .$($i.Ext)  $script:Dot  $(Format-Length $i.Seconds)  $script:Dot  $(Format-Size $i.Bytes)"
        $facts += $it.Folder
        $ui.TxtPrvFacts.Text = $facts -join "`n"
    } else { $ui.TxtPrvFacts.Text = $it.Folder }

    # Verdict, reasons and steps
    $ui.TxtSteps.Text = ''; $ui.TxtStepsHead.Visibility = 'Collapsed'
    $tname = [string]$script:Settings.Target
    switch ($it.State) {
        'Error' { $ui.TxtVerdict.Text = "Can't be read"; $ui.TxtVerdict.Foreground = Get-Brush 'Bad'; $ui.TxtReasons.Text = $it.Error; $ui.TxtReasons.Foreground = Get-Brush 'Soft' }
        'Checking' { $ui.TxtVerdict.Text = 'Being checked...'; $ui.TxtVerdict.Foreground = Get-Brush 'Soft'; $ui.TxtReasons.Text = '' }
        'Done' { $ui.TxtVerdict.Text = 'Converted'; $ui.TxtVerdict.Foreground = Get-Brush 'Good'; $ui.TxtReasons.Text = "New file: $($it.OutPath)"; $ui.TxtReasons.Foreground = Get-Brush 'Soft' }
        'Failed' { $ui.TxtVerdict.Text = "Couldn't be converted"; $ui.TxtVerdict.Foreground = Get-Brush 'Bad'; $ui.TxtReasons.Text = $it.Error; $ui.TxtReasons.Foreground = Get-Brush 'Soft' }
        'Working' {
            $ui.TxtVerdict.Text = 'Being converted now'; $ui.TxtVerdict.Foreground = Get-Brush 'Accent'; $ui.TxtReasons.Text = ''
            if ($script:Run -and $script:Run.Plan) { $ui.TxtStepsHead.Visibility = 'Visible'; $ui.TxtSteps.Text = (@($script:Run.Plan.Steps) | ForEach-Object { "$script:Dot $_" }) -join "`n" }
        }
        default {
            $v = $it.Verdict
            if ($v.Ok) {
                $ui.TxtVerdict.Text = "Should play on: $tname"; $ui.TxtVerdict.Foreground = Get-Brush 'Good'
                $ui.TxtReasons.Text = (@($v.Notes) | ForEach-Object { "$script:Dot $_" }) -join "`n"; $ui.TxtReasons.Foreground = Get-Brush 'Soft'
            } else {
                $ui.TxtVerdict.Text = "Won't play as it is on: $tname"; $ui.TxtVerdict.Foreground = Get-Brush 'Bad'
                $ui.TxtReasons.Text = ((@($v.Reasons) + @($v.Notes)) | ForEach-Object { "$script:Dot $_" }) -join "`n"; $ui.TxtReasons.Foreground = Get-Brush 'Ink'
                $p = Get-Plan $i $script:Target
                $ui.TxtStepsHead.Visibility = 'Visible'
                $ui.TxtSteps.Text = (@($p.Steps) | ForEach-Object { "$script:Dot $_" }) -join "`n"
            }
        }
    }

    # The picture: made in the background (cached), shown when ready.
    $show = if ($it.State -eq 'Done' -and $it.OutPath -and (Test-Path -LiteralPath $it.OutPath)) { $it.OutPath } else { $it.Path }
    $ui.ImgPreview.Source = $null
    if (-not $i -or -not $i.VCodec -or -not $script:FFmpeg -or -not (Test-Path -LiteralPath $show)) { $ui.TxtNoPicture.Text = 'No picture'; $ui.TxtNoPicture.Visibility = 'Visible'; return }
    $thumb = Get-ThumbPath $show
    if (Test-Path -LiteralPath $thumb) { $ui.ImgPreview.Source = Get-ImageFromFile $thumb; $ui.TxtNoPicture.Visibility = 'Collapsed'; return }
    $ui.TxtNoPicture.Text = 'Making a picture...'; $ui.TxtNoPicture.Visibility = 'Visible'
    if ($script:Thumb -and -not $script:Thumb.Job.Done) { $script:Thumb.Job.Stop() }
    $at = if ($i.Seconds -gt 30) { [math]::Round($i.Seconds * 0.2, 1) } elseif ($i.Seconds -gt 2) { [math]::Round($i.Seconds / 2, 1) } else { 0 }
    $vf = if ($i.Hdr -and $script:Can.Zscale -and $i.Transfer -in 'smpte2084', 'arib-std-b67') { 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,scale=720:-2' } else { 'scale=720:-2' }
    $job = New-Object VcRun
    $job.Start($script:FFmpeg, (Join-Args @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-ss', ('{0:0.#}' -f $at).Replace(',', '.'), '-i', $show, '-map', "0:$($i.VIndex)", '-frames:v', '1', '-vf', $vf, '-q:v', '3', $thumb)))
    $script:Thumb = @{ Job = $job; Item = $it; Path = $thumb }
}

function Receive-Thumb {
    $t = $script:Thumb
    if (-not $t -or -not $t.Job.Done) { return }
    $script:Thumb = $null
    if ($script:UI.LstVideos.SelectedItem -ne $t.Item) { return }
    $img = Get-ImageFromFile $t.Path
    if ($img) { $script:UI.ImgPreview.Source = $img; $script:UI.TxtNoPicture.Visibility = 'Collapsed' }
    else { $script:UI.TxtNoPicture.Text = 'No picture could be made'; Write-AppLog "Preview picture failed: $($t.Job.Tail)" }
}

function Start-Sample {
    $it = $script:UI.LstVideos.SelectedItem
    if (-not $it -or $it.State -ne 'Needs' -or $script:Sample) { return }
    $i = $it.Info
    $p = Get-Plan $i $script:Target
    Get-ChildItem -LiteralPath $script:TempDir -Filter 'Sample - *' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $out = Join-Path $script:TempDir ("Sample - " + [IO.Path]::GetFileNameWithoutExtension($it.Name) + ".$($p.Out)")
    $start = if ($i.Seconds -gt 40) { [math]::Round($i.Seconds / 3, 1) } else { 0 }
    $job = New-Object VcRun
    $job.Start($script:FFmpeg, (Get-FfmpegArgs $i $p $it.Path $out $start))
    $script:Sample = @{ Gpu = $p.Gpu; Job = $job; Item = $it; Out = $out; Seconds = [math]::Min(20, [math]::Max(1, $i.Seconds - $start)) }
    $script:UI.BtnSample.IsEnabled = $false
    $script:UI.BtnSample.Content = 'Making the sample...'
    Set-Status "Converting 20 seconds of $($it.Name) to try..."
    Write-AppLog "Sample of $($it.Path): $($p.Action)"
}

function Receive-Sample {
    $s = $script:Sample
    if (-not $s) { return }
    if (-not $s.Job.Done) { $script:UI.BtnSample.Content = "Making the sample ($([int]([math]::Min(99, 100 * $s.Job.OutSeconds / $s.Seconds)))%)"; return }
    $script:Sample = $null
    $script:UI.BtnSample.Content = 'Try 20 seconds'
    Show-Preview
    if ($s.Job.ExitCode -ne 0 -and $s.Gpu) {
        $script:GpuBroken = $true
        Write-AppLog "Graphics card ($($s.Gpu)) failed on a sample, so the processor is used from now on: $($s.Job.Tail)"
        Show-Options
        $script:UI.LstVideos.SelectedItem = $s.Item
        Start-Sample
        return
    }
    if ($s.Job.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $s.Out)) {
        Write-AppLog "Sample failed ($($s.Job.ExitCode)): $($s.Job.Tail)"
        Set-Status "The sample couldn't be made: $(($s.Job.Tail -split "`n")[-1])" 'Bad'
        return
    }
    $size = (Get-Item -LiteralPath $s.Out).Length
    $whole = $size / $s.Seconds * $s.Item.Info.Seconds
    Set-Status "Sample ready and playing. The whole video would be about $(Format-Size $whole) (it's $(Format-Size $s.Item.Info.Bytes) now)." 'Good'
    try { Start-Process -FilePath $s.Out } catch { [void](Show-AppMessage "The sample is ready, but no player opened it:`n$($s.Out)") }
}
#endregion PREVIEW

#region CONVERT
# ---------------------------------------------------------------------------
#  Converting the list, one video at a time
# ---------------------------------------------------------------------------
function Get-FreeName([string]$Dir, [string]$Base, [string]$Ext, [string]$Original) {
    <# A file name for the new video that isn't taken (and isn't the original). #>
    $p = Join-Path $Dir "$Base.$Ext"
    if ($p -ne $Original -and -not (Test-Path -LiteralPath $p)) { return $p }
    $n = 1
    while ($true) {
        $label = if ($n -eq 1) { 'converted' } else { "converted $n" }
        $p = Join-Path $Dir "$Base ($label).$Ext"
        if (-not (Test-Path -LiteralPath $p)) { return $p }
        $n++
    }
}

function Get-SrtSuffix($Sub, [int]$N) {
    $lang = if ($Sub.Lang -and $Sub.Lang -ne 'und') { $Sub.Lang } else { "$N" }
    return ".$lang$(if ($Sub.Forced) { '.forced' })"
}

function Start-Convert {
    $list = @($script:Items | Where-Object { $_.State -eq 'Needs' })
    if (-not $list.Count) { return }
    $s = $script:Settings
    if ($s.SaveTo -eq 'Folder' -and (-not $s.OutFolder -or -not (Test-Path -LiteralPath $s.OutFolder))) {
        if (-not (Select-OutFolder)) { return }
    }
    $total = 0.0; foreach ($it in $list) { $total += [math]::Max(1, $it.Info.Seconds) }
    $script:Run = @{ List = $list; Index = -1; Job = $null; Item = $null; Total = $total; DoneSecs = 0.0; Watch = New-Object Diagnostics.Stopwatch; Good = 0; Bad = 0; Stopping = $false; StartSecs = 0.0 }
    [VcRun]::KeepAwake($true)
    $ui = $script:UI
    $ui.BtnPause.Visibility = 'Visible'; $ui.BtnStop.Visibility = 'Visible'; $ui.BtnPause.Content = 'Pause'
    foreach ($b in 'BtnConvert', 'BtnClear', 'BtnSample', 'CmbTarget') { $ui[$b].IsEnabled = $false }
    $ui.BtnStop.Content = "Stop"
    $ui.Progress.IsIndeterminate = $false; $ui.Progress.Value = 0; $ui.Progress.Visibility = 'Visible'
    $script:Window.TaskbarItemInfo.ProgressState = 'Normal'
    Write-AppLog "Converting $($list.Count) video(s) for $($s.Target)"
    Start-NextVideo
}

function Start-NextVideo {
    $r = $script:Run
    $r.Index++
    if ($r.Index -ge $r.List.Count -or $r.Stopping) { Stop-Convert; return }
    $it = $r.List[$r.Index]
    if ($it.State -ne 'Needs' -or -not $script:Items.Contains($it)) { Start-NextVideo; return }
    $i = $it.Info
    $s = $script:Settings
    try {
        if (-not (Test-Path -LiteralPath $it.Path)) { throw 'The file isn''t there any more.' }
        $p = Get-Plan $i $script:Target
        $dir = if ($s.SaveTo -eq 'Folder') { $s.OutFolder } else { $it.Folder }
        $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
        $final = Get-FreeName $dir $base $p.Out $it.Path
        $part = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($final) + ".converting.$($p.Out)")
        # Enough room? Roughly the original's size (smaller when the picture is converted).
        try {
            $root = [IO.Path]::GetPathRoot($dir)
            if ($root -match '^[A-Za-z]:\\$') {
                $free = (New-Object IO.DriveInfo $root).AvailableFreeSpace
                if ($free -lt $i.Bytes * 1.05 + 200MB) { throw "Not enough free space on $root ($(Format-Size $free) free, about $(Format-Size $i.Bytes) needed)." }
            }
        } catch [IO.IOException] { Write-AppLog "Free space not known: $($_.Exception.Message)" }
        $srtPaths = @()
        $newBase = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($final))
        for ($k = 0; $k -lt $p.Srt.Count; $k++) {
            $sp = $newBase + (Get-SrtSuffix $p.Srt[$k] ($k + 1)) + '.srt'
            if (Test-Path -LiteralPath $sp) { $sp = $newBase + (Get-SrtSuffix $p.Srt[$k] ($k + 1)) + '.converted.srt' }
            $srtPaths += $sp
        }
        $ffArgs = Get-FfmpegArgs $i $p $it.Path $part -1 $srtPaths
        Write-AppLog "Start $($it.Path) -> $final ($($p.Action)): ffmpeg $ffArgs"
        $job = New-Object VcRun
        $job.Start($script:FFmpeg, $ffArgs)
        $r.Job = $job; $r.Item = $it; $r.Plan = $p; $r.Part = $part; $r.Final = $final; $r.SrtPaths = $srtPaths; $r.Dir = $dir
        $it.State = 'Working'; $it.Status = 'Starting'; $it.Pill = Get-Brush 'Accent'; $it.Progress = 0.5
        $r.Watch.Start()
        Update-Summary
        $script:UI.LstVideos.ScrollIntoView($it)
    } catch {
        $it.State = 'Failed'; $it.Error = $_.Exception.Message; Set-ItemLook $it
        $r.Bad++; $r.DoneSecs += [math]::Max(1, $i.Seconds)
        Write-AppLog "Couldn't start $($it.Path): $($_.Exception.Message)"
        Update-Summary
        Start-NextVideo
    }
}

function Complete-Video {
    <# ffmpeg has finished one: check the new file, put it in place, tidy up. #>
    $r = $script:Run
    $it = $r.Item; $job = $r.Job; $i = $it.Info
    $r.Job = $null; $r.Item = $null
    $r.DoneSecs += [math]::Max(1, $i.Seconds)
    $it.Progress = 0
    $cleanup = { Remove-Item -LiteralPath $r.Part -Force -ErrorAction SilentlyContinue; foreach ($sp in $r.SrtPaths) { Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue } }
    if ($r.Stopping) {
        & $cleanup
        $it.State = ''; Set-ItemLook $it
        Write-AppLog "Stopped: $($it.Path)"
        return
    }
    if ($job.ExitCode -ne 0 -and $r.Plan.Gpu) {
        # The graphics card failed: the processor is used from now on, starting with this video again.
        & $cleanup
        $script:GpuBroken = $true
        Write-AppLog "Graphics card ($($r.Plan.Gpu)) failed on $($it.Path), so the processor is used from now on: $($job.Tail)"
        $it.State = 'Needs'
        $r.DoneSecs -= [math]::Max(1, $i.Seconds)
        $r.Index--
        Show-Options
        return
    }
    try {
        if ($job.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $r.Part)) {
            $last = @($job.Tail -split "`n" | Where-Object { $_ }) | Select-Object -Last 1
            throw "FFmpeg stopped with an error: $last"
        }
        # The new file must be as long as the original before anything else happens.
        $err = ''
        $len = [VcProbe]::Run($script:FFprobe, (Join-Args @('-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', $r.Part)), 60000, [ref]$err)
        $newSecs = 0.0; [void][double]::TryParse($len.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$newSecs)
        if ($i.Seconds -gt 5 -and $newSecs -lt $i.Seconds * 0.98 - 1) { throw "The new file is shorter than the original ($(Format-Length $newSecs) of $(Format-Length $i.Seconds)), so it was deleted." }
        Move-Item -LiteralPath $r.Part -Destination $r.Final
        $final = $r.Final
        # Subtitle files already beside the original go with it to another folder.
        $oldBase = Join-Path $it.Folder ([IO.Path]::GetFileNameWithoutExtension($it.Name))
        $newBase = Join-Path $r.Dir ([IO.Path]::GetFileNameWithoutExtension($final))
        if ($oldBase -ne $newBase) {
            foreach ($ext in '.srt', '.ass', '.ssa', '.vtt', '.sub', '.idx', '.sup') {
                foreach ($f in @(Get-ChildItem -LiteralPath $it.Folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith([IO.Path]::GetFileNameWithoutExtension($it.Name) + '.', [StringComparison]::OrdinalIgnoreCase) -and $_.Extension -eq $ext })) {
                    $to = $newBase + $f.Name.Substring([IO.Path]::GetFileNameWithoutExtension($it.Name).Length)
                    if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath $f.FullName -Destination $to }
                }
            }
        }
        # The original to the Recycle Bin, if chosen; the new file then takes its name when it had "(converted)".
        if ($script:Settings.Originals -eq 'Recycle') {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($it.Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
            Write-AppLog "Recycled $($it.Path)"
            $plain = Join-Path $r.Dir ([IO.Path]::GetFileNameWithoutExtension($it.Name) + ".$($r.Plan.Out)")
            if ($final -ne $plain -and -not (Test-Path -LiteralPath $plain)) { Move-Item -LiteralPath $final -Destination $plain; $final = $plain }
        }
        $it.OutPath = $final
        $it.State = 'Done'; Set-ItemLook $it
        $newSize = (Get-Item -LiteralPath $final).Length
        $it.Details = "$script:Arrow $([IO.Path]::GetFileName($final))  $script:Dot  $(Format-Size $newSize) (was $(Format-Size $i.Bytes))"
        $r.Good++
        Write-AppLog "Done $final ($(Format-Size $newSize))"
        Add-AllTimeStats $i.Seconds $i.Bytes $newSize
        # Copy or move it (and its .srt files) to the chosen folder, in the background.
        $sm = $script:Settings.SendMode; $sf = $script:Settings.SendFolder
        if ($sm -in 'Copy', 'Move' -and $sf -and (Test-Path -LiteralPath $sf) -and ([IO.Path]::GetDirectoryName($final) -ne $sf.TrimEnd('\'))) {
            $name = [IO.Path]::GetFileNameWithoutExtension($final); $ext = [IO.Path]::GetExtension($final)
            $dest = Join-Path $sf "$name$ext"; $n = 2
            while (Test-Path -LiteralPath $dest) { $dest = Join-Path $sf "$name ($n)$ext"; $n++ }
            foreach ($sp in @($r.SrtPaths | Where-Object { Test-Path -LiteralPath $_ })) {
                $to = Join-Path $sf ([IO.Path]::GetFileNameWithoutExtension($dest) + [IO.Path]::GetFileName($sp).Substring($name.Length))
                if (-not (Test-Path -LiteralPath $to)) { if ($sm -eq 'Move') { Move-Item -LiteralPath $sp -Destination $to } else { Copy-Item -LiteralPath $sp -Destination $to } }
            }
            $cp = New-Object VcCopy
            $cp.Start($final, $dest, ($sm -eq 'Move'))
            $r.Send = @{ Copy = $cp; Item = $it; Dest = $dest; Move = ($sm -eq 'Move'); Folder = $sf }
            $it.Status = 'Copying'; $it.Pill = Get-Brush 'Accent'
            Write-AppLog "$sm to $dest"
        }
    } catch {
        & $cleanup
        $it.State = 'Failed'; $it.Error = $_.Exception.Message; Set-ItemLook $it
        $r.Bad++
        Write-AppLog "Failed $($it.Path): $($_.Exception.Message)`n$($job.Tail)"
    }
    Update-Summary
    if ($script:UI.LstVideos.SelectedItem -eq $it) { Show-Preview }
}

function Update-Convert {
    $r = $script:Run
    if (-not $r) { return }
    if ($r.Send) {
        # Waiting for the finished video to reach the chosen folder before the next one starts.
        $c = $r.Send
        if (-not $c.Copy.Done) {
            $pc = if ($c.Copy.Total) { [int](100 * $c.Copy.Copied / $c.Copy.Total) } else { 0 }
            $c.Item.Status = "Copying $pc%"
            Set-Status "$(if ($c.Move) { 'Moving' } else { 'Copying' }) $($c.Item.Name) to $($c.Folder)  $script:Dot  $pc%"
            return
        }
        $r.Send = $null
        $it = $c.Item
        $it.State = 'Done'; Set-ItemLook $it
        if ($c.Copy.Error) {
            $it.Details += "  $script:Dot  couldn't $(if ($c.Move) { 'move' } else { 'copy' }) it to $($c.Folder): $($c.Copy.Error)"
            Write-AppLog "Copy failed: $($c.Copy.Error)"
        } else {
            if ($c.Move) { $it.OutPath = $c.Dest }
            $it.Details += "  $script:Dot  $(if ($c.Move) { 'moved' } else { 'copied' }) to $($c.Folder)"
        }
        if ($script:UI.LstVideos.SelectedItem -eq $it) { Show-Preview }
        Start-NextVideo
        return
    }
    if (-not $r.Job) { return }
    $job = $r.Job; $it = $r.Item
    if ($job.Done) { $r.Watch.Stop(); Complete-Video; if (-not $r.Send) { Start-NextVideo }; return }
    $secs = [math]::Max(1, $it.Info.Seconds)
    $doneHere = [math]::Min($job.OutSeconds, $secs)
    $pc = [math]::Min(99.5, 100 * $doneHere / $secs)
    $it.Progress = [math]::Max(0.5, $pc)
    $it.Status = if ($job.Paused) { 'Paused' } else { "$([int]$pc)%" }
    $all = [math]::Min(100, 100 * ($r.DoneSecs + $doneHere) / $r.Total)
    $script:UI.Progress.Value = $all
    $script:Window.TaskbarItemInfo.ProgressValue = $all / 100
    $script:Window.TaskbarItemInfo.ProgressState = if ($job.Paused) { 'Paused' } else { 'Normal' }
    $el = $r.Watch.Elapsed.TotalSeconds
    $speed = if ($el -gt 4) { ($r.DoneSecs + $doneHere - $r.StartSecs) / $el } else { 0 }
    $left = if ($speed -gt 0) { Format-TimeLeft (($r.Total - $r.DoneSecs - $doneHere) / $speed) } else { 'working out the time left' }
    $what = if ($job.Paused) { 'Paused' } else { 'Converting' }
    Set-Status "$what $($r.Index + 1) of $($r.List.Count): $($it.Name)  $script:Dot  $([int]$all)% of the list  $script:Dot  $left"
}

function Stop-Convert {
    $r = $script:Run
    $script:Run = $null
    [VcRun]::KeepAwake($false)
    $ui = $script:UI
    $ui.BtnPause.Visibility = 'Collapsed'; $ui.BtnStop.Visibility = 'Collapsed'
    $ui.CmbTarget.IsEnabled = $true
    $ui.Progress.Visibility = 'Hidden'
    $script:Window.TaskbarItemInfo.ProgressState = 'None'
    Update-Summary
    Show-Preview
    $msg = "Finished: $($r.Good) converted"
    if ($r.Bad) { $msg += ", $($r.Bad) failed (click one to see why)" }
    if ($r.Stopping) { $msg = "Stopped. $($r.Good) converted before that." }
    Set-Status $msg $(if ($r.Bad) { 'Warn' } else { 'Good' })
    Write-AppLog $msg
    $ui.BtnStop.Content = 'Stop'
    if (-not $r.Stopping) {
        if ($script:Settings.Notify) { Show-DoneNotice $msg }
        $action = [string]$ui.CmbWhenDone.SelectedItem.Tag
        if ($action -in 'Sleep', 'Shutdown') { $ui.CmbWhenDone.SelectedIndex = 0; Start-PowerCountdown $action; return }
    }
    if (-not $script:Window.IsActive -and -not $r.Stopping) { try { $script:Window.Activate() | Out-Null } catch { Write-Verbose 'not activated' } }
}

function Switch-Pause {
    $r = $script:Run
    if (-not $r -or -not $r.Job) { return }
    if ($r.Job.Paused) { $r.Job.Resume(); $r.Watch.Start(); $script:UI.BtnPause.Content = 'Pause'; [VcRun]::KeepAwake($true) }
    else { $r.Job.Pause(); $r.Watch.Stop(); $script:UI.BtnPause.Content = 'Resume'; [VcRun]::KeepAwake($false) }
    Update-Convert
}

function Request-Stop {
    if (-not $script:Run -and $script:StartAt) {
        $script:StartAt = $null
        $script:UI.BtnStop.Visibility = 'Collapsed'; $script:UI.BtnStop.Content = 'Stop'
        Update-Summary
        Set-Status 'Cancelled: it won''t start at the set time.'
        return $true
    }
    if (-not $script:Run) { return $true }
    if (-not (Show-AppMessage "Stop converting?`n`nThe video being converted now is left as it was, and its part-made file is deleted. Videos already done are kept." -YesText 'Stop' -NoText 'Carry on')) { return $false }
    $r = $script:Run
    if (-not $r) { return $true }
    $r.Stopping = $true
    if ($r.Job) { $r.Job.Stop() } else { Stop-Convert }
    return $true
}

function Select-SendFolder {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder to copy or move each finished video to (your NAS films folder, say).'
    if ($script:Settings.SendFolder -and (Test-Path -LiteralPath $script:Settings.SendFolder)) { $dlg.SelectedPath = $script:Settings.SendFolder }
    if ($dlg.ShowDialog() -ne 'OK') { return $false }
    $script:Settings.SendFolder = $dlg.SelectedPath
    Save-AppSetting
    Show-Options
    return $true
}

function Select-OutFolder {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the folder for the new videos.'
    if ($script:Settings.OutFolder -and (Test-Path -LiteralPath $script:Settings.OutFolder)) { $dlg.SelectedPath = $script:Settings.OutFolder }
    if ($dlg.ShowDialog() -ne 'OK') { return $false }
    $script:Settings.OutFolder = $dlg.SelectedPath
    Save-AppSetting
    Show-Options
    return $true
}
#endregion CONVERT

#region UTILITIES
# ---------------------------------------------------------------------------
#  Utilities for one video: keep or remove tracks, trim, save the sound,
#  subtitles or a picture, even out quiet sound, turn the picture, remove tags.
#  Each saves a new file ("Name (what).ext") and leaves the original alone.
# ---------------------------------------------------------------------------
$script:AudioExt = @{ aac = 'm4a'; ac3 = 'ac3'; eac3 = 'eac3'; dts = 'dts'; mp3 = 'mp3'; mp2 = 'mp2'; flac = 'flac'; opus = 'opus'; vorbis = 'ogg'; alac = 'm4a' }

function Get-TimeSeconds([string]$Text) {
    <# "1:02:03", "2:03", "75" or "1:02.5" as seconds, or -1 if it isn't a time. #>
    $t = $Text.Trim().Replace(',', '.')
    if ($t -notmatch '^\d+(\.\d+)?(:\d{1,2}(\.\d+)?){0,2}$') { return -1 }
    $sec = 0.0
    foreach ($part in $t.Split(':')) { $sec = $sec * 60 + [double]::Parse($part, [Globalization.CultureInfo]::InvariantCulture) }
    return $sec
}

function Format-Time([double]$Seconds) {
    $ts = [TimeSpan]::FromSeconds([math]::Max(0, $Seconds))
    return '{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

function Test-DisplayRotation {
    <# FFmpeg 6 and later can turn a picture by changing a tag (-display_rotation), with no converting. #>
    if ($null -eq $script:CanRotate) {
        $err = ''
        try { $script:CanRotate = ([VcProbe]::Run($script:FFmpeg, '-hide_banner -h full', 30000, [ref]$err)) -match 'display_rotation' } catch { $script:CanRotate = $false }
    }
    return $script:CanRotate
}

function Get-KeepArgs($i, [int[]]$Audio, [int[]]$Subs, [int]$Main, [string]$Out) {
    <# -map and copy arguments that keep the picture, the given sound and subtitle tracks and the chapters, unchanged.
       Text subtitles become MP4 text in MP4 files; picture subtitles can't go in one, so they're left out. #>
    $mp4 = $Out -in 'mp4', 'm4v', 'mov'
    $a = @('-map', "0:$($i.VIndex)")
    foreach ($x in $Audio) { $a += '-map', "0:$x" }
    $keptSubs = @($i.Subs | Where-Object { $Subs -contains $_.Index -and (-not $mp4 -or $_.Text) })
    foreach ($s in $keptSubs) { $a += '-map', "0:$($s.Index)" }
    if ($Out -eq 'mkv' -and $i.Attach) { $a += '-map', '0:t?' }
    $a += '-map_metadata', '0', '-map_chapters', '0', '-c', 'copy'
    if ($mp4 -and $keptSubs.Count) { $a += '-c:s', 'mov_text' }
    if ($mp4 -and $i.VCodec -eq 'hevc') { $a += '-tag:v:0', 'hvc1' }
    for ($k = 0; $k -lt $Audio.Count; $k++) { $a += "-disposition:a:$k", $(if ($Audio[$k] -eq $Main) { 'default' } else { '0' }) }
    if ($mp4) { $a += '-movflags', '+faststart' }
    return $a
}

function Get-UtilOutPath($it, [string]$What, [string]$Ext) {
    <# "<name> (<what>).<ext>" where the settings say new files go, never over an existing file. #>
    $dir = if ($script:Settings.SaveTo -eq 'Folder' -and $script:Settings.OutFolder -and (Test-Path -LiteralPath $script:Settings.OutFolder)) { $script:Settings.OutFolder } else { $it.Folder }
    $base = [IO.Path]::GetFileNameWithoutExtension($it.Name) + " ($What)"
    $p = Join-Path $dir "$base.$Ext"; $n = 2
    while (Test-Path -LiteralPath $p) { $p = Join-Path $dir "$base $n.$Ext"; $n++ }
    return $p
}

function Show-Utilities {
    $it = $script:UI.LstVideos.SelectedItem
    if (-not $it -or -not $it.Info -or -not $it.Info.VCodec -or -not (Test-Path -LiteralPath $it.Path)) { return }
    $i = $it.Info
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="760" Height="760" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="14" Background="{Page}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel x:Name="URoot" Margin="18,14,18,14">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock x:Name="UName" FontSize="18" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="UFacts" Foreground="{Soft}" FontSize="12" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
      <TextBlock Foreground="{Soft}" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Text="Each of these saves a new file, named after the original with what was done in brackets. The original is never changed."/>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,12,0,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="UOpen" Content="Open folder" Visibility="Collapsed"/>
          <Button x:Name="UCancel" Content="Stop" Visibility="Collapsed"/>
          <Button x:Name="UClose" Content="Close" Margin="0" IsCancel="True"/>
        </StackPanel>
        <StackPanel VerticalAlignment="Center" Margin="0,0,12,0">
          <TextBlock x:Name="UStatus" TextWrapping="Wrap" Foreground="{Soft}" Text="Pick what to do below."/>
          <ProgressBar x:Name="UProgress" Height="4" Margin="0,6,0,0" Foreground="{Accent}" Background="{Line}" BorderThickness="0" Maximum="100" Visibility="Collapsed"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="0,12,0,0">
      <StackPanel x:Name="UBody">
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14">
          <StackPanel>
            <TextBlock Text="Sound and subtitle tracks" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="Untick the tracks you don't want (a language you never use, a commentary, a second copy of the sound). Nothing is converted, so it takes seconds."/>
            <StackPanel x:Name="UTracks" Margin="0,4,0,0"/>
            <TextBlock x:Name="UMainLabel" Text="Main sound track (plays first)" Style="{StaticResource Label}"/>
            <ComboBox x:Name="UMain"/>
            <Button x:Name="UTracksGo" Content="Save a copy with these tracks" Style="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,12,0,0"/>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Trim" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="Keep only the part between two times (hours:minutes:seconds). Nothing is converted, so the cut is at the nearest key frame and may start a second or two early."/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <TextBlock Text="From" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBox x:Name="UFrom" Width="110" Height="32"/>
              <TextBlock Text="to" VerticalAlignment="Center" Margin="12,0,8,0"/>
              <TextBox x:Name="UTo" Width="110" Height="32"/>
              <Button x:Name="UTrimGo" Content="Save the trimmed part" Margin="14,0,0,0"/>
            </StackPanel>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Margin="0,12,0,0" Text="Or make that part into a GIF (no sound, a minute at most), or a small MP4 clip for sharing (cut exactly, as it's converted):"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="UGifGo" Content="Make a GIF"/>
              <Button x:Name="UClipGo" Content="Make a small clip"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Save parts of it" Style="{StaticResource Head}" Margin="0,10,0,6"/>
            <DockPanel>
              <Button x:Name="USoundGo" DockPanel.Dock="Right" Content="Save the sound" Margin="10,4,0,0"/>
              <CheckBox x:Name="UMp3" DockPanel.Dock="Right" Content="As MP3" Margin="10,4,0,0" VerticalAlignment="Center"/>
              <ComboBox x:Name="USound"/>
            </DockPanel>
            <WrapPanel Margin="0,12,0,0">
              <Button x:Name="USubsGo" Content="Save the subtitles as files" Margin="0,0,8,6"/>
              <Button x:Name="UPicGo" Content="Save the picture at" Margin="0,0,8,6"/>
              <TextBox x:Name="UPicAt" Width="110" Height="32" Margin="0,0,0,6" VerticalAlignment="Top"/>
            </WrapPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Fix" Style="{StaticResource Head}" Margin="0,10,0,6"/>
            <DockPanel>
              <Button x:Name="ULoudGo" DockPanel.Dock="Right" Content="Make it louder" Margin="10,0,0,0" VerticalAlignment="Center"/>
              <TextBlock TextWrapping="Wrap" VerticalAlignment="Center" Text="Quiet or uneven sound: evens it out to a steady TV level (EBU R128). The sound is converted; the picture isn't touched."/>
            </DockPanel>
            <DockPanel Margin="0,12,0,0">
              <Button x:Name="UTurnGo" DockPanel.Dock="Right" Content="Turn it" Margin="10,0,0,0" VerticalAlignment="Center"/>
              <ComboBox x:Name="UTurn" DockPanel.Dock="Right" Width="190" Margin="10,0,0,0">
                <ComboBoxItem Tag="-90" Content="A quarter turn right" IsSelected="True"/><ComboBoxItem Tag="90" Content="A quarter turn left"/><ComboBoxItem Tag="180" Content="Upside down"/><ComboBoxItem Tag="0" Content="Back to normal"/>
              </ComboBox>
              <TextBlock x:Name="UTurnNote" TextWrapping="Wrap" VerticalAlignment="Center" Text="Sideways or upside-down video (from a phone, say)."/>
            </DockPanel>
            <DockPanel Margin="0,12,0,0">
              <Button x:Name="UTagsGo" DockPanel.Dock="Right" Content="Remove tags" Margin="10,0,0,0" VerticalAlignment="Center"/>
              <TextBlock TextWrapping="Wrap" VerticalAlignment="Center" Text="Removes the title, comments and other tags saved in the file (some TVs show the title instead of the file name). Languages and chapters stay."/>
            </DockPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Sound out of step" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="When lips move before or after the voices. Nothing is converted, so it takes seconds. Try 0.5 first, and watch a few minutes of the new file."/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <TextBlock Text="Move the sound" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBox x:Name="USync" Width="70" Height="32" Text="0.5"/>
              <TextBlock Text="seconds" VerticalAlignment="Center" Margin="8,0,8,0"/>
              <ComboBox x:Name="USyncDir" Width="130" Margin="0">
                <ComboBoxItem Tag="later" Content="later" IsSelected="True"/><ComboBoxItem Tag="earlier" Content="earlier"/>
              </ComboBox>
              <Button x:Name="USyncGo" Content="Save it" Margin="12,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Split into parts" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="Saves the video as several files, named (part 01), (part 02) and so on. Nothing is converted, so each cut is at the nearest key frame."/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <ComboBox x:Name="USplitBy" Width="240" Margin="0">
                <ComboBoxItem Tag="time" Content="Every so many minutes" IsSelected="True"/><ComboBoxItem x:Name="USplitChapters" Tag="chapters" Content="At each chapter"/>
              </ComboBox>
              <TextBox x:Name="USplitMins" Width="70" Height="32" Margin="10,0,0,0" Text="30"/>
              <TextBlock x:Name="USplitMinsLabel" Text="minutes" VerticalAlignment="Center" Margin="8,0,0,0"/>
              <Button x:Name="USplitGo" Content="Split it" Margin="12,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Shrink for sharing" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="Makes an MP4 copy that fits under a size, for email, WhatsApp, Discord and the like (with the main sound track only). The smaller the size, the softer the picture; it's made smaller too when it needs to be."/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <TextBlock Text="Under" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBox x:Name="USize" Width="80" Height="32" Text="25"/>
              <TextBlock Text="MB" VerticalAlignment="Center" Margin="8,0,0,0"/>
              <Button x:Name="UShrinkGo" Content="Make the copy" Margin="12,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Contact sheet" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="One picture with a grid of frames from all through the video, to see what's in it at a glance."/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <ComboBox x:Name="UGrid" Width="200" Margin="0">
                <ComboBoxItem Tag="3x3" Content="3 by 3 (9 frames)"/><ComboBoxItem Tag="4x4" Content="4 by 4 (16 frames)" IsSelected="True"/><ComboBoxItem Tag="5x5" Content="5 by 5 (25 frames)"/><ComboBoxItem Tag="6x6" Content="6 by 6 (36 frames)"/>
              </ComboBox>
              <Button x:Name="USheetGo" Content="Make the contact sheet" Margin="12,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Old tapes and DVDs" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <DockPanel Margin="0,4,0,0">
              <Button x:Name="UTapeGo" DockPanel.Dock="Right" Content="Clean it up" Margin="10,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="UTapeNote" TextWrapping="Wrap" VerticalAlignment="Center" Text="For videos from old tapes, camcorders and DVDs: makes the picture smooth (de-interlaced), takes out grain and noise, and makes it 1080p with a light sharpen so it looks better on a big TV. The picture is converted, so this takes a while. The sound and subtitles are kept as they are."/>
            </DockPanel>
          </StackPanel>
        </Border>
        <Border Background="{Card}" BorderBrush="{Line}" BorderThickness="1" CornerRadius="8" Padding="16,4,16,14" Margin="0,12,0,0">
          <StackPanel>
            <TextBlock Text="Cover and title" Style="{StaticResource Head}" Margin="0,10,0,2"/>
            <TextBlock Foreground="{Soft}" FontSize="12" TextWrapping="Wrap" Text="Saves a copy with a cover picture and a proper title inside it, which Plex, Jellyfin, Emby, Windows and many TVs show. Nothing is converted."/>
            <DockPanel Margin="0,10,0,0">
              <TextBlock Text="Title" VerticalAlignment="Center" Margin="0,0,10,0" DockPanel.Dock="Left"/>
              <TextBox x:Name="UTitle" Height="32"/>
            </DockPanel>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <Button x:Name="UCoverPick" Content="Choose a picture..."/>
              <TextBlock x:Name="UCoverName" Foreground="{Soft}" VerticalAlignment="Center" Text="No picture chosen (the title alone is fine too)" TextTrimming="CharacterEllipsis" MaxWidth="300"/>
              <Button x:Name="UCoverGo" Content="Save it" Margin="12,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    if ($script:Zoom -gt 1.01) { $w.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $script:Zoom, $script:Zoom; $w.Width *= $script:Zoom; $w.Height = [math]::Min($w.Height * $script:Zoom, [Windows.SystemParameters]::WorkArea.Height * 0.92) }
    $w.Title = "Utilities - $($it.Name)"
    $u = @{}
    foreach ($n in 'UName', 'UFacts', 'UOpen', 'UCancel', 'UClose', 'UStatus', 'UProgress', 'UBody', 'UTracks', 'UMainLabel', 'UMain', 'UTracksGo', 'UFrom', 'UTo', 'UTrimGo',
                   'USoundGo', 'UMp3', 'USound', 'USubsGo', 'UPicGo', 'UPicAt', 'ULoudGo', 'UTurnGo', 'UTurn', 'UTurnNote', 'UTagsGo', 'UGifGo', 'UClipGo', 'USync', 'USyncDir', 'USyncGo', 'USplitBy', 'USplitChapters', 'USplitMins', 'USplitMinsLabel', 'USplitGo',
                   'USize', 'UShrinkGo', 'UGrid', 'USheetGo', 'UTapeGo', 'UTapeNote', 'UTitle', 'UCoverPick', 'UCoverName', 'UCoverGo') { $u[$n] = $w.FindName($n) }
    $script:U = @{ W = $w; C = $u; Item = $it; Job = $null; Outs = @(); Secs = 0.0 }
    $u.UName.Text = $it.Name
    $u.UFacts.Text = $it.Details

    # One tick box for each sound and subtitle track
    $soundNames = @()
    $k = 1
    foreach ($a in $i.Audio) {
        $label = "Sound $k`: $(Get-SoundName $a)$(if ($a.Lang -and $a.Lang -ne 'und') { ", $($a.Lang)" })$(if ($a.Title) { ", $($a.Title)" })"
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $label; $cb.Tag = "a$($a.Index)"; $cb.IsChecked = $true
        [void]$u.UTracks.Children.Add($cb)
        $ci = New-Object Windows.Controls.ComboBoxItem; $ci.Content = $label; $ci.Tag = $a.Index
        [void]$u.UMain.Items.Add($ci)
        $ci2 = New-Object Windows.Controls.ComboBoxItem; $ci2.Content = $label; $ci2.Tag = $a.Index
        [void]$u.USound.Items.Add($ci2)
        $soundNames += $label
        $k++
    }
    $k = 1
    foreach ($s in $i.Subs) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = "Subtitles $k`: $(Get-CodecName $s.Codec)$(if ($s.Lang -and $s.Lang -ne 'und') { ", $($s.Lang)" })$(if ($s.Forced) { ', forced' })"
        $cb.Tag = "s$($s.Index)"; $cb.IsChecked = $true
        [void]$u.UTracks.Children.Add($cb)
        $k++
    }
    if (-not $i.Audio.Count -and -not $i.Subs.Count) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = 'This video has no sound or subtitle tracks.'; $t.Foreground = Get-Brush 'Soft'; $t.Margin = '0,8,0,0'
        [void]$u.UTracks.Children.Add($t); $u.UTracksGo.IsEnabled = $false
    }
    $main = Get-MainSound $i
    if ($i.Audio.Count) {
        foreach ($ci in $u.UMain.Items) { if ($ci.Tag -eq $main.Index) { $u.UMain.SelectedItem = $ci } }
        foreach ($ci in $u.USound.Items) { if ($ci.Tag -eq $main.Index) { $u.USound.SelectedItem = $ci } }
    } else {
        $u.UMain.IsEnabled = $false; $u.USound.IsEnabled = $false; $u.USoundGo.IsEnabled = $false; $u.ULoudGo.IsEnabled = $false; $u.UMp3.IsEnabled = $false
    }
    if ($i.Audio.Count -lt 2) { $u.UMainLabel.Visibility = 'Collapsed'; $u.UMain.Visibility = 'Collapsed' }
    if (-not @($i.Subs | Where-Object { $_.Text -or $_.Codec -eq 'hdmv_pgs_subtitle' }).Count) { $u.USubsGo.IsEnabled = $false; $u.USubsGo.ToolTip = 'It has no subtitles that can be saved as files' }
    $u.UFrom.Text = '0:00:00'
    $u.UTo.Text = Format-Time ([math]::Ceiling($i.Seconds))
    $u.UPicAt.Text = Format-Time ([math]::Floor($i.Seconds * 0.2))
    if (-not (Test-DisplayRotation)) { $u.UTurnNote.Text = 'Sideways or upside-down video. This FFmpeg is older than version 6, so the picture is converted to turn it.' }

    $u.UTracksGo.Add_Click({ Invoke-Safely { Start-Utility 'Tracks' } })
    $u.UTrimGo.Add_Click({ Invoke-Safely { Start-Utility 'Trim' } })
    $u.USoundGo.Add_Click({ Invoke-Safely { Start-Utility 'Sound' } })
    $u.USubsGo.Add_Click({ Invoke-Safely { Start-Utility 'Subs' } })
    $u.UPicGo.Add_Click({ Invoke-Safely { Start-Utility 'Picture' } })
    $u.ULoudGo.Add_Click({ Invoke-Safely { Start-Utility 'Louder' } })
    $u.UTurnGo.Add_Click({ Invoke-Safely { Start-Utility 'Turn' } })
    $u.UTagsGo.Add_Click({ Invoke-Safely { Start-Utility 'Tags' } })
    foreach ($b in @(@('UGifGo', 'Gif'), @('UClipGo', 'Clip'), @('USyncGo', 'Sync'), @('USplitGo', 'Split'), @('UShrinkGo', 'Shrink'), @('USheetGo', 'Sheet'), @('UTapeGo', 'Tape'), @('UCoverGo', 'Cover'))) {
        $u[$b[0]].Tag = $b[1]
        $u[$b[0]].Add_Click({ Invoke-Safely { Start-Utility ([string]$this.Tag) } })
    }
    # Chapters, for splitting at each one
    $script:U.Chapters = @()
    try {
        $err = ''
        $cj = [VcProbe]::Run($script:FFprobe, (Join-Args @('-v', 'error', '-show_chapters', '-of', 'json', $it.Path)), 30000, [ref]$err) | ConvertFrom-Json
        $script:U.Chapters = @($cj.chapters | ForEach-Object { [double]::Parse([string]$_.start_time, [Globalization.CultureInfo]::InvariantCulture) })
    } catch { Write-AppLog "Chapters couldn't be read: $($_.Exception.Message)" }
    if ($script:U.Chapters.Count -gt 1) { $u.USplitChapters.Content = "At each chapter ($($script:U.Chapters.Count) chapters)" } else { $u.USplitChapters.IsEnabled = $false; $u.USplitChapters.Content = 'At each chapter (it has none)' }
    $u.USplitBy.Add_SelectionChanged({ $v = if ([string]$this.SelectedItem.Tag -eq 'time') { 'Visible' } else { 'Collapsed' }; $script:U.C.USplitMins.Visibility = $v; $script:U.C.USplitMinsLabel.Visibility = $v })
    if ($i.Height -ge 720) { $u.UTapeNote.Text = 'Mostly for videos from old tapes, camcorders and DVDs. This one is already HD, so it''s only de-noised and lightly sharpened. The picture is converted, so this takes a while.' }
    $u.UTitle.Text = [IO.Path]::GetFileNameWithoutExtension($it.Name)
    $u.UCoverPick.Add_Click({ Invoke-Safely {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Choose a cover picture'
        $dlg.Filter = 'Pictures (*.jpg, *.jpeg, *.png)|*.jpg;*.jpeg;*.png'
        if ($dlg.ShowDialog($script:U.W)) { $script:U.Cover = $dlg.FileName; $script:U.C.UCoverName.Text = [IO.Path]::GetFileName($dlg.FileName) }
    } })
    $u.UCancel.Add_Click({ if ($script:U.Job) { $script:U.Stopping = $true; $script:U.Job.Stop() } })
    $u.UOpen.Add_Click({ if ($script:U.Outs.Count) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($script:U.Outs[0])`"" } })
    $u.UClose.Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $w.Add_Closing({
        param($s, $e)
        if ($script:U.Job -and -not $script:U.Job.Done) {
            if (-not (Show-AppMessage 'Stop it and close? The part-made file is deleted.' -YesText 'Stop and close' -NoText 'Keep going' -Owner $script:U.W)) { $e.Cancel = $true; return }
            $script:U.Stopping = $true; $script:U.Job.Stop(); Start-Sleep -Milliseconds 500
            foreach ($o in $script:U.Outs) { Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue }
        }
    })
    $ut = New-Object Windows.Threading.DispatcherTimer
    $ut.Interval = [TimeSpan]::FromMilliseconds(250)
    $ut.Add_Tick({ try { Update-Utility } catch { Write-AppLog "Utility update: $($_.Exception.Message)" } })
    $ut.Start()
    $w.Add_Closed({ $ut.Stop() })
    [void]$w.ShowDialog()
    $script:U = $null
}

function Start-Utility([string]$What) {
    $U = $script:U
    if ($U.Job -and -not $U.Job.Done) { return }
    $c = $U.C; $it = $U.Item; $i = $it.Info
    $ext = $i.Ext
    $keepExt = if ($ext -in 'mkv', 'mp4', 'm4v', 'mov', 'webm', 'avi') { $ext } else { 'mkv' }
    $allA = @($i.Audio | ForEach-Object { $_.Index })
    $allS = @($i.Subs | ForEach-Object { $_.Index })
    $mainA = if ($i.Audio.Count) { (Get-MainSound $i).Index } else { -1 }
    $pre = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error')
    $post = @('-max_muxing_queue_size', '4096', '-progress', 'pipe:1', '-nostats')
    $secs = [math]::Max(1, $i.Seconds)
    $outs = @(); $ffArgs = $null; $label = ''
    switch ($What) {
        'Tracks' {
            $ticked = @($c.UTracks.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked } | ForEach-Object { [string]$_.Tag })
            $a = @($ticked | Where-Object { $_ -like 'a*' } | ForEach-Object { [int]$_.Substring(1) })
            $s = @($ticked | Where-Object { $_ -like 's*' } | ForEach-Object { [int]$_.Substring(1) })
            if ($a.Count -eq $allA.Count -and $s.Count -eq $allS.Count -and (-not $c.UMain.SelectedItem -or [int]$c.UMain.SelectedItem.Tag -eq $mainA)) { [void](Show-AppMessage 'Every track is still ticked and the main sound is the same, so the copy would be just the same. Untick the tracks you don''t want first.' -Owner $U.W); return }
            if ($allA.Count -and -not $a.Count -and -not (Show-AppMessage 'Every sound track is unticked, so the copy will have no sound at all. Carry on?' -YesText 'Carry on' -NoText 'Go back' -Owner $U.W)) { return }
            $main = if ($c.UMain.SelectedItem -and $a -contains [int]$c.UMain.SelectedItem.Tag) { [int]$c.UMain.SelectedItem.Tag } elseif ($a.Count) { $a[0] } else { -1 }
            if ($ext -eq 'webm' -or $ext -eq 'avi') { $keepExt = 'mkv' }
            $o = Get-UtilOutPath $it 'tracks' $keepExt
            $ffArgs = $pre + @('-i', $it.Path) + (Get-KeepArgs $i $a $s $main $keepExt) + $post + @($o)
            $outs = @($o); $label = 'Saving a copy with the tracks you picked'
        }
        'Trim' {
            $from = Get-TimeSeconds $c.UFrom.Text; $to = Get-TimeSeconds $c.UTo.Text
            if ($from -lt 0 -or $to -lt 0) { [void](Show-AppMessage 'Type the times as hours:minutes:seconds, such as 0:01:30 for a minute and a half in.' -Owner $U.W); return }
            if ($to -gt $i.Seconds -and $i.Seconds -gt 0) { $to = $i.Seconds }
            if ($to -le $from) { [void](Show-AppMessage "The end ($($c.UTo.Text)) has to be after the start ($($c.UFrom.Text))." -Owner $U.W); return }
            if ($ext -eq 'webm') { $keepExt = 'mkv' }
            $o = Get-UtilOutPath $it 'trimmed' $keepExt
            $k = Get-KeepArgs $i $allA $allS $mainA $keepExt
            $ffArgs = $pre + @('-ss', ('{0:0.###}' -f $from).Replace(',', '.'), '-i', $it.Path, '-t', ('{0:0.###}' -f ($to - $from)).Replace(',', '.')) + $k + @('-avoid_negative_ts', 'make_zero') + $post + @($o)
            $secs = [math]::Max(1, $to - $from); $outs = @($o); $label = "Saving $(Format-Time $from) to $(Format-Time $to)"
        }
        'Sound' {
            $idx = [int]$c.USound.SelectedItem.Tag
            $a = $i.Audio | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
            if ($c.UMp3.IsChecked) {
                $o = Get-UtilOutPath $it 'sound' 'mp3'
                $codec = @('-c:a', 'libmp3lame', '-q:a', '2'); if ($a.Ch -gt 2) { $codec += '-ac', '2' }
            } else {
                $aext = if ($script:AudioExt.ContainsKey($a.Codec)) { $script:AudioExt[$a.Codec] } elseif ($a.Codec -like 'pcm_*') { 'wav' } else { 'mka' }
                $o = Get-UtilOutPath $it 'sound' $aext
                $codec = @('-c:a', 'copy')
            }
            $ffArgs = $pre + @('-i', $it.Path, '-map', "0:$idx", '-vn', '-sn', '-map_metadata', '0') + $codec + $post + @($o)
            $outs = @($o); $label = "Saving the sound ($(Get-SoundName $a))"
        }
        'Subs' {
            $ffArgs = $pre + @('-i', $it.Path)
            $n = 1
            foreach ($s in $i.Subs) {
                $suffix = (Get-SrtSuffix $s $n).TrimStart('.')
                if ($s.Text) { $o = Get-UtilOutPath $it "subtitles $suffix" 'srt'; $ffArgs += '-map', "0:$($s.Index)", '-c:s', 'srt', $o; $outs += $o }
                elseif ($s.Codec -eq 'hdmv_pgs_subtitle') { $o = Get-UtilOutPath $it "subtitles $suffix" 'sup'; $ffArgs += '-map', "0:$($s.Index)", '-c:s', 'copy', $o; $outs += $o }
                $n++
            }
            $label = "Saving $($outs.Count) subtitle file$(if ($outs.Count -ne 1) { 's' })"
        }
        'Picture' {
            $at = Get-TimeSeconds $c.UPicAt.Text
            if ($at -lt 0) { [void](Show-AppMessage 'Type the time as hours:minutes:seconds, such as 0:12:05.' -Owner $U.W); return }
            if ($at -ge $i.Seconds -and $i.Seconds -gt 1) { $at = $i.Seconds - 1 }
            $suggest = Get-UtilOutPath $it "picture $((Format-Time $at).Replace(':', '.'))" 'png'
            $U.SaveAs = @{ Dir = Split-Path -Parent $suggest; Name = [IO.Path]::GetFileName($suggest); What = 'picture'; Filter = 'PNG picture (*.png)|*.png' }
            $o = Join-Path $script:TempDir ('Picture - ' + [IO.Path]::GetFileNameWithoutExtension($it.Name) + '.png')
            $vf = if ($i.Hdr -and $script:Can.Zscale -and $i.Transfer -in 'smpte2084', 'arib-std-b67') { @('-vf', 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=rgb24') } else { @() }
            $ffArgs = $pre + @('-ss', ('{0:0.###}' -f $at).Replace(',', '.'), '-i', $it.Path, '-map', "0:$($i.VIndex)", '-frames:v', '1') + $vf + @($o)
            $secs = 1; $outs = @($o); $label = "Saving the picture at $(Format-Time $at)"
        }
        'Louder' {
            if ($ext -notin 'mkv', 'mp4', 'm4v', 'mov') { $keepExt = 'mkv' }
            $o = Get-UtilOutPath $it 'louder' $keepExt
            $k = Get-KeepArgs $i $allA $allS $mainA $keepExt
            $k += '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-ar', '48000'
            $n = 0
            foreach ($a in $i.Audio) {
                if ($a.Ch -gt 2) { $k += "-c:a:$n", 'eac3', "-b:a:$n", '640k'; if ($a.Ch -gt 6) { $k += "-ac:a:$n", '6' } }
                else { $k += "-c:a:$n", 'aac', "-b:a:$n", '192k' }
                $n++
            }
            $ffArgs = $pre + @('-i', $it.Path) + $k + $post + @($o)
            $outs = @($o); $label = 'Evening out the sound'
        }
        'Turn' {
            $deg = [int]$c.UTurn.SelectedItem.Tag
            if ($ext -eq 'webm') { $keepExt = 'mkv' }
            $o = Get-UtilOutPath $it 'turned' $keepExt
            if (Test-DisplayRotation) {
                $ffArgs = $pre + @('-display_rotation:v:0', "$deg", '-i', $it.Path) + (Get-KeepArgs $i $allA $allS $mainA $keepExt) + $post + @($o)
            } else {
                $tf = switch ($deg) { -90 { 'transpose=1' } 90 { 'transpose=2' } 180 { 'hflip,vflip' } default { 'null' } }
                $k = Get-KeepArgs $i $allA $allS $mainA $keepExt
                $k += '-vf', $tf, '-c:v', 'libx264', '-crf', '20', '-preset', 'medium', '-pix_fmt', 'yuv420p'
                $ffArgs = $pre + @('-i', $it.Path) + $k + $post + @($o)
            }
            $outs = @($o); $label = 'Turning the picture'
        }
        'Sync' {
            $sec = 0.0
            if (-not [double]::TryParse($c.USync.Text.Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sec) -or $sec -le 0 -or $sec -gt 600) {
                [void](Show-AppMessage 'Type how many seconds to move the sound, such as 0.5 or 2.' -Owner $U.W); return
            }
            $off = if ([string]$c.USyncDir.SelectedItem.Tag -eq 'earlier') { -$sec } else { $sec }
            if ($ext -eq 'webm') { $keepExt = 'mkv' }
            $o = Get-UtilOutPath $it "sound $(if ($off -gt 0) { 'later' } else { 'earlier' }) $sec s" $keepExt
            # The same file is read twice: the picture and subtitles from the first, the sound from the second, moved.
            $k = @(Get-KeepArgs $i $allA $allS $mainA $keepExt)
            foreach ($a in $allA) { $p = [array]::IndexOf($k, "0:$a"); if ($p -ge 0) { $k[$p] = "1:$a" } }
            $ffArgs = $pre + @('-i', $it.Path, '-itsoffset', ('{0:0.###}' -f $off).Replace(',', '.'), '-i', $it.Path) + $k + $post + @($o)
            $outs = @($o); $label = "Moving the sound $sec seconds $(if ($off -gt 0) { 'later' } else { 'earlier' })"
        }
        'Split' {
            if ($ext -eq 'webm') { $keepExt = 'mkv' }
            $k = @(Get-KeepArgs $i $allA $allS $mainA $keepExt | Where-Object { $_ -ne '-movflags' -and $_ -ne '+faststart' })
            if ([string]$c.USplitBy.SelectedItem.Tag -eq 'chapters') {
                $times = @($U.Chapters | Where-Object { $_ -gt 1 })
                if (-not $times.Count) { [void](Show-AppMessage 'This video has no chapters to split at. Choose "Every so many minutes" instead.' -Owner $U.W); return }
                $seg = @('-f', 'segment', '-segment_times', (($times | ForEach-Object { ('{0:0.###}' -f $_).Replace(',', '.') }) -join ','))
            } else {
                $mins = 0
                if (-not [int]::TryParse($c.USplitMins.Text.Trim(), [ref]$mins) -or $mins -lt 1) { [void](Show-AppMessage 'Type how many minutes each part should be, such as 30.' -Owner $U.W); return }
                if ($mins * 60 -ge $i.Seconds) { [void](Show-AppMessage "The video is only $(Format-Length $i.Seconds) long, so parts of $mins minutes would leave it in one piece." -Owner $U.W); return }
                $seg = @('-f', 'segment', '-segment_time', "$($mins * 60)")
            }
            $seg += '-reset_timestamps', '1', '-segment_start_number', '1'
            $dir = Split-Path -Parent (Get-UtilOutPath $it 'x' $keepExt)
            $base = [IO.Path]::GetFileNameWithoutExtension($it.Name)
            $n = 1
            do { $tag = if ($n -eq 1) { 'part' } else { "split $n part" }; $n++ } while (Test-Path -LiteralPath (Join-Path $dir "$base ($tag 01).$keepExt"))
            $o = Join-Path $dir "$base ($tag %02d).$keepExt"
            $U.Glob = @{ Dir = $dir; Filter = "$base ($tag ??).$keepExt" }
            $ffArgs = $pre + @('-i', $it.Path) + $k + $seg + $post + @($o)
            $outs = @($o); $label = 'Splitting it into parts'
        }
        'Shrink' {
            $mb = 0.0
            if (-not [double]::TryParse($c.USize.Text.Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mb) -or $mb -lt 1) {
                [void](Show-AppMessage 'Type the largest size in MB, such as 25.' -Owner $U.W); return
            }
            if ($mb * 1MB -ge $i.Bytes) { [void](Show-AppMessage "It's already $(Format-Size $i.Bytes), which is under $mb MB." -Owner $U.W); return }
            $total = $mb * 8192 * 0.94 / $secs                      # kbit/s for the whole file, with a little room to spare
            $audioK = if ($i.Audio.Count) { if ($total -lt 600) { 64 } else { 128 } } else { 0 }
            $videoK = [int]($total - $audioK)
            if ($videoK -lt 120) { [void](Show-AppMessage "$mb MB is too small for $(Format-Length $i.Seconds) of video. Try a bigger size, or trim it first." -Owner $U.W); return }
            $high = if ($videoK -lt 700) { 480 } elseif ($videoK -lt 1800) { 720 } elseif ($videoK -lt 5000) { 1080 } else { 2160 }
            $vf = @(Get-SdrFilter $i)
            if ([math]::Min($i.Width, $i.Height) -gt $high) { $vf += $(if ($i.Height -le $i.Width) { "scale=-2:$high" } else { "scale=${high}:-2" }) }
            $vf += 'format=yuv420p'
            $o = Get-UtilOutPath $it "under $mb MB" 'mp4'
            $ffArgs = $pre + @('-i', $it.Path, '-map', "0:$($i.VIndex)")
            if ($i.Audio.Count) { $ffArgs += '-map', "0:$mainA" }
            $ffArgs += '-map_metadata', '0', '-vf', ($vf -join ','), '-c:v', 'libx264', '-preset', 'medium', '-b:v', "${videoK}k", '-maxrate', "$([int]($videoK * 1.3))k", '-bufsize', "$($videoK * 2)k"
            if ($i.Audio.Count) { $ffArgs += '-c:a', 'aac', '-b:a', "${audioK}k", '-ac', '2' }
            $ffArgs += '-movflags', '+faststart'
            $ffArgs += $post + @($o)
            $U.Target = $mb * 1MB
            $outs = @($o); $label = "Making a copy under $mb MB"
        }
        { $_ -in 'Gif', 'Clip' } {
            $from = Get-TimeSeconds $c.UFrom.Text; $to = Get-TimeSeconds $c.UTo.Text
            if ($from -lt 0 -or $to -lt 0) { [void](Show-AppMessage 'Type the times in the Trim boxes as hours:minutes:seconds, such as 0:01:30.' -Owner $U.W); return }
            if ($to -gt $i.Seconds -and $i.Seconds -gt 0) { $to = $i.Seconds }
            if ($to -le $from) { [void](Show-AppMessage "The end ($($c.UTo.Text)) has to be after the start ($($c.UFrom.Text))." -Owner $U.W); return }
            $dur = $to - $from
            $vf = @(Get-SdrFilter $i)
            if ($What -eq 'Gif') {
                if ($dur -gt 60) { [void](Show-AppMessage "That's $(Format-Length $dur). A GIF that long would be huge: pick a part of a minute or less (a few seconds is usual) in the Trim boxes." -Owner $U.W); return }
                $suggest = Get-UtilOutPath $it "GIF $((Format-Time $from).Replace(':', '.'))" 'gif'
                $U.SaveAs = @{ Dir = Split-Path -Parent $suggest; Name = [IO.Path]::GetFileName($suggest); What = 'GIF'; Filter = 'GIF (*.gif)|*.gif' }
                $o = Join-Path $script:TempDir ('GIF - ' + [IO.Path]::GetFileNameWithoutExtension($it.Name) + '.gif')
                $vf += 'fps=12', "scale='min(480,iw)':-2:flags=lanczos", 'split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4'
                $ffArgs = $pre + @('-ss', ('{0:0.###}' -f $from).Replace(',', '.'), '-t', ('{0:0.###}' -f $dur).Replace(',', '.'), '-i', $it.Path, '-map', "0:$($i.VIndex)", '-vf', ($vf -join ','), '-loop', '0') + $post + @($o)
                $label = 'Making the GIF'
            } else {
                $o = Get-UtilOutPath $it "clip $((Format-Time $from).Replace(':', '.'))" 'mp4'
                if ([math]::Min($i.Width, $i.Height) -gt 720) { $vf += $(if ($i.Height -le $i.Width) { 'scale=-2:720' } else { 'scale=720:-2' }) }
                $vf += 'format=yuv420p'
                $ffArgs = $pre + @('-ss', ('{0:0.###}' -f $from).Replace(',', '.'), '-i', $it.Path, '-t', ('{0:0.###}' -f $dur).Replace(',', '.'), '-map', "0:$($i.VIndex)")
                if ($i.Audio.Count) { $ffArgs += '-map', "0:$mainA", '-c:a', 'aac', '-b:a', '128k', '-ac', '2' }
                $ffArgs += '-vf', ($vf -join ','), '-c:v', 'libx264', '-preset', 'medium', '-crf', '23', '-movflags', '+faststart'
                $ffArgs += $post + @($o)
                $label = 'Making the clip'
            }
            $secs = [math]::Max(1, $dur); $outs = @($o)
        }
        'Sheet' {
            $grid = [string]$c.UGrid.SelectedItem.Tag
            $cols = [int]$grid.Split('x')[0]; $rows = [int]$grid.Split('x')[1]
            $start = $i.Seconds * 0.03
            $rate = ($cols * $rows) / [math]::Max(1, $i.Seconds - $start)
            $vf = @(Get-SdrFilter $i) + @(('fps=' + ('{0:0.######}' -f $rate).Replace(',', '.')), 'scale=480:-2', "tile=${cols}x${rows}:padding=6:margin=6:color=black")
            # Made in the temp folder first: it's shown, and then you choose where to save it.
            $suggest = Get-UtilOutPath $it 'contact sheet' 'jpg'
            $U.SaveAs = @{ Dir = Split-Path -Parent $suggest; Name = [IO.Path]::GetFileName($suggest); What = 'contact sheet'; Filter = 'JPEG picture (*.jpg)|*.jpg' }
            $o = Join-Path $script:TempDir ('Contact sheet - ' + [IO.Path]::GetFileNameWithoutExtension($it.Name) + '.jpg')
            # Only key frames are read, so even a long film is quick.
            $ffArgs = $pre + @('-skip_frame', 'nokey', '-ss', ('{0:0.###}' -f $start).Replace(',', '.'), '-i', $it.Path, '-map', "0:$($i.VIndex)", '-vf', ($vf -join ','), '-frames:v', '1', '-q:v', '3') + $post + @($o)
            $outs = @($o); $label = 'Making the contact sheet'
        }
        'Tape' {
            $vf = @()
            if ($i.Interlaced -or ($i.Height -le 576 -and $i.VCodec -in 'mpeg2video', 'mpeg1video', 'dvvideo')) { $vf += 'bwdif' }
            $vf += 'hqdn3d=3:2:4:3'
            if ($i.Height -lt 720 -and $i.Width -lt 1280) {
                $vf += 'scale=trunc(iw*sar/2)*2:ih', 'setsar=1', 'scale=-2:1080:flags=lanczos', 'unsharp=5:5:0.6:5:5:0'
            } else { $vf += 'unsharp=5:5:0.3:5:5:0' }
            $vf += 'setsar=1', 'format=yuv420p'
            $o = Get-UtilOutPath $it 'cleaned up' 'mkv'
            $k = @(Get-KeepArgs $i $allA $allS $mainA 'mkv')
            $ffArgs = $pre + @('-i', $it.Path) + $k + @('-vf', ($vf -join ','), '-c:v', 'libx264', '-preset', 'slow', '-crf', '18') + $post + @($o)
            $outs = @($o); $label = 'Cleaning up the picture'
        }
        'Cover' {
            $title = $c.UTitle.Text.Trim()
            if (-not $U.Cover -and -not $title) { [void](Show-AppMessage 'Type a title, choose a picture, or both.' -Owner $U.W); return }
            if ($ext -notin 'mp4', 'm4v', 'mov', 'mkv') { $keepExt = 'mkv' }
            $mp4 = $keepExt -in 'mp4', 'm4v', 'mov'
            $o = Get-UtilOutPath $it 'with cover' $keepExt
            $k = @(Get-KeepArgs $i $allA $allS $mainA $keepExt)
            $ffArgs = $pre + @('-i', $it.Path)
            if ($U.Cover -and $mp4) {
                $ffArgs += '-i', $U.Cover
                $k += '-map', '1:0', '-disposition:v:1', 'attached_pic'
            } elseif ($U.Cover) {
                $mime = if ($U.Cover -match '\.png$') { 'image/png' } else { 'image/jpeg' }
                $k += '-attach', $U.Cover, "-metadata:s:t:$($i.Attach)", "mimetype=$mime", "-metadata:s:t:$($i.Attach)", "filename=cover$([IO.Path]::GetExtension($U.Cover).ToLowerInvariant().Replace('.jpeg', '.jpg'))"
            }
            if ($title) { $k += '-metadata', "title=$title" }
            $ffArgs += $k + $post + @($o)
            $outs = @($o); $label = 'Saving it with the cover and title'
        }
        'Tags' {
            if ($ext -eq 'webm') { $keepExt = 'mkv' }
            $o = Get-UtilOutPath $it 'no tags' $keepExt
            $k = Get-KeepArgs $i $allA $allS $mainA $keepExt
            $k = @($k | ForEach-Object { $_ })
            $p = [array]::IndexOf($k, '-map_metadata'); if ($p -ge 0) { $k[$p + 1] = '-1' }
            # Everything goes except each track's language, which is put back.
            $n = 0
            foreach ($a in $i.Audio) { if ($a.Lang) { $k += "-metadata:s:a:$n", "language=$($a.Lang)" }; $n++ }
            $n = 0
            foreach ($sub in @($i.Subs | Where-Object { $keepExt -notin 'mp4', 'm4v', 'mov' -or $_.Text })) { if ($sub.Lang) { $k += "-metadata:s:s:$n", "language=$($sub.Lang)" }; $n++ }
            $ffArgs = $pre + @('-i', $it.Path) + $k + $post + @($o)
            $outs = @($o); $label = 'Removing the tags'
        }
    }
    if (-not $ffArgs -or -not $outs.Count) { return }
    $line = Join-Args $ffArgs
    Write-AppLog "Utility $What on $($it.Path): ffmpeg $line"
    $job = New-Object VcRun
    $job.Start($script:FFmpeg, $line)
    $U.Job = $job; $U.Outs = $outs; $U.Secs = $secs; $U.What = $What; $U.Label = $label; $U.Stopping = $false
    if ($What -ne 'Split') { $U.Glob = $null }
    if ($What -ne 'Shrink') { $U.Target = $null }
    if ($What -notin 'Sheet', 'Picture', 'Gif') { $U.SaveAs = $null }
    $c.UBody.IsEnabled = $false
    $c.UCancel.Visibility = 'Visible'; $c.UOpen.Visibility = 'Collapsed'
    $c.UProgress.Visibility = 'Visible'; $c.UProgress.Value = 0
    $c.UStatus.Text = "$label..."; $c.UStatus.Foreground = Get-Brush 'Ink'
}

function Show-SavePreview([string]$Path, $SaveAs) {
    <# Shows a finished contact sheet, picture or GIF, then asks where to save it. Returns the chosen path, or $null. #>
    $w = New-ToolWindow ((Get-Culture).TextInfo.ToTitleCase($SaveAs.What.Substring(0, 1)) + $SaveAs.What.Substring(1)) 900 760
    if ($script:U -and $script:U.W) { $w.Owner = $script:U.W }
    $w.FindName('TwHead').Text = "Here's the $($SaveAs.What). Save it?"
    if ($SaveAs.What -eq 'GIF') {
        $w.FindName('TwHead').Text = 'Here''s the GIF (its first frame; Play it shows it moving). Save it?'
        $script:PreviewPath = $Path
        [void](Add-ToolButton $w 'Play it' { try { Start-Process -FilePath $script:PreviewPath } catch { Write-AppLog "No viewer for the GIF: $($_.Exception.Message)" } })
    }
    $img = New-Object Windows.Controls.Image
    $img.Source = Get-ImageFromFile $Path
    $img.Stretch = 'Uniform'
    $w.FindName('TwText').Parent.Content = $img
    $w.FindName('TwClose').Content = 'Don''t save'
    $script:SheetDest = $null
    $script:SheetSave = $SaveAs
    [void](Add-ToolButton $w 'Save it...' {
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Title = "Save the $($script:SheetSave.What)"
        $dlg.Filter = $script:SheetSave.Filter
        $dlg.FileName = $script:SheetSave.Name
        if (Test-Path -LiteralPath $script:SheetSave.Dir) { $dlg.InitialDirectory = $script:SheetSave.Dir }
        $win = [Windows.Window]::GetWindow($this)
        if ($dlg.ShowDialog($win)) { $script:SheetDest = $dlg.FileName; $win.Close() }
    } -Accent)
    [void]$w.ShowDialog()
    return $script:SheetDest
}

function Update-Utility {
    $U = $script:U
    if (-not $U -or -not $U.Job) { return }
    $c = $U.C; $job = $U.Job
    if (-not $job.Done) {
        $pc = [math]::Min(99, 100 * $job.OutSeconds / $U.Secs)
        $c.UProgress.Value = $pc
        $c.UStatus.Text = "$($U.Label)... $([int]$pc)%"
        return
    }
    $U.Job = $null
    $c.UBody.IsEnabled = $true; $c.UCancel.Visibility = 'Collapsed'; $c.UProgress.Visibility = 'Collapsed'
    # @( ) around the if: an if-expression would hand back a single file as plain text.
    $made = @(if ($U.Glob) { Get-ChildItem -LiteralPath $U.Glob.Dir -Filter $U.Glob.Filter -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName } } else { $U.Outs | Where-Object { Test-Path -LiteralPath $_ } })
    if ($U.Stopping) {
        foreach ($o in @($U.Outs) + @($made)) { Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue }
        $c.UStatus.Text = 'Stopped. Nothing was saved.'; $c.UStatus.Foreground = Get-Brush 'Soft'
        return
    }
    if ($job.ExitCode -ne 0 -or -not $made.Count) {
        foreach ($o in @($U.Outs) + @($made)) { Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue }
        $last = @($job.Tail -split "`n" | Where-Object { $_ }) | Select-Object -Last 1
        Write-AppLog "Utility $($U.What) failed ($($job.ExitCode)): $($job.Tail)"
        $c.UStatus.Text = "That didn't work: $last"; $c.UStatus.Foreground = Get-Brush 'Bad'
        return
    }
    if ($U.SaveAs) {
        $dest = Show-SavePreview $made[0] $U.SaveAs
        if (-not $dest) {
            Remove-Item -LiteralPath $made[0] -Force -ErrorAction SilentlyContinue
            $c.UStatus.Text = "The $($U.SaveAs.What) wasn't saved."; $c.UStatus.Foreground = Get-Brush 'Soft'
            return
        }
        Move-Item -LiteralPath $made[0] -Destination $dest -Force
        $made = @($dest)
    }
    $names = if ($made.Count -gt 4) { "$($made.Count) files, $([IO.Path]::GetFileName($made[0])) to $([IO.Path]::GetFileName($made[-1]))" } else { ($made | ForEach-Object { "$([IO.Path]::GetFileName($_)) ($(Format-Size (Get-Item -LiteralPath $_).Length))" }) -join ', ' }
    $c.UStatus.Text = "Saved: $names"; $c.UStatus.Foreground = Get-Brush 'Good'
    if ($U.Target -and (Get-Item -LiteralPath $made[0]).Length -gt $U.Target) { $c.UStatus.Text += ". It came out a little over the size: try a size a few MB smaller."; $c.UStatus.Foreground = Get-Brush 'Warn' }
    $U.Outs = $made
    $c.UOpen.Visibility = 'Visible'
    Write-AppLog "Utility $($U.What) saved $($made -join ', ')"
    # New videos go in the main list too, so they're checked for the chosen TV or device.
    $vids = @($made | Where-Object { $script:VideoExt -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
    if ($vids.Count) { Add-Paths $vids }
}
#endregion UTILITIES

#region TOOLS
# ---------------------------------------------------------------------------
#  Tools for the whole list (the More button): join, duplicates, stats,
#  report, save and open the list, convert at a set time; and what happens
#  when the list is done (notification, sleep or shut down).
# ---------------------------------------------------------------------------
function Get-SdrFilter($i) {
    <# Filters that turn an HDR picture into normal colours (empty for SDR, or when FFmpeg can't). #>
    if ($i.Hdr -and $script:Can.Zscale -and $i.Transfer -in 'smpte2084', 'arib-std-b67') {
        return @('zscale=t=linear:npl=100', 'format=gbrpf32le', 'zscale=p=bt709', 'tonemap=tonemap=hable:desat=0', 'zscale=t=bt709:m=bt709:r=tv')
    }
    return @()
}

function New-ToolWindow([string]$Title, [int]$Width = 640, [int]$Height = 560) {
    <# A plain window in the app's look with a scrolling text area and a row of buttons. #>
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        ShowInTaskbar="False" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="14" Background="{Card}" Foreground="{Ink}">
  <Window.Resources>
STYLES
  </Window.Resources>
  <DockPanel Margin="22,18,22,16">
    <TextBlock x:Name="TwHead" DockPanel.Dock="Top" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <StackPanel x:Name="TwButtons" DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="TwClose" Content="Close" MinWidth="80" Margin="0" IsCancel="True"/>
    </StackPanel>
    <StackPanel x:Name="TwJob" DockPanel.Dock="Bottom" Visibility="Collapsed" Margin="0,10,0,0">
      <TextBlock x:Name="TwStatus" TextWrapping="Wrap" Foreground="{Soft}"/>
      <ProgressBar x:Name="TwProgress" Height="4" Margin="0,6,0,0" Foreground="{Accent}" Background="{Line}" BorderThickness="0" Maximum="100"/>
    </StackPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="TwText" TextWrapping="Wrap" LineHeight="21" Margin="0,0,8,0"/></ScrollViewer>
  </DockPanel>
</Window>
'@.Replace('STYLES', $script:Styles)
    $w = New-XamlWindow $x $script:Window
    $w.Width = $Width; $w.Height = $Height
    if ($script:Zoom -gt 1.01) { $w.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $script:Zoom, $script:Zoom; $w.Width *= $script:Zoom; $w.Height = [math]::Min($w.Height * $script:Zoom, [Windows.SystemParameters]::WorkArea.Height * 0.9) }
    $w.Title = $Title
    $w.FindName('TwClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    return $w
}

function Add-ToolButton($Window, [string]$Text, [scriptblock]$OnClick, [switch]$Accent) {
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text
    if ($Accent) { $b.Style = $Window.FindResource('Accent') }
    $b.Add_Click($OnClick)
    $row = $Window.FindName('TwButtons')
    $row.Children.Insert($row.Children.Count - 1, $b)
    return $b
}

function Set-ToolText($Window, [string[]]$Lines) {
    <# Lines in capitals are headings; the rest plain. #>
    $tb = $Window.FindName('TwText')
    $tb.Inlines.Clear()
    foreach ($line in $Lines) {
        if ($tb.Inlines.Count) { $tb.Inlines.Add((New-Object Windows.Documents.LineBreak)) }
        $run = New-Object Windows.Documents.Run $line
        if ($line -cmatch '^[A-Z][A-Z0-9 ,]+$') { $run.FontWeight = 'SemiBold'; $run.Foreground = Get-Brush 'Accent' }
        $tb.Inlines.Add($run)
    }
}

function Invoke-FfmpegJob($Window, [string]$Label, [string]$FfArgs, [double]$Secs, [string]$Out) {
    <# Runs FFmpeg with its progress shown in a tool window; Close stops it. The new video joins the list. #>
    $Window.FindName('TwJob').Visibility = 'Visible'
    $st = $Window.FindName('TwStatus'); $pb = $Window.FindName('TwProgress')
    $st.Text = "$Label..."; $st.Foreground = Get-Brush 'Ink'
    Write-AppLog "$Label`: ffmpeg $FfArgs"
    $job = New-Object VcRun
    $job.Start($script:FFmpeg, $FfArgs)
    $script:ToolJob = @{ Job = $job; Out = $Out; Secs = [math]::Max(1, $Secs); Label = $Label; Status = $st; Bar = $pb }
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(250)
    $t.Add_Tick({
        $j = $script:ToolJob
        if (-not $j) { $this.Stop(); return }
        if (-not $j.Job.Done) { $pc = [math]::Min(99, 100 * $j.Job.OutSeconds / $j.Secs); $j.Bar.Value = $pc; $j.Status.Text = "$($j.Label)... $([int]$pc)%"; return }
        $this.Stop(); $script:ToolJob = $null
        $j.Bar.Value = 100
        if ($j.Job.ExitCode -eq 0 -and (Test-Path -LiteralPath $j.Out)) {
            $j.Status.Text = "Saved: $([IO.Path]::GetFileName($j.Out)) ($(Format-Size (Get-Item -LiteralPath $j.Out).Length))"; $j.Status.Foreground = Get-Brush 'Good'
            Write-AppLog "Saved $($j.Out)"
            Add-Paths @($j.Out)
        } else {
            Remove-Item -LiteralPath $j.Out -Force -ErrorAction SilentlyContinue
            $last = @($j.Job.Tail -split "`n" | Where-Object { $_ }) | Select-Object -Last 1
            $j.Status.Text = "That didn't work: $last"; $j.Status.Foreground = Get-Brush 'Bad'
            Write-AppLog "Failed: $($j.Job.Tail)"
        }
    })
    $t.Start()
    $Window.Add_Closing({
        param($s, $e)
        $j = $script:ToolJob
        if ($j -and -not $j.Job.Done) {
            if (-not (Show-AppMessage 'Stop it and close? The part-made file is deleted.' -YesText 'Stop and close' -NoText 'Keep going' -Owner $s)) { $e.Cancel = $true; return }
            $j.Job.Stop(); Start-Sleep -Milliseconds 500; Remove-Item -LiteralPath $j.Out -Force -ErrorAction SilentlyContinue; $script:ToolJob = $null
        }
    })
}

# --- Join -----------------------------------------------------------------
function Show-Join {
    $ui = $script:UI
    # In name order, so "part 1, part 2, part 3" or "Episode 1, Episode 2" go together the right way round.
    $sel = @($script:Items | Where-Object { $ui.LstVideos.SelectedItems.Contains($_) -and $_.Info -and $_.Info.VCodec -and (Test-Path -LiteralPath $_.Path) } |
        Sort-Object { [regex]::Replace($_.Name, '\d+', { param($m) $m.Value.PadLeft(8, '0') }) })
    if ($sel.Count -lt 2) { [void](Show-AppMessage 'Select the videos to join in the list first: two or more, with Ctrl+click (or Shift+click). They''re joined in name order (so Part 1 comes before Part 2).'); return }
    $first = $sel[0].Info
    $sig = { param($x) "$($x.VCodec)|$($x.Width)x$($x.Height)|$($x.Bits)|" + ((@($x.Audio) | ForEach-Object { "$($_.Codec)/$($_.Ch)" }) -join ',') }
    $same = @($sel | Where-Object { (& $sig $_.Info) -ne (& $sig $first) -or $_.Info.Ext -ne $first.Ext }).Count -eq 0
    $noSound = @($sel | Where-Object { -not $_.Info.Audio.Count }).Count
    $total = 0.0; foreach ($s in $sel) { $total += $s.Info.Seconds }
    $w = New-ToolWindow 'Join videos' 640 520
    $w.FindName('TwHead').Text = "Join $($sel.Count) videos into one ($(Format-Length $total))"
    $lines = @('IN THIS ORDER') + @($sel | ForEach-Object { "$script:Dot $($_.Name)  ($(Format-Length $_.Info.Seconds))" }) + @('')
    if ($same) {
        $lines += 'HOW', 'They all have the same picture and sound, so they''re joined as they are: nothing is converted, it takes seconds and nothing is lost.'
    } elseif ($noSound -and $noSound -lt $sel.Count) {
        $lines += 'CAN''T JOIN', 'Some of them have no sound and some do, so they can''t be joined. Convert the ones with no sound first or leave them out.'
    } else {
        $lines += 'HOW', "They're different (picture size, format or sound), so they have to be converted to one H.264 MP4 at the size of the first ($($first.Width)x$($first.Height)), with stereo sound. That takes a while, and subtitles aren't kept."
    }
    $lines += '', 'The new video is saved where the new videos go, named after the first one with (joined), and added to the list.'
    Set-ToolText $w $lines
    $go = Add-ToolButton $w 'Join them' {
        $this.IsEnabled = $false
        $it0 = $script:JoinSel[0]; $f = $it0.Info
        if ($script:JoinSame) {
            $ext = $f.Ext
            $o = Get-UtilOutPath $it0 'joined' $ext
            $list = Join-Path $script:TempDir 'join-list.txt'
            $txt = ($script:JoinSel | ForEach-Object { "file '" + $_.Path.Replace("'", "'\''") + "'" }) -join "`n"
            [IO.File]::WriteAllText($list, $txt, (New-Object Text.UTF8Encoding $false))
            $a = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $list, '-map', '0:v:0', '-map', '0:a?', '-map', '0:s?', '-c', 'copy')
            if ($ext -in 'mp4', 'm4v', 'mov') { $a += '-movflags', '+faststart' }
            $a += '-max_muxing_queue_size', '4096', '-progress', 'pipe:1', '-nostats', $o
        } else {
            $o = Get-UtilOutPath $it0 'joined' 'mp4'
            $W = $f.Width - ($f.Width % 2); $H = $f.Height - ($f.Height % 2)
            $a = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error')
            foreach ($s in $script:JoinSel) { $a += '-i', $s.Path }
            $parts = @(); $chain = ''
            for ($k = 0; $k -lt $script:JoinSel.Count; $k++) {
                $x = $script:JoinSel[$k].Info
                $sdr = @(Get-SdrFilter $x)
                $pre = if ($sdr.Count) { ($sdr -join ',') + ',' } else { '' }
                $parts += "[${k}:$($x.VIndex)]${pre}scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25,format=yuv420p[v$k]"
                if ($script:JoinSound) {
                    $m = Get-MainSound $x
                    $parts += "[${k}:$($m.Index)]aformat=sample_rates=48000:channel_layouts=stereo[a$k]"
                    $chain += "[v$k][a$k]"
                } else { $chain += "[v$k]" }
            }
            $n = $script:JoinSel.Count
            $parts += "${chain}concat=n=${n}:v=1:a=$(if ($script:JoinSound) { 1 } else { 0 })[v]$(if ($script:JoinSound) { '[a]' })"
            $a += '-filter_complex', ($parts -join ';'), '-map', '[v]'
            if ($script:JoinSound) { $a += '-map', '[a]', '-c:a', 'aac', '-b:a', '192k' }
            $a += '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-movflags', '+faststart', '-max_muxing_queue_size', '4096', '-progress', 'pipe:1', '-nostats', $o
        }
        Invoke-FfmpegJob ([Windows.Window]::GetWindow($this)) 'Joining' (Join-Args $a) $script:JoinSecs $o
    } -Accent
    if (-not $same -and $noSound -and $noSound -lt $sel.Count) { $go.IsEnabled = $false }
    $script:JoinSel = $sel; $script:JoinSame = $same; $script:JoinSecs = $total; $script:JoinSound = ($noSound -eq 0)
    [void]$w.ShowDialog()
}

# --- Duplicates -------------------------------------------------------------
function Get-PlainTitle([string]$Name) {
    <# A film's name with the quality words, brackets and punctuation taken out, to spot the same film twice. #>
    $n = [IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
    $n = $n -replace '\((converted|tracks|louder|turned|no tags|with cover|sound (later|earlier)[^)]*)\)', ' '    # copies of the same film; trimmed, joined and parts aren't
    $n = $n -replace '[\._\-\[\]\(\)\{\}]', ' '
    $n = $n -replace '\b(2160p|1080p|1080i|720p|576p|480p|4k|uhd|hd|sd|x264|x265|h264|h265|hevc|avc|xvid|divx|av1|vp9|10bit|8bit|hdr|hdr10|dv|bluray|blu ray|bdrip|brrip|webrip|web dl|web|dvdrip|dvd|remux|aac|ac3|dts|truehd|atmos|5 1|7 1|proper|repack|extended|remastered|copy)\b', ' '
    return (($n -replace '\s+', ' ').Trim())
}

function Get-QualityScore($i) {
    $codec = switch ($i.VCodec) { 'av1' { 3 } 'hevc' { 3 } 'vp9' { 2 } 'h264' { 2 } default { 1 } }
    return ($i.Width * $i.Height) * 10 + $(if ($i.Hdr) { 5 } else { 0 }) + $codec + [math]::Min(0.99, $i.Bytes / 1e12)
}

function Show-Duplicates {
    $all = @($script:Items | Where-Object { $_.Info -and $_.Info.VCodec })
    if ($all.Count -lt 2) { [void](Show-AppMessage 'Add some videos (or a whole folder) first, then look for duplicates among them.'); return }
    $groups = New-Object Collections.Generic.List[object]
    $used = @{}
    # The same name once the quality words are taken out
    foreach ($g in @($all | Group-Object { Get-PlainTitle $_.Name } | Where-Object { $_.Count -gt 1 -and $_.Name })) {
        $groups.Add(@{ Why = 'Same name'; Items = @($g.Group) }); foreach ($x in $g.Group) { $used[$x.Path] = $true }
    }
    # Or the same length to the second (films over 5 minutes), whatever they're called
    $rest = @($all | Where-Object { -not $used[$_.Path] -and $_.Info.Seconds -gt 300 })
    foreach ($g in @($rest | Group-Object { [math]::Round($_.Info.Seconds) } | Where-Object { $_.Count -gt 1 })) { $groups.Add(@{ Why = 'Same length'; Items = @($g.Group) }) }
    $w = New-ToolWindow 'Find duplicates' 760 600
    $script:DupExtras = @()
    if (-not $groups.Count) {
        $w.FindName('TwHead').Text = 'No duplicates found'
        Set-ToolText $w @("None of the $($all.Count) videos in the list look like the same film twice (by name, leaving out words such as 1080p, x265 or BluRay, or by having the same length).")
    } else {
        $w.FindName('TwHead').Text = "$($groups.Count) video$(if ($groups.Count -ne 1) { 's' }) found more than once"
        $lines = @()
        foreach ($g in $groups) {
            $sorted = @($g.Items | Sort-Object { Get-QualityScore $_.Info } -Descending)
            $lines += ($(Get-PlainTitle $sorted[0].Name).ToUpper() -replace '[^A-Z0-9 ,]', '') + $(if (-not (Get-PlainTitle $sorted[0].Name)) { 'UNTITLED' })
            $lines += "$($g.Why). Best first:"
            $k = 0
            foreach ($x in $sorted) {
                $mark = if ($k -eq 0) { 'Best  ' } else { '       ' }
                $lines += "$mark$script:Dot $($x.Name)  ($(Get-ItemDetails $x.Info))"
                $lines += "          $($x.Folder)"
                if ($k -gt 0) { $script:DupExtras += $x }
                $k++
            }
            $lines += ''
        }
        $lines += 'Best is the biggest picture first, then HDR, then the newer format, then the bigger file. Nothing is deleted here: Select the extra copies picks them in the list, so you can look at them, or Remove them from the list.'
        Set-ToolText $w $lines
        [void](Add-ToolButton $w 'Select the extra copies' {
            $lst = $script:UI.LstVideos
            $script:UI.PillAll.IsChecked = $true
            $lst.SelectedItems.Clear()
            foreach ($x in $script:DupExtras) { [void]$lst.SelectedItems.Add($x) }
            [Windows.Window]::GetWindow($this).Close()
            Set-Status "$($script:DupExtras.Count) extra cop$(if ($script:DupExtras.Count -eq 1) { 'y' } else { 'ies' }) selected in the list. Nothing has been deleted."
        })
    }
    [void]$w.ShowDialog()
}

# --- Stats ------------------------------------------------------------------
$script:StatsPath = Join-Path $script:DataDir 'stats.json'
function Get-AllTimeStats {
    $s = @{ Converted = 0; Seconds = 0.0; Before = 0.0; After = 0.0 }
    if (Test-Path -LiteralPath $script:StatsPath) {
        try { $j = Get-Content -LiteralPath $script:StatsPath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = [double]$j.$k } } } catch { Write-AppLog "stats.json couldn't be read: $($_.Exception.Message)" }
    }
    return $s
}

function Add-AllTimeStats([double]$Seconds, [double]$Before, [double]$After) {
    $s = Get-AllTimeStats
    $s.Converted++; $s.Seconds += $Seconds; $s.Before += $Before; $s.After += $After
    try { [pscustomobject]$s | ConvertTo-Json | Set-Content -LiteralPath $script:StatsPath -Encoding UTF8 } catch { Write-AppLog "stats.json couldn't be saved: $($_.Exception.Message)" }
}

function Get-CountLine([string]$Head, $Values) {
    $g = @($Values | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending)
    if (-not $g.Count) { return @() }
    return @($Head) + @(($g | ForEach-Object { "$($_.Name) $($_.Count)" }) -join "  $script:Dot  ") + @('')
}

function Show-Stats {
    $all = @($script:Items)
    $ok = @($all | Where-Object { $_.Info -and $_.Info.VCodec })
    $w = New-ToolWindow 'Stats' 680 620
    $w.FindName('TwHead').Text = 'Stats'
    $lines = @()
    if ($all.Count) {
        $size = 0.0; $len = 0.0; foreach ($x in $ok) { $size += $x.Info.Bytes; $len += $x.Info.Seconds }
        $plays = @($all | Where-Object { $_.State -eq 'Plays' }).Count
        $lines += 'THIS LIST'
        $lines += "$($all.Count) videos, $(Format-Size $size), $(Format-Length $len) to watch."
        $lines += "On $($script:Settings.Target): $plays play as they are ($([int](100 * $plays / [math]::Max(1, $ok.Count)))%), $(@($all | Where-Object { $_.State -eq 'Needs' }).Count) need work, $(@($all | Where-Object { $_.State -eq 'Done' }).Count) done, $(@($all | Where-Object { $_.State -in 'Error', 'Failed' }).Count) can't be read or failed."
        $lines += ''
        $lines += Get-CountLine 'PICTURE FORMATS' @($ok | ForEach-Object { Get-CodecName $_.Info.VCodec })
        $lines += Get-CountLine 'PICTURE SIZES' @($ok | ForEach-Object { Get-ResLabel $_.Info.Width $_.Info.Height })
        $lines += Get-CountLine 'HDR' @($ok | ForEach-Object { $_.Info.Hdr })
        $lines += Get-CountLine 'MAIN SOUND' @($ok | ForEach-Object { $m = Get-MainSound $_.Info; if ($m) { Get-SoundName $m } else { 'No sound' } })
        $lines += Get-CountLine 'FILE TYPES' @($ok | ForEach-Object { $_.Info.Ext.ToUpper() })
        $big = @($ok | Sort-Object { $_.Info.Bytes } -Descending | Select-Object -First 5)
        if ($big.Count) { $lines += 'BIGGEST'; $lines += @($big | ForEach-Object { "$script:Dot $($_.Name)  ($(Format-Size $_.Info.Bytes))" }); $lines += '' }
    } else { $lines += 'THIS LIST', 'No videos in the list yet.', '' }
    $s = Get-AllTimeStats
    $lines += 'ALL TIME'
    if ($s.Converted) {
        $diff = $s.Before - $s.After
        $lines += "$([int]$s.Converted) videos converted, $(Format-Length $s.Seconds) of video."
        $lines += "They were $(Format-Size $s.Before) and are now $(Format-Size $s.After): $(if ($diff -ge 0) { "$(Format-Size $diff) saved" } else { "$(Format-Size (-$diff)) more" })."
    } else { $lines += 'Nothing converted yet.' }
    Set-ToolText $w $lines
    [void]$w.ShowDialog()
}

# --- Report -------------------------------------------------------------------
function Get-ExcelText([string]$Text) {
    <# Excel turns 1917, 007 or 3-10 into numbers and dates: those are written ="..." so they open as typed. #>
    if ($null -eq $Text) { $Text = '' }
    $q = '"' + $Text.Replace('"', '""') + '"'
    if ($Text -match '^\s*[=+\-@]' -or $Text -match '^[\d\s\-/.:,]+$') { return '=' + $q }
    return $q
}

function Get-ReportRows {
    foreach ($x in @($script:Items)) {
        $i = $x.Info
        $why = if ($x.Verdict) { ((@($x.Verdict.Reasons) + @($x.Verdict.Notes)) -join '; ') } else { $x.Error }
        [pscustomobject][ordered]@{
            Name = $x.Name; Folder = $x.Folder; Status = $x.Status
            Picture = if ($i -and $i.VCodec) { Get-VideoName $i } else { '' }
            Size = if ($i -and $i.VCodec) { "$($i.Width)x$($i.Height)" } else { '' }
            Sound = if ($i) { (@($i.Audio) | ForEach-Object { Get-SoundName $_ }) -join ', ' } else { '' }
            Subtitles = if ($i) { (@($i.Subs) | ForEach-Object { Get-CodecName $_.Codec }) -join ', ' } else { '' }
            Type = if ($i) { $i.Ext.ToUpper() } else { '' }
            Length = if ($i) { Format-Length $i.Seconds } else { '' }
            FileSize = if ($i) { Format-Size $i.Bytes } else { '' }
            Why = $why; NewFile = $x.OutPath
        }
    }
}

function Export-Report([ValidateSet('Csv', 'Html')][string]$Kind, [string]$Path) {
    if (-not $script:Items.Count) { [void](Show-AppMessage 'The list is empty, so there''s nothing to put in a report yet.'); return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Save the report'
    $dlg.FileName = "Video Converter report $((Get-Date).ToString('yyyy-MM-dd'))"
    $dlg.Filter = if ($Kind -eq 'Csv') { 'CSV for Excel (*.csv)|*.csv' } else { 'Web page (*.html)|*.html' }
    if ($Path) { $dlg.FileName = $Path } elseif (-not $dlg.ShowDialog($script:Window)) { return }
    $rows = @(Get-ReportRows)
    $heads = @('Name', 'Folder', 'Status', 'Picture', 'Size', 'Sound', 'Subtitles', 'File type', 'Length', 'File size', 'Why', 'New file')
    $props = @('Name', 'Folder', 'Status', 'Picture', 'Size', 'Sound', 'Subtitles', 'Type', 'Length', 'FileSize', 'Why', 'NewFile')
    if ($Kind -eq 'Csv') {
        $sb = New-Object Text.StringBuilder
        [void]$sb.AppendLine((($heads | ForEach-Object { '"' + $_ + '"' }) -join ','))
        foreach ($r in $rows) { [void]$sb.AppendLine((($props | ForEach-Object { Get-ExcelText ([string]$r.$_) }) -join ',')) }
        [IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), (New-Object Text.UTF8Encoding $true))
    } else {
        $enc = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append("<!doctype html><html lang=""en""><head><meta charset=""utf-8""><title>Video Converter report</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#262220}h1{font-size:22px;margin:0 0 4px}p{color:#6a615b;margin:0 0 16px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid #e3dcd6;padding:6px 8px;text-align:left;vertical-align:top}th{background:#f7f4f1}tr.Plays td.s,tr.Done td.s{color:#1e8a57;font-weight:600}tr.Needs td.s{color:#b8461b;font-weight:600}tr.Error td.s,tr.Failed td.s{color:#b3261e;font-weight:600}</style></head><body>")
        [void]$sb.Append("<h1>Video Converter report</h1><p>$(& $enc "$($rows.Count) videos for $($script:Settings.Target), $((Get-Date).ToString('d MMMM yyyy HH:mm'))")</p><table><tr>")
        foreach ($h in $heads) { [void]$sb.Append("<th>$(& $enc $h)</th>") }
        [void]$sb.Append('</tr>')
        $k = 0
        foreach ($r in $rows) {
            $state = [string]@($script:Items)[$k].State; $k++
            [void]$sb.Append("<tr class=""$state"">")
            foreach ($p in $props) { [void]$sb.Append("<td$(if ($p -eq 'Status') { ' class="s"' })>$(& $enc $r.$p)</td>") }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table></body></html>')
        [IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
    }
    Set-Status "Report saved: $($dlg.FileName)" 'Good'
    Write-AppLog "Report saved: $($dlg.FileName)"
}

# --- Save and open the list ---------------------------------------------------
# v1.00 kept the list between runs in last-list.json; it always starts empty now, so that file is tidied away.
$oldList = Join-Path $script:DataDir 'last-list.json'
if (Test-Path -LiteralPath $oldList) { Remove-Item -LiteralPath $oldList -Force -ErrorAction SilentlyContinue }
$script:Restore = @{}
function Save-List([string]$Path) {
    $data = [ordered]@{ Target = $script:Settings.Target; Videos = @($script:Items | ForEach-Object { [ordered]@{ Path = $_.Path; State = $(if ($_.State -eq 'Done') { 'Done' } else { '' }); OutPath = $_.OutPath } }) }
    [pscustomobject]$data | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Open-List([string]$Path, [switch]$Quiet) {
    $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $paths = @(); $missing = 0
    foreach ($v in @($j.Videos)) {
        if (-not $v.Path) { continue }
        if (Test-Path -LiteralPath $v.Path) { $paths += [string]$v.Path; $script:Restore[[string]$v.Path] = @{ State = [string]$v.State; OutPath = [string]$v.OutPath } }
        elseif ($v.State -eq 'Done' -and $v.OutPath -and (Test-Path -LiteralPath $v.OutPath)) { $paths += [string]$v.OutPath }    # the original went to the Recycle Bin: the new file is checked instead
        else { $missing++ }
    }
    if ($paths.Count) { Add-Paths $paths }
    $msg = "Opened the list: $($paths.Count) video$(if ($paths.Count -ne 1) { 's' }) being checked."
    if ($missing) { $msg += " $missing aren't there any more, so they're left out." }
    if ($Quiet) { $msg = "Reopened last time's list: $($paths.Count) video$(if ($paths.Count -ne 1) { 's' })." + $(if ($missing) { " $missing aren't there any more." } else { '' }) }
    Set-Status $msg
    Write-AppLog $msg
}

function Save-ListAs {
    if (-not $script:Items.Count) { [void](Show-AppMessage 'The list is empty, so there''s nothing to save yet.'); return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Save the list'
    $dlg.FileName = "Video list $((Get-Date).ToString('yyyy-MM-dd'))"
    $dlg.Filter = 'Video Converter list (*.vclist)|*.vclist'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    Save-List $dlg.FileName
    Set-Status "List saved: $($dlg.FileName)" 'Good'
}

function Open-ListFile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Open a list'
    $dlg.Filter = 'Video Converter list (*.vclist)|*.vclist|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    if ($script:Items.Count -and (Show-AppMessage 'Add its videos to the ones already in the list, or start a new list with them?' -YesText 'Start a new list' -NoText 'Add them')) { $script:Items.Clear(); Update-Summary }
    Open-List $dlg.FileName
}

# --- Convert at a set time ------------------------------------------------------
function Select-StartTime {
    if ($script:Run) { return }
    $w = New-ToolWindow 'Convert at a set time' 520 330
    $w.FindName('TwHead').Text = 'Start converting at a set time'
    Set-ToolText $w @('Type the time to start, such as 01:00 for one in the morning. The app has to stay open (the PC can be locked). Under "When the whole list is done" on the right you can also have it put the PC to sleep or shut it down afterwards.')
    $box = New-Object Windows.Controls.TextBox
    $box.Width = 120; $box.Height = 32; $box.Text = '01:00'; $box.HorizontalAlignment = 'Left'; $box.Margin = '0,12,0,0'
    $panel = $w.FindName('TwText').Parent.Parent
    $sp = New-Object Windows.Controls.StackPanel
    [Windows.Controls.DockPanel]::SetDock($sp, 'Bottom')
    [void]$sp.Children.Add($box)
    $panel.Children.Insert(2, $sp)
    $script:TimeBox = $box
    [void](Add-ToolButton $w 'Start then' {
        $t = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($script:TimeBox.Text.Trim(), @('H:mm', 'HH:mm', 'H.mm', 'HH.mm'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)) { [void](Show-AppMessage 'Type the time as hours:minutes, such as 01:00 or 23:30.' -Owner ([Windows.Window]::GetWindow($this))); return }
        $at = (Get-Date).Date.Add($t.TimeOfDay)
        if ($at -le (Get-Date)) { $at = $at.AddDays(1) }
        $script:StartAt = $at
        [Windows.Window]::GetWindow($this).Close()
        $script:UI.BtnStop.Visibility = 'Visible'; $script:UI.BtnStop.Content = 'Cancel'
        Update-Summary
        Set-Status "Waiting to start converting at $($at.ToString('HH:mm'))$(if ($at.Date -gt (Get-Date).Date) { ' tomorrow' }). Leave the app open; Cancel stops the wait."
        Write-AppLog "Waiting to convert at $at"
    } -Accent)
    [void]$w.ShowDialog()
}

function Test-StartTime {
    if (-not $script:StartAt -or $script:Run) { return }
    if ((Get-Date) -lt $script:StartAt) { return }
    $script:StartAt = $null
    $script:UI.BtnStop.Content = 'Stop'
    Write-AppLog 'Set time reached: converting'
    if (@($script:Items | Where-Object { $_.State -eq 'Needs' }).Count) { Start-Convert }
    else { $script:UI.BtnStop.Visibility = 'Collapsed'; Set-Status 'The set time came, but nothing in the list needed converting.' }
}

# --- When the list is done -------------------------------------------------------
function Show-DoneNotice([string]$Text) {
    <# A Windows notification (beside the clock) and a sound. #>
    try { [Media.SystemSounds]::Asterisk.Play() } catch { Write-Verbose 'no sound' }
    try {
        $ni = New-Object Windows.Forms.NotifyIcon
        $ico = Join-Path $script:AssetsDir 'Video-Converter.ico'
        $ni.Icon = if (Test-Path -LiteralPath $ico) { New-Object Drawing.Icon $ico } else { [Drawing.SystemIcons]::Information }
        $ni.Text = $script:AppName
        $ni.Visible = $true
        $ni.ShowBalloonTip(15000, $script:AppName, $Text, [Windows.Forms.ToolTipIcon]::Info)
        $script:Notice = $ni
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds(20)
        $t.Add_Tick({ $this.Stop(); if ($script:Notice) { $script:Notice.Visible = $false; $script:Notice.Dispose(); $script:Notice = $null } })
        $t.Start()
    } catch { Write-AppLog "No notification: $($_.Exception.Message)" }
}

function Invoke-PowerAction([string]$Action) {
    Write-AppLog "When done: $Action"
    if ($Action -eq 'Shutdown') { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s', '/t', '0' -WindowStyle Hidden }
    elseif ($Action -eq 'Sleep') { [void][Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) }
}

function Start-PowerCountdown([string]$Action) {
    <# 60 seconds to change your mind before sleep or shut down. #>
    $what = if ($Action -eq 'Shutdown') { 'shut down' } else { 'go to sleep' }
    $w = New-ToolWindow 'The list is done' 520 300
    $w.FindName('TwHead').Text = "The PC will $what in 60 seconds"
    Set-ToolText $w @("Everything in the list is done. Cancel to keep the PC on.")
    $script:Countdown = @{ Left = 60; Action = $Action; Window = $w; What = $what }
    [void](Add-ToolButton $w "$(if ($Action -eq 'Shutdown') { 'Shut down' } else { 'Sleep' }) now" { $script:Countdown.Left = 0 } -Accent)
    $w.FindName('TwClose').Content = 'Cancel'
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1)
    $t.Add_Tick({
        $c = $script:Countdown
        if (-not $c) { $this.Stop(); return }
        $c.Left--
        if ($c.Left -gt 0) { $c.Window.FindName('TwHead').Text = "The PC will $($c.What) in $($c.Left) seconds"; return }
        $this.Stop(); $script:Countdown = $null
        $c.Window.Close()
        Invoke-PowerAction $c.Action
    })
    $w.Add_Closed({ if ($script:Countdown) { $script:Countdown = $null; Set-Status 'Cancelled: the PC stays on.' } })
    $t.Start()
    [void]$w.ShowDialog()
}

# --- The More button ------------------------------------------------------------
function Show-MoreMenu {
    $menu = New-Object Windows.Controls.ContextMenu
    $menu.Style = $script:Window.FindResource([Windows.Controls.ContextMenu])
    if ($script:Zoom -gt 1.01) { $menu.LayoutTransform = New-Object Windows.Media.ScaleTransform $script:Zoom, $script:Zoom }
    $canConvert = -not $script:Run -and [bool]@($script:Items | Where-Object { $_.State -eq 'Needs' }).Count
    $items = @(
        @{ Text = 'Join the selected videos...'; Do = { Invoke-Safely { Show-Join } }; On = $true }
        @{ Text = 'Find duplicates...'; Do = { Invoke-Safely { Show-Duplicates } }; On = $true }
        @{ Text = 'Stats...'; Do = { Invoke-Safely { Show-Stats } }; On = $true }
        @{ Text = 'Save a report for Excel (CSV)...'; Do = { Invoke-Safely { Export-Report 'Csv' } }; On = $true }
        @{ Text = 'Save a report as a web page (HTML)...'; Do = { Invoke-Safely { Export-Report 'Html' } }; On = $true }
        @{ Text = 'Save the list...'; Do = { Invoke-Safely { Save-ListAs } }; On = $true }
        @{ Text = 'Open a list...'; Do = { Invoke-Safely { Open-ListFile } }; On = (-not $script:Run) }
        @{ Text = 'Convert at a set time...'; Do = { Invoke-Safely { Select-StartTime } }; On = $canConvert }
    )
    foreach ($m in $items) {
        $mi = New-Object Windows.Controls.MenuItem
        $mi.Header = $m.Text; $mi.Style = $script:Window.FindResource([Windows.Controls.MenuItem]); $mi.IsEnabled = [bool]$m.On
        $mi.Add_Click($m.Do)
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $script:UI.BtnMore
    $menu.Placement = 'Bottom'
    $menu.IsOpen = $true
}
#endregion TOOLS

#region OPTIONS
function Get-GpuText {
    if (-not $script:FFmpeg) { return '' }
    if (-not [VcGpu]::Ready) { return 'Looking for a graphics card encoder...' }
    if ($script:GpuBroken) { return "The graphics card ($([VcGpu]::Name)) failed once, so the processor is used until the app is started again." }
    if ([VcGpu]::Name) {
        $kinds = @(@([VcGpu]::H264, [VcGpu]::Hevc) | Where-Object { $_ } | ForEach-Object { if ($_ -like 'h264*') { 'H.264' } else { 'HEVC' } }) -join ' and '
        return "Found: $([VcGpu]::Name), for $kinds$(if ([VcGpu]::Hevc -and -not [VcGpu]::HevcTen) { ' (10-bit HEVC is done on the processor)' })."
    }
    return 'No graphics card encoder works on this PC, so the processor is used. It needs an NVIDIA (GTX 900 or later), Intel (Quick Sync) or AMD card with up-to-date drivers.'
}

function Show-Options {
    $ui = $script:UI; $s = $script:Settings
    $script:Loading = $true
    Select-ComboTag $ui.CmbQuality $s.Quality
    Select-ComboTag $ui.CmbFileType $s.FileType
    Select-ComboTag $ui.CmbVideo $s.VideoOut
    Select-ComboTag $ui.CmbSave $s.SaveTo
    Select-ComboTag $ui.CmbOriginals $s.Originals
    Select-ComboTag $ui.CmbCType $s.CustomType
    Select-ComboTag $ui.CmbCVideo $s.CustomVideo
    Select-ComboTag $ui.CmbCSound $s.CustomSound
    Select-ComboTag $ui.CmbCSize $s.CustomSize
    $ui.ChkSrt.IsChecked = [bool]$s.Srt
    $ui.ChkGpu.IsChecked = [bool]$s.Gpu
    $ui.TxtGpu.Text = Get-GpuText
    Select-ComboTag $ui.CmbSend $s.SendMode
    $ui.PanelSend.Visibility = if ($s.SendMode -ne 'Off') { 'Visible' } else { 'Collapsed' }
    $ui.TxtSend.Text = if ($s.SendFolder) { $s.SendFolder } else { '(not chosen yet)' }
    $ui.ChkNotify.IsChecked = [bool]$s.Notify
    $ui.PanelOut.Visibility = if ($s.SaveTo -eq 'Folder') { 'Visible' } else { 'Collapsed' }
    $ui.TxtOut.Text = if ($s.OutFolder) { $s.OutFolder } else { '(not chosen yet)' }
    $custom = [bool]$script:Targets[[string]$s.Target].Custom
    $ui.PanelCustom.Visibility = if ($custom) { 'Visible' } else { 'Collapsed' }
    $ui.PanelFormat.Visibility = if ($custom) { 'Collapsed' } else { 'Visible' }
    $ui.TxtTargetNote.Text = (Get-Target).Note
    $ui.TxtFfmpeg.Text = if ($script:FFmpeg) { "FFmpeg: $script:FFmpeg" } else { 'FFmpeg: not found' }
    $ui.PanelNoFfmpeg.Visibility = if ($script:FFprobe) { 'Collapsed' } else { 'Visible' }
    $script:Loading = $false
}

function Read-Options {
    if ($script:Loading) { return }
    $ui = $script:UI; $s = $script:Settings
    $s.Target = [string]$ui.CmbTarget.SelectedItem
    $s.Quality = [string]$ui.CmbQuality.SelectedItem.Tag
    $s.FileType = [string]$ui.CmbFileType.SelectedItem.Tag
    $s.VideoOut = [string]$ui.CmbVideo.SelectedItem.Tag
    $s.SaveTo = [string]$ui.CmbSave.SelectedItem.Tag
    $s.Originals = [string]$ui.CmbOriginals.SelectedItem.Tag
    $s.CustomType = [string]$ui.CmbCType.SelectedItem.Tag
    $s.CustomVideo = [string]$ui.CmbCVideo.SelectedItem.Tag
    $s.CustomSound = [string]$ui.CmbCSound.SelectedItem.Tag
    $s.CustomSize = [string]$ui.CmbCSize.SelectedItem.Tag
    $s.Srt = [bool]$ui.ChkSrt.IsChecked
    $s.Gpu = [bool]$ui.ChkGpu.IsChecked
    $s.SendMode = [string]$ui.CmbSend.SelectedItem.Tag
    $s.Notify = [bool]$ui.ChkNotify.IsChecked
    Save-AppSetting
    Show-Options
    Update-AllChecks
}

function Find-FfmpegByHand {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Find ffmpeg.exe (ffprobe.exe must be in the same folder)'
    $dlg.Filter = 'ffmpeg.exe|ffmpeg.exe|Programs (*.exe)|*.exe'
    if (-not $dlg.ShowDialog($script:Window)) { return }
    $script:Settings.FFmpeg = $dlg.FileName
    Save-AppSetting
    Reset-FFmpeg
}

function Reset-FFmpeg {
    $ok = Initialize-FFmpeg
    $script:GpuBroken = $false; $script:GpuShown = $false
    if ($script:FFmpeg) { [VcGpu]::Start($script:FFmpeg) }
    Show-Options
    Update-Summary
    if ($ok) { Set-Status "FFmpeg found: $script:FFmpeg" 'Good' }
    elseif ($script:FFmpeg) { Set-Status "ffmpeg.exe was found but ffprobe.exe wasn't, in $(Split-Path -Parent $script:FFmpeg). Both are needed." 'Warn' }
    else { Set-Status "FFmpeg still isn't found. When winget has finished, press Look again." 'Warn' }
}
#endregion OPTIONS

# ---------------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------------
try {
    $window = New-XamlWindow $mainXaml
    $script:Window = $window
    $window.Title = "$script:AppName v$script:AppVersion"
    # A roomy window: most of the screen, never smaller than 1280 x 800 (when the screen has room).
    $area = [Windows.SystemParameters]::WorkArea
    $window.Width  = [Math]::Min($area.Width, [Math]::Max(1280, $area.Width * 0.88))
    $window.Height = [Math]::Min($area.Height, [Math]::Max(800, $area.Height * 0.88))
    # On a big screen everything is drawn larger too (text, buttons, lists), not just the window.
    $zoom = [Math]::Max(1.0, [Math]::Min(1.3, $area.Width / 1900.0))
    if ($zoom -gt 1.01) { $window.FindName('Root').LayoutTransform = New-Object Windows.Media.ScaleTransform $zoom, $zoom }
    $script:Zoom = $zoom
    $icon = Get-AssetImage 'Video-Converter.ico'
    if ($icon) { $window.Icon = $icon }
    $ui = @{}
    foreach ($n in 'BtnPause', 'BtnStop', 'BtnLook', 'BtnHelp', 'BtnAbout', 'TxtStatus', 'Progress', 'BtnAddFiles', 'BtnAddFolder', 'BtnConvert', 'TxtSummary',
                   'CmbTarget', 'TxtTargetNote', 'PanelNoFfmpeg', 'BtnInstall', 'BtnFindFfmpeg', 'BtnLookAgain', 'BtnRemove', 'BtnClear',
                   'PillAll', 'PillNeeds', 'PillPlays', 'PillDone', 'PanelEmpty', 'TxtEmpty', 'LstVideos',
                   'TxtNoPicture', 'ImgPreview', 'TxtPrvName', 'TxtPrvFacts', 'BtnPlay', 'BtnSample', 'BtnFolder', 'BtnUtils', 'TxtVerdict', 'TxtReasons', 'TxtStepsHead', 'TxtSteps',
                   'PanelCustom', 'CmbCType', 'CmbCVideo', 'CmbCSound', 'CmbCSize', 'CmbQuality', 'PanelFormat', 'CmbFileType', 'CmbVideo', 'CmbSave', 'PanelOut', 'BtnOut', 'TxtOut',
                   'CmbOriginals', 'ChkSrt', 'ChkGpu', 'TxtGpu', 'BtnFfmpeg', 'TxtFfmpeg', 'BtnMore', 'CmbSend', 'PanelSend', 'BtnSend', 'TxtSend', 'CmbWhenDone', 'ChkNotify') { $ui[$n] = $window.FindName($n) }
    $script:UI = $ui

    [void](Initialize-FFmpeg)
    if ($script:FFmpeg) { [VcGpu]::Start($script:FFmpeg) }
    if (-not $script:Targets.Contains([string]$script:Settings.Target)) { $script:Settings.Target = $script:DefaultTarget }
    $script:Loading = $true
    foreach ($k in $script:Targets.Keys) { [void]$ui.CmbTarget.Items.Add($k) }
    $ui.CmbTarget.SelectedItem = [string]$script:Settings.Target
    $script:Loading = $false
    $script:Target = Get-Target
    Show-Options

    $script:View = [Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $script:View.Filter = [Predicate[object]] {
        param($x)
        switch ($script:Filter) {
            'Needs' { return $x.State -in 'Needs', 'Working' }
            'Plays' { return $x.State -eq 'Plays' }
            'Done'  { return $x.State -in 'Done', 'Failed' }
            default { return $true }
        }
    }
    $ui.LstVideos.ItemsSource = $script:View
    Update-Summary

    $setLook = { $ui.BtnLook.Content = switch ($script:Settings.Look) { 'Dark' { 'Look: Dark' } 'System' { 'Look: Auto' } default { 'Look: Light' } } }
    & $setLook
    $ui.BtnLook.ToolTip = 'Light, dark, or the same as Windows. Used the next time the app starts.'
    $ui.BtnLook.Add_Click({
        $script:Settings.Look = switch ($script:Settings.Look) { 'Light' { 'Dark' } 'Dark' { 'System' } default { 'Light' } }
        Save-AppSetting; & $setLook
        Set-Status 'Look saved. It is used the next time the app starts.'
    })
    $ui.BtnHelp.Add_Click({ Show-Help })
    $ui.BtnAbout.Add_Click({ Show-About -Owner $window })

    $ui.BtnAddFiles.Add_Click({ Invoke-Safely {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Add videos'
        $dlg.Multiselect = $true
        $dlg.Filter = 'Videos|' + (($script:VideoExt | ForEach-Object { "*$_" }) -join ';') + '|All files (*.*)|*.*'
        if ($script:Settings.LastFolder -and (Test-Path -LiteralPath $script:Settings.LastFolder)) { $dlg.InitialDirectory = $script:Settings.LastFolder }
        if ($dlg.ShowDialog($window)) {
            $script:Settings.LastFolder = Split-Path -Parent $dlg.FileNames[0]; Save-AppSetting
            Add-Paths $dlg.FileNames
        }
    } })
    $ui.BtnAddFolder.Add_Click({ Invoke-Safely {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose a folder of videos. Every folder inside it is searched too.'
        $dlg.ShowNewFolderButton = $false
        if ($script:Settings.LastFolder -and (Test-Path -LiteralPath $script:Settings.LastFolder)) { $dlg.SelectedPath = $script:Settings.LastFolder }
        if ($dlg.ShowDialog() -eq 'OK') {
            $script:Settings.LastFolder = $dlg.SelectedPath; Save-AppSetting
            Add-Paths @($dlg.SelectedPath)
        }
    } })
    $window.Add_DragOver({ param($s, $e) $e.Effects = if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }; $e.Handled = $true })
    $window.Add_Drop({ param($s, $e) Invoke-Safely { if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { Add-Paths ([string[]]$e.Data.GetData([Windows.DataFormats]::FileDrop)) } } })

    $ui.CmbTarget.Add_SelectionChanged({ Invoke-Safely { Read-Options } })
    foreach ($c in 'CmbQuality', 'CmbFileType', 'CmbVideo', 'CmbOriginals', 'CmbCType', 'CmbCVideo', 'CmbCSound', 'CmbCSize') { $ui[$c].Add_SelectionChanged({ Invoke-Safely { Read-Options } }) }
    $ui.CmbSave.Add_SelectionChanged({ Invoke-Safely {
        Read-Options
        if ($script:Settings.SaveTo -eq 'Folder' -and -not $script:Settings.OutFolder) { [void](Select-OutFolder) }
    } })
    $ui.ChkSrt.Add_Checked({ Invoke-Safely { Read-Options } }); $ui.ChkSrt.Add_Unchecked({ Invoke-Safely { Read-Options } })
    $ui.ChkGpu.Add_Checked({ Invoke-Safely { Read-Options } }); $ui.ChkGpu.Add_Unchecked({ Invoke-Safely { Read-Options } })
    foreach ($c in 'ChkNotify') { $ui[$c].Add_Checked({ Invoke-Safely { Read-Options } }); $ui[$c].Add_Unchecked({ Invoke-Safely { Read-Options } }) }
    $ui.CmbSend.Add_SelectionChanged({ Invoke-Safely {
        Read-Options
        if ($script:Settings.SendMode -ne 'Off' -and -not $script:Settings.SendFolder) { [void](Select-SendFolder) }
    } })
    $ui.BtnSend.Add_Click({ Invoke-Safely { [void](Select-SendFolder) } })
    $ui.BtnMore.Add_Click({ Invoke-Safely { Show-MoreMenu } })
    $ui.BtnOut.Add_Click({ Invoke-Safely { [void](Select-OutFolder) } })
    $ui.BtnFfmpeg.Add_Click({ Invoke-Safely { Find-FfmpegByHand } })
    $ui.BtnFindFfmpeg.Add_Click({ Invoke-Safely { Find-FfmpegByHand } })
    $ui.BtnLookAgain.Add_Click({ Invoke-Safely { Reset-FFmpeg } })
    $ui.BtnInstall.Add_Click({ Invoke-Safely {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { [void](Show-AppMessage "winget isn't on this PC. Download FFmpeg from https://ffmpeg.org/download.html (a Windows build such as gyan.dev's), unzip it, then press Choose ffmpeg.exe... and pick bin\ffmpeg.exe."); return }
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -NoExit -Command "winget install --id Gyan.FFmpeg -e --accept-source-agreements; Write-Host; Write-Host ''When it has finished, close this window and press Look again in Video Converter.''"'
        Set-Status 'Installing FFmpeg in the other window. When it has finished, press Look again.'
    } })

    foreach ($p in 'PillAll', 'PillNeeds', 'PillPlays', 'PillDone') { $ui[$p].Add_Checked({ $script:Filter = [string]$this.Tag; if ($script:View) { Update-Filter } }) }
    $ui.LstVideos.Add_SelectionChanged({ Invoke-Safely { Show-Preview } })
    $ui.LstVideos.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Delete') { Invoke-Safely { Remove-Selected } } })
    $ui.LstVideos.Add_MouseDoubleClick({ $it = $ui.LstVideos.SelectedItem; if ($it) { $f = if ($it.State -eq 'Done' -and $it.OutPath) { $it.OutPath } else { $it.Path }; try { Start-Process -FilePath $f } catch { Set-Status "No player opened it: $($_.Exception.Message)" 'Warn' } } })
    $ui.BtnRemove.Add_Click({ Invoke-Safely { Remove-Selected } })
    $ui.BtnClear.Add_Click({ Invoke-Safely { $script:Items.Clear(); Update-Summary; Show-Preview; Set-Status 'List cleared. Nothing on the disk was changed.' } })
    $ui.BtnPlay.Add_Click({ Invoke-Safely { $it = $ui.LstVideos.SelectedItem; if ($it) { $f = if ($it.State -eq 'Done' -and $it.OutPath -and (Test-Path -LiteralPath $it.OutPath)) { $it.OutPath } else { $it.Path }; Start-Process -FilePath $f } } })
    $ui.BtnFolder.Add_Click({ Invoke-Safely { $it = $ui.LstVideos.SelectedItem; if ($it) { $f = if ($it.State -eq 'Done' -and $it.OutPath -and (Test-Path -LiteralPath $it.OutPath)) { $it.OutPath } else { $it.Path }; Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$f`"" } } })
    $ui.BtnSample.Add_Click({ Invoke-Safely { Start-Sample } })
    $ui.BtnUtils.Add_Click({ Invoke-Safely { Show-Utilities } })
    $ui.BtnConvert.Add_Click({ Invoke-Safely { Start-Convert } })
    $ui.BtnPause.Add_Click({ Invoke-Safely { Switch-Pause } })
    $ui.BtnStop.Add_Click({ Invoke-Safely { [void](Request-Stop) } })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        try {
            Receive-Checks; Receive-Thumb; Receive-Sample; if ($script:Run) { Update-Convert }; Test-StartTime
            if (-not $script:GpuShown -and [VcGpu]::Ready) {
                $script:GpuShown = $true
                Write-AppLog "Graphics card: '$([VcGpu]::Name)' H.264 '$([VcGpu]::H264)' HEVC '$([VcGpu]::Hevc)' 10-bit $([VcGpu]::HevcTen)"
                Show-Options
                if (-not $script:Run) { Update-AllChecks }
            }
        }
        catch { Write-AppLog "Update: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
    })
    $window.Add_ContentRendered({
        $timer.Start()
        if (-not $script:FFprobe) { Set-Status 'FFmpeg is needed first: see the box at the top.' 'Warn' }
        else {
            Set-Status 'Pick what the videos should play on, then drop videos or folders onto the window (or use Add videos...).'
        }
    })
    $window.Add_Closing({
        param($s, $e)
        if ($script:Run) {
            if (-not (Show-AppMessage "A conversion is still running.`n`nClose anyway? The video being converted now is left unfinished and its part-made file is deleted." -YesText 'Close' -NoText 'Keep converting')) { $e.Cancel = $true; return }
            $r = $script:Run
            if ($r.Job) { $r.Job.Stop(); Start-Sleep -Milliseconds 600; Remove-Item -LiteralPath $r.Part -Force -ErrorAction SilentlyContinue; foreach ($sp in $r.SrtPaths) { Remove-Item -LiteralPath $sp -Force -ErrorAction SilentlyContinue } }
            [VcRun]::KeepAwake($false)
        }
        [VcProbe]::Cancel = $true
        if ($script:Sample) { $script:Sample.Job.Stop() }
    })
    $window.Add_Closed({ $timer.Stop() })
    # Old preview pictures (over a week old) are tidied away.
    Get-ChildItem -LiteralPath (Join-Path $script:TempDir 'previews') -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-AppLog "Started v$script:AppVersion from $script:ProgramDir"
    [void]$window.ShowDialog()
} catch {
    Write-AppLog "Error: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
    [void][Windows.MessageBox]::Show("$script:AppName couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}
