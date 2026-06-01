$ErrorActionPreference = "Stop"

# Auto-build lfilter.exe and lstore.exe if not present.
# lparser requires regex.h and is not built natively on Windows.
# Requires MinGW gcc. Without it, use Docker (scripts\run_linux_demo.ps1).
function Ensure-Built {
    param([string[]]$Names)
    $needBuild = $Names | Where-Object { -not (Test-Path "build\${_}.exe") }
    if (-not $needBuild) { return }

    if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
        Write-Host "gcc not found. Install MinGW: https://www.mingw-w64.org/" -ForegroundColor Red
        Write-Host "Or use Docker: powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1"
        exit 1
    }

    Write-Host "Building: $($needBuild -join ', ')" -ForegroundColor Cyan
    $null = New-Item -ItemType Directory -Path "build" -Force
    foreach ($name in $needBuild) {
        # Compile common.c together with each tool to avoid stale cross-platform .o files.
        & gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 "src\${name}.c" src\common.c -o "build\${name}"
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile ${name}.c" }
        if (-not (Test-Path "build\${name}.exe")) { throw "build\${name}.exe not found after build" }
        Write-Host "  Built: build\${name}.exe" -ForegroundColor Green
    }
}

Ensure-Built @("lfilter", "lstore")

# --- Prepare test data ---
$null = New-Item -ItemType Directory -Path "data" -Force

$csv = @'
ip,time,method,path,status
192.168.0.2,30/Apr/2026:08:00:00 +0800,GET,/index.html,200
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@

$inputPath = "data\demo_input.csv"
$dbPath    = "data\demo.tsv"
$tmpPath   = $dbPath + ".tmp"

if (Test-Path $dbPath)  { Remove-Item $dbPath  -Force }
if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force }

Set-Content -Path $inputPath -Value $csv -Encoding ascii

# --- Demo ---
Write-Host ""
Write-Host "== BusyPipe MVP Demo ==" -ForegroundColor Cyan

Write-Host ""
Write-Host "[1] Raw CSV" -ForegroundColor Yellow
Get-Content $inputPath

Write-Host ""
Write-Host "[2] Filter status >= 400, project ip,path,status" -ForegroundColor Yellow
Get-Content $inputPath | .\build\lfilter.exe --where "status>=400" --select "ip,path,status"

Write-Host ""
Write-Host "[3] Store to demo.tsv (TTL 3600s)" -ForegroundColor Yellow
Get-Content $inputPath | .\build\lstore.exe --db $dbPath --put --key-field ip --ttl 3600
Get-Content $dbPath

Write-Host ""
Write-Host "[4] Query key 192.168.0.4" -ForegroundColor Yellow
.\build\lstore.exe --db $dbPath --get 192.168.0.4

Write-Host ""
Write-Host "[5] List all valid records" -ForegroundColor Yellow
.\build\lstore.exe --db $dbPath --list

Write-Host ""
Write-Host "== Demo done ==" -ForegroundColor Cyan
