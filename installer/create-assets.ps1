<#
.SYNOPSIS
    Generates bitmap and icon assets for the Inno Setup installer.

.DESCRIPTION
    Uses System.Drawing to programmatically create:
      - wizard-banner.bmp  (164x314)  Left panel banner with gradient and title
      - wizard-small.bmp   (55x55)    Small icon for the wizard header
      - icon.ico           (32x32)    Application icon with "D" letter

    No external tools are required — only .NET Framework (built into Windows).

    Run with:  npm run build:assets
    Or:        powershell -ExecutionPolicy Bypass -File installer\create-assets.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AssetsDir  = Join-Path $ScriptDir "assets"

if (-not (Test-Path $AssetsDir)) {
    New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
}

Write-Host "Generating installer assets..." -ForegroundColor Cyan
Write-Host "  Output directory: $AssetsDir" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# Color constants (matching the setup wizard dark theme)
# ---------------------------------------------------------------------------
$ColorDarkBg    = [System.Drawing.Color]::FromArgb(26, 26, 46)      # #1a1a2e
$ColorPanel     = [System.Drawing.Color]::FromArgb(22, 33, 62)      # #16213e
$ColorAccent    = [System.Drawing.Color]::FromArgb(15, 52, 96)      # #0f3460
$ColorHighlight = [System.Drawing.Color]::FromArgb(233, 69, 96)     # #e94560
$ColorWhite     = [System.Drawing.Color]::White
$ColorLightGray = [System.Drawing.Color]::FromArgb(180, 180, 200)

# ---------------------------------------------------------------------------
# 1. Wizard Banner (164 x 314) — left side panel
# ---------------------------------------------------------------------------
Write-Host "  [1/3] wizard-banner.bmp (164x314)..." -ForegroundColor White

$bannerWidth  = 164
$bannerHeight = 314
$banner = New-Object System.Drawing.Bitmap($bannerWidth, $bannerHeight)
$g = [System.Drawing.Graphics]::FromImage($banner)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

# Dark blue gradient background
$gradBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.Point(0, 0)),
    (New-Object System.Drawing.Point(0, $bannerHeight)),
    $ColorDarkBg,
    $ColorPanel
)
$g.FillRectangle($gradBrush, 0, 0, $bannerWidth, $bannerHeight)

# Accent stripe along the left edge
$accentBrush = New-Object System.Drawing.SolidBrush($ColorHighlight)
$g.FillRectangle($accentBrush, 0, 0, 4, $bannerHeight)

# Decorative circle (subtle)
$circleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30, 233, 69, 96))
$g.FillEllipse($circleBrush, -40, 20, 180, 180)

# Large "D" letter as a logo element
$fontLargeD = New-Object System.Drawing.Font("Segoe UI", 64, [System.Drawing.FontStyle]::Bold)
$dBrush     = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 255, 255, 255))
$g.DrawString("D", $fontLargeD, $dBrush, 30, 30)

# Title text: "Dispatch"
$fontTitle = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$whiteBrush = New-Object System.Drawing.SolidBrush($ColorWhite)
$g.DrawString("Dispatch", $fontTitle, $whiteBrush, 14, 200)

# Subtitle: "Orchestrator"
$fontSub = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$grayBrush = New-Object System.Drawing.SolidBrush($ColorLightGray)
$g.DrawString("Orchestrator", $fontSub, $grayBrush, 14, 228)

# Version
$fontVer = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
$dimBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 180, 180, 200))
$g.DrawString("v1.0.0", $fontVer, $dimBrush, 14, 290)

# Bottom accent line
$g.FillRectangle($accentBrush, 14, 260, 60, 2)

$g.Dispose()
$bannerPath = Join-Path $AssetsDir "wizard-banner.bmp"
$banner.Save($bannerPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
$banner.Dispose()
Write-Host "         Saved: $bannerPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Wizard Small Image (55 x 55) — header icon
# ---------------------------------------------------------------------------
Write-Host "  [2/3] wizard-small.bmp (55x55)..." -ForegroundColor White

$smallSize = 55
$small = New-Object System.Drawing.Bitmap($smallSize, $smallSize)
$g = [System.Drawing.Graphics]::FromImage($small)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

# Background gradient
$gradSmall = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.Point(0, 0)),
    (New-Object System.Drawing.Point($smallSize, $smallSize)),
    $ColorAccent,
    $ColorHighlight
)
$g.FillRectangle($gradSmall, 0, 0, $smallSize, $smallSize)

# Rounded appearance — fill corners with background-ish color (optional)
# Draw "D" letter centered
$fontSmallD = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center
$rect = New-Object System.Drawing.RectangleF(0, 0, $smallSize, $smallSize)
$g.DrawString("D", $fontSmallD, (New-Object System.Drawing.SolidBrush($ColorWhite)), $rect, $sf)

$g.Dispose()
$smallPath = Join-Path $AssetsDir "wizard-small.bmp"
$small.Save($smallPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
$small.Dispose()
Write-Host "         Saved: $smallPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Application Icon (icon.ico) — 32x32 and 16x16
# ---------------------------------------------------------------------------
Write-Host "  [3/3] icon.ico (32x32 + 16x16)..." -ForegroundColor White

# Helper function: create a single icon bitmap at a given size
function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    # Background
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)),
        (New-Object System.Drawing.Point($size, $size)),
        $ColorAccent,
        $ColorHighlight
    )
    $g.FillRectangle($grad, 0, 0, $size, $size)

    # "D" letter
    $fontSize = [math]::Floor($size * 0.55)
    $font = New-Object System.Drawing.Font("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Bold)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $g.DrawString("D", $font, (New-Object System.Drawing.SolidBrush($ColorWhite)), $rect, $sf)

    $g.Dispose()
    return $bmp
}

# .NET does not have a built-in ICO writer, so we build the binary format manually.
# ICO format: header (6 bytes) + directory entries (16 bytes each) + PNG image data.

$icon32 = New-IconBitmap 32
$icon16 = New-IconBitmap 16

# Save each as PNG to memory streams
$stream32 = New-Object System.IO.MemoryStream
$icon32.Save($stream32, [System.Drawing.Imaging.ImageFormat]::Png)
$png32 = $stream32.ToArray()
$stream32.Dispose()

$stream16 = New-Object System.IO.MemoryStream
$icon16.Save($stream16, [System.Drawing.Imaging.ImageFormat]::Png)
$png16 = $stream16.ToArray()
$stream16.Dispose()

$icon32.Dispose()
$icon16.Dispose()

# Build ICO file
$icoPath = Join-Path $AssetsDir "icon.ico"
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)

# ICO Header: reserved(2) + type(2) + count(2)
$bw.Write([UInt16]0)       # Reserved
$bw.Write([UInt16]1)       # Type: 1 = ICO
$bw.Write([UInt16]2)       # Count: 2 images

# Directory entry offsets: header=6, each entry=16, data starts at 6+2*16=38
$dataOffset1 = 6 + 2 * 16
$dataOffset2 = $dataOffset1 + $png32.Length

# Entry 1: 32x32
$bw.Write([byte]32)                          # Width
$bw.Write([byte]32)                          # Height
$bw.Write([byte]0)                           # Color palette
$bw.Write([byte]0)                           # Reserved
$bw.Write([UInt16]1)                         # Color planes
$bw.Write([UInt16]32)                        # Bits per pixel
$bw.Write([UInt32]$png32.Length)             # Image data size
$bw.Write([UInt32]$dataOffset1)             # Offset to image data

# Entry 2: 16x16
$bw.Write([byte]16)                          # Width
$bw.Write([byte]16)                          # Height
$bw.Write([byte]0)                           # Color palette
$bw.Write([byte]0)                           # Reserved
$bw.Write([UInt16]1)                         # Color planes
$bw.Write([UInt16]32)                        # Bits per pixel
$bw.Write([UInt32]$png16.Length)             # Image data size
$bw.Write([UInt32]$dataOffset2)             # Offset to image data

# Image data
$bw.Write($png32)
$bw.Write($png16)

$bw.Close()
$fs.Close()

Write-Host "         Saved: $icoPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "All assets generated successfully." -ForegroundColor Green
Write-Host ""
Write-Host "To use these in the installer, uncomment the asset lines in" -ForegroundColor Yellow
Write-Host "dispatch-orchestrator.iss (SetupIconFile, WizardImageFile, WizardSmallImageFile)." -ForegroundColor Yellow
Write-Host ""
