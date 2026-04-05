<#
.SYNOPSIS
    Builds the Dispatch Orchestrator Windows installer(s) using Inno Setup.

.DESCRIPTION
    Locates the Inno Setup compiler (ISCC.exe), compiles the .iss script(s),
    and produces ready-to-distribute installer EXE(s) in the dist/ directory.

    Run with:  npm run build:installer
    Or:        powershell -ExecutionPolicy Bypass -File install\inno\build.ps1
    Or:        powershell -ExecutionPolicy Bypass -File install\inno\build.ps1 -Target agent
    Or:        powershell -ExecutionPolicy Bypass -File install\inno\build.ps1 -Target all

.PARAMETER Target
    Which installer(s) to build:
      "orchestrator" (default) — full Dispatch Orchestrator installer
      "agent"                  — lightweight agent-only installer
      "all"                    — both orchestrator and agent installers

.NOTES
    Requires Inno Setup 6+ installed on the build machine.
    Download: https://jrsoftware.org/isdl.php
#>

param(
    [ValidateSet("orchestrator", "agent", "all")]
    [string]$Target = "orchestrator"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$DistDir     = Join-Path $ProjectRoot "dist"

# Determine which .iss files to compile based on the -Target parameter
$IssTargets = @()
switch ($Target) {
    "orchestrator" {
        $IssTargets += @{ Name = "Dispatch Orchestrator"; IssFile = (Join-Path $ScriptDir "dispatch-orchestrator.iss"); OutputExe = "DispatchOrchestratorSetup.exe" }
    }
    "agent" {
        $IssTargets += @{ Name = "Dispatch Agent"; IssFile = (Join-Path $ScriptDir "dispatch-agent.iss"); OutputExe = "DispatchAgentSetup.exe" }
    }
    "all" {
        $IssTargets += @{ Name = "Dispatch Orchestrator"; IssFile = (Join-Path $ScriptDir "dispatch-orchestrator.iss"); OutputExe = "DispatchOrchestratorSetup.exe" }
        $IssTargets += @{ Name = "Dispatch Agent"; IssFile = (Join-Path $ScriptDir "dispatch-agent.iss"); OutputExe = "DispatchAgentSetup.exe" }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Dispatch Orchestrator - Build Installer" -ForegroundColor Cyan
Write-Host "  Target: $Target" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Locate Inno Setup Compiler (ISCC.exe)
# ---------------------------------------------------------------------------
$IsccPaths = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:USERPROFILE\AppData\Local\Programs\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 5\ISCC.exe"
)

# Also check the registry for install location
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup*"
)
foreach ($regPath in $regPaths) {
    $regEntry = Get-ItemProperty $regPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($regEntry -and $regEntry.InstallLocation) {
        $regIscc = Join-Path $regEntry.InstallLocation "ISCC.exe"
        if (Test-Path $regIscc) {
            $IsccPaths = @($regIscc) + $IsccPaths
        }
    }
}

$IsccExe = $null

# First check common install locations
foreach ($path in $IsccPaths) {
    if (Test-Path $path) {
        $IsccExe = $path
        break
    }
}

# Fall back to PATH
if (-not $IsccExe) {
    $found = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($found) {
        $IsccExe = $found.Source
    }
}

# Not found — help the user install it
if (-not $IsccExe) {
    Write-Host "[ERROR] Inno Setup compiler (ISCC.exe) not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Inno Setup 6 is required to build the installer." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Install options:" -ForegroundColor White
    Write-Host "  1. winget:  winget install JRSoftware.InnoSetup" -ForegroundColor Gray
    Write-Host "  2. Manual:  https://jrsoftware.org/isdl.php" -ForegroundColor Gray
    Write-Host ""

    $choice = Read-Host "Would you like to try installing via winget now? (Y/N)"
    if ($choice -match '^[Yy]') {
        Write-Host ""
        Write-Host "Running: winget install JRSoftware.InnoSetup ..." -ForegroundColor Cyan
        try {
            winget install JRSoftware.InnoSetup --accept-source-agreements --accept-package-agreements
            # Re-check after install
            foreach ($path in $IsccPaths) {
                if (Test-Path $path) {
                    $IsccExe = $path
                    break
                }
            }
            if (-not $IsccExe) {
                Write-Host "[ERROR] ISCC.exe still not found after install. You may need to restart your terminal." -ForegroundColor Red
                exit 1
            }
        } catch {
            Write-Host "[ERROR] winget install failed: $_" -ForegroundColor Red
            Write-Host "Please install Inno Setup manually from https://jrsoftware.org/isdl.php" -ForegroundColor Yellow
            exit 1
        }
    } else {
        Write-Host "Aborting build. Install Inno Setup and try again." -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "[OK] Inno Setup compiler: $IsccExe" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Verify the .iss file(s) exist
# ---------------------------------------------------------------------------
foreach ($issEntry in $IssTargets) {
    if (-not (Test-Path $issEntry.IssFile)) {
        Write-Host "[ERROR] Inno Setup script not found: $($issEntry.IssFile)" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Script file: $($issEntry.IssFile)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Create dist/ output directory
# ---------------------------------------------------------------------------
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
    Write-Host "[OK] Created output directory: $DistDir" -ForegroundColor Green
} else {
    Write-Host "[OK] Output directory exists: $DistDir" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Generate assets if missing (optional)
# ---------------------------------------------------------------------------
$AssetsScript = Join-Path $ScriptDir "create-assets.ps1"
$BannerFile   = Join-Path $ScriptDir "assets\wizard-banner.bmp"
if (-not (Test-Path $BannerFile) -and (Test-Path $AssetsScript)) {
    Write-Host ""
    Write-Host "Generating installer assets..." -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File $AssetsScript
}

# ---------------------------------------------------------------------------
# Compile the installer(s)
# ---------------------------------------------------------------------------
$buildResults = @()

foreach ($issTarget in $IssTargets) {
    Write-Host ""
    Write-Host "Compiling $($issTarget.Name) installer..." -ForegroundColor Cyan
    Write-Host "  Command: $IsccExe `"$($issTarget.IssFile)`"" -ForegroundColor Gray
    Write-Host ""

    $startTime = Get-Date
    & "$IsccExe" "$($issTarget.IssFile)"
    $exitCode = $LASTEXITCODE
    $elapsed = (Get-Date) - $startTime

    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Host "[FAILED] Inno Setup compiler exited with code $exitCode for $($issTarget.Name)" -ForegroundColor Red
        exit $exitCode
    }

    $buildResults += @{
        Name      = $issTarget.Name
        OutputExe = $issTarget.OutputExe
        Elapsed   = $elapsed
    }
}

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  BUILD SUCCESSFUL" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

foreach ($result in $buildResults) {
    $OutputExe = Join-Path $DistDir $result.OutputExe
    if (Test-Path $OutputExe) {
        $fileInfo = Get-Item $OutputExe
        $sizeMB   = [math]::Round($fileInfo.Length / 1MB, 2)
        Write-Host "  [$($result.Name)]" -ForegroundColor Cyan
        Write-Host "  Output:   $OutputExe" -ForegroundColor White
        Write-Host "  Size:     $sizeMB MB" -ForegroundColor White
        Write-Host "  Built in: $([math]::Round($result.Elapsed.TotalSeconds, 1)) seconds" -ForegroundColor White

        # Generate SHA256 checksum
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($result.OutputExe)
        $hash = (Get-FileHash -Path $OutputExe -Algorithm SHA256).Hash
        $checksumFile = Join-Path $DistDir "$baseName.sha256"
        "$hash  $($result.OutputExe)" | Set-Content -Path $checksumFile -Encoding UTF8
        Write-Host "  SHA256:   $hash" -ForegroundColor Gray
        Write-Host "  Saved to: $checksumFile" -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "  [WARNING] Expected output file not found: $OutputExe" -ForegroundColor Yellow
        Write-Host ""
    }
}

Write-Host "The installer(s) are ready to distribute." -ForegroundColor Cyan
Write-Host ""
