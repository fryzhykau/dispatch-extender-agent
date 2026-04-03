<#
.SYNOPSIS
    Wrapper that launches the agent setup wizard with logging.
    Called by the Inno Setup installer post-install step.
#>

$ErrorActionPreference = "Stop"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$AppRoot     = Split-Path -Parent $ScriptDir
$WizardScript = Join-Path $AppRoot "installer\agent-setup-wizard.ps1"

# Use ProgramData for logs (Program Files is read-only for non-admin)
$LogDir  = Join-Path $env:ProgramData "DispatchAgent\logs"
$LogFile = Join-Path $LogDir "setup-wizard.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Log basic diagnostics
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$logHeader = @"
=== Agent Setup Wizard Launch Log ===
Timestamp:    $timestamp
AppRoot:      $AppRoot
WizardScript: $WizardScript
WizardExists: $(Test-Path $WizardScript)
PSVersion:    $($PSVersionTable.PSVersion)
User:         $env:USERNAME
"@

$logHeader | Out-File -FilePath $LogFile -Encoding UTF8 -Force

try {
    "Launching wizard..." | Out-File -FilePath $LogFile -Append -Encoding UTF8

    if (-not (Test-Path $WizardScript)) {
        $msg = "ERROR: Setup wizard script not found at: $WizardScript"
        $msg | Out-File -FilePath $LogFile -Append -Encoding UTF8
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "Setup wizard not found.`n`nExpected: $WizardScript`nSee log: $LogFile",
            "Dispatch Agent", 0, 48) | Out-Null
        exit 1
    }

    # Launch the wizard directly (it contains its own WinForms GUI)
    # Do not pipe output — the wizard needs foreground access for its WinForms window
    & $WizardScript

    $exitCode = $LASTEXITCODE
    "Wizard exited with code: $exitCode" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
catch {
    $errMsg = "ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    $errMsg | Out-File -FilePath $LogFile -Append -Encoding UTF8

    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        "Setup wizard failed to launch.`n`n$($_.Exception.Message)`n`nSee log: $LogFile",
        "Dispatch Agent", 0, 48) | Out-Null
    exit 1
}
