<#
.SYNOPSIS
    Generates self-signed CA, server, and client certificates for the dispatch relay.

.DESCRIPTION
    Uses OpenSSL (typically available via Git for Windows) to create:
      - A self-signed Certificate Authority (CA)
      - A server certificate signed by the CA (for the relay)
      - A client certificate signed by the CA (for workers)

    All output goes to the certs/ directory relative to the repository root.

.PARAMETER Hostname
    Additional hostname to include in the server certificate SAN.
    Defaults to the local machine name.

.PARAMETER Force
    Regenerate certificates even if they already exist.

.EXAMPLE
    .\generate-certs.ps1
    .\generate-certs.ps1 -Hostname relay.example.com
    .\generate-certs.ps1 -Force
#>

param(
    [string]$Hostname = $env:COMPUTERNAME,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# If invoked directly from the install folder, resolve relative to script dir
if (-not (Test-Path (Join-Path $RepoRoot ".gitignore"))) {
    $RepoRoot = Split-Path -Parent $PSCommandPath | Split-Path -Parent
}
$CertsDir = Join-Path $RepoRoot "certs"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# Verify openssl is available
try {
    $null = & openssl version 2>&1
} catch {
    Write-Error "OpenSSL not found on PATH. Install Git for Windows or add OpenSSL to PATH."
    exit 1
}

# Check if certs already exist
$expectedFiles = @(
    "ca.key", "ca.crt",
    "server.key", "server.crt",
    "client.key", "client.crt"
)

if (-not $Force) {
    $allExist = $true
    foreach ($f in $expectedFiles) {
        if (-not (Test-Path (Join-Path $CertsDir $f))) {
            $allExist = $false
            break
        }
    }
    if ($allExist) {
        Write-Host "Certificates already exist in $CertsDir. Use -Force to regenerate."
        exit 0
    }
}

# Create output directory
if (-not (Test-Path $CertsDir)) {
    New-Item -ItemType Directory -Path $CertsDir | Out-Null
}

Write-Host "Generating certificates in $CertsDir ..."
Write-Host "  SAN hostnames: localhost, $Hostname"
Write-Host "  SAN IPs:       127.0.0.1"

# ---------------------------------------------------------------------------
# 1. Certificate Authority
# ---------------------------------------------------------------------------

Write-Host "`n--- Generating CA key and certificate ---"

& openssl genrsa -out (Join-Path $CertsDir "ca.key") 4096 2>&1 | Out-Null

& openssl req -new -x509 -days 365 -key (Join-Path $CertsDir "ca.key") `
    -out (Join-Path $CertsDir "ca.crt") `
    -subj "/CN=Dispatch Relay CA/O=DispatchExtender/C=US"

Write-Host "  CA certificate created."

# ---------------------------------------------------------------------------
# 2. Server certificate (for the relay)
# ---------------------------------------------------------------------------

Write-Host "`n--- Generating server key and certificate ---"

# Create a temporary SAN config
$ServerExtFile = Join-Path $CertsDir "_server_ext.cnf"
@"
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
CN = dispatch-relay
O = DispatchExtender
C = US

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = $Hostname
IP.1 = 127.0.0.1
"@ | Set-Content -Path $ServerExtFile -Encoding UTF8

& openssl genrsa -out (Join-Path $CertsDir "server.key") 2048 2>&1 | Out-Null

& openssl req -new -key (Join-Path $CertsDir "server.key") `
    -out (Join-Path $CertsDir "server.csr") `
    -config $ServerExtFile

& openssl x509 -req -days 365 `
    -in (Join-Path $CertsDir "server.csr") `
    -CA (Join-Path $CertsDir "ca.crt") `
    -CAkey (Join-Path $CertsDir "ca.key") `
    -CAcreateserial `
    -out (Join-Path $CertsDir "server.crt") `
    -extensions v3_req `
    -extfile $ServerExtFile

Write-Host "  Server certificate created."

# ---------------------------------------------------------------------------
# 3. Client certificate (for workers)
# ---------------------------------------------------------------------------

Write-Host "`n--- Generating client key and certificate ---"

$ClientExtFile = Join-Path $CertsDir "_client_ext.cnf"
@"
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
CN = dispatch-worker
O = DispatchExtender
C = US

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
"@ | Set-Content -Path $ClientExtFile -Encoding UTF8

& openssl genrsa -out (Join-Path $CertsDir "client.key") 2048 2>&1 | Out-Null

& openssl req -new -key (Join-Path $CertsDir "client.key") `
    -out (Join-Path $CertsDir "client.csr") `
    -config $ClientExtFile

& openssl x509 -req -days 365 `
    -in (Join-Path $CertsDir "client.csr") `
    -CA (Join-Path $CertsDir "ca.crt") `
    -CAkey (Join-Path $CertsDir "ca.key") `
    -CAcreateserial `
    -out (Join-Path $CertsDir "client.crt") `
    -extensions v3_req `
    -extfile $ClientExtFile

Write-Host "  Client certificate created."

# ---------------------------------------------------------------------------
# Cleanup temporary files
# ---------------------------------------------------------------------------

Remove-Item -Path (Join-Path $CertsDir "server.csr") -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $CertsDir "client.csr") -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $CertsDir "ca.srl") -ErrorAction SilentlyContinue
Remove-Item -Path $ServerExtFile -ErrorAction SilentlyContinue
Remove-Item -Path $ClientExtFile -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host "`nCertificates generated successfully:"
foreach ($f in $expectedFiles) {
    $full = Join-Path $CertsDir $f
    if (Test-Path $full) {
        Write-Host "  [OK] $f"
    } else {
        Write-Host "  [MISSING] $f" -ForegroundColor Red
    }
}
Write-Host ""
