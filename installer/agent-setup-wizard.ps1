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

# ---------------------------------------------------------------------------
# State — current step and collected config values
# ---------------------------------------------------------------------------
$script:CurrentStep = 0
$script:TotalSteps  = 8  # 0-indexed: 0=Welcome,1=Identity,2=Connection,3=Dirs,4=Options,5=Review,6=Installing,7=Complete
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
$form.Size = New-Object System.Drawing.Size((S 680), (S 500))
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
# Content panel — holds each step's content (swapped on navigation)
# ---------------------------------------------------------------------------
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Location = New-Object System.Drawing.Point(0, 0)
$contentPanel.Size = New-Object System.Drawing.Size((S 680), (S 420))
$contentPanel.BackColor = $ColorDarkBg
$form.Controls.Add($contentPanel)

# ---------------------------------------------------------------------------
# Bottom bar — navigation buttons + step indicator
# ---------------------------------------------------------------------------
$bottomBar = New-Object System.Windows.Forms.Panel
$bottomBar.Location = New-Object System.Drawing.Point(0, (S 420))
$bottomBar.Size = New-Object System.Drawing.Size((S 680), (S 50))
$bottomBar.BackColor = $ColorPanel
$form.Controls.Add($bottomBar)

$lblStep = New-StyledLabel -Parent $bottomBar -Text "Step 1 of 8" -X 20 -Y 14 -Width 200 -Font $FontSmall -ForeColor $ColorDimGray

$btnBack = New-StyledButton -Parent $bottomBar -Text "Back" -X 400 -Y 9 -Width 80 -Height 32
$btnNext = New-StyledButton -Parent $bottomBar -Text "Next" -X 490 -Y 9 -Width 80 -Height 32 -BackColor $ColorHighlight
$btnCancel = New-StyledButton -Parent $bottomBar -Text "Cancel" -X 580 -Y 9 -Width 80 -Height 32

# ---------------------------------------------------------------------------
# Step panels — created once, shown/hidden as needed
# ---------------------------------------------------------------------------
$panels = @{}

# ========================== STEP 0: Welcome ================================
$p0 = New-Object System.Windows.Forms.Panel
$p0.Size = $contentPanel.Size
$p0.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p0 -Text "Dispatch Agent Setup" -X 40 -Y 30 -Width 600 -Height 36 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null
New-StyledLabel -Parent $p0 -Text "This wizard will configure this machine as a named agent`nin your Dispatch Orchestrator network." -X 40 -Y 80 -Width 600 -Height 44 -Font $FontSubtitle | Out-Null
New-StyledLabel -Parent $p0 -Text "Agents receive tasks from the orchestrator and run them using Claude Code.`nEach agent has a name and capabilities that determine which tasks it handles." -X 40 -Y 140 -Width 600 -Height 44 -Font $FontBody -ForeColor $ColorLightGray | Out-Null

$diagramBox = New-Object System.Windows.Forms.TextBox
$diagramBox.Multiline = $true
$diagramBox.ReadOnly = $true
$diagramBox.Location = New-Object System.Drawing.Point((S 40), (S 210))
$diagramBox.Size = New-Object System.Drawing.Size((S 580), (S 100))
$diagramBox.Font = $FontMono
$diagramBox.BackColor = $ColorPanel
$diagramBox.ForeColor = $ColorLightGray
$diagramBox.BorderStyle = "FixedSingle"
$diagramBox.Text = @"
  Orchestrator ──relay──>  [This Machine]
  (your main PC)          Agent "YourBot"
                          claude --print

  Tasks flow from the orchestrator to your agent via
  a WebSocket relay connection (auto-discovered or manual).
"@
$p0.Controls.Add($diagramBox)

New-StyledLabel -Parent $p0 -Text "Click Next to begin configuration." -X 40 -Y 330 -Width 600 -Height 24 -Font $FontBody -ForeColor $ColorDimGray | Out-Null

$panels[0] = $p0

# ========================== STEP 1: Agent Identity =========================
$p1 = New-Object System.Windows.Forms.Panel
$p1.Size = $contentPanel.Size
$p1.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p1 -Text "Agent Identity" -X 40 -Y 20 -Width 600 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

New-StyledLabel -Parent $p1 -Text "Agent Name (required)" -X 40 -Y 70 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtAgentName = New-StyledTextBox -Parent $p1 -Text "" -X 40 -Y 94 -Width 400
New-StyledLabel -Parent $p1 -Text "e.g., CodeBot, ResearchBot, AnalysisAgent" -X 450 -Y 96 -Width 200 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p1 -Text "Agent Description" -X 40 -Y 134 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtAgentDesc = New-StyledTextBox -Parent $p1 -Text "" -X 40 -Y 158 -Width 580
New-StyledLabel -Parent $p1 -Text "e.g., Handles coding and code review tasks" -X 40 -Y 186 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p1 -Text "Capabilities (comma-separated tags)" -X 40 -Y 216 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtCapabilities = New-StyledTextBox -Parent $p1 -Text "code, refactor, review, debug" -X 40 -Y 240 -Width 580
New-StyledLabel -Parent $p1 -Text "The orchestrator routes tasks to agents by name or capability match" -X 40 -Y 268 -Width 500 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

New-StyledLabel -Parent $p1 -Text "Machine ID" -X 40 -Y 304 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtMachineId = New-StyledTextBox -Parent $p1 -Text $script:Config.machineId -X 40 -Y 328 -Width 300
New-StyledLabel -Parent $p1 -Text "Auto-generated, editable" -X 350 -Y 330 -Width 200 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[1] = $p1

# ========================== STEP 2: Connection =============================
$p2 = New-Object System.Windows.Forms.Panel
$p2.Size = $contentPanel.Size
$p2.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p2 -Text "Connection" -X 40 -Y 20 -Width 600 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null
New-StyledLabel -Parent $p2 -Text "How should this agent find the orchestrator?" -X 40 -Y 58 -Width 500 -Height 22 -Font $FontSubtitle | Out-Null

$script:radioAuto = New-StyledRadio -Parent $p2 -Text "Auto-discover on local network (UDP broadcast)" -X 40 -Y 96 -Checked $true
$script:radioManual = New-StyledRadio -Parent $p2 -Text "Connect to specific address" -X 40 -Y 124

New-StyledLabel -Parent $p2 -Text "Orchestrator address:" -X 60 -Y 158 -Width 200 -Height 20 -Font $FontLabel | Out-Null
$script:txtCoordAddr = New-StyledTextBox -Parent $p2 -Text "ws://192.168.1.100:7070" -X 60 -Y 182 -Width 360
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

New-StyledLabel -Parent $p2 -Text "Shared Secret (required)" -X 40 -Y 224 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtSecret = New-StyledTextBox -Parent $p2 -Text "" -X 40 -Y 248 -Width 360
New-StyledLabel -Parent $p2 -Text "Get this from whoever set up the orchestrator" -X 40 -Y 276 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$script:lblTestResult = New-StyledLabel -Parent $p2 -Text "" -X 60 -Y 328 -Width 500 -Height 22 -Font $FontBody -ForeColor $ColorLightGray
$script:btnTest = New-StyledButton -Parent $p2 -Text "Test Connection" -X 40 -Y 310 -Width 140 -Height 30 -BackColor $ColorAccent

$script:btnTest.Add_Click({
    $script:lblTestResult.Text = "Testing..."
    $script:lblTestResult.ForeColor = $ColorLightGray
    $form.Refresh()

    if ($script:radioAuto.Checked) {
        # Try UDP discovery for ~10 seconds
        $script:lblTestResult.Text = "Listening for UDP broadcast (10s)..."
        $form.Refresh()
        try {
            $udpResult = & powershell -NoProfile -Command @"
`$socket = New-Object System.Net.Sockets.UdpClient(7071)
`$socket.Client.ReceiveTimeout = 10000
try {
    `$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    `$data = `$socket.Receive([ref]`$ep)
    `$msg = [System.Text.Encoding]::UTF8.GetString(`$data)
    Write-Output "OK:`$msg from `$(`$ep.Address)"
} catch {
    Write-Output "FAIL:No broadcast received within 10 seconds"
} finally {
    `$socket.Close()
}
"@
            if ($udpResult -like "OK:*") {
                $script:lblTestResult.Text = "Connected! Relay found: $($udpResult.Substring(3))"
                $script:lblTestResult.ForeColor = $ColorGreen
            } else {
                $script:lblTestResult.Text = "Failed: $($udpResult.Substring(5))"
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
            $script:lblTestResult.Text = "Connected! Status: $($response.StatusCode)"
            $script:lblTestResult.ForeColor = $ColorGreen
        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg.Length -gt 60) { $errMsg = $errMsg.Substring(0, 60) + "..." }
            $script:lblTestResult.Text = "Failed: $errMsg"
            $script:lblTestResult.ForeColor = $ColorRed
        }
    }
})

$panels[2] = $p2

# ========================== STEP 3: Working Directories ====================
$p3 = New-Object System.Windows.Forms.Panel
$p3.Size = $contentPanel.Size
$p3.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p3 -Text "Working Directories" -X 40 -Y 20 -Width 600 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

New-StyledLabel -Parent $p3 -Text "Default Working Directory" -X 40 -Y 64 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtWorkDir = New-StyledTextBox -Parent $p3 -Text "C:\workspace" -X 40 -Y 88 -Width 470
$script:btnBrowseWork = New-StyledButton -Parent $p3 -Text "Browse..." -X 520 -Y 86 -Width 100 -Height 28

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

New-StyledLabel -Parent $p3 -Text "Allowed Directories (one per line)" -X 40 -Y 128 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtAllowed = New-Object System.Windows.Forms.TextBox
$script:txtAllowed.Multiline = $true
$script:txtAllowed.ScrollBars = "Vertical"
$script:txtAllowed.Location = New-Object System.Drawing.Point((S 40), (S 150))
$script:txtAllowed.Size = New-Object System.Drawing.Size((S 470), (S 60))
$script:txtAllowed.Font = $FontMonoSmall
$script:txtAllowed.BackColor = $ColorInputBg
$script:txtAllowed.ForeColor = $ColorWhite
$script:txtAllowed.BorderStyle = "FixedSingle"
$script:txtAllowed.Text = "C:\workspace"
$p3.Controls.Add($script:txtAllowed)

$script:btnAddAllowed = New-StyledButton -Parent $p3 -Text "Add Folder..." -X 520 -Y 152 -Width 100 -Height 28

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

New-StyledLabel -Parent $p3 -Text "Denied Directories (one per line)" -X 40 -Y 222 -Width 300 -Height 20 -Font $FontLabel | Out-Null
$script:txtDenied = New-Object System.Windows.Forms.TextBox
$script:txtDenied.Multiline = $true
$script:txtDenied.ScrollBars = "Vertical"
$script:txtDenied.Location = New-Object System.Drawing.Point((S 40), (S 244))
$script:txtDenied.Size = New-Object System.Drawing.Size((S 580), (S 80))
$script:txtDenied.Font = $FontMonoSmall
$script:txtDenied.BackColor = $ColorInputBg
$script:txtDenied.ForeColor = $ColorWhite
$script:txtDenied.BorderStyle = "FixedSingle"
$script:txtDenied.Text = "C:\Windows`r`nC:\Program Files`r`nC:\Program Files (x86)`r`nC:\Users\*\AppData"
$p3.Controls.Add($script:txtDenied)

New-StyledLabel -Parent $p3 -Text "The agent will only execute tasks in allowed directories. System directories are blocked for safety." -X 40 -Y 336 -Width 600 -Height 36 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[3] = $p3

# ========================== STEP 4: Options ================================
$p4 = New-Object System.Windows.Forms.Panel
$p4.Size = $contentPanel.Size
$p4.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p4 -Text "Options" -X 40 -Y 20 -Width 600 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

$script:chkKeepAwake = New-StyledCheckBox -Parent $p4 -Text "Keep machine awake while agent is running" -X 40 -Y 72 -Checked $true
$script:chkTls = New-StyledCheckBox -Parent $p4 -Text "Enable TLS encryption" -X 40 -Y 102 -Checked $false
New-StyledLabel -Parent $p4 -Text "Enable only if the orchestrator has TLS configured" -X 68 -Y 128 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

# Detect NSSM
$nssmAvailable = $null -ne (Get-Command nssm.exe -ErrorAction SilentlyContinue)
$script:chkService = New-StyledCheckBox -Parent $p4 -Text "Install as Windows service" -X 40 -Y 158 -Checked $false
if (-not $nssmAvailable) {
    $script:chkService.Enabled = $false
    New-StyledLabel -Parent $p4 -Text "NSSM not detected. Install NSSM to enable service mode." -X 68 -Y 184 -Width 500 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null
} else {
    New-StyledLabel -Parent $p4 -Text "NSSM detected. The agent will start automatically with Windows." -X 68 -Y 184 -Width 500 -Height 18 -Font $FontSmall -ForeColor $ColorGreen | Out-Null
}

$script:chkStartAfter = New-StyledCheckBox -Parent $p4 -Text "Start agent after setup completes" -X 40 -Y 214 -Checked $true

New-StyledLabel -Parent $p4 -Text "Max Output Size" -X 40 -Y 264 -Width 200 -Height 20 -Font $FontLabel | Out-Null
$script:cmbMaxOutput = New-Object System.Windows.Forms.ComboBox
$script:cmbMaxOutput.DropDownStyle = "DropDownList"
$script:cmbMaxOutput.Location = New-Object System.Drawing.Point((S 40), (S 288))
$script:cmbMaxOutput.Size = New-Object System.Drawing.Size((S 200), (S 28))
$script:cmbMaxOutput.Font = $FontBody
$script:cmbMaxOutput.BackColor = $ColorInputBg
$script:cmbMaxOutput.ForeColor = $ColorWhite
$script:cmbMaxOutput.FlatStyle = "Flat"
$script:cmbMaxOutput.Items.AddRange(@("100 KB", "500 KB", "1 MB", "5 MB", "10 MB"))
$script:cmbMaxOutput.SelectedIndex = 2  # 1 MB default
$p4.Controls.Add($script:cmbMaxOutput)
New-StyledLabel -Parent $p4 -Text "Maximum size of task output returned to the orchestrator" -X 250 -Y 290 -Width 400 -Height 18 -Font $FontSmall -ForeColor $ColorDimGray | Out-Null

$panels[4] = $p4

# ========================== STEP 5: Review =================================
$p5 = New-Object System.Windows.Forms.Panel
$p5.Size = $contentPanel.Size
$p5.BackColor = $ColorDarkBg

New-StyledLabel -Parent $p5 -Text "Review Configuration" -X 40 -Y 20 -Width 600 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null
New-StyledLabel -Parent $p5 -Text "Review your settings below. Click Install to proceed." -X 40 -Y 56 -Width 500 -Height 22 -Font $FontSubtitle | Out-Null

$script:txtReview = New-Object System.Windows.Forms.TextBox
$script:txtReview.Multiline = $true
$script:txtReview.ReadOnly = $true
$script:txtReview.ScrollBars = "Both"
$script:txtReview.WordWrap = $false
$script:txtReview.Location = New-Object System.Drawing.Point((S 40), (S 86))
$script:txtReview.Size = New-Object System.Drawing.Size((S 600), (S 300))
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

New-StyledLabel -Parent $p6 -Text "Installing..." -X 40 -Y 20 -Width 600 -Height 32 -Font $FontTitle -ForeColor $ColorHighlight | Out-Null

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location = New-Object System.Drawing.Point((S 40), (S 66))
$script:progressBar.Size = New-Object System.Drawing.Size((S 600), (S 24))
$script:progressBar.Style = "Continuous"
$script:progressBar.Minimum = 0
$script:progressBar.Maximum = 100
$p6.Controls.Add($script:progressBar)

$script:txtInstallLog = New-Object System.Windows.Forms.TextBox
$script:txtInstallLog.Multiline = $true
$script:txtInstallLog.ReadOnly = $true
$script:txtInstallLog.ScrollBars = "Vertical"
$script:txtInstallLog.Location = New-Object System.Drawing.Point((S 40), (S 100))
$script:txtInstallLog.Size = New-Object System.Drawing.Size((S 600), (S 290))
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

New-StyledLabel -Parent $p7 -Text "Setup Complete" -X 40 -Y 30 -Width 600 -Height 36 -Font $FontTitle -ForeColor $ColorGreen | Out-Null
$script:lblCompleteStatus = New-StyledLabel -Parent $p7 -Text "" -X 40 -Y 80 -Width 600 -Height 60 -Font $FontSubtitle
$script:lblCompleteAgent = New-StyledLabel -Parent $p7 -Text "" -X 40 -Y 150 -Width 600 -Height 30 -Font $FontBody -ForeColor $ColorLightGray
$script:lblCompleteHint = New-StyledLabel -Parent $p7 -Text "" -X 40 -Y 200 -Width 600 -Height 80 -Font $FontBody -ForeColor $ColorDimGray

$panels[7] = $p7

# ---------------------------------------------------------------------------
# Helper: collect config values from the UI fields
# ---------------------------------------------------------------------------
function Collect-Config {
    $script:Config.agentName = $script:txtAgentName.Text.Trim()
    $script:Config.agentDescription = $script:txtAgentDesc.Text.Trim()
    $script:Config.agentCapabilities = @(($script:txtCapabilities.Text -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
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
# Show a specific step panel
# ---------------------------------------------------------------------------
function Show-Step {
    param([int]$StepIndex)

    $contentPanel.Controls.Clear()
    if ($panels.ContainsKey($StepIndex)) {
        $contentPanel.Controls.Add($panels[$StepIndex])
    }

    $lblStep.Text = "Step $($StepIndex + 1) of $($script:TotalSteps)"

    # Navigation button visibility
    $btnBack.Visible = ($StepIndex -gt 0) -and ($StepIndex -lt 6)
    $btnCancel.Visible = ($StepIndex -lt 6)

    switch ($StepIndex) {
        5 { $btnNext.Text = "Install"; $btnNext.Visible = $true }
        6 { $btnNext.Visible = $false; $btnBack.Visible = $false; $btnCancel.Visible = $false }
        7 { $btnNext.Text = "Finish"; $btnNext.Visible = $true; $btnBack.Visible = $false; $btnCancel.Visible = $false }
        default { $btnNext.Text = "Next"; $btnNext.Visible = $true }
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

    $script:CurrentStep = $StepIndex
}

# ---------------------------------------------------------------------------
# Validation per step
# ---------------------------------------------------------------------------
function Validate-Step {
    param([int]$StepIndex)

    switch ($StepIndex) {
        1 {
            if ($script:txtAgentName.Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Agent name is required.", "Validation", "OK", "Warning")
                return $false
            }
            if ($script:txtMachineId.Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Machine ID is required.", "Validation", "OK", "Warning")
                return $false
            }
        }
        2 {
            if ($script:txtSecret.Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Shared secret is required. Get this from whoever set up the orchestrator.", "Validation", "OK", "Warning")
                return $false
            }
            if ($script:radioManual.Checked -and $script:txtCoordAddr.Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Orchestrator address is required for manual connection.", "Validation", "OK", "Warning")
                return $false
            }
        }
        3 {
            if ($script:txtWorkDir.Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Default working directory is required.", "Validation", "OK", "Warning")
                return $false
            }
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
    try {
        $json = Build-ConfigJson
        $json | Set-Content -Path $ConfigFile -Encoding UTF8 -Force
        Write-InstallLog "  Config written to: $ConfigFile"
    } catch {
        Write-InstallLog "  ERROR: Failed to write config: $_"
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

    # Step 8: Start agent (if selected and not installed as service)
    if ($script:Config.startAfterSetup) {
        if ($script:Config.installService) {
            Write-InstallLog "Agent should be running as a service."
        } else {
            Write-InstallLog "Starting agent..."
            try {
                $agentScript = Join-Path $ProjectRoot "worker\agent-relay.js"
                Start-Process -FilePath "cmd.exe" -ArgumentList "/K", "node", "`"$agentScript`"" -WorkingDirectory $ProjectRoot
                Write-InstallLog "  Agent started in a new console window."
            } catch {
                Write-InstallLog "  ERROR: Failed to start agent: $_"
            }
        }
    } else {
        Write-InstallLog "Agent start skipped (not selected)."
    }
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

    # Validate current step before advancing
    if ($step -ge 1 -and $step -le 4) {
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
        # "Finish" button
        $form.Close()
        return
    }

    if ($step -lt ($script:TotalSteps - 1)) {
        Show-Step ($step + 1)
    }
})

$btnBack.Add_Click({
    $step = $script:CurrentStep
    if ($step -gt 0) {
        Show-Step ($step - 1)
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
