<#
.SYNOPSIS
    Generates bitmap and icon assets for the Inno Setup installers from logo source.

.DESCRIPTION
    Uses dedicated logo files for each installer:
      - logo/claude-code-dispatch-orchestrator-logo.png
      - logo/claude-code-dispatch-agent-logo.png
    Generates:
      - assets/wizard-banner.bmp       (164x314)  Orchestrator installer banner
      - assets/wizard-small.bmp        (55x55)    Orchestrator header icon
      - assets/icon.ico                (multi)    Orchestrator app icon
      - assets/agent-wizard-banner.bmp (164x314)  Agent installer banner
      - assets/agent-wizard-small.bmp  (55x55)    Agent header icon
      - assets/agent-icon.ico          (multi)    Agent app icon

    No external tools required -- only .NET Framework (built into Windows).

    Run with:  npm run build:assets
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
$AssetsDir  = Join-Path $ScriptDir "assets"
$LogoDir      = Join-Path $ProjectRoot "logo"
$OrcLogoFile  = Join-Path $LogoDir "claude-code-dispatch-orchestrator-logo.png"
$AgentLogoFile = Join-Path $LogoDir "claude-code-dispatch-agent-logo.png"

if (-not (Test-Path $AssetsDir)) {
    New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
}

if (-not (Test-Path $OrcLogoFile)) {
    Write-Error "Orchestrator logo not found: $OrcLogoFile"
    exit 1
}
if (-not (Test-Path $AgentLogoFile)) {
    Write-Error "Agent logo not found: $AgentLogoFile"
    exit 1
}

Write-Host "Generating installer assets..." -ForegroundColor Cyan
Write-Host "  Orchestrator logo: logo/claude-code-dispatch-orchestrator-logo.png" -ForegroundColor Gray
Write-Host "  Agent logo:        logo/claude-code-dispatch-agent-logo.png" -ForegroundColor Gray
Write-Host "  Output directory: $AssetsDir" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# Load source images
# ---------------------------------------------------------------------------

$orchestratorLogo = [System.Drawing.Bitmap]::new($OrcLogoFile)
$agentLogo = [System.Drawing.Bitmap]::new($AgentLogoFile)

Write-Host "  Orchestrator: $($orchestratorLogo.Width)x$($orchestratorLogo.Height)" -ForegroundColor Gray
Write-Host "  Agent:        $($agentLogo.Width)x$($agentLogo.Height)" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Color constants (matching the setup wizard dark theme)
# ---------------------------------------------------------------------------
$ColorDarkBg    = [System.Drawing.Color]::FromArgb(26, 26, 46)      # #1a1a2e
$ColorPanel     = [System.Drawing.Color]::FromArgb(22, 33, 62)      # #16213e
$ColorHighlight = [System.Drawing.Color]::FromArgb(233, 69, 96)     # #e94560
$ColorWhite     = [System.Drawing.Color]::White
$ColorLightGray = [System.Drawing.Color]::FromArgb(180, 180, 200)

# ---------------------------------------------------------------------------
# Helper: resize a bitmap to fit within a target size, preserving aspect ratio
# ---------------------------------------------------------------------------
function Resize-Image([System.Drawing.Bitmap]$src, [int]$maxW, [int]$maxH) {
    $ratioW = $maxW / $src.Width
    $ratioH = $maxH / $src.Height
    $ratio = [math]::Min($ratioW, $ratioH)
    [int]$newW = [math]::Max(1, [math]::Floor($src.Width * $ratio))
    [int]$newH = [math]::Max(1, [math]::Floor($src.Height * $ratio))

    # Progressive downscale: halve repeatedly until close to target, then final resize.
    # This preserves much more detail than a single large jump.
    $current = $src
    $tempList = @()
    while ($current.Width -gt ($newW * 2)) {
        [int]$halfW = [math]::Floor($current.Width / 2)
        [int]$halfH = [math]::Floor($current.Height / 2)
        $half = New-Object System.Drawing.Bitmap($halfW, $halfH)
        $gh = [System.Drawing.Graphics]::FromImage($half)
        $gh.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gh.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $gh.DrawImage($current, 0, 0, $halfW, $halfH)
        $gh.Dispose()
        $tempList += $half
        $current = $half
    }

    $bmp = New-Object System.Drawing.Bitmap($newW, $newH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.DrawImage($current, 0, 0, $newW, $newH)
    $g.Dispose()

    foreach ($tmp in $tempList) { $tmp.Dispose() }
    return $bmp
}

# ---------------------------------------------------------------------------
# Helper: create wizard banner (410x797 for WizardStyle=modern)
# ---------------------------------------------------------------------------
function New-WizardBanner([System.Drawing.Bitmap]$logo, [string]$title, [string]$subtitle) {
    $bannerWidth  = 410
    $bannerHeight = 797

    $banner = New-Object System.Drawing.Bitmap($bannerWidth, $bannerHeight)
    $g = [System.Drawing.Graphics]::FromImage($banner)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # Dark gradient background
    $gradBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)),
        (New-Object System.Drawing.Point(0, $bannerHeight)),
        $ColorDarkBg,
        $ColorPanel
    )
    $g.FillRectangle($gradBrush, 0, 0, $bannerWidth, $bannerHeight)

    # Accent stripe along left edge
    $accentBrush = New-Object System.Drawing.SolidBrush($ColorHighlight)
    $g.FillRectangle($accentBrush, 0, 0, 6, $bannerHeight)

    # Draw logo centered in upper area
    $resized = Resize-Image $logo 300 300
    $logoX = [math]::Floor(($bannerWidth - $resized.Width) / 2)
    $g.DrawImage($resized, $logoX, 80, $resized.Width, $resized.Height)
    $resized.Dispose()

    # Title text
    $fontTitle = New-Object System.Drawing.Font("Segoe UI", 32, [System.Drawing.FontStyle]::Bold)
    $whiteBrush = New-Object System.Drawing.SolidBrush($ColorWhite)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $titleRect = New-Object System.Drawing.RectangleF(0, 420, $bannerWidth, 60)
    $g.DrawString($title, $fontTitle, $whiteBrush, $titleRect, $sf)

    # Subtitle
    $fontSub = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Regular)
    $grayBrush = New-Object System.Drawing.SolidBrush($ColorLightGray)
    $subRect = New-Object System.Drawing.RectangleF(0, 490, $bannerWidth, 45)
    $g.DrawString($subtitle, $fontSub, $grayBrush, $subRect, $sf)

    # Accent line
    $g.FillRectangle($accentBrush, 130, 570, 150, 3)

    # Version
    $fontVer = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Regular)
    $dimBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 180, 180, 200))
    $verRect = New-Object System.Drawing.RectangleF(0, 740, $bannerWidth, 40)
    $g.DrawString("v1.0.0", $fontVer, $dimBrush, $verRect, $sf)

    $g.Dispose()
    return $banner
}

# ---------------------------------------------------------------------------
# Helper: create wizard small image (58x58 for WizardStyle=modern)
# ---------------------------------------------------------------------------
function New-WizardSmall([System.Drawing.Bitmap]$logo) {
    $size = 58
    $small = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($small)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # BMP has no transparency — fill with white to match Inno Setup page background
    $g.Clear([System.Drawing.Color]::White)

    $resized = Resize-Image $logo $size $size
    $x = [math]::Floor(($size - $resized.Width) / 2)
    $y = [math]::Floor(($size - $resized.Height) / 2)
    $g.DrawImage($resized, $x, $y, $resized.Width, $resized.Height)
    $resized.Dispose()

    $g.Dispose()
    return $small
}

# ---------------------------------------------------------------------------
# Helper: create .ico file from a logo bitmap (256, 48, 32, 16 px sizes)
# ---------------------------------------------------------------------------
function New-IconFile([System.Drawing.Bitmap]$logo, [string]$outPath) {
    $sizes = @(256, 48, 32, 16)
    $pngDataList = @()

    foreach ($sz in $sizes) {
        # Resize logo to fill the entire icon (logo has its own background)
        $resized = Resize-Image $logo $sz $sz

        $square = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($square)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

        # Transparent background — the logo's own background shows through
        $g.Clear([System.Drawing.Color]::Transparent)

        [int]$x = [math]::Floor(($sz - $resized.Width) / 2)
        [int]$y = [math]::Floor(($sz - $resized.Height) / 2)
        $g.DrawImage($resized, $x, $y, $resized.Width, $resized.Height)
        $g.Dispose()
        $resized.Dispose()

        $stream = New-Object System.IO.MemoryStream
        $square.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngDataList += ,($stream.ToArray())
        $stream.Dispose()
        $square.Dispose()
    }

    # Build ICO binary
    $numImages = $sizes.Count
    $headerSize = 6
    $dirEntrySize = 16
    $dataOffset = $headerSize + ($numImages * $dirEntrySize)

    $fs = [System.IO.File]::Create($outPath)
    $bw = New-Object System.IO.BinaryWriter($fs)

    # ICO Header
    $bw.Write([UInt16]0)               # Reserved
    $bw.Write([UInt16]1)               # Type: ICO
    $bw.Write([UInt16]$numImages)      # Image count

    # Calculate offsets
    $currentOffset = $dataOffset
    for ($i = 0; $i -lt $numImages; $i++) {
        $sz = $sizes[$i]
        $pngData = $pngDataList[$i]
        $widthByte  = if ($sz -ge 256) { 0 } else { [byte]$sz }
        $heightByte = if ($sz -ge 256) { 0 } else { [byte]$sz }

        $bw.Write([byte]$widthByte)
        $bw.Write([byte]$heightByte)
        $bw.Write([byte]0)             # Color palette
        $bw.Write([byte]0)             # Reserved
        $bw.Write([UInt16]1)           # Color planes
        $bw.Write([UInt16]32)          # Bits per pixel
        $bw.Write([UInt32]$pngData.Length)
        $bw.Write([UInt32]$currentOffset)
        $currentOffset += $pngData.Length
    }

    # Image data
    foreach ($pngData in $pngDataList) {
        $bw.Write($pngData)
    }

    $bw.Close()
    $fs.Close()
}

# ---------------------------------------------------------------------------
# Generate orchestrator assets
# ---------------------------------------------------------------------------

Write-Host "  [1/6] wizard-banner.bmp (orchestrator)..." -ForegroundColor White
$banner = New-WizardBanner $orchestratorLogo "Dispatch" "Orchestrator"
$bannerPath = Join-Path $AssetsDir "wizard-banner.bmp"
$banner.Save($bannerPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
$banner.Dispose()
Write-Host "         Saved: $bannerPath" -ForegroundColor Green

Write-Host "  [2/6] wizard-small.bmp (orchestrator)..." -ForegroundColor White
$small = New-WizardSmall $orchestratorLogo
$smallPath = Join-Path $AssetsDir "wizard-small.bmp"
$small.Save($smallPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
$small.Dispose()
Write-Host "         Saved: $smallPath" -ForegroundColor Green

Write-Host "  [3/6] icon.ico (orchestrator)..." -ForegroundColor White
$icoPath = Join-Path $AssetsDir "icon.ico"
New-IconFile $orchestratorLogo $icoPath
Write-Host "         Saved: $icoPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Generate agent assets
# ---------------------------------------------------------------------------

Write-Host "  [4/6] agent-wizard-banner.bmp (agent)..." -ForegroundColor White
$agentBanner = New-WizardBanner $agentLogo "Dispatch" "Agent"
$agentBannerPath = Join-Path $AssetsDir "agent-wizard-banner.bmp"
$agentBanner.Save($agentBannerPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
$agentBanner.Dispose()
Write-Host "         Saved: $agentBannerPath" -ForegroundColor Green

Write-Host "  [5/6] agent-wizard-small.bmp (agent)..." -ForegroundColor White
$agentSmall = New-WizardSmall $agentLogo
$agentSmallPath = Join-Path $AssetsDir "agent-wizard-small.bmp"
$agentSmall.Save($agentSmallPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
$agentSmall.Dispose()
Write-Host "         Saved: $agentSmallPath" -ForegroundColor Green

Write-Host "  [6/6] agent-icon.ico (agent)..." -ForegroundColor White
$agentIcoPath = Join-Path $AssetsDir "agent-icon.ico"
New-IconFile $agentLogo $agentIcoPath
Write-Host "         Saved: $agentIcoPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
$orchestratorLogo.Dispose()
$agentLogo.Dispose()

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "All assets generated successfully." -ForegroundColor Green
Write-Host ""
