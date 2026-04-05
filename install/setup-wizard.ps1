<#
.SYNOPSIS
    Dispatch Orchestrator Setup Wizard - Windows Forms GUI installer.

.DESCRIPTION
    A professional, dark-themed multi-step installer wizard that guides the user
    through the complete setup of either a Coordinator (relay) or Worker machine.

    Run with:  npm run setup
    Or:        powershell -ExecutionPolicy Bypass -File install\setup-wizard.ps1

.NOTES
    Requires Windows 10/11 with .NET Framework (built-in).
    No external dependencies for the GUI itself.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Detect project root
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
if (-not (Test-Path (Join-Path $ProjectRoot "package.json"))) {
    # Might be running from project root directly
    if (Test-Path (Join-Path $PWD "package.json")) {
        $ProjectRoot = $PWD.Path
    } else {
        Write-Error "Cannot locate project root. Run from the project directory or install/ subdirectory."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Load assemblies
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Enable DPI awareness for crisp rendering on high-DPI displays.
# SetProcessDPIAware tells Windows not to bitmap-scale the window.
# All control layouts are designed at 96 DPI; we scale them by $DpiScale.
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class DpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
[DpiHelper]::SetProcessDPIAware() | Out-Null

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Calculate DPI scale factor (1.0 at 96 DPI, 1.5 at 144 DPI, 2.0 at 192 DPI)
$tmpBmp = New-Object System.Drawing.Bitmap(1, 1)
$tmpG = [System.Drawing.Graphics]::FromImage($tmpBmp)
$script:DpiScale = $tmpG.DpiX / 96.0
$tmpG.Dispose()
$tmpBmp.Dispose()

# Helper: scale a value by the DPI factor
function S([double]$val) { [int][math]::Round($val * $script:DpiScale) }

# ---------------------------------------------------------------------------
# Color palette
# ---------------------------------------------------------------------------
$C_BG         = [System.Drawing.ColorTranslator]::FromHtml("#1a1a2e")
$C_PANEL      = [System.Drawing.ColorTranslator]::FromHtml("#16213e")
$C_ACCENT     = [System.Drawing.ColorTranslator]::FromHtml("#0f3460")
$C_HIGHLIGHT  = [System.Drawing.ColorTranslator]::FromHtml("#e94560")
$C_TEXT        = [System.Drawing.Color]::White
$C_TEXTDIM    = [System.Drawing.ColorTranslator]::FromHtml("#8899aa")
$C_FIELD_BG   = [System.Drawing.ColorTranslator]::FromHtml("#0d1b2a")
$C_SUCCESS     = [System.Drawing.ColorTranslator]::FromHtml("#00c853")
$C_ERROR       = [System.Drawing.ColorTranslator]::FromHtml("#ff5252")

# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------
$F_TITLE    = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$F_SUBTITLE = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$F_NORMAL   = New-Object System.Drawing.Font("Segoe UI", 9.5)
$F_SMALL    = New-Object System.Drawing.Font("Segoe UI", 8.5)
$F_MONO     = New-Object System.Drawing.Font("Consolas", 8.5)
$F_MONO_SM  = New-Object System.Drawing.Font("Consolas", 7.5)
$F_STEP     = New-Object System.Drawing.Font("Segoe UI", 9)
$F_STEP_ACT = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$F_ICON     = New-Object System.Drawing.Font("Segoe UI", 22)

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:CurrentStep = 0
$script:SelectedRole = "coordinator"  # Orchestrator installer is always coordinator
$script:InstallCancelled = $false
$script:SetupMode = "basic"  # "basic" or "advanced"

# Step flow sequences for each mode (panel indices)
# Basic:    Welcome(0) -> BasicConfig(10) -> Review(4) -> Installing(5) -> Complete(6)
# Advanced: Welcome(0) -> Config(1) -> TLS(2) -> Service(3) -> Review(4) -> Installing(5) -> Complete(6)
$script:BasicFlow    = @(0, 10, 4, 5, 6)
$script:AdvancedFlow = @(0, 1, 2, 3, 4, 5, 6)

$script:BasicSidebarNames    = @("Welcome", "Configuration", "Review", "Installing", "Complete")
$script:AdvancedSidebarNames = @("Welcome", "Configuration", "TLS Settings", "Windows Service", "Review", "Installing", "Complete")

# ---------------------------------------------------------------------------
# Helper: create a styled label
# ---------------------------------------------------------------------------
function New-StyledLabel {
    param(
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 440, [int]$Height = 20,
        [System.Drawing.Font]$Font = $F_NORMAL,
        [System.Drawing.Color]$Color = $C_TEXT,
        [switch]$AutoSize
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $lbl.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $lbl.Font = $Font
    $lbl.ForeColor = $Color
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    if ($AutoSize) { $lbl.AutoSize = $true }
    return $lbl
}

# ---------------------------------------------------------------------------
# Helper: create a styled textbox
# ---------------------------------------------------------------------------
function New-StyledTextBox {
    param(
        [int]$X, [int]$Y,
        [int]$Width = 300, [int]$Height = 24,
        [string]$Text = "",
        [switch]$Multiline,
        [switch]$ReadOnly
    )
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $tb.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $tb.Font = $F_NORMAL
    $tb.BackColor = $C_FIELD_BG
    $tb.ForeColor = $C_TEXT
    $tb.BorderStyle = "FixedSingle"
    $tb.Text = $Text
    if ($Multiline) {
        $tb.Multiline = $true
        $tb.ScrollBars = "Vertical"
        $tb.AcceptsReturn = $true
    }
    if ($ReadOnly) {
        $tb.ReadOnly = $true
    }
    return $tb
}

# ---------------------------------------------------------------------------
# Helper: create a styled button
# ---------------------------------------------------------------------------
function New-StyledButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 100, [int]$Height = 32,
        [System.Drawing.Color]$BGColor = $C_ACCENT,
        [System.Drawing.Color]$FGColor = $C_TEXT
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $btn.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $btn.Font = $F_NORMAL
    $btn.BackColor = $BGColor
    $btn.ForeColor = $FGColor
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = $C_ACCENT
    $btn.FlatAppearance.BorderSize = 1
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

# ---------------------------------------------------------------------------
# Helper: create a styled checkbox
# ---------------------------------------------------------------------------
function New-StyledCheckBox {
    param(
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 420,
        [bool]$Checked = $false
    )
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text
    $cb.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $cb.Size = New-Object System.Drawing.Size((S $Width), (S 22))
    $cb.Font = $F_NORMAL
    $cb.ForeColor = $C_TEXT
    $cb.BackColor = [System.Drawing.Color]::Transparent
    $cb.Checked = $Checked
    return $cb
}

# ---------------------------------------------------------------------------
# Helper: create a styled combobox
# ---------------------------------------------------------------------------
function New-StyledComboBox {
    param(
        [int]$X, [int]$Y,
        [int]$Width = 200,
        [string[]]$Items,
        [int]$SelectedIndex = 0
    )
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $cb.Size = New-Object System.Drawing.Size((S $Width), (S 26))
    $cb.Font = $F_NORMAL
    $cb.BackColor = $C_FIELD_BG
    $cb.ForeColor = $C_TEXT
    $cb.DropDownStyle = "DropDownList"
    $cb.FlatStyle = "Flat"
    foreach ($item in $Items) { $cb.Items.Add($item) | Out-Null }
    if ($Items.Count -gt 0) { $cb.SelectedIndex = $SelectedIndex }
    return $cb
}

# ---------------------------------------------------------------------------
# Generate a shared secret
# ---------------------------------------------------------------------------
function New-SharedSecret {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

# ===================================================================
# MAIN FORM
# ===================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "Dispatch Orchestrator Setup"
# Scale form to DPI so it's not tiny on high-DPI displays
[int]$formW = [math]::Round(716 * $script:DpiScale)
[int]$formH = [math]::Round(558 * $script:DpiScale)
$form.Size = New-Object System.Drawing.Size($formW, $formH)
$form.MinimumSize = $form.Size
$form.MaximumSize = $form.Size
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.Font = $F_NORMAL

# Set form icon from install/inno assets
$icoPath = Join-Path (Join-Path $ProjectRoot "install\inno") "assets\icon.ico"
if (Test-Path $icoPath) {
    $form.Icon = New-Object System.Drawing.Icon($icoPath)
}

# ===================================================================
# SIDEBAR (step list)
# ===================================================================
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Location = New-Object System.Drawing.Point(0, 0)
$sidebar.Size = New-Object System.Drawing.Size((S 190), (S 520))
$sidebar.BackColor = $C_PANEL

$sideTitle = New-StyledLabel -Text "Setup Steps" -X 14 -Y 14 -Width 170 -Height 28 -Font $F_SUBTITLE -Color $C_HIGHLIGHT
$sidebar.Controls.Add($sideTitle)

# Create max sidebar labels (7 slots) -- rebuilt dynamically by Rebuild-Sidebar
$script:stepLabels = @()
for ($i = 0; $i -lt 7; $i++) {
    $sl = New-StyledLabel -Text "" -X 8 -Y (50 + $i * 28) -Width 174 -Height 24 -Font $F_STEP -Color $C_TEXTDIM
    $sl.Visible = $false
    $sidebar.Controls.Add($sl)
    $script:stepLabels += $sl
}

function Rebuild-Sidebar {
    $names = if ($script:SetupMode -eq "basic") { $script:BasicSidebarNames } else { $script:AdvancedSidebarNames }
    for ($i = 0; $i -lt $script:stepLabels.Count; $i++) {
        if ($i -lt $names.Count) {
            $script:stepLabels[$i].Text = "  $($i + 1). $($names[$i])"
            $script:stepLabels[$i].Visible = $true
        } else {
            $script:stepLabels[$i].Text = ""
            $script:stepLabels[$i].Visible = $false
        }
    }
}

Rebuild-Sidebar

$form.Controls.Add($sidebar)

# ===================================================================
# CONTENT AREA
# ===================================================================
$contentArea = New-Object System.Windows.Forms.Panel
$contentArea.Location = New-Object System.Drawing.Point((S 190), 0)
$contentArea.Size = New-Object System.Drawing.Size((S 510), (S 470))
$contentArea.BackColor = $C_BG
$form.Controls.Add($contentArea)

# ===================================================================
# BOTTOM BUTTON BAR
# ===================================================================
$buttonBar = New-Object System.Windows.Forms.Panel
$buttonBar.Location = New-Object System.Drawing.Point((S 190), (S 470))
$buttonBar.Size = New-Object System.Drawing.Size((S 510), (S 50))
$buttonBar.BackColor = $C_PANEL
$form.Controls.Add($buttonBar)

$btnBack = New-StyledButton -Text "< Back" -X 10 -Y 9 -Width 90
$btnNext = New-StyledButton -Text "Next >" -X 300 -Y 9 -Width 90
$btnCancel = New-StyledButton -Text "Cancel" -X 400 -Y 9 -Width 90 -BGColor $C_PANEL
$btnCancel.FlatAppearance.BorderColor = $C_TEXTDIM

$buttonBar.Controls.Add($btnBack)
$buttonBar.Controls.Add($btnNext)
$buttonBar.Controls.Add($btnCancel)

# ===================================================================
# STEP PANELS
# ===================================================================
$panels = @{}

# ---------------------------------------------------------------------------
# STEP 0: Welcome
# ---------------------------------------------------------------------------
$p0 = New-Object System.Windows.Forms.Panel
$p0.Dock = "Fill"
$p0.BackColor = $C_BG

$p0.Controls.Add((New-StyledLabel -Text "Welcome to Dispatch Orchestrator Setup" -X 20 -Y 14 -Width 470 -Height 36 -Font $F_TITLE))
$p0.Controls.Add((New-StyledLabel -Text "This orchestrator extends Anthropic's Dispatch into a hub-and-spoke model:`nyour phone dispatches tasks through an orchestrator machine, which routes`nsubtasks to one or more named worker agents over a local WebSocket relay." `
    -X 20 -Y 54 -Width 470 -Height 60 -Font $F_NORMAL -Color $C_TEXTDIM))

# Architecture diagram image
$diagramPath = Join-Path (Join-Path $ProjectRoot "docs") "images\integration-diagram-simple.png"
if (-not (Test-Path $diagramPath)) {
    $diagramPath = Join-Path (Join-Path $ProjectRoot "install\inno") "assets\integration-diagram.png"
}
if (Test-Path $diagramPath) {
    # Pre-scale the diagram with high-quality bicubic to avoid PictureBox pixelation
    $diagramSrc = [System.Drawing.Image]::FromFile($diagramPath)
    $dw = S 360; $dh = S 240
    $diagramScaled = New-Object System.Drawing.Bitmap($dw, $dh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $dg = [System.Drawing.Graphics]::FromImage($diagramScaled)
    $dg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $dg.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $dg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $dg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    # Fit preserving aspect ratio
    $ratioW = $dw / $diagramSrc.Width; $ratioH = $dh / $diagramSrc.Height
    $ratio = [math]::Min($ratioW, $ratioH)
    [int]$sw = [math]::Floor($diagramSrc.Width * $ratio)
    [int]$sh = [math]::Floor($diagramSrc.Height * $ratio)
    [int]$sx = [math]::Floor(($dw - $sw) / 2)
    [int]$sy = [math]::Floor(($dh - $sh) / 2)
    $dg.Clear([System.Drawing.Color]::Transparent)
    $dg.DrawImage($diagramSrc, $sx, $sy, $sw, $sh)
    $dg.Dispose()
    $diagramSrc.Dispose()

    $diagramPic = New-Object System.Windows.Forms.PictureBox
    $diagramPic.Location = New-Object System.Drawing.Point((S 60), (S 118))
    $diagramPic.Size = New-Object System.Drawing.Size($dw, $dh)  # already scaled
    $diagramPic.SizeMode = "CenterImage"
    $diagramPic.BackColor = [System.Drawing.Color]::Transparent
    $diagramPic.Image = $diagramScaled
    $p0.Controls.Add($diagramPic)
}

$p0.Controls.Add((New-StyledLabel -Text "This wizard will configure this machine as the Orchestrator." `
    -X 20 -Y 366 -Width 470 -Height 22 -Font $F_NORMAL))

# Setup mode selection — use a Panel (not GroupBox) for clean look
$modePanel = New-Object System.Windows.Forms.Panel
$modePanel.Location = New-Object System.Drawing.Point((S 20), (S 394))
$modePanel.Size = New-Object System.Drawing.Size((S 460), (S 46))
$modePanel.BackColor = [System.Drawing.Color]::Transparent
$p0.Controls.Add($modePanel)

$script:radioBasicMode = New-Object System.Windows.Forms.RadioButton
$script:radioBasicMode.Text = "Basic Setup (recommended)"
$script:radioBasicMode.Location = New-Object System.Drawing.Point(0, 0)
$script:radioBasicMode.Size = New-Object System.Drawing.Size((S 230), (S 20))
$script:radioBasicMode.Font = $F_NORMAL
$script:radioBasicMode.ForeColor = $C_TEXT
$script:radioBasicMode.BackColor = [System.Drawing.Color]::Transparent
$script:radioBasicMode.Checked = $true
$modePanel.Controls.Add($script:radioBasicMode)

$script:radioAdvancedMode = New-Object System.Windows.Forms.RadioButton
$script:radioAdvancedMode.Text = "Advanced Setup"
$script:radioAdvancedMode.Location = New-Object System.Drawing.Point((S 240), 0)
$script:radioAdvancedMode.Size = New-Object System.Drawing.Size((S 200), (S 20))
$script:radioAdvancedMode.Font = $F_NORMAL
$script:radioAdvancedMode.ForeColor = $C_TEXT
$script:radioAdvancedMode.BackColor = [System.Drawing.Color]::Transparent
$modePanel.Controls.Add($script:radioAdvancedMode)

$script:lblModeDesc = New-Object System.Windows.Forms.Label
$script:lblModeDesc.Text = "Quick setup -- port, shared secret, and PIN. Uses sensible defaults."
$script:lblModeDesc.Location = New-Object System.Drawing.Point(0, (S 22))
$script:lblModeDesc.Size = New-Object System.Drawing.Size((S 450), (S 18))
$script:lblModeDesc.Font = $F_SMALL
$script:lblModeDesc.ForeColor = $C_TEXTDIM
$script:lblModeDesc.BackColor = [System.Drawing.Color]::Transparent
$modePanel.Controls.Add($script:lblModeDesc)

$script:radioBasicMode.Add_CheckedChanged({
    if ($script:radioBasicMode.Checked) {
        $script:SetupMode = "basic"
        $script:lblModeDesc.Text = "Quick setup -- port, shared secret, and PIN. Uses sensible defaults."
        Rebuild-Sidebar
    }
})
$script:radioAdvancedMode.Add_CheckedChanged({
    if ($script:radioAdvancedMode.Checked) {
        $script:SetupMode = "advanced"
        $script:lblModeDesc.Text = "Full control over TLS, services, rate limiting, and all options."
        Rebuild-Sidebar
    }
})

$p0.Controls.Add((New-StyledLabel -Text "Project root: $ProjectRoot" -X 20 -Y 444 -Width 460 -Height 20 -Font $F_SMALL -Color $C_TEXTDIM))
$panels[0] = $p0

# ---------------------------------------------------------------------------
# STEP 1: Role Selection
# ---------------------------------------------------------------------------
$p1 = New-Object System.Windows.Forms.Panel
$p1.Dock = "Fill"
$p1.BackColor = $C_BG

$p1.Controls.Add((New-StyledLabel -Text "Select Machine Role" -X 20 -Y 18 -Width 460 -Height 32 -Font $F_TITLE))
$p1.Controls.Add((New-StyledLabel -Text "Choose the role for this machine in your dispatch network." -X 20 -Y 56 -Width 460 -Height 24 -Font $F_NORMAL -Color $C_TEXTDIM))

# --- Coordinator card ---
$cardCoord = New-Object System.Windows.Forms.Panel
$cardCoord.Location = New-Object System.Drawing.Point(20, 92)
$cardCoord.Size = New-Object System.Drawing.Size(460, 130)
$cardCoord.BackColor = $C_PANEL
$cardCoord.BorderStyle = "FixedSingle"
$cardCoord.Cursor = [System.Windows.Forms.Cursors]::Hand

$script:rbCoord = New-Object System.Windows.Forms.RadioButton
$script:rbCoord.Text = ""
$script:rbCoord.Location = New-Object System.Drawing.Point(14, 50)
$script:rbCoord.Size = New-Object System.Drawing.Size(20, 20)
$script:rbCoord.BackColor = [System.Drawing.Color]::Transparent
$script:rbCoord.ForeColor = $C_TEXT
$cardCoord.Controls.Add($script:rbCoord)

$cardCoord.Controls.Add((New-StyledLabel -Text ([System.Char]::ConvertFromUtf32(0x1F5A5)) -X 40 -Y 10 -Width 40 -Height 40 -Font $F_ICON -Color $C_HIGHLIGHT))
$cardCoord.Controls.Add((New-StyledLabel -Text "Coordinator" -X 86 -Y 12 -Width 300 -Height 28 -Font $F_SUBTITLE))
$cardCoord.Controls.Add((New-StyledLabel -Text "Runs the relay server. Receives tasks from your phone via Dispatch`nand routes them to workers. Only one coordinator per network." `
    -X 86 -Y 42 -Width 360 -Height 40 -Font $F_SMALL -Color $C_TEXTDIM))
$cardCoord.Controls.Add((New-StyledLabel -Text "Includes: Relay server, HTTP API, Dashboard, Task queue, Discovery" `
    -X 86 -Y 90 -Width 360 -Height 20 -Font $F_SMALL -Color $C_HIGHLIGHT))

$cardCoord.Add_Click({ $script:rbCoord.Checked = $true })
foreach ($ctrl in $cardCoord.Controls) {
    if ($ctrl -isnot [System.Windows.Forms.RadioButton]) {
        $ctrl.Add_Click({ $script:rbCoord.Checked = $true })
    }
}

$p1.Controls.Add($cardCoord)

# --- Worker card ---
$cardWorker = New-Object System.Windows.Forms.Panel
$cardWorker.Location = New-Object System.Drawing.Point(20, 232)
$cardWorker.Size = New-Object System.Drawing.Size(460, 130)
$cardWorker.BackColor = $C_PANEL
$cardWorker.BorderStyle = "FixedSingle"
$cardWorker.Cursor = [System.Windows.Forms.Cursors]::Hand

$script:rbWorker = New-Object System.Windows.Forms.RadioButton
$script:rbWorker.Text = ""
$script:rbWorker.Location = New-Object System.Drawing.Point(14, 50)
$script:rbWorker.Size = New-Object System.Drawing.Size(20, 20)
$script:rbWorker.BackColor = [System.Drawing.Color]::Transparent
$script:rbWorker.ForeColor = $C_TEXT
$cardWorker.Controls.Add($script:rbWorker)

$cardWorker.Controls.Add((New-StyledLabel -Text ([char]0x2699) -X 40 -Y 10 -Width 40 -Height 40 -Font $F_ICON -Color $C_HIGHLIGHT))
$cardWorker.Controls.Add((New-StyledLabel -Text "Worker" -X 86 -Y 12 -Width 300 -Height 28 -Font $F_SUBTITLE))
$cardWorker.Controls.Add((New-StyledLabel -Text "Runs a named agent that executes tasks. Connects to the coordinator's`nrelay. Multiple workers per network." `
    -X 86 -Y 42 -Width 360 -Height 40 -Font $F_SMALL -Color $C_TEXTDIM))
$cardWorker.Controls.Add((New-StyledLabel -Text "Includes: Claude CLI runner, Auto-discovery, Sleep prevention" `
    -X 86 -Y 90 -Width 360 -Height 20 -Font $F_SMALL -Color $C_HIGHLIGHT))

$cardWorker.Add_Click({ $script:rbWorker.Checked = $true })
foreach ($ctrl in $cardWorker.Controls) {
    if ($ctrl -isnot [System.Windows.Forms.RadioButton]) {
        $ctrl.Add_Click({ $script:rbWorker.Checked = $true })
    }
}

$p1.Controls.Add($cardWorker)

# Highlight selected card
$updateCardHighlight = {
    if ($script:rbCoord.Checked) {
        $cardCoord.BackColor = $C_ACCENT
        $cardWorker.BackColor = $C_PANEL
    } elseif ($script:rbWorker.Checked) {
        $cardWorker.BackColor = $C_ACCENT
        $cardCoord.BackColor = $C_PANEL
    }
}
$script:rbCoord.Add_CheckedChanged($updateCardHighlight)
$script:rbWorker.Add_CheckedChanged($updateCardHighlight)

# Role selection panel ($p1) is not added to panels — orchestrator is always coordinator

# ---------------------------------------------------------------------------
# STEP 1: Configuration (was STEP 2)
# ---------------------------------------------------------------------------
$p2 = New-Object System.Windows.Forms.Panel
$p2.Dock = "Fill"
$p2.BackColor = $C_BG
$p2.AutoScroll = $true

# We create two sub-panels: one for coordinator, one for worker
# --- Coordinator config panel ---
$pCoordCfg = New-Object System.Windows.Forms.Panel
$pCoordCfg.Location = New-Object System.Drawing.Point(0, 0)
$pCoordCfg.Size = New-Object System.Drawing.Size((S 490), (S 460))
$pCoordCfg.BackColor = $C_BG

$pCoordCfg.Controls.Add((New-StyledLabel -Text "Orchestrator Configuration" -X 20 -Y 10 -Width 460 -Height 30 -Font $F_TITLE))

$yC = 46

# Port
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Relay Port:" -X 20 -Y $yC -Width 120 -Height 22))
$script:txtPort = New-StyledTextBox -X 150 -Y ($yC - 2) -Width 80 -Text "7070"
$pCoordCfg.Controls.Add($script:txtPort)
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Port the relay listens on (1024-65535)" -X 240 -Y $yC -Width 250 -Height 22 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 34

# Shared Secret
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Shared Secret:" -X 20 -Y $yC -Width 120 -Height 22))
$script:txtSecretCoord = New-StyledTextBox -X 150 -Y ($yC - 2) -Width 220 -Text (New-SharedSecret)
$pCoordCfg.Controls.Add($script:txtSecretCoord)

$btnGenSecret = New-StyledButton -Text "Generate" -X 376 -Y ($yC - 3) -Width 70 -Height 26
$btnGenSecret.Font = $F_SMALL
$btnGenSecret.Add_Click({ $script:txtSecretCoord.Text = New-SharedSecret })
$pCoordCfg.Controls.Add($btnGenSecret)

$btnCopySecret = New-StyledButton -Text "Copy" -X 450 -Y ($yC - 3) -Width 50 -Height 26
$btnCopySecret.Font = $F_SMALL
$btnCopySecret.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($script:txtSecretCoord.Text)
})
$pCoordCfg.Controls.Add($btnCopySecret)
$yC += 22
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Auth token for API and agent connections. Agents must use the same secret." -X 150 -Y $yC -Width 340 -Height 18 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 24

# PIN
$pCoordCfg.Controls.Add((New-StyledLabel -Text "PIN Code:" -X 20 -Y $yC -Width 120 -Height 22))
$script:txtPinCode = New-StyledTextBox -X 150 -Y ($yC - 2) -Width 100 -Text ""
$pCoordCfg.Controls.Add($script:txtPinCode)
$yC += 22
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Second factor for task submission. 4-8 digits, leave blank to disable." -X 150 -Y $yC -Width 340 -Height 18 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 28

# Checkboxes with descriptions
$script:cbDiscovery = New-StyledCheckBox -Text "Enable auto-discovery broadcasting" -X 20 -Y $yC -Checked $true
$pCoordCfg.Controls.Add($script:cbDiscovery)
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Agents on your LAN find this relay automatically via UDP broadcast" -X 44 -Y ($yC + 20) -Width 440 -Height 16 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 38

$script:cbQueue = New-StyledCheckBox -Text "Enable task queue" -X 20 -Y $yC -Checked $true
$pCoordCfg.Controls.Add($script:cbQueue)
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Queue tasks when all agents are busy instead of rejecting them" -X 44 -Y ($yC + 20) -Width 440 -Height 16 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 38

$script:cbKeepAwakeCoord = New-StyledCheckBox -Text "Enable sleep prevention" -X 20 -Y $yC -Checked $true
$pCoordCfg.Controls.Add($script:cbKeepAwakeCoord)
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Prevent Windows from sleeping while the relay is running" -X 44 -Y ($yC + 20) -Width 440 -Height 16 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 38

$script:cbRateLimit = New-StyledCheckBox -Text "Enable rate limiting" -X 20 -Y $yC -Checked $true
$pCoordCfg.Controls.Add($script:cbRateLimit)
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Limit task submissions to 10/min and 100/hour" -X 44 -Y ($yC + 20) -Width 440 -Height 16 -Font $F_SMALL -Color $C_TEXTDIM))
$yC += 38

# Load balancing
$pCoordCfg.Controls.Add((New-StyledLabel -Text "Load Balancing:" -X 20 -Y $yC -Width 120 -Height 22))
$script:cmbLB = New-StyledComboBox -X 150 -Y ($yC - 2) -Width 180 -Items @("least-busy", "round-robin", "fastest", "random") -SelectedIndex 0
$pCoordCfg.Controls.Add($script:cmbLB)
$pCoordCfg.Controls.Add((New-StyledLabel -Text "How tasks are distributed across idle agents" -X 340 -Y $yC -Width 150 -Height 32 -Font $F_SMALL -Color $C_TEXTDIM))

$p2.Controls.Add($pCoordCfg)

# --- Worker config panel ---
$pWorkerCfg = New-Object System.Windows.Forms.Panel
$pWorkerCfg.Location = New-Object System.Drawing.Point(0, 0)
$pWorkerCfg.Size = New-Object System.Drawing.Size((S 490), (S 460))
$pWorkerCfg.BackColor = $C_BG
$pWorkerCfg.Visible = $false

$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Worker Configuration" -X 20 -Y 6 -Width 460 -Height 30 -Font $F_TITLE))

$yOff = 40

# Agent Name
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Agent Name:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtAgentName = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 200 -Text "CodeBot"
$pWorkerCfg.Controls.Add($script:txtAgentName)
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "(required)" -X 358 -Y $yOff -Width 80 -Height 22 -Font $F_SMALL -Color $C_HIGHLIGHT))
$yOff += 30

# Description
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Description:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtAgentDesc = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 330 -Text "Handles coding tasks, refactoring, and code review"
$pWorkerCfg.Controls.Add($script:txtAgentDesc)
$yOff += 30

# Capabilities
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Capabilities:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtCapabilities = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 330 -Text "code, refactor, review, debug"
$pWorkerCfg.Controls.Add($script:txtCapabilities)
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "(comma-separated keywords)" -X 150 -Y ($yOff + 22) -Width 330 -Height 18 -Font $F_SMALL -Color $C_TEXTDIM))
$yOff += 46

# Machine ID
$autoMachineId = "$($env:COMPUTERNAME.ToLower())-$('{0:x4}' -f (Get-Random -Maximum 65535))"
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Machine ID:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtMachineId = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 330 -Text $autoMachineId
$pWorkerCfg.Controls.Add($script:txtMachineId)
$yOff += 30

# Coordinator Host
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Coordinator:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtCoordHost = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 330 -Text "auto"
$pWorkerCfg.Controls.Add($script:txtCoordHost)
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "`"auto`" = use discovery, or enter ws://host:port" -X 150 -Y ($yOff + 22) -Width 330 -Height 18 -Font $F_SMALL -Color $C_TEXTDIM))
$yOff += 46

# Shared Secret
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Shared Secret:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtSecretWorker = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 330 -Text ""
$pWorkerCfg.Controls.Add($script:txtSecretWorker)
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "(must match coordinator's secret)" -X 150 -Y ($yOff + 22) -Width 330 -Height 18 -Font $F_SMALL -Color $C_HIGHLIGHT))
$yOff += 46

# Default working dir
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Working Dir:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtWorkDir = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 260 -Text "C:/workspace"
$pWorkerCfg.Controls.Add($script:txtWorkDir)
$btnBrowseWork = New-StyledButton -Text "Browse..." -X 416 -Y ($yOff - 3) -Width 66 -Height 26
$btnBrowseWork.Font = $F_SMALL
$btnBrowseWork.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = "Select default working directory"
    if ($fb.ShowDialog() -eq "OK") { $script:txtWorkDir.Text = $fb.SelectedPath.Replace("\", "/") }
})
$pWorkerCfg.Controls.Add($btnBrowseWork)
$yOff += 30

# Allowed dirs
$pWorkerCfg.Controls.Add((New-StyledLabel -Text "Allowed Dirs:" -X 20 -Y $yOff -Width 120 -Height 22))
$script:txtAllowedDirs = New-StyledTextBox -X 150 -Y ($yOff - 2) -Width 260 -Height 60 -Text "C:/workspace" -Multiline
$pWorkerCfg.Controls.Add($script:txtAllowedDirs)
$btnBrowseAllow = New-StyledButton -Text "Add..." -X 416 -Y ($yOff - 3) -Width 66 -Height 26
$btnBrowseAllow.Font = $F_SMALL
$btnBrowseAllow.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = "Add allowed directory"
    if ($fb.ShowDialog() -eq "OK") {
        $newDir = $fb.SelectedPath.Replace("\", "/")
        if ($script:txtAllowedDirs.Text.Trim().Length -gt 0) {
            $script:txtAllowedDirs.Text += "`r`n$newDir"
        } else {
            $script:txtAllowedDirs.Text = $newDir
        }
    }
})
$pWorkerCfg.Controls.Add($btnBrowseAllow)
$yOff += 66

# Worker checkboxes
$script:cbWorkerDiscovery = New-StyledCheckBox -Text "Enable auto-discovery" -X 20 -Y $yOff -Checked $true
$script:cbKeepAwakeWorker = New-StyledCheckBox -Text "Enable sleep prevention" -X 250 -Y $yOff -Checked $true
$pWorkerCfg.Controls.Add($script:cbWorkerDiscovery)
$pWorkerCfg.Controls.Add($script:cbKeepAwakeWorker)

$p2.Controls.Add($pWorkerCfg)

$panels[1] = $p2

# ---------------------------------------------------------------------------
# STEP 3: TLS Configuration
# ---------------------------------------------------------------------------
$p3 = New-Object System.Windows.Forms.Panel
$p3.Dock = "Fill"
$p3.BackColor = $C_BG

$p3.Controls.Add((New-StyledLabel -Text "TLS Configuration" -X 20 -Y 18 -Width 460 -Height 32 -Font $F_TITLE))
$p3.Controls.Add((New-StyledLabel -Text "TLS is optional for LAN use but recommended for cross-network setups." -X 20 -Y 56 -Width 460 -Height 22 -Font $F_NORMAL -Color $C_TEXTDIM))

$script:cbEnableTLS = New-StyledCheckBox -Text "Enable TLS encryption (WSS/HTTPS)" -X 20 -Y 90
$p3.Controls.Add($script:cbEnableTLS)

# TLS options panel (hidden by default)
$pTlsOptions = New-Object System.Windows.Forms.Panel
$pTlsOptions.Location = New-Object System.Drawing.Point((S 20), (S 120))
$pTlsOptions.Size = New-Object System.Drawing.Size((S 460), (S 320))
$pTlsOptions.BackColor = $C_BG
$pTlsOptions.Visible = $false

$script:rbSelfSigned = New-Object System.Windows.Forms.RadioButton
$script:rbSelfSigned.Text = "Generate self-signed certificates"
$script:rbSelfSigned.Location = New-Object System.Drawing.Point((S 10), (S 10))
$script:rbSelfSigned.Size = New-Object System.Drawing.Size((S 400), (S 22))
$script:rbSelfSigned.Font = $F_NORMAL
$script:rbSelfSigned.ForeColor = $C_TEXT
$script:rbSelfSigned.BackColor = [System.Drawing.Color]::Transparent
$script:rbSelfSigned.Checked = $true
$pTlsOptions.Controls.Add($script:rbSelfSigned)

$pTlsOptions.Controls.Add((New-StyledLabel -Text "Certificates will be generated in the certs/ directory using OpenSSL." `
    -X 30 -Y 36 -Width 420 -Height 22 -Font $F_SMALL -Color $C_TEXTDIM))

$script:rbExistingCerts = New-Object System.Windows.Forms.RadioButton
$script:rbExistingCerts.Text = "Use existing certificates"
$script:rbExistingCerts.Location = New-Object System.Drawing.Point((S 10), (S 68))
$script:rbExistingCerts.Size = New-Object System.Drawing.Size((S 400), (S 22))
$script:rbExistingCerts.Font = $F_NORMAL
$script:rbExistingCerts.ForeColor = $C_TEXT
$script:rbExistingCerts.BackColor = [System.Drawing.Color]::Transparent
$pTlsOptions.Controls.Add($script:rbExistingCerts)

# Existing cert fields panel
$pCertFields = New-Object System.Windows.Forms.Panel
$pCertFields.Location = New-Object System.Drawing.Point((S 10), (S 96))
$pCertFields.Size = New-Object System.Drawing.Size((S 440), (S 130))
$pCertFields.BackColor = $C_BG
$pCertFields.Visible = $false

$pCertFields.Controls.Add((New-StyledLabel -Text "Certificate File:" -X 10 -Y 6 -Width 110 -Height 22))
$script:txtCertFile = New-StyledTextBox -X 126 -Y 4 -Width 230
$pCertFields.Controls.Add($script:txtCertFile)
$btnBrowseCert = New-StyledButton -Text "..." -X 362 -Y 2 -Width 36 -Height 26
$btnBrowseCert.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Certificate files (*.crt;*.pem)|*.crt;*.pem|All files (*.*)|*.*"
    if ($ofd.ShowDialog() -eq "OK") { $script:txtCertFile.Text = $ofd.FileName }
})
$pCertFields.Controls.Add($btnBrowseCert)

$pCertFields.Controls.Add((New-StyledLabel -Text "Key File:" -X 10 -Y 38 -Width 110 -Height 22))
$script:txtKeyFile = New-StyledTextBox -X 126 -Y 36 -Width 230
$pCertFields.Controls.Add($script:txtKeyFile)
$btnBrowseKey = New-StyledButton -Text "..." -X 362 -Y 34 -Width 36 -Height 26
$btnBrowseKey.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Key files (*.key;*.pem)|*.key;*.pem|All files (*.*)|*.*"
    if ($ofd.ShowDialog() -eq "OK") { $script:txtKeyFile.Text = $ofd.FileName }
})
$pCertFields.Controls.Add($btnBrowseKey)

$pCertFields.Controls.Add((New-StyledLabel -Text "CA File:" -X 10 -Y 70 -Width 110 -Height 22))
$script:txtCaFile = New-StyledTextBox -X 126 -Y 68 -Width 230
$pCertFields.Controls.Add($script:txtCaFile)
$btnBrowseCa = New-StyledButton -Text "..." -X 362 -Y 66 -Width 36 -Height 26
$btnBrowseCa.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Certificate files (*.crt;*.pem)|*.crt;*.pem|All files (*.*)|*.*"
    if ($ofd.ShowDialog() -eq "OK") { $script:txtCaFile.Text = $ofd.FileName }
})
$pCertFields.Controls.Add($btnBrowseCa)

$pTlsOptions.Controls.Add($pCertFields)
$p3.Controls.Add($pTlsOptions)

# Toggle TLS options visibility
$script:cbEnableTLS.Add_CheckedChanged({ $pTlsOptions.Visible = $script:cbEnableTLS.Checked })
$script:rbExistingCerts.Add_CheckedChanged({ $pCertFields.Visible = $script:rbExistingCerts.Checked })
$script:rbSelfSigned.Add_CheckedChanged({ $pCertFields.Visible = -not $script:rbSelfSigned.Checked })

$panels[2] = $p3

# ---------------------------------------------------------------------------
# STEP 4: Windows Service
# ---------------------------------------------------------------------------
$p4 = New-Object System.Windows.Forms.Panel
$p4.Dock = "Fill"
$p4.BackColor = $C_BG

$p4.Controls.Add((New-StyledLabel -Text "Windows Service" -X 20 -Y 18 -Width 460 -Height 32 -Font $F_TITLE))
$p4.Controls.Add((New-StyledLabel -Text "Optionally install as a Windows service that starts at boot." -X 20 -Y 56 -Width 460 -Height 22 -Font $F_NORMAL -Color $C_TEXTDIM))

$script:cbInstallService = New-StyledCheckBox -Text "Install as Windows service (NSSM)" -X 20 -Y 92
$p4.Controls.Add($script:cbInstallService)

# Service options
$pSvcOptions = New-Object System.Windows.Forms.Panel
$pSvcOptions.Location = New-Object System.Drawing.Point((S 20), (S 124))
$pSvcOptions.Size = New-Object System.Drawing.Size((S 460), (S 180))
$pSvcOptions.BackColor = $C_BG
$pSvcOptions.Visible = $false

$pSvcOptions.Controls.Add((New-StyledLabel -Text "Service Name:" -X 10 -Y 6 -Width 120 -Height 22))
$script:txtServiceName = New-StyledTextBox -X 136 -Y 4 -Width 200 -Text "DispatchRelay"
$pSvcOptions.Controls.Add($script:txtServiceName)

$script:cbAutoStart = New-StyledCheckBox -Text "Start automatically on boot" -X 10 -Y 38 -Checked $true
$pSvcOptions.Controls.Add($script:cbAutoStart)

# NSSM detection
$script:lblNssmStatus = New-StyledLabel -Text "" -X 10 -Y 72 -Width 440 -Height 60 -Font $F_SMALL
$pSvcOptions.Controls.Add($script:lblNssmStatus)

$nssmFound = $null -ne (Get-Command nssm.exe -ErrorAction SilentlyContinue)
if (-not $nssmFound) {
    $candidates = @("C:\nssm\nssm.exe","C:\tools\nssm\nssm.exe","C:\Program Files\nssm\nssm.exe","C:\ProgramData\chocolatey\bin\nssm.exe")
    foreach ($c in $candidates) { if (Test-Path $c) { $nssmFound = $true; break } }
}
if ($nssmFound) {
    $script:lblNssmStatus.Text = "NSSM detected on this system."
    $script:lblNssmStatus.ForeColor = $C_SUCCESS
} else {
    $script:lblNssmStatus.Text = "WARNING: NSSM was not found on this system.`nInstall with: choco install nssm  |  scoop install nssm`nOr download from https://nssm.cc"
    $script:lblNssmStatus.ForeColor = $C_ERROR
}

$p4.Controls.Add($pSvcOptions)

$script:cbInstallService.Add_CheckedChanged({ $pSvcOptions.Visible = $script:cbInstallService.Checked })

$p4.Controls.Add((New-StyledLabel -Text "You can also run manually with 'npm run relay' or 'npm run worker'." `
    -X 20 -Y 320 -Width 460 -Height 22 -Font $F_NORMAL -Color $C_TEXTDIM))

$panels[3] = $p4

# ---------------------------------------------------------------------------
# STEP 5: Review
# ---------------------------------------------------------------------------
$p5 = New-Object System.Windows.Forms.Panel
$p5.Dock = "Fill"
$p5.BackColor = $C_BG

$p5.Controls.Add((New-StyledLabel -Text "Review & Install" -X 20 -Y 18 -Width 460 -Height 32 -Font $F_TITLE))
$p5.Controls.Add((New-StyledLabel -Text "Review your settings, then click Install to apply." -X 20 -Y 54 -Width 460 -Height 22 -Font $F_NORMAL -Color $C_TEXTDIM))

$script:txtReview = New-Object System.Windows.Forms.TextBox
$script:txtReview.Multiline = $true
$script:txtReview.ReadOnly = $true
$script:txtReview.ScrollBars = "Both"
$script:txtReview.WordWrap = $false
$script:txtReview.Location = New-Object System.Drawing.Point((S 20), (S 82))
$script:txtReview.Size = New-Object System.Drawing.Size((S 460), (S 370))
$script:txtReview.Font = $F_MONO
$script:txtReview.BackColor = $C_PANEL
$script:txtReview.ForeColor = $C_TEXT
$script:txtReview.BorderStyle = "FixedSingle"
$p5.Controls.Add($script:txtReview)

$panels[4] = $p5

# ---------------------------------------------------------------------------
# STEP 6: Installation Progress
# ---------------------------------------------------------------------------
$p6 = New-Object System.Windows.Forms.Panel
$p6.Dock = "Fill"
$p6.BackColor = $C_BG

$p6.Controls.Add((New-StyledLabel -Text "Installing..." -X 20 -Y 18 -Width 460 -Height 32 -Font $F_TITLE))

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point((S 20), (S 60))
$script:progressBar.Size = New-Object System.Drawing.Size((S 460), (S 24))
$script:progressBar.Style = "Continuous"
$script:progressBar.Minimum = 0
$script:progressBar.Maximum = 100
$p6.Controls.Add($script:progressBar)

$script:txtInstallLog = New-Object System.Windows.Forms.TextBox
$script:txtInstallLog.Multiline = $true
$script:txtInstallLog.ReadOnly = $true
$script:txtInstallLog.ScrollBars = "Vertical"
$script:txtInstallLog.Location = New-Object System.Drawing.Point((S 20), (S 94))
$script:txtInstallLog.Size = New-Object System.Drawing.Size((S 460), (S 356))
$script:txtInstallLog.Font = $F_MONO
$script:txtInstallLog.BackColor = $C_PANEL
$script:txtInstallLog.ForeColor = $C_TEXT
$script:txtInstallLog.BorderStyle = "FixedSingle"
$p6.Controls.Add($script:txtInstallLog)

$panels[5] = $p6

# ---------------------------------------------------------------------------
# STEP 7: Complete
# ---------------------------------------------------------------------------
$p7 = New-Object System.Windows.Forms.Panel
$p7.Dock = "Fill"
$p7.BackColor = $C_BG

$script:lblCompleteIcon = New-StyledLabel -Text "" -X 200 -Y 8 -Width 60 -Height 40 -Font (New-Object System.Drawing.Font("Segoe UI", 26)) -Color $C_SUCCESS
$p7.Controls.Add($script:lblCompleteIcon)

$script:lblCompleteTitle = New-StyledLabel -Text "Setup Complete!" -X 20 -Y 46 -Width 460 -Height 30 -Font $F_TITLE -Color $C_SUCCESS
$script:lblCompleteTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$p7.Controls.Add($script:lblCompleteTitle)

$script:lblCompleteSummary = New-StyledLabel -Text "" -X 20 -Y 80 -Width 460 -Height 60 -Font $F_NORMAL -Color $C_TEXTDIM
$p7.Controls.Add($script:lblCompleteSummary)

# Scrollable "What's next" area
$script:txtWhatsNext = New-Object System.Windows.Forms.TextBox
$script:txtWhatsNext.Multiline = $true
$script:txtWhatsNext.ReadOnly = $true
$script:txtWhatsNext.ScrollBars = "Vertical"
$script:txtWhatsNext.Location = New-Object System.Drawing.Point((S 20), (S 148))
$script:txtWhatsNext.Size = New-Object System.Drawing.Size((S 460), (S 210))
$script:txtWhatsNext.Font = $F_NORMAL
$script:txtWhatsNext.BackColor = $C_PANEL
$script:txtWhatsNext.ForeColor = $C_TEXT
$script:txtWhatsNext.BorderStyle = "FixedSingle"
$p7.Controls.Add($script:txtWhatsNext)

$script:cbStartRelay = New-StyledCheckBox -Text "Start the Relay and open the Dashboard" -X 20 -Y 368 -Width 350 -Checked $true
$p7.Controls.Add($script:cbStartRelay)

$btnViewLogs = New-StyledButton -Text "View Logs" -X 380 -Y 366 -Width 100 -Height 30
$btnViewLogs.Add_Click({
    # Logs are in ProgramData when installed to Program Files
    $logsDir = Join-Path (Join-Path $env:ProgramData "DispatchOrchestrator") "logs"
    if (-not (Test-Path $logsDir)) {
        $logsDir = Join-Path $ProjectRoot "logs"
    }
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    Start-Process "explorer.exe" $logsDir
})
$p7.Controls.Add($btnViewLogs)

$panels[6] = $p7

# ---------------------------------------------------------------------------
# STEP 10: Basic Config (basic mode)
# ---------------------------------------------------------------------------
$p10 = New-Object System.Windows.Forms.Panel
$p10.Dock = "Fill"
$p10.BackColor = $C_BG

$p10.Controls.Add((New-StyledLabel -Text "Basic Configuration" -X 20 -Y 14 -Width 460 -Height 30 -Font $F_TITLE))

$yB = 52

# Port
$p10.Controls.Add((New-StyledLabel -Text "Relay Port:" -X 20 -Y $yB -Width 120 -Height 22))
$script:txtBasicPort = New-StyledTextBox -X 150 -Y ($yB - 2) -Width 80 -Text "7070"
$p10.Controls.Add($script:txtBasicPort)
$p10.Controls.Add((New-StyledLabel -Text "Port the relay listens on (1024-65535)" -X 240 -Y $yB -Width 250 -Height 22 -Font $F_SMALL -Color $C_TEXTDIM))
$yB += 38

# Shared Secret
$p10.Controls.Add((New-StyledLabel -Text "Shared Secret:" -X 20 -Y $yB -Width 120 -Height 22))
$script:txtBasicSecret = New-StyledTextBox -X 150 -Y ($yB - 2) -Width 220 -Text (New-SharedSecret)
$p10.Controls.Add($script:txtBasicSecret)

$btnGenBasicSecret = New-StyledButton -Text "Generate" -X 376 -Y ($yB - 3) -Width 70 -Height 26
$btnGenBasicSecret.Font = $F_SMALL
$btnGenBasicSecret.Add_Click({ $script:txtBasicSecret.Text = New-SharedSecret })
$p10.Controls.Add($btnGenBasicSecret)

$btnCopyBasicSecret = New-StyledButton -Text "Copy" -X 450 -Y ($yB - 3) -Width 50 -Height 26
$btnCopyBasicSecret.Font = $F_SMALL
$btnCopyBasicSecret.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($script:txtBasicSecret.Text)
})
$p10.Controls.Add($btnCopyBasicSecret)
$yB += 22
$p10.Controls.Add((New-StyledLabel -Text "Auth token for API and agent connections. Agents must use the same secret." -X 150 -Y $yB -Width 340 -Height 18 -Font $F_SMALL -Color $C_TEXTDIM))
$yB += 28

# PIN
$p10.Controls.Add((New-StyledLabel -Text "PIN Code:" -X 20 -Y $yB -Width 120 -Height 22))
$script:txtBasicPin = New-StyledTextBox -X 150 -Y ($yB - 2) -Width 100 -Text ""
$p10.Controls.Add($script:txtBasicPin)
$yB += 22
$p10.Controls.Add((New-StyledLabel -Text "Second factor for task submission. 4-8 digits, leave blank to disable." -X 150 -Y $yB -Width 340 -Height 18 -Font $F_SMALL -Color $C_TEXTDIM))
$yB += 32

$p10.Controls.Add((New-StyledLabel -Text "Basic mode uses these defaults:" -X 20 -Y $yB -Width 460 -Height 22 -Font $F_NORMAL -Color $C_TEXTDIM))
$yB += 26
$p10.Controls.Add((New-StyledLabel -Text "  Auto-discovery: On     Task queue: On     Sleep prevention: On" -X 20 -Y $yB -Width 460 -Height 20 -Font $F_SMALL -Color $C_TEXTDIM))
$yB += 20
$p10.Controls.Add((New-StyledLabel -Text "  Rate limiting: On     Load balancing: least-busy     TLS: Off     Service: Off" -X 20 -Y $yB -Width 460 -Height 20 -Font $F_SMALL -Color $C_TEXTDIM))

$panels[10] = $p10

# ===================================================================
# Add all panels to content area (all hidden initially)
# ===================================================================
foreach ($panel in $panels.Values) {
    $panel.Visible = $false
    $contentArea.Controls.Add($panel)
}

# ===================================================================
# NAVIGATION LOGIC
# ===================================================================

# Helper: get current step flow based on mode
function Get-StepFlow {
    if ($script:SetupMode -eq "basic") { return $script:BasicFlow }
    return $script:AdvancedFlow
}

# Helper: get index within the current flow for a given panel index
function Get-FlowIndex {
    param([int]$PanelIndex)
    $flow = Get-StepFlow
    for ($i = 0; $i -lt $flow.Count; $i++) {
        if ($flow[$i] -eq $PanelIndex) { return $i }
    }
    return -1
}

function Update-Sidebar {
    $flowIdx = Get-FlowIndex $script:CurrentStep
    for ($i = 0; $i -lt $script:stepLabels.Count; $i++) {
        if (-not $script:stepLabels[$i].Visible) { continue }
        if ($i -eq $flowIdx) {
            $script:stepLabels[$i].Font = $F_STEP_ACT
            $script:stepLabels[$i].ForeColor = $C_HIGHLIGHT
            $script:stepLabels[$i].BackColor = $C_ACCENT
        } elseif ($i -lt $flowIdx) {
            $script:stepLabels[$i].Font = $F_STEP
            $script:stepLabels[$i].ForeColor = $C_SUCCESS
            $script:stepLabels[$i].BackColor = [System.Drawing.Color]::Transparent
        } else {
            $script:stepLabels[$i].Font = $F_STEP
            $script:stepLabels[$i].ForeColor = $C_TEXTDIM
            $script:stepLabels[$i].BackColor = [System.Drawing.Color]::Transparent
        }
    }
}

function Show-Step {
    param([int]$StepIndex)

    # Clear content area and show the requested panel
    $contentArea.Controls.Clear()
    if ($panels.ContainsKey($StepIndex)) {
        $contentArea.Controls.Add($panels[$StepIndex])
        $panels[$StepIndex].Visible = $true
    }

    $script:CurrentStep = $StepIndex
    Update-Sidebar

    $flow = Get-StepFlow
    $flowIdx = Get-FlowIndex $StepIndex
    $isReview = ($StepIndex -eq 4)
    $isInstalling = ($StepIndex -eq 5)
    $isComplete = ($StepIndex -eq 6)

    # Navigation button visibility
    $btnBack.Visible = ($flowIdx -gt 0) -and (-not $isInstalling) -and (-not $isComplete)
    $btnCancel.Visible = (-not $isInstalling) -and (-not $isComplete)

    if ($isReview) {
        $btnNext.Text = "Install"
        $btnNext.BackColor = $C_HIGHLIGHT
        $btnNext.Visible = $true
    } elseif ($isInstalling) {
        $btnNext.Visible = $false
        $btnBack.Visible = $false
        $btnCancel.Visible = $false
    } elseif ($isComplete) {
        $btnNext.Text = "Finish"
        $btnNext.BackColor = $C_HIGHLIGHT
        $btnNext.Visible = $true
        $btnBack.Visible = $false
        $btnCancel.Visible = $false
    } else {
        $btnNext.Text = "Next >"
        $btnNext.BackColor = $C_ACCENT
        $btnNext.Visible = $true
    }
}

function Build-ReviewText {
    $role = $script:SelectedRole
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("=== DISPATCH ORCHESTRATOR SETUP REVIEW ===")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Role:          ORCHESTRATOR")
    [void]$sb.AppendLine("Mode:          $(if ($script:SetupMode -eq 'basic') { 'Basic' } else { 'Advanced' })")
    [void]$sb.AppendLine("Project Root:  $ProjectRoot")
    [void]$sb.AppendLine("")

    if ($script:SetupMode -eq "basic") {
        [void]$sb.AppendLine("--- Orchestrator Settings (Basic) ---")
        [void]$sb.AppendLine("Port:              $($script:txtBasicPort.Text)")
        [void]$sb.AppendLine("Shared Secret:     $($script:txtBasicSecret.Text.Substring(0, [Math]::Min(16, $script:txtBasicSecret.Text.Length)))...")
        $pinDisplay = if ($script:txtBasicPin.Text.Length -gt 0) { $script:txtBasicPin.Text } else { "(disabled)" }
        [void]$sb.AppendLine("PIN Code:          $pinDisplay")
        [void]$sb.AppendLine("Auto-discovery:    True")
        [void]$sb.AppendLine("Task Queue:        True")
        [void]$sb.AppendLine("Sleep Prevention:  True")
        [void]$sb.AppendLine("Rate Limiting:     True")
        [void]$sb.AppendLine("Load Balancing:    least-busy")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- TLS ---")
        [void]$sb.AppendLine("TLS:               Disabled")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- Windows Service ---")
        [void]$sb.AppendLine("Service:           Not installing")
    } elseif ($role -eq "coordinator") {
        [void]$sb.AppendLine("--- Orchestrator Settings ---")
        [void]$sb.AppendLine("Port:              $($script:txtPort.Text)")
        [void]$sb.AppendLine("Shared Secret:     $($script:txtSecretCoord.Text.Substring(0, [Math]::Min(16, $script:txtSecretCoord.Text.Length)))...")
        $pinDisplay = if ($script:txtPinCode.Text.Length -gt 0) { $script:txtPinCode.Text } else { "(disabled)" }
        [void]$sb.AppendLine("PIN Code:          $pinDisplay")
        [void]$sb.AppendLine("Auto-discovery:    $($script:cbDiscovery.Checked)")
        [void]$sb.AppendLine("Task Queue:        $($script:cbQueue.Checked)")
        [void]$sb.AppendLine("Sleep Prevention:  $($script:cbKeepAwakeCoord.Checked)")
        [void]$sb.AppendLine("Rate Limiting:     $($script:cbRateLimit.Checked)")
        [void]$sb.AppendLine("Load Balancing:    $($script:cmbLB.SelectedItem)")

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- TLS ---")
        if ($script:cbEnableTLS.Checked) {
            if ($script:rbSelfSigned.Checked) {
                [void]$sb.AppendLine("TLS:               Enabled (self-signed, will generate)")
            } else {
                [void]$sb.AppendLine("TLS:               Enabled (existing certificates)")
                [void]$sb.AppendLine("  Cert:            $($script:txtCertFile.Text)")
                [void]$sb.AppendLine("  Key:             $($script:txtKeyFile.Text)")
                [void]$sb.AppendLine("  CA:              $($script:txtCaFile.Text)")
            }
        } else {
            [void]$sb.AppendLine("TLS:               Disabled")
        }

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- Windows Service ---")
        if ($script:cbInstallService.Checked) {
            [void]$sb.AppendLine("Service:           $($script:txtServiceName.Text)")
            [void]$sb.AppendLine("Auto-start:        $($script:cbAutoStart.Checked)")
        } else {
            [void]$sb.AppendLine("Service:           Not installing")
        }
    } else {
        [void]$sb.AppendLine("--- Worker Settings ---")
        [void]$sb.AppendLine("Agent Name:        $($script:txtAgentName.Text)")
        [void]$sb.AppendLine("Description:       $($script:txtAgentDesc.Text)")
        [void]$sb.AppendLine("Capabilities:      $($script:txtCapabilities.Text)")
        [void]$sb.AppendLine("Machine ID:        $($script:txtMachineId.Text)")
        [void]$sb.AppendLine("Coordinator:       $($script:txtCoordHost.Text)")
        [void]$sb.AppendLine("Shared Secret:     $($script:txtSecretWorker.Text.Substring(0, [Math]::Min(16, $script:txtSecretWorker.Text.Length)))...")
        [void]$sb.AppendLine("Working Dir:       $($script:txtWorkDir.Text)")
        [void]$sb.AppendLine("Allowed Dirs:      $($script:txtAllowedDirs.Text.Replace("`r`n", ", "))")
        [void]$sb.AppendLine("Auto-discovery:    $($script:cbWorkerDiscovery.Checked)")
        [void]$sb.AppendLine("Sleep Prevention:  $($script:cbKeepAwakeWorker.Checked)")

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- TLS ---")
        if ($script:cbEnableTLS.Checked) {
            if ($script:rbSelfSigned.Checked) {
                [void]$sb.AppendLine("TLS:               Enabled (self-signed, will generate)")
            } else {
                [void]$sb.AppendLine("TLS:               Enabled (existing certificates)")
                [void]$sb.AppendLine("  Cert:            $($script:txtCertFile.Text)")
                [void]$sb.AppendLine("  Key:             $($script:txtKeyFile.Text)")
                [void]$sb.AppendLine("  CA:              $($script:txtCaFile.Text)")
            }
        } else {
            [void]$sb.AppendLine("TLS:               Disabled")
        }

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("--- Windows Service ---")
        if ($script:cbInstallService.Checked) {
            [void]$sb.AppendLine("Service:           $($script:txtServiceName.Text)")
            [void]$sb.AppendLine("Auto-start:        $($script:cbAutoStart.Checked)")
        } else {
            [void]$sb.AppendLine("Service:           Not installing")
        }
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("--- Files to create/modify ---")
    if ($role -eq "coordinator") {
        [void]$sb.AppendLine("  WRITE  relay/config.json")
    } else {
        [void]$sb.AppendLine("  WRITE  worker/worker-config.json")
    }
    if ($script:SetupMode -eq "advanced" -and $script:cbEnableTLS.Checked -and $script:rbSelfSigned.Checked) {
        [void]$sb.AppendLine("  CREATE certs/ca.crt, ca.key")
        [void]$sb.AppendLine("  CREATE certs/server.crt, server.key")
        [void]$sb.AppendLine("  CREATE certs/client.crt, client.key")
    }
    [void]$sb.AppendLine("  RUN    npm install (if needed)")
    if ($script:SetupMode -eq "advanced" -and $script:cbInstallService.Checked) {
        [void]$sb.AppendLine("  RUN    nssm install $($script:txtServiceName.Text)")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("--- Config JSON Preview ---")
    [void]$sb.AppendLine((Build-ConfigJson))

    return $sb.ToString()
}

function Build-ConfigJson {
    $role = $script:SelectedRole
    if ($script:SetupMode -eq "basic" -and $role -eq "coordinator") {
        # Basic mode — use fields from the basic config panel, defaults for the rest
        $port = [int]$script:txtBasicPort.Text
        $secret = $script:txtBasicSecret.Text
        $pinEnabled = $script:txtBasicPin.Text.Length -gt 0
        $pinCode = if ($pinEnabled) { $script:txtBasicPin.Text } else { "" }

        $config = [ordered]@{
            port = $port
            sharedSecret = $secret
            machines = @(
                [ordered]@{
                    machineId = "machine-2"
                    description = "Worker machine 2"
                    defaultWorkingDir = "C:/workspace"
                }
            )
            tls = [ordered]@{
                enabled = $false
                certFile = "../certs/server.crt"
                keyFile = "../certs/server.key"
                caFile = "../certs/ca.crt"
            }
            discovery = [ordered]@{
                enabled = $true
                broadcastPort = 7071
                intervalMs = 5000
            }
            heartbeat = [ordered]@{
                intervalMs = 30000
                timeoutMs = 10000
            }
            loadBalancing = [ordered]@{
                strategy = "least-busy"
            }
            rateLimiting = [ordered]@{
                enabled = $true
                maxTasksPerMinute = 10
                maxTasksPerHour = 100
            }
            limits = [ordered]@{
                maxPromptLength = 50000
                maxOutputLength = 1000000
                maxRequestBodyBytes = 102400
            }
            keepAwake = [ordered]@{
                enabled = $true
            }
            queue = [ordered]@{
                enabled = $true
                maxQueueSize = 100
            }
            pin = [ordered]@{
                enabled = $pinEnabled
                code = $pinCode
                maxAttempts = 5
                lockoutMinutes = 15
            }
        }
    } elseif ($role -eq "coordinator") {
        $port = [int]$script:txtPort.Text
        $secret = $script:txtSecretCoord.Text
        $pinEnabled = $script:txtPinCode.Text.Length -gt 0
        $pinCode = if ($pinEnabled) { $script:txtPinCode.Text } else { "" }

        $certFile = "../certs/server.crt"
        $keyFile = "../certs/server.key"
        $caFile = "../certs/ca.crt"
        if ($script:cbEnableTLS.Checked -and $script:rbExistingCerts.Checked) {
            $certFile = $script:txtCertFile.Text
            $keyFile = $script:txtKeyFile.Text
            $caFile = $script:txtCaFile.Text
        }

        $config = [ordered]@{
            port = $port
            sharedSecret = $secret
            machines = @(
                [ordered]@{
                    machineId = "machine-2"
                    description = "Worker machine 2"
                    defaultWorkingDir = "C:/workspace"
                }
            )
            tls = [ordered]@{
                enabled = $script:cbEnableTLS.Checked
                certFile = $certFile
                keyFile = $keyFile
                caFile = $caFile
            }
            discovery = [ordered]@{
                enabled = $script:cbDiscovery.Checked
                broadcastPort = 7071
                intervalMs = 5000
            }
            heartbeat = [ordered]@{
                intervalMs = 30000
                timeoutMs = 10000
            }
            loadBalancing = [ordered]@{
                strategy = $script:cmbLB.SelectedItem.ToString()
            }
            rateLimiting = [ordered]@{
                enabled = $script:cbRateLimit.Checked
                maxTasksPerMinute = 10
                maxTasksPerHour = 100
            }
            limits = [ordered]@{
                maxPromptLength = 50000
                maxOutputLength = 1000000
                maxRequestBodyBytes = 102400
            }
            keepAwake = [ordered]@{
                enabled = $script:cbKeepAwakeCoord.Checked
            }
            queue = [ordered]@{
                enabled = $script:cbQueue.Checked
                maxQueueSize = 100
            }
            pin = [ordered]@{
                enabled = $pinEnabled
                code = $pinCode
                maxAttempts = 5
                lockoutMinutes = 15
            }
        }
    } else {
        $coordHost = $script:txtCoordHost.Text
        if ($coordHost -ne "auto" -and -not $coordHost.StartsWith("ws")) {
            $proto = if ($script:cbEnableTLS.Checked) { "wss" } else { "ws" }
            $coordHost = "$proto`://$coordHost"
        }

        $certFile = "../certs/client.crt"
        $keyFile = "../certs/client.key"
        $caFile = "../certs/ca.crt"
        if ($script:cbEnableTLS.Checked -and $script:rbExistingCerts.Checked) {
            $certFile = $script:txtCertFile.Text
            $keyFile = $script:txtKeyFile.Text
            $caFile = $script:txtCaFile.Text
        }

        $caps = @($script:txtCapabilities.Text -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
        $allowedDirs = @($script:txtAllowedDirs.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })

        $config = [ordered]@{
            machineId = $script:txtMachineId.Text
            agentName = $script:txtAgentName.Text
            agentDescription = $script:txtAgentDesc.Text
            agentCapabilities = $caps
            coordinatorHost = $coordHost
            sharedSecret = $script:txtSecretWorker.Text
            defaultWorkingDir = $script:txtWorkDir.Text
            allowedDirs = $allowedDirs
            denyDirs = @(
                "C:/Windows",
                "C:/Program Files",
                "C:/Program Files (x86)",
                "C:/Users/*/AppData",
                "C:/Users/*/.ssh",
                "C:/Users/*/.aws",
                "C:/Users/*/.azure",
                "C:/Users/*/.kube",
                "C:/Users/*/.docker",
                "C:/Users/*/.gnupg",
                "C:/ProgramData",
                "C:/Recovery",
                'C:/$Recycle.Bin'
            )
            tls = [ordered]@{
                enabled = $script:cbEnableTLS.Checked
                certFile = $certFile
                keyFile = $keyFile
                caFile = $caFile
            }
            discovery = [ordered]@{
                enabled = $script:cbWorkerDiscovery.Checked
                broadcastPort = 7071
                timeoutMs = 15000
            }
            maxOutputLength = 1000000
            keepAwake = [ordered]@{
                enabled = $script:cbKeepAwakeWorker.Checked
            }
        }
    }

    return ($config | ConvertTo-Json -Depth 5)
}

function Write-InstallLog {
    param([string]$Message, [string]$Status = "INFO")
    $prefix = switch ($Status) {
        "OK"    { "[OK]    " }
        "FAIL"  { "[FAIL]  " }
        "INFO"  { "[....]  " }
        "SKIP"  { "[SKIP]  " }
        default { "[....]  " }
    }
    $script:txtInstallLog.AppendText("$prefix$Message`r`n")
    $script:txtInstallLog.SelectionStart = $script:txtInstallLog.Text.Length
    $script:txtInstallLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Run-Installation {
    $script:InstallCancelled = $false
    $script:progressBar.Value = 0
    $script:txtInstallLog.Text = ""
    $role = $script:SelectedRole
    $totalSteps = 5
    $doTls = ($script:SetupMode -eq "advanced") -and $script:cbEnableTLS.Checked -and $script:rbSelfSigned.Checked
    $doService = ($script:SetupMode -eq "advanced") -and $script:cbInstallService.Checked
    if ($doTls) { $totalSteps++ }
    if ($doService) { $totalSteps++ }
    $script:_installStepNum = 0
    $script:_installTotalSteps = $totalSteps

    $advanceProgress = {
        $script:_installStepNum++
        $pct = [Math]::Min(100, [int](($script:_installStepNum / $script:_installTotalSteps) * 100))
        $script:progressBar.Value = $pct
        [System.Windows.Forms.Application]::DoEvents()
    }

    # --- Step: Check Node.js ---
    Write-InstallLog "Checking Node.js..." "INFO"
    try {
        $nodeVer = & node --version 2>&1
        Write-InstallLog "Node.js $nodeVer found." "OK"
    } catch {
        Write-InstallLog "Node.js not found! Please install Node.js 18+ and try again." "FAIL"
        return $false
    }
    & $advanceProgress

    # --- Step: npm install ---
    Write-InstallLog "Checking npm dependencies..." "INFO"
    $nodeModules = Join-Path $ProjectRoot "node_modules"
    if (-not (Test-Path $nodeModules)) {
        Write-InstallLog "Running npm install (this may take a moment)..." "INFO"
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $npmOutput = & npm install --prefix $ProjectRoot 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-InstallLog "npm install failed:`n$npmOutput" "FAIL"
                return $false
            }
            Write-InstallLog "npm dependencies installed." "OK"
        } catch {
            Write-InstallLog "npm install error: $_" "FAIL"
            return $false
        }
    } else {
        Write-InstallLog "node_modules/ already exists, skipping npm install." "SKIP"
    }
    & $advanceProgress

    # --- Step: Write config ---
    $configJson = Build-ConfigJson
    if ($role -eq "coordinator") {
        $configPath = Join-Path (Join-Path $ProjectRoot "relay") "config.json"
        Write-InstallLog "Writing relay/config.json..." "INFO"
    } else {
        $configPath = Join-Path (Join-Path $ProjectRoot "worker") "worker-config.json"
        Write-InstallLog "Writing worker/worker-config.json..." "INFO"
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    try {
        # Try direct write first (works outside Program Files)
        [System.IO.File]::WriteAllText($configPath, $configJson, $utf8NoBom)
        Write-InstallLog "Configuration written to $configPath" "OK"
    } catch {
        # Any write failure — try elevated copy (Program Files needs admin)
        Write-InstallLog "Direct write failed, requesting elevation..." "INFO"
        try {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmpFile, $configJson, $utf8NoBom)
            $copyCmd = "Copy-Item -Path '$tmpFile' -Destination '$configPath' -Force; Remove-Item '$tmpFile' -Force"
            Start-Process powershell -ArgumentList "-NoProfile -Command `"$copyCmd`"" -Verb RunAs -Wait
            Write-InstallLog "Configuration written to $configPath (elevated)" "OK"
        } catch {
            Write-InstallLog "Failed to write config: $_" "FAIL"
            return $false
        }
    }
    & $advanceProgress

    # --- Step: Deploy orchestrate skill (coordinator only) ---
    if ($role -eq "coordinator") {
        Write-InstallLog "Deploying orchestrate skill for Claude Code..." "INFO"
        $skillDir = Join-Path (Join-Path $ProjectRoot ".claude") "commands"
        $skillSource = Join-Path $skillDir "orchestrate.md"
        if (Test-Path $skillSource) {
            Write-InstallLog "Orchestrate skill available at $skillDir" "OK"
            Write-InstallLog "Use /orchestrate in Claude Code to dispatch tasks across agents." "INFO"
        } else {
            Write-InstallLog "Orchestrate skill not found in .claude/commands/ - skipped." "SKIP"
        }
    }

    # --- Step: TLS certs ---
    if ($doTls) {
        Write-InstallLog "Generating TLS certificates..." "INFO"
        [System.Windows.Forms.Application]::DoEvents()
        $certScript = Join-Path (Join-Path $ProjectRoot "install") "generate-certs.ps1"
        if (Test-Path $certScript) {
            try {
                $certOutput = & powershell -ExecutionPolicy Bypass -File $certScript -Force 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    Write-InstallLog "Certificate generation had warnings:`n$certOutput" "FAIL"
                } else {
                    Write-InstallLog "TLS certificates generated in certs/ directory." "OK"
                }
            } catch {
                Write-InstallLog "Certificate generation failed: $_" "FAIL"
                Write-InstallLog "You can run install/generate-certs.ps1 manually later." "INFO"
            }
        } else {
            Write-InstallLog "generate-certs.ps1 not found, skipping cert generation." "FAIL"
        }
        & $advanceProgress
    }

    # --- Step: Kill any existing process on the relay port ---
    $port = if ($role -eq "coordinator" -and $script:SetupMode -eq "basic") {
        [int]$script:txtBasicPort.Text
    } elseif ($role -eq "coordinator") {
        [int]$script:txtPort.Text
    } else { $null }
    if ($port) {
        $existing = netstat -ano 2>$null | Select-String ":$port\s+.*LISTENING\s+(\d+)" |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique
        foreach ($pid in $existing) {
            Write-InstallLog "Stopping existing process on port $port (PID $pid)..." "INFO"
            Stop-Process -Id ([int]$pid) -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }

    # --- Step: Windows service ---
    if ($doService) {
        $svcName = $script:txtServiceName.Text
        Write-InstallLog "Installing Windows service '$svcName'..." "INFO"
        [System.Windows.Forms.Application]::DoEvents()

        # Find NSSM
        $nssmPath = $null
        $nssmCmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
        if ($nssmCmd) { $nssmPath = $nssmCmd.Source }
        if (-not $nssmPath) {
            $candidates = @("C:\nssm\nssm.exe","C:\tools\nssm\nssm.exe","C:\Program Files\nssm\nssm.exe","C:\ProgramData\chocolatey\bin\nssm.exe")
            foreach ($c in $candidates) { if (Test-Path $c) { $nssmPath = $c; break } }
        }

        if (-not $nssmPath) {
            Write-InstallLog "NSSM not found. Service installation skipped." "FAIL"
            Write-InstallLog "Install NSSM and run install-relay.ps1 or install-worker.ps1 manually." "INFO"
        } else {
            try {
                $nodePath = (Get-Command node.exe).Source
                if ($role -eq "coordinator") {
                    $entryScript = Join-Path (Join-Path $ProjectRoot "relay") "server.js"
                    $appDir = Join-Path $ProjectRoot "relay"
                } else {
                    $entryScript = Join-Path (Join-Path $ProjectRoot "worker") "agent-relay.js"
                    $appDir = Join-Path $ProjectRoot "worker"
                }
                $logsDir = Join-Path $ProjectRoot "logs"
                if (-not (Test-Path $logsDir)) {
                    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
                }

                # Remove existing service if present
                $svcStatus = & $nssmPath status $svcName 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-InstallLog "Removing existing service '$svcName'..." "INFO"
                    & $nssmPath stop $svcName 2>&1 | Out-Null
                    & $nssmPath remove $svcName confirm 2>&1 | Out-Null
                }

                & $nssmPath install $svcName $nodePath $entryScript 2>&1 | Out-Null
                & $nssmPath set $svcName AppDirectory $appDir 2>&1 | Out-Null
                if ($script:cbAutoStart.Checked) {
                    & $nssmPath set $svcName Start SERVICE_AUTO_START 2>&1 | Out-Null
                }
                & $nssmPath set $svcName AppStdout (Join-Path $logsDir "$svcName-stdout.log") 2>&1 | Out-Null
                & $nssmPath set $svcName AppStderr (Join-Path $logsDir "$svcName-stderr.log") 2>&1 | Out-Null
                & $nssmPath set $svcName AppStdoutCreationDisposition 4 2>&1 | Out-Null
                & $nssmPath set $svcName AppStderrCreationDisposition 4 2>&1 | Out-Null

                Write-InstallLog "Service '$svcName' installed." "OK"
                & $advanceProgress

                # Start service
                Write-InstallLog "Starting service '$svcName'..." "INFO"
                [System.Windows.Forms.Application]::DoEvents()
                & $nssmPath start $svcName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-InstallLog "Service installed but failed to start. Check logs in $logsDir" "FAIL"
                } else {
                    Write-InstallLog "Service '$svcName' started successfully." "OK"
                }
            } catch {
                Write-InstallLog "Service installation error: $_" "FAIL"
                Write-InstallLog "You may need to run this wizard as Administrator." "INFO"
            }
        }
        & $advanceProgress
    } else {
        # --- Step: Start process directly (no service) ---
        Write-InstallLog "Starting process directly (no Windows service)..." "INFO"
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $nodePath = (Get-Command node.exe).Source
            if ($role -eq "coordinator") {
                $entryScript = Join-Path (Join-Path $ProjectRoot "relay") "server.js"
            } else {
                $entryScript = Join-Path (Join-Path $ProjectRoot "worker") "agent-relay.js"
            }

            # Use AppData for logs when installed to a protected directory (Program Files)
            $normalizedRoot = $ProjectRoot.Replace('\', '/').ToLower()
            if ($normalizedRoot -match 'program files' -and $env:APPDATA) {
                $logsDir = Join-Path (Join-Path $env:APPDATA "DispatchOrchestrator") "logs"
            } else {
                $logsDir = Join-Path $ProjectRoot "logs"
            }
            if (-not (Test-Path $logsDir)) {
                New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            }
            $processName = if ($role -eq 'coordinator') { 'relay' } else { 'worker' }
            $logFile = Join-Path $logsDir "$processName-stdout.log"
            $errFile = Join-Path $logsDir "$processName-stderr.log"

            # Write a temp .cmd launcher to avoid nested quoting issues with cmd /C
            $launcherFile = Join-Path $logsDir "$processName-launcher.cmd"
            $launcherContent = "@echo off`r`ncd /d `"$ProjectRoot`"`r`n`"$nodePath`" `"$entryScript`" > `"$logFile`" 2> `"$errFile`""
            $launcherContent | Set-Content -Path $launcherFile -Encoding ASCII -Force
            Start-Process -FilePath "cmd.exe" -ArgumentList "/C `"$launcherFile`"" `
                -WindowStyle Hidden | Out-Null

            # Brief pause to check if the process crashed immediately
            Start-Sleep -Milliseconds 2000
            $running = Get-Process -Name "node" -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -gt (Get-Date).AddSeconds(-5) }

            if ($running) {
                Write-InstallLog "Started $processName process in the background." "OK"
                Write-InstallLog "Logs: $logsDir" "INFO"
            } else {
                # Process may have crashed — show stderr if available
                Write-InstallLog "Process may have failed to start." "FAIL"
                if (Test-Path $errFile) {
                    $errContent = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
                    if ($errContent) {
                        Write-InstallLog "Error output: $($errContent.Substring(0, [Math]::Min(500, $errContent.Length)))" "FAIL"
                    }
                }
                Write-InstallLog "Start manually with: npm run $processName" "INFO"
            }
            Write-InstallLog "NOTE: This process will stop when you log out. Use the Windows Service option for persistent operation." "INFO"
        } catch {
            Write-InstallLog "Failed to start process: $_" "FAIL"
            Write-InstallLog "Start manually with: npm run $(if ($role -eq 'coordinator') { 'relay' } else { 'worker' })" "INFO"
        }
        & $advanceProgress
    }

    # --- Final ---
    $script:progressBar.Value = 100
    Write-InstallLog "" "INFO"
    Write-InstallLog "Installation complete!" "OK"
    return $true
}

function Validate-Step {
    param([int]$StepIndex)

    if ($StepIndex -eq 0) {
        # Welcome — set up coordinator config panel visibility
        $pCoordCfg.Visible = $true
        $pWorkerCfg.Visible = $false
        $script:txtServiceName.Text = "DispatchRelay"
    }
    elseif ($StepIndex -eq 10) {
        # Basic config validation
        $port = 0
        if (-not [int]::TryParse($script:txtBasicPort.Text, [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
            [void][System.Windows.Forms.MessageBox]::Show("Port must be a number between 1024 and 65535.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:txtBasicSecret.Text.Trim().Length -lt 8) {
            [void][System.Windows.Forms.MessageBox]::Show("Shared secret must be at least 8 characters.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:txtBasicPin.Text.Length -gt 0) {
            if ($script:txtBasicPin.Text -notmatch '^\d{4,8}$') {
                [void][System.Windows.Forms.MessageBox]::Show("PIN must be 4-8 digits (or leave blank to disable).", "Validation", "OK", "Warning")
                return $false
            }
        }
    }
    elseif ($StepIndex -eq 1) {
        # Configuration validation (coordinator, advanced)
        $port = 0
        if (-not [int]::TryParse($script:txtPort.Text, [ref]$port) -or $port -lt 1024 -or $port -gt 65535) {
            [void][System.Windows.Forms.MessageBox]::Show("Port must be a number between 1024 and 65535.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:txtSecretCoord.Text.Trim().Length -lt 8) {
            [void][System.Windows.Forms.MessageBox]::Show("Shared secret must be at least 8 characters.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:txtPinCode.Text.Length -gt 0) {
            if ($script:txtPinCode.Text -notmatch '^\d{4,8}$') {
                [void][System.Windows.Forms.MessageBox]::Show("PIN must be 4-8 digits (or leave blank to disable).", "Validation", "OK", "Warning")
                return $false
            }
        }
    }
    elseif ($StepIndex -eq 2) {
        # TLS validation
        if ($script:cbEnableTLS.Checked -and $script:rbExistingCerts.Checked) {
            if ($script:txtCertFile.Text.Trim().Length -eq 0 -or
                $script:txtKeyFile.Text.Trim().Length -eq 0 -or
                $script:txtCaFile.Text.Trim().Length -eq 0) {
                [void][System.Windows.Forms.MessageBox]::Show("Please provide all three certificate files (cert, key, CA).", "Validation", "OK", "Warning")
                return $false
            }
        }
    }
    elseif ($StepIndex -eq 3) {
        # Service validation
        if ($script:cbInstallService.Checked -and $script:txtServiceName.Text.Trim().Length -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show("Service name is required.", "Validation", "OK", "Warning")
            return $false
        }
    }
    return $true
}

# ===================================================================
# BUTTON HANDLERS
# ===================================================================

$btnNext.Add_Click({
    $step = $script:CurrentStep
    $flow = Get-StepFlow
    $flowIdx = Get-FlowIndex $step

    # Validate current step before proceeding
    if (-not (Validate-Step $step)) { return }

    if ($step -eq 4) {
        # Review -> Installing: populate review, then install
        $script:txtReview.Text = Build-ReviewText
        Show-Step 5
        [System.Windows.Forms.Application]::DoEvents()
        $success = Run-Installation
        if ($success) {
            # Populate complete page
            $role = $script:SelectedRole
            $script:lblCompleteIcon.Text = [char]0x2713
            $script:lblCompleteTitle.Text = "Setup Complete!"
            $script:lblCompleteTitle.ForeColor = $C_SUCCESS

            if ($role -eq "coordinator") {
                $port = if ($script:SetupMode -eq "basic") { $script:txtBasicPort.Text } else { $script:txtPort.Text }
                $proto = if ($script:SetupMode -eq "advanced" -and $script:cbEnableTLS.Checked) { "https" } else { "http" }
                $secret = if ($script:SetupMode -eq "basic") { $script:txtBasicSecret.Text } else { $script:txtSecretCoord.Text }
                $secretHint = $secret.Substring(0, [Math]::Min(4, $secret.Length)) + "...." + $secret.Substring([Math]::Max(0, $secret.Length - 4))
                $svcInstalled = ($script:SetupMode -eq "advanced") -and $script:cbInstallService.Checked
                $script:lblCompleteSummary.Text = "Your machine has been configured as the Orchestrator.`nThe relay server is configured on port $port.`nShared secret has been set in relay/config.json."
                if ($svcInstalled) {
                    $script:txtWhatsNext.Text = "What's next:`n`n" +
                        "  - The relay is running as a Windows service (starts on boot)`n" +
                        "  - Open the dashboard at $proto`://localhost:$port/dashboard`n" +
                        "  - Install agents on other machines and point them to this orchestrator`n`n" +
                        "DASHBOARD SETUP:`n" +
                        "  When prompted, enter your shared secret as the Bearer token.`n" +
                        "  Your shared secret is: $secretHint"
                } else {
                    $script:txtWhatsNext.Text = "What's next:`n`n" +
                        "  - The relay has been started in the background`n" +
                        "  - Open the dashboard at $proto`://localhost:$port/dashboard`n" +
                        "  - Install agents on other machines and point them to this orchestrator`n" +
                        "  - To restart later: npm run relay`n`n" +
                        "DASHBOARD SETUP:`n" +
                        "  When prompted, enter your shared secret as the Bearer token.`n" +
                        "  Your shared secret is: $secretHint"
                }
            } else {
                $agentName = $script:txtAgentName.Text
                $coordHost = $script:txtCoordHost.Text
                $secret = $script:txtSecretWorker.Text
                $secretHint = $secret.Substring(0, [Math]::Min(4, $secret.Length)) + "...." + $secret.Substring([Math]::Max(0, $secret.Length - 4))
                $svcInstalled = ($script:SetupMode -eq "advanced") -and $script:cbInstallService.Checked
                $script:lblCompleteSummary.Text = "Your machine has been configured as Worker '$agentName'.`nCoordinator: $coordHost`nConfiguration saved to worker/worker-config.json."
                if ($svcInstalled) {
                    $script:txtWhatsNext.Text = "What's next:`n`n" +
                        "  - The worker is running as a Windows service (starts on boot)`n" +
                        "  - Ensure the coordinator is running`n" +
                        "  - Your agent '$agentName' will connect automatically`n`n" +
                        "DASHBOARD SETUP:`n" +
                        "  Open the coordinator's dashboard`n" +
                        "  When prompted, enter your shared secret as the Bearer token.`n" +
                        "  Your shared secret is: $secretHint"
                } else {
                    $script:txtWhatsNext.Text = "What's next:`n`n" +
                        "  - The worker has been started in the background`n" +
                        "  - Ensure the coordinator is running`n" +
                        "  - Your agent '$agentName' will connect automatically`n" +
                        "  - To restart later: npm run worker`n`n" +
                        "DASHBOARD SETUP:`n" +
                        "  Open the coordinator's dashboard`n" +
                        "  When prompted, enter your shared secret as the Bearer token.`n" +
                        "  Your shared secret is: $secretHint"
                }
            }

            Show-Step 6
        } else {
            # Stay on install page, user can see errors
            $btnNext.Visible = $true
            $btnNext.Text = "Retry"
            $btnBack.Visible = $true
            $btnCancel.Visible = $true
        }
        return
    }

    if ($step -eq 6) {
        # Finish — launch relay + dashboard if checkbox is checked
        if ($script:cbStartRelay -and $script:cbStartRelay.Checked) {
            $port = if ($script:SetupMode -eq "basic") { $script:txtBasicPort.Text } elseif ($script:SelectedRole -eq "coordinator") { $script:txtPort.Text } else { "7070" }
            $proto = if ($script:SetupMode -eq "advanced" -and $script:cbEnableTLS.Checked) { "https" } else { "http" }

            # Kill any existing process on the relay port
            try {
                $existing = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($existing) {
                    Stop-Process -Id $existing.OwningProcess -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                }
            } catch {}

            $cmdArgs = "/C title Dispatch Relay & node relay/server.js || (echo. & echo Relay stopped. Press any key to close. & pause >nul)"
            Start-Process cmd.exe -ArgumentList $cmdArgs -WorkingDirectory $ProjectRoot -WindowStyle Minimized
            Start-Sleep -Seconds 3
            # Pass the shared secret as a URL param so the dashboard auto-configures
            $secret = if ($script:SetupMode -eq "basic") { $script:txtBasicSecret.Text } else { $script:txtSecretCoord.Text }
            $encodedSecret = [System.Uri]::EscapeDataString($secret)
            Start-Process "$proto`://localhost:$port/dashboard?token=$encodedSecret"
        }
        $form.Close()
        return
    }

    # Populate review before showing Review step (the step before review in the flow)
    $nextFlowIdx = $flowIdx + 1
    if ($nextFlowIdx -lt $flow.Count -and $flow[$nextFlowIdx] -eq 4) {
        $script:txtReview.Text = Build-ReviewText
    }

    # Move to next step in the flow
    if ($flowIdx -ge 0 -and $flowIdx -lt ($flow.Count - 1)) {
        Show-Step $flow[$flowIdx + 1]
    }
})

$btnBack.Add_Click({
    $step = $script:CurrentStep
    $flow = Get-StepFlow
    $flowIdx = Get-FlowIndex $step
    if ($flowIdx -gt 0) {
        Show-Step $flow[$flowIdx - 1]
    }
})

$btnCancel.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to cancel setup?", "Cancel Setup", "YesNo", "Question")
    if ($result -eq "Yes") {
        $script:InstallCancelled = $true
        $form.Close()
    }
})

# ===================================================================
# SHOW FIRST STEP AND RUN
# ===================================================================
Show-Step 0

# When launched with -WindowStyle Hidden (from installer), the console is hidden
# but the WinForms form still needs to be brought to front.
$form.Add_Shown({
    $form.TopMost = $true
    $form.Activate()
    $form.BringToFront()
    $form.TopMost = $false
})

[void]$form.ShowDialog()

# Cleanup
$form.Dispose()

# Exit with code 0 on success, 1 on cancel
if ($script:InstallCancelled) {
    exit 1
} else {
    exit 0
}
