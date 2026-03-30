# install-relay.ps1
# Registers the Dispatch Relay server as a Windows service using NSSM.

param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ServiceName = "DispatchRelay"
$EntryScript = "relay\server.js"
$AppDirectory = Join-Path $ProjectRoot "relay"
$LogsDir = Join-Path $ProjectRoot "logs"

# --- Locate NSSM ---
$nssm = Get-Command nssm.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $nssm) {
    # Check common locations
    $candidates = @(
        "C:\nssm\nssm.exe",
        "C:\tools\nssm\nssm.exe",
        "C:\Program Files\nssm\nssm.exe",
        "C:\ProgramData\chocolatey\bin\nssm.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $nssm = $c; break }
    }
}
if (-not $nssm) {
    Write-Error @"
NSSM (Non-Sucking Service Manager) was not found.

Install it via one of:
  choco install nssm
  scoop install nssm
  Download from https://nssm.cc and place nssm.exe on your PATH.
"@
    exit 1
}
Write-Host "Using NSSM at: $nssm"

# --- Locate node.exe ---
$node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $node) {
    Write-Error "node.exe was not found on PATH. Install Node.js first."
    exit 1
}
Write-Host "Using Node at: $node"

# --- Create logs directory ---
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
    Write-Host "Created logs directory: $LogsDir"
}

# --- Check for existing service ---
$existing = & $nssm status $ServiceName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warning "Service '$ServiceName' already exists (status: $existing)."
    $answer = Read-Host "Remove and reinstall? (y/N)"
    if ($answer -ne 'y') {
        Write-Host "Aborted."
        exit 0
    }
    Write-Host "Stopping and removing existing service..."
    & $nssm stop $ServiceName 2>&1 | Out-Null
    & $nssm remove $ServiceName confirm
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to remove existing service."
        exit 1
    }
}

# --- Install service ---
Write-Host "Installing service '$ServiceName'..."

& $nssm install $ServiceName $node (Join-Path $ProjectRoot $EntryScript)
if ($LASTEXITCODE -ne 0) { Write-Error "NSSM install failed."; exit 1 }

& $nssm set $ServiceName AppDirectory $AppDirectory
& $nssm set $ServiceName Start SERVICE_AUTO_START
& $nssm set $ServiceName AppStdout (Join-Path $LogsDir "$ServiceName-stdout.log")
& $nssm set $ServiceName AppStderr (Join-Path $LogsDir "$ServiceName-stderr.log")
& $nssm set $ServiceName AppStdoutCreationDisposition 4
& $nssm set $ServiceName AppStderrCreationDisposition 4

# --- Start the service ---
Write-Host "Starting service '$ServiceName'..."
& $nssm start $ServiceName
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Service installed but failed to start. Check logs in $LogsDir"
} else {
    Write-Host "Service started successfully."
}

# --- Print status ---
Write-Host ""
Write-Host "--- Service Status ---"
& $nssm status $ServiceName
Write-Host "Logs directory: $LogsDir"
Write-Host "Done."
