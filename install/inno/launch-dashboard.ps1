<#
.SYNOPSIS
    Starts the relay server and opens the dashboard in the default browser.
#>

$AppRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition))

# Use ProgramData for logs (Program Files is read-only for non-admin)
$LogDir  = Join-Path $env:ProgramData "DispatchOrchestrator\logs"
$LogFile = Join-Path $LogDir "launch-dashboard.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"[$timestamp] Starting relay from $AppRoot" | Out-File -FilePath $LogFile -Encoding UTF8 -Force

# Only proceed if the setup wizard completed successfully
$markerFile = Join-Path $LogDir "setup-complete.marker"
if (-not (Test-Path $markerFile)) {
    "[$timestamp] Skipping - setup wizard was cancelled or not completed" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    exit 0
}

try {
    # Start the relay in a minimized cmd window
    $cmdArgs = "/K title Dispatch Relay & node relay/server.js"
    Start-Process cmd.exe -ArgumentList $cmdArgs -WorkingDirectory $AppRoot -WindowStyle Minimized

    "[$timestamp] Relay process started, waiting 3s for bind..." | Out-File -FilePath $LogFile -Append -Encoding UTF8

    # Give the relay time to bind the port
    Start-Sleep -Seconds 3

    # Open dashboard in default browser
    Start-Process "http://localhost:7070/dashboard"

    "[$timestamp] Dashboard opened in browser" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
catch {
    $errMsg = "[$timestamp] ERROR: $($_.Exception.Message)"
    $errMsg | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
