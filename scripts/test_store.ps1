$ErrorActionPreference = "Stop"

# Auto-build lstore.exe if not present.
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
    if (-not (Test-Path "build\common.o")) {
        & gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 -c src\common.c -o build\common.o
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile common.c" }
    }
    foreach ($name in $needBuild) {
        & gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 "src\${name}.c" build\common.o -o "build\${name}"
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile ${name}.c" }
        if (-not (Test-Path "build\${name}.exe")) { throw "build\${name}.exe not found after build" }
        Write-Host "  Built: build\${name}.exe" -ForegroundColor Green
    }
}

Ensure-Built @("lstore")

# --- lstore regression tests ---
Write-Host "== test lstore ==" -ForegroundColor Cyan

$null = New-Item -ItemType Directory -Path "data" -Force
$db  = "data\test_store.tsv"
$tmp = $db + ".tmp"

if (Test-Path $db)  { Remove-Item $db  -Force }
if (Test-Path $tmp) { Remove-Item $tmp -Force }

$csv1 = @'
ip,time,method,path,status
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@

$csv2 = @'
ip,time,method,path,status
192.168.0.4,30/Apr/2026:09:00:03 +0800,POST,/login,503
'@

# 1. --put: write two batches
$csv1 | .\build\lstore.exe --db $db --put --key-field ip --ttl 3600
$csv2 | .\build\lstore.exe --db $db --put --key-field ip --ttl 3600

# 2. --get: should return latest record (status 503)
$latest = (& .\build\lstore.exe --db $db --get 192.168.0.4).Trim()
if ($latest -notmatch "503$") {
    throw "FAIL get latest value: $latest"
}
Write-Host "PASS: --get returns latest row (503)" -ForegroundColor Green

# 3. --delete: remove a key
& .\build\lstore.exe --db $db --delete 192.168.0.3 | Out-Null
$afterDelete = & .\build\lstore.exe --db $db --list
if ($afterDelete -match "192\.168\.0\.3") {
    throw "FAIL: delete did not remove target key"
}
Write-Host "PASS: --delete removes target key" -ForegroundColor Green

# 4. --cleanup: remove expired records (epoch=1 is already expired)
$expired = "192.168.0.9`t1`texpired-row"
Add-Content -Path $db -Value $expired -Encoding UTF8
& .\build\lstore.exe --db $db --cleanup | Out-Null
if ($LASTEXITCODE -ne 0) { throw "FAIL: --cleanup returned non-zero exit code" }
$afterCleanup = Get-Content $db -Raw
if ($afterCleanup -match "expired-row") {
    throw "FAIL: --cleanup did not remove expired row"
}
Write-Host "PASS: --cleanup removes expired rows" -ForegroundColor Green

# 5. --count: valid record count
$count = (& .\build\lstore.exe --db $db --count).Trim()
if ([int]$count -le 0) {
    throw "FAIL: --count returned invalid value: $count"
}
Write-Host "PASS: --count returns $count valid record(s)" -ForegroundColor Green

Write-Host ""
Write-Host "== all tests passed ==" -ForegroundColor Cyan
