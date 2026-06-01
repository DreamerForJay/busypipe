$ErrorActionPreference = "Stop"

# ── Windows 執行檔自動建置 ────────────────────────────────────────────────────
# lparser 在 Windows 上需要 regex.h，僅建置 lfilter 與 lstore。
# 若 gcc 不存在，請安裝 MinGW (https://www.mingw-w64.org/) 或改用 Docker。
function Ensure-Built {
    param([string[]]$Names)
    $needBuild = $Names | Where-Object { -not (Test-Path "build\$_.exe") }
    if (-not $needBuild) { return }

    if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
        Write-Host "找不到 gcc，請安裝 MinGW 或改用 Docker：" -ForegroundColor Red
        Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1"
        exit 1
    }

    Write-Host "正在建置工具（$($needBuild -join ', ')）..." -ForegroundColor Cyan
    $null = New-Item -ItemType Directory -Path "build" -Force
    if (-not (Test-Path "build\common.o")) {
        & gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 -c src\common.c -o build\common.o
        if ($LASTEXITCODE -ne 0) { throw "common.c 編譯失敗" }
    }
    foreach ($name in $needBuild) {
        & gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 "src\$name.c" build\common.o -o "build\$name"
        if ($LASTEXITCODE -ne 0) { throw "$name.c 編譯失敗" }
        if (-not (Test-Path "build\$name.exe")) { throw "build\$name.exe 建置後仍不存在" }
        Write-Host "  建置完成：build\$name.exe" -ForegroundColor Green
    }
}

Ensure-Built @("lfilter", "lstore")

# ── Demo 資料準備 ──────────────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Path "data" -Force

$csv = @'
ip,time,method,path,status
192.168.0.2,30/Apr/2026:08:00:00 +0800,GET,/index.html,200
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@

$inputPath = "data\demo_input.csv"
$dbPath    = "data\demo.tsv"
$tmpPath   = "$dbPath.tmp"

if (Test-Path $dbPath)  { Remove-Item $dbPath  -Force }
if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force }

Set-Content -Path $inputPath -Value $csv -Encoding ascii

# ── Demo 開始 ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "== BusyPipe MVP Demo ==" -ForegroundColor Cyan

Write-Host ""
Write-Host "[1] 原始 CSV" -ForegroundColor Yellow
Get-Content $inputPath

Write-Host ""
Write-Host "[2] 過濾 status >= 400，投影 ip,path,status" -ForegroundColor Yellow
Get-Content $inputPath | .\build\lfilter.exe --where "status>=400" --select "ip,path,status"

Write-Host ""
Write-Host "[3] 寫入 demo.tsv（TTL 3600 秒）" -ForegroundColor Yellow
Get-Content $inputPath | .\build\lstore.exe --db $dbPath --put --key-field ip --ttl 3600
Get-Content $dbPath

Write-Host ""
Write-Host "[4] 查詢 key 192.168.0.4" -ForegroundColor Yellow
.\build\lstore.exe --db $dbPath --get 192.168.0.4

Write-Host ""
Write-Host "[5] 列出所有有效記錄" -ForegroundColor Yellow
.\build\lstore.exe --db $dbPath --list

Write-Host ""
Write-Host "== Demo 完成 ==" -ForegroundColor Cyan
