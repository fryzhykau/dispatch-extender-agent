<#
.SYNOPSIS
    Dispatch Agent Setup Wizard — standalone GUI for configuring a worker agent.

.DESCRIPTION
    A Windows Forms GUI wizard that configures this machine as a named agent
    in a Dispatch Orchestrator network. This is a simplified, self-contained
    version for agent/worker machines only — no relay, orchestrator, or dashboard.

    Run with:  powershell -ExecutionPolicy Bypass -File installer\agent-setup-wizard.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Global error trap — log crash details to ProgramData for diagnostics
trap {
    $crashLog = Join-Path (Join-Path $env:ProgramData "DispatchAgent") "logs\wizard-crash.log"
    $crashDir = Split-Path $crashLog
    if (-not (Test-Path $crashDir)) { New-Item -ItemType Directory -Path $crashDir -Force | Out-Null }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') CRASH: $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Out-File $crashLog -Encoding UTF8 -Force
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [void][System.Windows.Forms.MessageBox]::Show("Agent wizard crashed:`n`n$($_.Exception.Message)`n`nSee: $crashLog", "Dispatch Agent", 0, 16)
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Enable DPI awareness for crisp rendering on high-DPI displays.
# SetProcessDPIAware tells Windows not to bitmap-scale the window.
# All control layouts are designed at 96 DPI; we scale them by $DpiScale.
try {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class AgentDpiHelper {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
    [AgentDpiHelper]::SetProcessDPIAware() | Out-Null
} catch {
    # Already loaded or unavailable — continue without DPI awareness
}

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
# Resolve paths
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigFile  = Join-Path $ProjectRoot "worker\worker-config.json"

# ---------------------------------------------------------------------------
# Theme colors
# ---------------------------------------------------------------------------
$ColorDarkBg    = [System.Drawing.Color]::FromArgb(26, 26, 46)      # #1a1a2e
$ColorPanel     = [System.Drawing.Color]::FromArgb(22, 33, 62)      # #16213e
$ColorAccent    = [System.Drawing.Color]::FromArgb(15, 52, 96)      # #0f3460
$ColorHighlight = [System.Drawing.Color]::FromArgb(233, 69, 96)     # #e94560
$ColorWhite     = [System.Drawing.Color]::White
$ColorLightGray = [System.Drawing.Color]::FromArgb(180, 180, 200)
$ColorDimGray   = [System.Drawing.Color]::FromArgb(120, 130, 150)
$ColorInputBg   = [System.Drawing.Color]::FromArgb(30, 40, 70)
$ColorInputBorder = [System.Drawing.Color]::FromArgb(50, 65, 110)
$ColorGreen     = [System.Drawing.Color]::FromArgb(80, 200, 120)
$ColorRed       = [System.Drawing.Color]::FromArgb(233, 69, 96)

# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------
$FontTitle      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$FontSubtitle   = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$FontBody       = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$FontLabel      = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$FontSmall      = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
$FontMono       = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)
$FontMonoSmall  = New-Object System.Drawing.Font("Consolas", 8.5, [System.Drawing.FontStyle]::Regular)
$FontStep       = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$FontStepActive = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

# ---------------------------------------------------------------------------
# State — current step and collected config values
# ---------------------------------------------------------------------------
$script:CurrentStep = 0
$script:TotalSteps  = 8  # 0-indexed: 0=Welcome,1=Identity,2=Connection,3=Dirs,4=Options,5=Review,6=Installing,7=Complete
$script:SetupMode   = "basic"  # "basic" or "advanced"

# Step flow sequences for each mode (panel indices)
# Basic:    Welcome(0) -> BasicConfig(10) -> Review(5) -> Installing(6) -> Complete(7)
# Advanced: Welcome(0) -> Identity(1) -> Connection(2) -> Dirs(3) -> Options(4) -> Review(5) -> Installing(6) -> Complete(7)
$script:BasicFlow    = @(0, 10, 5, 6, 7)
$script:AdvancedFlow = @(0, 1, 2, 3, 4, 5, 6, 7)

$script:BasicSidebarNames    = @("Welcome", "Configuration", "Review", "Installing", "Complete")
$script:AdvancedSidebarNames = @("Welcome", "Agent Identity", "Connection", "Directories", "Options", "Review", "Installing", "Complete")

$script:Config = @{
    agentName          = ""
    agentDescription   = ""
    agentCapabilities  = @()
    machineId          = "$($env:COMPUTERNAME.ToLower())-$(Get-Random -Minimum 1000 -Maximum 9999)"
    connectionMode     = "auto"     # "auto" or "manual"
    coordinatorHost    = "ws://192.168.1.100:7070"
    sharedSecret       = ""
    defaultWorkingDir  = "C:\workspace"
    allowedDirs        = @("C:\workspace")
    denyDirs           = @("C:\Windows", "C:\Program Files", "C:\Program Files (x86)", "C:\Users\*\AppData")
    keepAwake          = $true
    enableTls          = $false
    installService     = $false
    startAfterSetup    = $true
    maxOutputLength    = 1000000
}

# ---------------------------------------------------------------------------
# Main form
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Dispatch Agent Setup"
$form.Size = New-Object System.Drawing.Size((S 716), (S 558))
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = $ColorDarkBg
$form.ForeColor = $ColorWhite
$form.Font = $FontBody

$icoPath = Join-Path $ProjectRoot "installer\assets\icon.ico"
if (Test-Path $icoPath) {
    $form.Icon = New-Object System.Drawing.Icon($icoPath)
}

# ---------------------------------------------------------------------------
# Helper: create a styled label
# ---------------------------------------------------------------------------
function New-StyledLabel {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 600, [int]$Height = 20,
        [System.Drawing.Font]$Font = $FontBody,
        [System.Drawing.Color]$ForeColor = $ColorWhite
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $lbl.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $lbl.Font = $Font
    $lbl.ForeColor = $ForeColor
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($lbl)
    return $lbl
}

# ---------------------------------------------------------------------------
# Helper: create a styled text input
# ---------------------------------------------------------------------------
function New-StyledTextBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 400, [int]$Height = 26
    )
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $Text
    $tb.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $tb.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $tb.Font = $FontBody
    $tb.BackColor = $ColorInputBg
    $tb.ForeColor = $ColorWhite
    $tb.BorderStyle = "FixedSingle"
    $Parent.Controls.Add($tb)
    return $tb
}

# ---------------------------------------------------------------------------
# Helper: create a styled button
# ---------------------------------------------------------------------------
function New-StyledButton {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 100, [int]$Height = 32,
        [System.Drawing.Color]$BackColor = $ColorAccent,
        [System.Drawing.Color]$ForeColor = $ColorWhite
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $btn.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $btn.Font = $FontBody
    $btn.BackColor = $BackColor
    $btn.ForeColor = $ForeColor
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderColor = $ColorInputBorder
    $btn.FlatAppearance.BorderSize = 1
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Parent.Controls.Add($btn)
    return $btn
}

# ---------------------------------------------------------------------------
# Helper: create a styled checkbox
# ---------------------------------------------------------------------------
function New-StyledCheckBox {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 550, [int]$Height = 24,
        [bool]$Checked = $false
    )
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $Text
    $cb.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $cb.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $cb.Font = $FontBody
    $cb.ForeColor = $ColorWhite
    $cb.BackColor = [System.Drawing.Color]::Transparent
    $cb.Checked = $Checked
    $Parent.Controls.Add($cb)
    return $cb
}

# ---------------------------------------------------------------------------
# Helper: create a styled radio button
# ---------------------------------------------------------------------------
function New-StyledRadio {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X, [int]$Y,
        [int]$Width = 550, [int]$Height = 24,
        [bool]$Checked = $false
    )
    $rb = New-Object System.Windows.Forms.RadioButton
    $rb.Text = $Text
    $rb.Location = New-Object System.Drawing.Point((S $X), (S $Y))
    $rb.Size = New-Object System.Drawing.Size((S $Width), (S $Height))
    $rb.Font = $FontBody
    $rb.ForeColor = $ColorWhite
    $rb.BackColor = [System.Drawing.Color]::Transparent
    $rb.Checked = $Checked
    $Parent.Controls.Add($rb)
    return $rb
}

# ---------------------------------------------------------------------------
# Sidebar — step labels on the left
# ---------------------------------------------------------------------------
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Location = New-Object System.Drawing.Point(0, 0)
$sidebar.Size = New-Object System.Drawing.Size((S 190), (S 558))
$sidebar.BackColor = $ColorPanel

$sideTitle = New-StyledLabel -Parent $sidebar -Text "Setup Steps" -X 14 -Y 14 -Width 170 -Height 28 -Font $FontLabel -ForeColor $ColorHighlight

# Create max sidebar labels (8 slots) — rebuilt dynamically by Rebuild-Sidebar
$script:stepLabels = @()
for ($i = 0; $i -lt 8; $i++) {
    $sl = New-StyledLabel -Parent $sidebar -Text "" -X 8 -Y (50 + $i * 28) -Width 174 -Height 24 -Font $FontStep -ForeColor $ColorDimGray
    $sl.Visible = $false
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

# ---------------------------------------------------------------------------
# Content panel — holds each step's content (swapped on navigation)
# ---------------------------------------------------------------------------
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point((S 190), 0)
$contentPanel.Size = New-Object System.Drawing.Size((S 510), (S 470))
$contentPanel.BackColor = $ColorDarkBg
$form.Controls.Add($contentPanel)

# ---------------------------------------------------------------------------
# Bottom bar — navigation buttons
# ---------------------------------------------------------------------------
$bottomBar = New-Object System.Windows.Forms.Panel
$bottomBar.Location = New-Object System.Drawing.Point((S 190), (S 470))
$bottomBar.Size = New-Object System.Drawing.Size((S 510), (S 50))
$bottomBar.BackColor = $ColorPanel
$form.Controls.Add($bottomBar)

$btnBack = New-StyledButton -Parent $bottomBar -Text "Back" -X 210 -Y 9 -Width 80 -Height 32
$btnNext = New-StyledButton -Parent $bottomBar -Text "Next" -X 300 -Y 9 -Width 80 -Height 32 -BackColor $ColorHighlight
$btnCancel = New-StyledButton -Parent $bottomBar -Text "Cancel" -X 390 -Y 9 -Width 80 -Height 32

# ---------------------------------------------------------------------------
# Step panels — created once, shown/hidden as needed
# ---------------------------------------------------------------------------
$panels = @{}

# ========================== STEP 0: Welcome ================================
$p0 = New-Object System.Windows.Forms.Panel
$p0.Size = $contentPanel.Size
$p0.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p0 -Text "Dispatch Agent Setup" -X 20 -Y 14 -Width 450 -Height 36 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null
New-StyledLabel -Parent $p0 -Text "This wizard will configure this machine as a named agent`nin your Dispatch Orchestrator network." -X 20 -Y 54 -Width 450 -Height 44 -Font $FontSubtitle | Out-Null

# Architecture diagram image
$diagramPath = Join-Path $ProjectRoot "logo"
$diagramPath = Join-Path $diagramPath "agent-diagram-simple.png"
if (-not (Test-Path $diagramPath)) {
    $diagramPath = Join-Path $ProjectRoot "installer"
    $diagramPath = Join-Path $diagramPath "assets"
    $diagramPath = Join-Path $diagramPath "agent-diagram.png"
}
if (Test-Path $diagramPath) {
    # Pre-scale the diagram with high-quality bicubic to avoid PictureBox pixelation
    $diagramSrc = [System.Drawing.Image]::FromFile($diagramPath)
    $dw = S 400; $dh = S 180
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
    $diagramPic.Location = New-Object System.Drawing.Point((S 40), (S 104))
    $diagramPic.Size = New-Object System.Drawing.Size($dw, $dh)  # already scaled
    $diagramPic.SizeMode = "CenterImage"
    $diagramPic.BackColor = [System.Drawing.Color]::Transparent
    $diagramPic.Image = $diagramScaled
    $p0.Controls.Add($diagramPic)
}

New-StyledLabel -Parent $p0 -Text "Agents receive tasks from the orchestrator and run them using Claude Code." -X 20 -Y 296 -Width 460 -Height 22 -Font $FontBody -ForeColor $ColorLightGray | Out-Null

# Setup mode selection
$modePanel = New-Object System.Windows.Forms.Panel
$modePanel.Location = New-Object System.Drawing.Point((S 20), (S 330))
$modePanel.Size = New-Object System.Drawing.Size((S 460), (S 46))
$modePanel.BackColor = [System.Drawing.Color]::Transparent
$p0.Controls.Add($modePanel)

$script:radioBasicMode = New-StyledRadio -Parent $modePanel -Text "Basic Setup (recommended)" -X 0 -Y 0 -Width 220 -Checked $true
$script:radioAdvancedMode = New-StyledRadio -Parent $modePanel -Text "Advanced Setup" -X 230 -Y 0 -Width 200

$script:lblModeDesc = New-StyledLabel -Parent $modePanel -Text "Quick setup -- just agent name, shared secret, and connection." -X 0 -Y 22 -Width 440 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray

$script:radioBasicMode.Add_CheckedChanged({
    if ($script:radioBasicMode.Checked) {
        $script:SetupMode = "basic"
        $script:lblModeDesc.Text = "Quick setup -- just agent name, shared secret, and connection."
        Rebuild-Sidebar
    }
})
$script:radioAdvancedMode.Add_CheckedChanged({
    if ($script:radioAdvancedMode.Checked) {
        $script:SetupMode = "advanced"
        $script:lblModeDesc.Text = "Full control over directories, TLS, services, and all options."
        Rebuild-Sidebar
    }
})

New-StyledLabel -Parent $p0 -Text "Click Next to begin." -X 20 -Y 388 -Width 460 -Height 20 -Font $FontBody -ForeColor $ColorDimGray | Out-Null
New-StyledLabel -Parent $p0 -Text "Project root: $ProjectRoot" -X 20 -Y 430 -Width 460 -Height 20 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[0] = $p0

# ========================== STEP 1: Agent Identity =========================
$p1 = New-Object System.Windows.Forms.Panel
$p1.Size = $contentPanel.Size
$p1.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p1 -Text "Agent Identity" -X 20 -Y 20 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

New-StyledLabel -Parent $p1 -Text "Agent Name (required)" -X 20 -Y 70 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtAgentName = New-StyledTextBox -Parent $p1 -Text "agent-1" -X 20 -Y 94 -Width 280
New-StyledLabel -Parent $p1 -Text "e.g., CodeBot, ResearchBot" -X 310 -Y 96 -Width 150 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p1 -Text "Agent Description" -X 20 -Y 134 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtAgentDesc = New-StyledTextBox -Parent $p1 -Text "" -X 20 -Y 158 -Width 430
New-StyledLabel -Parent $p1 -Text "e.g., Handles coding and code review tasks" -X 20 -Y 186 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p1 -Text "Capabilities" -X 20 -Y 216 -Width 300 -Height 20 -Font $FontLabel | Out-Null
New-StyledLabel -Parent $p1 -Text "Select what this agent can do (used for task routing)" -X 20 -Y 236 -Width 440 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$script:chkCapCode     = New-StyledCheckBox -Parent $p1 -Text "Code (write, refactor, debug)" -X 20 -Y 256 -Width 210
$script:chkCapReview   = New-StyledCheckBox -Parent $p1 -Text "Review (code review, audit)" -X 240 -Y 256 -Width 210
$script:chkCapResearch = New-StyledCheckBox -Parent $p1 -Text "Research (web search, analysis)" -X 20 -Y 280 -Width 210
$script:chkCapBrowsing = New-StyledCheckBox -Parent $p1 -Text "Browsing (web navigation)" -X 240 -Y 280 -Width 210 -Checked $true
$script:chkCapData     = New-StyledCheckBox -Parent $p1 -Text "Data (files, spreadsheets, PDF)" -X 20 -Y 304 -Width 210
$script:chkCapCustom   = New-StyledCheckBox -Parent $p1 -Text "Custom:" -X 240 -Y 304 -Width 70
$script:txtCustomCaps  = New-StyledTextBox -Parent $p1 -Text "" -X 316 -Y 304 -Width 134
$script:txtCustomCaps.Enabled = $false
$script:chkCapCustom.Add_CheckedChanged({ $script:txtCustomCaps.Enabled = $script:chkCapCustom.Checked })

New-StyledLabel -Parent $p1 -Text "Machine ID" -X 20 -Y 340 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtMachineId = New-StyledTextBox -Parent $p1 -Text $script:Config.machineId -X 20 -Y 364 -Width 260
New-StyledLabel -Parent $p1 -Text "Auto-generated, editable" -X 290 -Y 366 -Width 170 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[1] = $p1

# ========================== STEP 2: Connection =============================
$p2 = New-Object System.Windows.Forms.Panel
$p2.Size = $contentPanel.Size
$p2.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p2 -Text "Connection" -X 20 -Y 20 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null
New-StyledLabel -Parent $p2 -Text "How should this agent find the orchestrator?" -X 20 -Y 58 -Width 440 -Height 22 -Font $FontSubtitle | Out-Null

$script:radioAuto = New-StyledRadio -Parent $p2 -Text "Auto-discover on local network (UDP broadcast)" -X 20 -Y 96 -Width 430 -Checked $true
$script:radioManual = New-StyledRadio -Parent $p2 -Text "Connect to specific address" -X 20 -Y 124 -Width 430

New-StyledLabel -Parent $p2 -Text "Orchestrator address:" -X 40 -Y 158 -Width 200 -Height 20 -Font $FontLabel | Out-Null
$script:txtCoordAddr = New-StyledTextBox -Parent $p2 -Text "ws://192.168.1.100:7070" -X 40 -Y 182 -Width 340
$script:txtCoordAddr.Enabled = $false

$script:radioAuto.Add_CheckedChanged({
    if ($script:radioAuto.Checked) {
        $script:txtCoordAddr.Enabled = $false
    }
})
$script:radioManual.Add_CheckedChanged({
    if ($script:radioManual.Checked) {
        $script:txtCoordAddr.Enabled = $true
    }
})

New-StyledLabel -Parent $p2 -Text "Shared Secret (required)" -X 20 -Y 224 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtSecret = New-StyledTextBox -Parent $p2 -Text "" -X 20 -Y 248 -Width 340
New-StyledLabel -Parent $p2 -Text "Get this from whoever set up the orchestrator" -X 20 -Y 276 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$script:btnTest = New-StyledButton -Parent $p2 -Text "Test Connection" -X 20 -Y 308 -Width 140 -Height 30 -BackColor $ColorAccent
$script:lblTestResult = New-StyledLabel -Parent $p2 -Text "" -X 20 -Y 344 -Width 440 -Height 40 -Font $FontBody -ForeColor $ColorLightGray

$script:btnTest.Add_Click({
    $script:lblTestResult.Text = ""
    $script:lblTestResult.ForeColor = $ColorLightGray
    $form.Refresh()

    # Require shared secret for both modes
    $secret = $script:txtSecret.Text.Trim()
    if ($secret -eq "") {
        $script:lblTestResult.Text = "Please enter the shared secret first.`nYou can find it in the orchestrator's dashboard settings."
        $script:lblTestResult.ForeColor = $ColorRed
        return
    }

    if ($script:radioAuto.Checked) {
        # Try UDP discovery for ~10 seconds, verifying HMAC signature
        $script:lblTestResult.Text = "Listening for orchestrator broadcast (10s)..."
        $form.Refresh()
        try {
            $escapedSecret = $secret -replace "'", "''"
            $udpResult = & powershell -NoProfile -Command @"
`$secret = '$escapedSecret'
`$socket = New-Object System.Net.Sockets.UdpClient(7071)
`$socket.Client.ReceiveTimeout = 10000
try {
    `$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    `$data = `$socket.Receive([ref]`$ep)
    `$msg = [System.Text.Encoding]::UTF8.GetString(`$data)
    `$envelope = `$msg | ConvertFrom-Json
    if (`$envelope.payload -and `$envelope.ts -and `$envelope.hmac) {
        `$hmac = New-Object System.Security.Cryptography.HMACSHA256
        `$hmac.Key = [System.Text.Encoding]::UTF8.GetBytes(`$secret)
        `$computed = [BitConverter]::ToString(`$hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(`$envelope.ts + `$envelope.payload))).Replace('-','').ToLower()
        if (`$computed -eq `$envelope.hmac) {
            `$payload = `$envelope.payload | ConvertFrom-Json
            Write-Output "OK:`$(`$payload.host):`$(`$payload.port)"
        } else {
            Write-Output "FAIL:Wrong shared secret (HMAC mismatch)"
        }
    } else {
        Write-Output "FAIL:Unsigned broadcast (old relay version?)"
    }
} catch {
    Write-Output "FAIL:No broadcast received within 10 seconds"
} finally {
    `$socket.Close()
}
"@
            $udpStr = if ($udpResult -is [array]) { $udpResult -join "`n" } else { "$udpResult" }
            $udpStr = $udpStr.Trim()
            if ($udpStr -like "OK:*") {
                $relay = $udpStr -replace "^OK:", ""
                $script:lblTestResult.Text = "Relay found at $relay"
                $script:lblTestResult.ForeColor = $ColorGreen
            } elseif ($udpStr -match "HMAC mismatch") {
                $script:lblTestResult.Text = "Wrong shared secret. Check it matches the orchestrator."
                $script:lblTestResult.ForeColor = $ColorRed
            } elseif ($udpStr -match "No broadcast") {
                $script:lblTestResult.Text = "No orchestrator found on your network.`nMake sure the relay is running and discovery is enabled."
                $script:lblTestResult.ForeColor = $ColorRed
            } elseif ($udpStr -match "Unsigned") {
                $script:lblTestResult.Text = "Found a relay, but it's unsigned (older version?)."
                $script:lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(241, 196, 15)
            } else {
                $script:lblTestResult.Text = "Failed: $udpStr"
                $script:lblTestResult.ForeColor = $ColorRed
            }
        } catch {
            $script:lblTestResult.Text = "Failed: $_"
            $script:lblTestResult.ForeColor = $ColorRed
        }
    } else {
        # Manual — try HTTP GET to /status
        $addr = $script:txtCoordAddr.Text -replace "^ws://", "http://" -replace "^wss://", "https://"
        $secret = $script:txtSecret.Text
        try {
            $headers = @{ "Authorization" = "Bearer $secret" }
            $response = Invoke-WebRequest -Uri "$addr/status" -Headers $headers -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            $script:lblTestResult.Text = "Connected to orchestrator successfully!"
            $script:lblTestResult.ForeColor = $ColorGreen
        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match "401") {
                $script:lblTestResult.Text = "Wrong shared secret. Check it matches the orchestrator."
            } elseif ($errMsg -match "Unable to connect|No connection") {
                $script:lblTestResult.Text = "Cannot reach orchestrator at $addr.`nCheck the address and make sure the relay is running."
            } else {
                if ($errMsg -and $errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) + "..." }
                $script:lblTestResult.Text = "Failed: $errMsg"
            }
            $script:lblTestResult.ForeColor = $ColorRed
        }
    }
})

$panels[2] = $p2

# ========================== STEP 3: Working Directories ====================
$p3 = New-Object System.Windows.Forms.Panel
$p3.Size = $contentPanel.Size
$p3.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p3 -Text "Working Directories" -X 20 -Y 20 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

New-StyledLabel -Parent $p3 -Text "Default Working Directory" -X 20 -Y 64 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtWorkDir = New-StyledTextBox -Parent $p3 -Text "C:\workspace" -X 20 -Y 88 -Width 330
$script:btnBrowseWork = New-StyledButton -Parent $p3 -Text "Browse..." -X 360 -Y 86 -Width 90 -Height 28

$script:btnBrowseWork.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Select default working directory"
    $fbd.SelectedPath = $script:txtWorkDir.Text
    if ($fbd.ShowDialog() -eq "OK") {
        $script:txtWorkDir.Text = $fbd.SelectedPath
        # Also add to allowed dirs if not already there
        if (-not $script:txtAllowed.Text.Contains($fbd.SelectedPath)) {
            if ($script:txtAllowed.Text.Trim().Length -gt 0) {
                $script:txtAllowed.Text += "`r`n$($fbd.SelectedPath)"
            } else {
                $script:txtAllowed.Text = $fbd.SelectedPath
            }
        }
    }
})

New-StyledLabel -Parent $p3 -Text "Allowed Directories (one per line)" -X 20 -Y 128 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtAllowed = New-Object System.Windows.Forms.TextBox
$script:txtAllowed.Multiline = $true
$script:txtAllowed.ScrollBars = "Vertical"
$script:txtAllowed.Location = New-Object System.Drawing.Point((S 20), (S 150))
$script:txtAllowed.Size = New-Object System.Drawing.Size((S 330), (S 60))
$script:txtAllowed.Font = $FontMonoSmall
$script:txtAllowed.BackColor = $ColorInputBg
$script:txtAllowed.ForeColor = $ColorWhite
$script:txtAllowed.BorderStyle = "FixedSingle"
$script:txtAllowed.Text = "C:\workspace"
$p3.Controls.Add($script:txtAllowed)

$script:btnAddAllowed = New-StyledButton -Parent $p3 -Text "Add Folder..." -X 360 -Y 152 -Width 90 -Height 28

$script:btnAddAllowed.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Add an allowed directory"
    if ($fbd.ShowDialog() -eq "OK") {
        if ($script:txtAllowed.Text.Trim().Length -gt 0) {
            $script:txtAllowed.Text += "`r`n$($fbd.SelectedPath)"
        } else {
            $script:txtAllowed.Text = $fbd.SelectedPath
        }
    }
})

New-StyledLabel -Parent $p3 -Text "Denied Directories (one per line)" -X 20 -Y 222 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtDenied = New-Object System.Windows.Forms.TextBox
$script:txtDenied.Multiline = $true
$script:txtDenied.ScrollBars = "Vertical"
$script:txtDenied.Location = New-Object System.Drawing.Point((S 20), (S 244))
$script:txtDenied.Size = New-Object System.Drawing.Size((S 430), (S 80))
$script:txtDenied.Font = $FontMonoSmall
$script:txtDenied.BackColor = $ColorInputBg
$script:txtDenied.ForeColor = $ColorWhite
$script:txtDenied.BorderStyle = "FixedSingle"
$script:txtDenied.Text = "C:\Windows`r`nC:\Program Files`r`nC:\Program Files (x86)`r`nC:\Users\*\AppData"
$p3.Controls.Add($script:txtDenied)

New-StyledLabel -Parent $p3 -Text "The agent will only execute tasks in allowed directories.`nSystem directories are blocked for safety." -X 20 -Y 336 -Width 430 -Height 36 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[3] = $p3

# ========================== STEP 4: Options ================================
$p4 = New-Object System.Windows.Forms.Panel
$p4.Size = $contentPanel.Size
$p4.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p4 -Text "Options" -X 20 -Y 20 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

$script:chkKeepAwake = New-StyledCheckBox -Parent $p4 -Text "Keep machine awake while agent is running" -X 20 -Y 72 -Width 430 -Checked $true
$script:chkTls = New-StyledCheckBox -Parent $p4 -Text "Enable TLS encryption" -X 20 -Y 102 -Width 430 -Checked $false
New-StyledLabel -Parent $p4 -Text "Enable only if the orchestrator has TLS configured" -X 48 -Y 128 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

# Detect NSSM
$nssmAvailable = $null -ne (Get-Command nssm.exe -ErrorAction SilentlyContinue)
$script:chkService = New-StyledCheckBox -Parent $p4 -Text "Install as Windows service" -X 20 -Y 158 -Width 430 -Checked $false
if (-not $nssmAvailable) {
    $script:chkService.Enabled = $false
    New-StyledLabel -Parent $p4 -Text "NSSM not detected. Install NSSM to enable service mode." -X 48 -Y 184 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null
} else {
    New-StyledLabel -Parent $p4 -Text "NSSM detected. Agent will start automatically with Windows." -X 48 -Y 184 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorGreen | Out-Null
}

$script:chkStartAfter = New-StyledCheckBox -Parent $p4 -Text "Start agent after setup completes" -X 20 -Y 214 -Width 430 -Checked $true

New-StyledLabel -Parent $p4 -Text "Allowed Tools" -X 20 -Y 254 -Width 200 -Height 20 -Font $FontLabel | Out-Null
New-StyledLabel -Parent $p4 -Text "Which Claude tools this agent may use" -X 20 -Y 274 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$script:chkToolBrowser  = New-StyledCheckBox -Parent $p4 -Text "Browser (WebFetch, WebSearch)" -X 20 -Y 294 -Width 220 -Checked $true
$script:chkToolCode     = New-StyledCheckBox -Parent $p4 -Text "Code (Read, Edit, Write)" -X 250 -Y 294 -Width 200 -Checked $true
$script:chkToolBash     = New-StyledCheckBox -Parent $p4 -Text "Shell (Bash commands)" -X 20 -Y 318 -Width 220 -Checked $true
$script:chkToolCustom   = New-StyledCheckBox -Parent $p4 -Text "Custom:" -X 250 -Y 318 -Width 70
$script:txtCustomTools  = New-StyledTextBox -Parent $p4 -Text "" -X 326 -Y 318 -Width 130
$script:txtCustomTools.Enabled = $false
$script:chkToolCustom.Add_CheckedChanged({ $script:txtCustomTools.Enabled = $script:chkToolCustom.Checked })

New-StyledLabel -Parent $p4 -Text "Max Output Size" -X 20 -Y 358 -Width 200 -Height 20 -Font $FontLabel | Out-Null
$script:cmbMaxOutput = New-Object System.Windows.Forms.ComboBox
$script:cmbMaxOutput.DropDownStyle = "DropDownList"
$script:cmbMaxOutput.Location = New-Object System.Drawing.Point((S 20), (S 380))
$script:cmbMaxOutput.Size = New-Object System.Drawing.Size((S 180), (S 28))
$script:cmbMaxOutput.Font = $FontBody
$script:cmbMaxOutput.BackColor = $ColorInputBg
$script:cmbMaxOutput.ForeColor = $ColorWhite
$script:cmbMaxOutput.FlatStyle = "Flat"
$script:cmbMaxOutput.Items.AddRange(@("100 KB", "500 KB", "1 MB", "5 MB", "10 MB"))
$script:cmbMaxOutput.SelectedIndex = 2  # 1 MB default
$p4.Controls.Add($script:cmbMaxOutput)
New-StyledLabel -Parent $p4 -Text "Max task output returned to the orchestrator" -X 210 -Y 382 -Width 240 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[4] = $p4

# ========================== STEP 5: Review =================================
$p5 = New-Object System.Windows.Forms.Panel
$p5.Size = $contentPanel.Size
$p5.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p5 -Text "Review Configuration" -X 20 -Y 20 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null
New-StyledLabel -Parent $p5 -Text "Review your settings below. Click Install to proceed." -X 20 -Y 56 -Width 440 -Height 22 -Font $FontSubtitle | Out-Null

$script:txtReview = New-Object System.Windows.Forms.TextBox
$script:txtReview.Multiline = $true
$script:txtReview.ReadOnly = $true
$script:txtReview.ScrollBars = "Both"
$script:txtReview.WordWrap = $false
$script:txtReview.Location = New-Object System.Drawing.Point((S 20), (S 86))
$script:txtReview.Size = New-Object System.Drawing.Size((S 440), (S 300))
$script:txtReview.Font = $FontMono
$script:txtReview.BackColor = $ColorPanel
$script:txtReview.ForeColor = $ColorLightGray
$script:txtReview.BorderStyle = "FixedSingle"
$p5.Controls.Add($script:txtReview)

$panels[5] = $p5

# ========================== STEP 6: Installing =============================
$p6 = New-Object System.Windows.Forms.Panel
$p6.Size = $contentPanel.Size
$p6.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p6 -Text "Installing..." -X 20 -Y 20 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point((S 20), (S 66))
$script:progressBar.Size = New-Object System.Drawing.Size((S 440), (S 24))
$script:progressBar.Style = "Continuous"
$script:progressBar.Minimum = 0
$script:progressBar.Maximum = 100
$p6.Controls.Add($script:progressBar)

$script:txtInstallLog = New-Object System.Windows.Forms.TextBox
$script:txtInstallLog.Multiline = $true
$script:txtInstallLog.ReadOnly = $true
$script:txtInstallLog.ScrollBars = "Vertical"
$script:txtInstallLog.Location = New-Object System.Drawing.Point((S 20), (S 100))
$script:txtInstallLog.Size = New-Object System.Drawing.Size((S 440), (S 290))
$script:txtInstallLog.Font = $FontMonoSmall
$script:txtInstallLog.BackColor = $ColorPanel
$script:txtInstallLog.ForeColor = $ColorLightGray
$script:txtInstallLog.BorderStyle = "FixedSingle"
$p6.Controls.Add($script:txtInstallLog)

$panels[6] = $p6

# ========================== STEP 7: Complete ===============================
$p7 = New-Object System.Windows.Forms.Panel
$p7.Size = $contentPanel.Size
$p7.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p7 -Text "Setup Complete" -X 20 -Y 30 -Width 450 -Height 36 -Font $FontTitle -ForeColor $ColorGreen | Out-Null
$script:lblCompleteStatus = New-StyledLabel -Parent $p7 -Text "" -X 20 -Y 80 -Width 450 -Height 60 -Font $FontSubtitle
$script:lblCompleteAgent = New-StyledLabel -Parent $p7 -Text "" -X 20 -Y 150 -Width 450 -Height 30 -Font $FontBody -ForeColor $ColorLightGray
$script:lblCompleteHint = New-StyledLabel -Parent $p7 -Text "" -X 20 -Y 200 -Width 450 -Height 80 -Font $FontBody -ForeColor $ColorDimGray

$script:chkStartAgent = New-StyledCheckBox -Parent $p7 -Text "Start the agent now" -X 20 -Y 300 -Width 300 -Checked $true

$panels[7] = $p7

# ========================== STEP 10: Basic Config (basic mode) ==============
$p10 = New-Object System.Windows.Forms.Panel
$p10.Size = $contentPanel.Size
$p10.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p10 -Text "Agent Configuration" -X 20 -Y 14 -Width 450 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

New-StyledLabel -Parent $p10 -Text "Agent Name (required)" -X 20 -Y 58 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtBasicAgentName = New-StyledTextBox -Parent $p10 -Text "agent-1" -X 20 -Y 80 -Width 280
New-StyledLabel -Parent $p10 -Text "e.g., agent-1, CodeBot, ResearchBot" -X 310 -Y 82 -Width 150 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p10 -Text "Shared Secret (required)" -X 20 -Y 118 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtBasicSecret = New-StyledTextBox -Parent $p10 -Text "" -X 20 -Y 140 -Width 340
New-StyledLabel -Parent $p10 -Text "Get this from whoever set up the orchestrator" -X 20 -Y 168 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p10 -Text "Connection" -X 20 -Y 200 -Width 300 -Height 20 -Font $FontLabel | Out-Null

# Group container to isolate radios from welcome page radios
$basicConnGroup = New-Object System.Windows.Forms.Panel
$basicConnGroup.Location = New-Object System.Drawing.Point((S 20), (S 218))
$basicConnGroup.Size = New-Object System.Drawing.Size((S 440), (S 80))
$basicConnGroup.BackColor = [System.Drawing.Color]::Transparent
$p10.Controls.Add($basicConnGroup)

$script:radioBasicAuto = New-StyledRadio -Parent $basicConnGroup -Text "Auto-discover on local network (recommended)" -X 0 -Y 0 -Width 430 -Checked $true
$script:radioBasicManual = New-StyledRadio -Parent $basicConnGroup -Text "Connect to specific address" -X 0 -Y 26 -Width 430

$script:txtBasicCoordAddr = New-StyledTextBox -Parent $basicConnGroup -Text "ws://192.168.1.100:7070" -X 24 -Y 52 -Width 340
$script:txtBasicCoordAddr.Enabled = $false

$script:radioBasicAuto.Add_CheckedChanged({
    if ($script:radioBasicAuto.Checked) {
        $script:txtBasicCoordAddr.Enabled = $false
    }
})
$script:radioBasicManual.Add_CheckedChanged({
    if ($script:radioBasicManual.Checked) {
        $script:txtBasicCoordAddr.Enabled = $true
    }
})

$script:btnBasicTest = New-StyledButton -Parent $p10 -Text "Test Connection" -X 20 -Y 310 -Width 140 -Height 30 -BackColor $ColorAccent
$script:lblBasicTestResult = New-StyledLabel -Parent $p10 -Text "" -X 20 -Y 346 -Width 440 -Height 40 -Font $FontBody -ForeColor $ColorLightGray

$script:btnBasicTest.Add_Click({
    $script:lblBasicTestResult.Text = ""
    $script:lblBasicTestResult.ForeColor = $ColorLightGray
    $form.Refresh()

    $secret = $script:txtBasicSecret.Text.Trim()
    if ($secret -eq "") {
        $script:lblBasicTestResult.Text = "Please enter the shared secret first."
        $script:lblBasicTestResult.ForeColor = $ColorRed
        return
    }

    if ($script:radioBasicAuto.Checked) {
        $script:lblBasicTestResult.Text = "Listening for orchestrator broadcast (10s)..."
        $form.Refresh()
        try {
            $escapedSecret = $secret -replace "'", "''"
            $udpResult = & powershell -NoProfile -Command @"
`$secret = '$escapedSecret'
`$socket = New-Object System.Net.Sockets.UdpClient(7071)
`$socket.Client.ReceiveTimeout = 10000
try {
    `$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    `$data = `$socket.Receive([ref]`$ep)
    `$msg = [System.Text.Encoding]::UTF8.GetString(`$data)
    `$envelope = `$msg | ConvertFrom-Json
    if (`$envelope.payload -and `$envelope.ts -and `$envelope.hmac) {
        `$hmac = New-Object System.Security.Cryptography.HMACSHA256
        `$hmac.Key = [System.Text.Encoding]::UTF8.GetBytes(`$secret)
        `$computed = [BitConverter]::ToString(`$hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(`$envelope.ts + `$envelope.payload))).Replace('-','').ToLower()
        if (`$computed -eq `$envelope.hmac) {
            `$payload = `$envelope.payload | ConvertFrom-Json
            Write-Output "OK:`$(`$payload.host):`$(`$payload.port)"
        } else {
            Write-Output "FAIL:Wrong shared secret (HMAC mismatch)"
        }
    } else {
        Write-Output "FAIL:Unsigned broadcast (old relay version?)"
    }
} catch {
    Write-Output "FAIL:No broadcast received within 10 seconds"
} finally {
    `$socket.Close()
}
"@
            $udpStr = if ($udpResult -is [array]) { $udpResult -join "`n" } else { "$udpResult" }
            $udpStr = $udpStr.Trim()
            if ($udpStr -like "OK:*") {
                $relay = $udpStr -replace "^OK:", ""
                $script:lblBasicTestResult.Text = "Relay found at $relay"
                $script:lblBasicTestResult.ForeColor = $ColorGreen
            } elseif ($udpStr -match "HMAC mismatch") {
                $script:lblBasicTestResult.Text = "Wrong shared secret. Check it matches the orchestrator."
                $script:lblBasicTestResult.ForeColor = $ColorRed
            } elseif ($udpStr -match "No broadcast") {
                $script:lblBasicTestResult.Text = "No orchestrator found on your network.`nMake sure the relay is running and discovery is enabled."
                $script:lblBasicTestResult.ForeColor = $ColorRed
            } elseif ($udpStr -match "Unsigned") {
                $script:lblBasicTestResult.Text = "Found a relay, but it's unsigned (older version?)."
                $script:lblBasicTestResult.ForeColor = [System.Drawing.Color]::FromArgb(241, 196, 15)
            } else {
                $script:lblBasicTestResult.Text = "Failed: $udpStr"
                $script:lblBasicTestResult.ForeColor = $ColorRed
            }
        } catch {
            $script:lblBasicTestResult.Text = "Failed: $_"
            $script:lblBasicTestResult.ForeColor = $ColorRed
        }
    } else {
        $addr = $script:txtBasicCoordAddr.Text -replace "^ws://", "http://" -replace "^wss://", "https://"
        try {
            $headers = @{ "Authorization" = "Bearer $secret" }
            $response = Invoke-WebRequest -Uri "$addr/status" -Headers $headers -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            $script:lblBasicTestResult.Text = "Connected to orchestrator successfully!"
            $script:lblBasicTestResult.ForeColor = $ColorGreen
        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -match "401") {
                $script:lblBasicTestResult.Text = "Wrong shared secret. Check it matches the orchestrator."
            } elseif ($errMsg -match "Unable to connect|No connection") {
                $script:lblBasicTestResult.Text = "Cannot reach orchestrator at $addr.`nCheck the address and make sure the relay is running."
            } else {
                if ($errMsg -and $errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) + "..." }
                $script:lblBasicTestResult.Text = "Failed: $errMsg"
            }
            $script:lblBasicTestResult.ForeColor = $ColorRed
        }
    }
})

$panels[10] = $p10

# ---------------------------------------------------------------------------
# Helper: get current step flow based on mode
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: collect config values from the UI fields
# ---------------------------------------------------------------------------
function Collect-Config {
    if ($script:SetupMode -eq "basic") {
        # Basic mode: read from basic config panel, use defaults for the rest
        $script:Config.agentName = $script:txtBasicAgentName.Text.Trim()
        $script:Config.agentDescription = ""
        $script:Config.agentCapabilities = @("browsing", "web")
        # machineId stays as auto-generated default
        $script:Config.connectionMode = if ($script:radioBasicAuto.Checked) { "auto" } else { "manual" }
        $script:Config.coordinatorHost = $script:txtBasicCoordAddr.Text.Trim()
        $script:Config.sharedSecret = $script:txtBasicSecret.Text.Trim()
        $script:Config.defaultWorkingDir = "C:\workspace"
        $script:Config.allowedDirs = @("C:\workspace")
        $script:Config.denyDirs = @("C:\Windows", "C:\Program Files", "C:\Program Files (x86)", "C:\Users\*\AppData")
        $script:Config.keepAwake = $true
        $script:Config.enableTls = $false
        $script:Config.installService = $false
        $script:Config.startAfterSetup = $true
        $script:Config.maxOutputLength = 1000000
        $script:Config.allowedTools = @("Read", "Edit", "Write", "Bash", "Glob", "Grep", "WebFetch", "WebSearch")
        $script:Config.disallowedTools = @()
    } else {
        # Advanced mode: read from all panels
        $script:Config.agentName = $script:txtAgentName.Text.Trim()
        $script:Config.agentDescription = $script:txtAgentDesc.Text.Trim()
        $caps = @()
        if ($script:chkCapCode.Checked)     { $caps += "code"; $caps += "refactor"; $caps += "debug" }
        if ($script:chkCapReview.Checked)   { $caps += "review"; $caps += "audit" }
        if ($script:chkCapResearch.Checked) { $caps += "research"; $caps += "analysis" }
        if ($script:chkCapBrowsing.Checked) { $caps += "browsing"; $caps += "web" }
        if ($script:chkCapData.Checked)     { $caps += "data"; $caps += "files"; $caps += "pdf" }
        if ($script:chkCapCustom.Checked -and $script:txtCustomCaps.Text.Trim() -ne "") {
            $caps += @(($script:txtCustomCaps.Text -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        }
        $script:Config.agentCapabilities = $caps
        $script:Config.machineId = $script:txtMachineId.Text.Trim()
        $script:Config.connectionMode = if ($script:radioAuto.Checked) { "auto" } else { "manual" }
        $script:Config.coordinatorHost = $script:txtCoordAddr.Text.Trim()
        $script:Config.sharedSecret = $script:txtSecret.Text.Trim()
        $script:Config.defaultWorkingDir = $script:txtWorkDir.Text.Trim()
        $script:Config.allowedDirs = @(($script:txtAllowed.Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        $script:Config.denyDirs = @(($script:txtDenied.Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        $script:Config.keepAwake = $script:chkKeepAwake.Checked
        $script:Config.enableTls = $script:chkTls.Checked
        $script:Config.installService = $script:chkService.Checked
        $script:Config.startAfterSetup = $script:chkStartAfter.Checked

        $outputMap = @{
            "100 KB"  = 100000
            "500 KB"  = 500000
            "1 MB"    = 1000000
            "5 MB"    = 5000000
            "10 MB"   = 10000000
        }
        $selected = $script:cmbMaxOutput.SelectedItem
        if ($outputMap.ContainsKey($selected)) {
            $script:Config.maxOutputLength = $outputMap[$selected]
        } else {
            $script:Config.maxOutputLength = 1000000
        }

        # Collect allowed tools from checkboxes
        $tools = @()
        if ($script:chkToolCode.Checked)    { $tools += "Read"; $tools += "Edit"; $tools += "Write"; $tools += "Glob"; $tools += "Grep" }
        if ($script:chkToolBash.Checked)    { $tools += "Bash" }
        if ($script:chkToolBrowser.Checked) { $tools += "WebFetch"; $tools += "WebSearch" }
        if ($script:chkToolCustom.Checked -and $script:txtCustomTools.Text.Trim() -ne "") {
            $tools += @(($script:txtCustomTools.Text -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
        }
        $script:Config.allowedTools = $tools
        $script:Config.disallowedTools = @()
    }
}

# ---------------------------------------------------------------------------
# Helper: build the worker-config.json object
# ---------------------------------------------------------------------------
function Build-ConfigJson {
    Collect-Config
    $c = $script:Config

    $coordHost = if ($c.connectionMode -eq "auto") { "auto" } else { $c.coordinatorHost }

    $configObj = [ordered]@{
        machineId          = $c.machineId
        agentName          = $c.agentName
        agentDescription   = $c.agentDescription
        agentCapabilities  = $c.agentCapabilities
        coordinatorHost    = $coordHost
        sharedSecret       = $c.sharedSecret
        defaultWorkingDir  = $c.defaultWorkingDir
        allowedDirs        = $c.allowedDirs
        denyDirs           = $c.denyDirs
        tls                = [ordered]@{
            enabled  = $c.enableTls
            certFile = "../certs/client.crt"
            keyFile  = "../certs/client.key"
            caFile   = "../certs/ca.crt"
        }
        discovery          = [ordered]@{
            enabled       = ($c.connectionMode -eq "auto")
            broadcastPort = 7071
            timeoutMs     = 15000
        }
        allowedTools       = $c.allowedTools
        disallowedTools    = $c.disallowedTools
        maxOutputLength    = $c.maxOutputLength
        keepAwake          = [ordered]@{
            enabled = $c.keepAwake
        }
    }

    return ($configObj | ConvertTo-Json -Depth 4)
}

# ---------------------------------------------------------------------------
# Helper: append to install log
# ---------------------------------------------------------------------------
function Write-InstallLog {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $script:txtInstallLog.AppendText("[$timestamp] $Message`r`n")
    $form.Refresh()
}

# ---------------------------------------------------------------------------
# Update sidebar to highlight the current step
# ---------------------------------------------------------------------------
function Update-Sidebar {
    $flowIdx = Get-FlowIndex $script:CurrentStep
    $flow = Get-StepFlow
    for ($i = 0; $i -lt $script:stepLabels.Count; $i++) {
        if (-not $script:stepLabels[$i].Visible) { continue }
        if ($i -eq $flowIdx) {
            $script:stepLabels[$i].Font = $FontStepActive
            $script:stepLabels[$i].ForeColor = $ColorHighlight
            $script:stepLabels[$i].BackColor = $ColorAccent
        } elseif ($i -lt $flowIdx) {
            $script:stepLabels[$i].Font = $FontStep
            $script:stepLabels[$i].ForeColor = $ColorGreen
            $script:stepLabels[$i].BackColor = [System.Drawing.Color]::Transparent
        } else {
            $script:stepLabels[$i].Font = $FontStep
            $script:stepLabels[$i].ForeColor = $ColorDimGray
            $script:stepLabels[$i].BackColor = [System.Drawing.Color]::Transparent
        }
    }
}

# ---------------------------------------------------------------------------
# Show a specific step panel
# ---------------------------------------------------------------------------
function Show-Step {
    param([int]$StepIndex)

    $contentPanel.Controls.Clear()
    if ($panels.ContainsKey($StepIndex)) {
        $contentPanel.Controls.Add($panels[$StepIndex])
    }

    $script:CurrentStep = $StepIndex
    Update-Sidebar

    $flow = Get-StepFlow
    $flowIdx = Get-FlowIndex $StepIndex
    $isInstalling = ($StepIndex -eq 6)
    $isComplete = ($StepIndex -eq 7)
    $isReview = ($StepIndex -eq 5)

    # Navigation button visibility
    $btnBack.Visible = ($flowIdx -gt 0) -and (-not $isInstalling) -and (-not $isComplete)
    $btnCancel.Visible = (-not $isInstalling) -and (-not $isComplete)

    if ($isReview) {
        $btnNext.Text = "Install"
        $btnNext.Visible = $true
    } elseif ($isInstalling) {
        $btnNext.Visible = $false
        $btnBack.Visible = $false
        $btnCancel.Visible = $false
    } elseif ($isComplete) {
        $btnNext.Text = "Finish"
        $btnNext.Visible = $true
        $btnBack.Visible = $false
        $btnCancel.Visible = $false
    } else {
        $btnNext.Text = "Next"
        $btnNext.Visible = $true
    }

    # Populate review panel when entering step 5
    if ($StepIndex -eq 5) {
        $json = Build-ConfigJson
        $c = $script:Config
        $summary = @"
--- Agent Configuration Summary ---

  Agent Name:        $($c.agentName)
  Description:       $($c.agentDescription)
  Capabilities:      $($c.agentCapabilities -join ", ")
  Machine ID:        $($c.machineId)
  Connection:        $(if ($c.connectionMode -eq "auto") { "Auto-discover (UDP)" } else { $c.coordinatorHost })
  Working Dir:       $($c.defaultWorkingDir)
  Keep Awake:        $($c.keepAwake)
  TLS:               $($c.enableTls)
  Install Service:   $($c.installService)
  Start After Setup: $($c.startAfterSetup)
  Max Output:        $($c.maxOutputLength) bytes

--- worker-config.json ---

$json
"@
        $script:txtReview.Text = $summary
    }
}

# ---------------------------------------------------------------------------
# Check if agent name is already registered with the relay
# ---------------------------------------------------------------------------
function Test-AgentNameExists {
    param([string]$Name, [string]$Secret, [string]$RelayAddr)
    if (-not $Secret -or -not $RelayAddr) { return $false }
    try {
        $addr = $RelayAddr -replace "^ws://", "http://" -replace "^wss://", "https://"
        $headers = @{ "Authorization" = "Bearer $Secret" }
        $response = Invoke-WebRequest -Uri "$addr/status" -Headers $headers -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $agents = $response.Content | ConvertFrom-Json
        foreach ($a in $agents) {
            if ($a.agentName -and $a.agentName.ToLower() -eq $Name.ToLower()) {
                return $true
            }
        }
    } catch {
        # Can't reach relay — skip duplicate check
    }
    return $false
}

# ---------------------------------------------------------------------------
# Validation per step
# ---------------------------------------------------------------------------
function Validate-Step {
    param([int]$StepIndex)

    if ($StepIndex -eq 10) {
        # Basic config validation
        if ($script:txtBasicAgentName.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Agent name is required.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:txtBasicSecret.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Shared secret is required. Get this from whoever set up the orchestrator.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:radioBasicManual.Checked -and $script:txtBasicCoordAddr.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Orchestrator address is required for manual connection.", "Validation", "OK", "Warning")
            return $false
        }
        # Check for duplicate agent name
        $relayAddr = if ($script:radioBasicManual.Checked) { $script:txtBasicCoordAddr.Text.Trim() } else { "ws://localhost:7070" }
        if (Test-AgentNameExists -Name $script:txtBasicAgentName.Text.Trim() -Secret $script:txtBasicSecret.Text.Trim() -RelayAddr $relayAddr) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "An agent named '$($script:txtBasicAgentName.Text.Trim())' is already connected to the orchestrator.`n`nUse a different name?",
                "Duplicate Agent Name", "YesNo", "Warning")
            if ($result -eq "Yes") { return $false }
        }
    }
    elseif ($StepIndex -eq 1) {
        if ($script:txtAgentName.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Agent name is required.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:txtMachineId.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Machine ID is required.", "Validation", "OK", "Warning")
            return $false
        }
    }
    elseif ($StepIndex -eq 2) {
        if ($script:txtSecret.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Shared secret is required. Get this from whoever set up the orchestrator.", "Validation", "OK", "Warning")
            return $false
        }
        if ($script:radioManual.Checked -and $script:txtCoordAddr.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Orchestrator address is required for manual connection.", "Validation", "OK", "Warning")
            return $false
        }
        # Check for duplicate agent name
        $relayAddr = if ($script:radioManual.Checked) { $script:txtCoordAddr.Text.Trim() } else { "ws://localhost:7070" }
        if (Test-AgentNameExists -Name $script:txtAgentName.Text.Trim() -Secret $script:txtSecret.Text.Trim() -RelayAddr $relayAddr) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "An agent named '$($script:txtAgentName.Text.Trim())' is already connected to the orchestrator.`n`nUse a different name?",
                "Duplicate Agent Name", "YesNo", "Warning")
            if ($result -eq "Yes") { return $false }
        }
    }
    elseif ($StepIndex -eq 3) {
        if ($script:txtWorkDir.Text.Trim() -eq "") {
            [void][System.Windows.Forms.MessageBox]::Show("Default working directory is required.", "Validation", "OK", "Warning")
            return $false
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Install procedure (runs on step 5 -> 6 transition)
# ---------------------------------------------------------------------------
function Run-Install {
    $script:progressBar.Value = 0
    $script:txtInstallLog.Text = ""

    Collect-Config

    # Step 1: Check Node.js
    Write-InstallLog "Checking Node.js..."
    $script:progressBar.Value = 10
    $nodeExe = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($nodeExe) {
        $nodeVer = & node --version 2>&1
        Write-InstallLog "  Node.js found: $nodeVer"
    } else {
        Write-InstallLog "  WARNING: Node.js not found on PATH!"
        Write-InstallLog "  Install Node.js 18+ from https://nodejs.org/"
    }

    # Step 2: Check Claude CLI
    $script:progressBar.Value = 20
    Write-InstallLog "Checking Claude Code CLI..."
    try {
        $claudeVer = & claude --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-InstallLog "  Claude CLI found: $claudeVer"
        } else {
            Write-InstallLog "  WARNING: Claude CLI not found or returned an error."
            Write-InstallLog "  Install with: npm install -g @anthropic-ai/claude-code"
        }
    } catch {
        Write-InstallLog "  WARNING: Claude CLI not found."
        Write-InstallLog "  Install with: npm install -g @anthropic-ai/claude-code"
    }

    # Step 3: Install dependencies
    $script:progressBar.Value = 30
    Write-InstallLog "Installing dependencies (npm install --production)..."
    try {
        $npmResult = & cmd /C "cd /d `"$ProjectRoot`" && npm install --production 2>&1"
        if ($LASTEXITCODE -eq 0) {
            Write-InstallLog "  Dependencies installed successfully."
        } else {
            Write-InstallLog "  WARNING: npm install returned exit code $LASTEXITCODE"
            Write-InstallLog "  $npmResult"
        }
    } catch {
        Write-InstallLog "  ERROR: npm install failed: $_"
    }
    $script:progressBar.Value = 50

    # Step 4: Write worker-config.json
    Write-InstallLog "Writing worker-config.json..."
    $json = Build-ConfigJson
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    try {
        [System.IO.File]::WriteAllText($ConfigFile, $json, $utf8NoBom)
        Write-InstallLog "  Config written to: $ConfigFile"
    } catch {
        # Program Files requires elevation — try elevated copy
        Write-InstallLog "  Direct write failed, requesting elevation..."
        try {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tmpFile, $json, $utf8NoBom)
            $copyCmd = "Copy-Item -Path '$tmpFile' -Destination '$ConfigFile' -Force; Remove-Item '$tmpFile' -Force"
            Start-Process powershell -ArgumentList "-NoProfile -Command `"$copyCmd`"" -Verb RunAs -Wait
            Write-InstallLog "  Config written to: $ConfigFile (elevated)"
        } catch {
            Write-InstallLog "  ERROR: Failed to write config: $_"
        }
    }
    $script:progressBar.Value = 65

    # Step 5: Create working directory if needed
    $workDir = $script:Config.defaultWorkingDir
    if (-not (Test-Path $workDir)) {
        Write-InstallLog "Creating working directory: $workDir"
        try {
            New-Item -ItemType Directory -Path $workDir -Force | Out-Null
            Write-InstallLog "  Directory created."
        } catch {
            Write-InstallLog "  WARNING: Could not create directory: $_"
        }
    }
    $script:progressBar.Value = 70

    # Step 6: Test connection (optional, best-effort)
    if ($script:Config.connectionMode -eq "manual") {
        Write-InstallLog "Testing connection to orchestrator..."
        $addr = $script:Config.coordinatorHost -replace "^ws://", "http://" -replace "^wss://", "https://"
        try {
            $headers = @{ "Authorization" = "Bearer $($script:Config.sharedSecret)" }
            $null = Invoke-WebRequest -Uri "$addr/status" -Headers $headers -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            Write-InstallLog "  Connection test successful!"
        } catch {
            Write-InstallLog "  Connection test failed (orchestrator may not be running yet): $($_.Exception.Message)"
        }
    } else {
        Write-InstallLog "Orchestrator discovery mode: auto (will discover on agent start)."
    }
    $script:progressBar.Value = 80

    # Step 7: Install Windows service (if selected)
    if ($script:Config.installService) {
        Write-InstallLog "Installing Windows service (DispatchWorker)..."
        $installScript = Join-Path $ProjectRoot "install\install-worker.ps1"
        if (Test-Path $installScript) {
            try {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $installScript -ProjectRoot $ProjectRoot 2>&1 | ForEach-Object {
                    Write-InstallLog "  $_"
                }
            } catch {
                Write-InstallLog "  ERROR: Service installation failed: $_"
            }
        } else {
            Write-InstallLog "  WARNING: install-worker.ps1 not found at $installScript"
        }
    } else {
        Write-InstallLog "Windows service installation skipped (not selected)."
    }
    $script:progressBar.Value = 90

    # Agent start is deferred to the Finish button (Complete page checkbox)
    $script:progressBar.Value = 100

    Write-InstallLog ""
    Write-InstallLog "Setup complete!"

    # Move to complete step
    Start-Sleep -Milliseconds 500

    $name = $script:Config.agentName
    $script:lblCompleteStatus.Text = "Your agent '$name' has been configured and is ready."
    $script:lblCompleteAgent.Text = "Agent: $name  |  Machine: $($script:Config.machineId)"
    $hint = "Quick test: Ask the orchestrator to send a test task to '$name'.`n`n"
    if (-not $script:Config.installService) {
        $hint += "To start the agent manually later:`n  cd `"$ProjectRoot`" && node worker/agent-relay.js"
    } else {
        $hint += "The agent is running as a Windows service (DispatchWorker).`nUse 'nssm status DispatchWorker' to check its state."
    }
    $script:lblCompleteHint.Text = $hint

    Show-Step 7
}

# ---------------------------------------------------------------------------
# Navigation events
# ---------------------------------------------------------------------------
$btnNext.Add_Click({
    $step = $script:CurrentStep
    $flow = Get-StepFlow
    $flowIdx = Get-FlowIndex $step

    # Validate current step before advancing (steps that need validation)
    if ($step -eq 10 -or ($step -ge 1 -and $step -le 4)) {
        Collect-Config
        if (-not (Validate-Step $step)) { return }
    }

    if ($step -eq 5) {
        # "Install" button — move to installing step and run
        Show-Step 6
        Run-Install
        return
    }

    if ($step -eq 7) {
        # "Finish" button — start agent if checkbox is checked
        if ($script:chkStartAgent -and $script:chkStartAgent.Checked) {
            if (-not $script:Config.installService) {
                $agentScript = Join-Path $ProjectRoot "worker\agent-relay.js"
                $cmdArgs = "/C title Dispatch Agent & node `"$agentScript`" || (echo. & echo Agent stopped. Press any key to close. & pause >nul)"
                Start-Process cmd.exe -ArgumentList $cmdArgs -WorkingDirectory $ProjectRoot -WindowStyle Minimized
            }
        }
        $form.Close()
        return
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
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to cancel the setup?",
        "Cancel Setup",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq "Yes") {
        $form.Close()
    }
})

# ---------------------------------------------------------------------------
# Show initial step and run
# ---------------------------------------------------------------------------
Show-Step 0
[void]$form.ShowDialog()
