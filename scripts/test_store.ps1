$ErrorActionPreference = "Stop"

# ── Windows 執行檔自動建置 ────────────────────────────────────────────────────
function Ensure-Built {
    param([string[]]$Names)
    $needBuild = $Names | Where-Object { -not (Test-Path "build\$_.exe") }
    if (-not $needBuild) { return }

    if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
        Write-Host "找不到 gcc，請安裝 MinGW (https://www.mingw-w64.org/) 或改用 Docker：" -ForegroundColor Red
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

Ensure-Built @("lstore")

# ── lstore 回歸測試 ───────────────────────────────────────────────────────────
Write-Host "== test lstore ==" -ForegroundColor Cyan

$null = New-Item -ItemType Directory -Path "data" -Force
$db  = "data\test_store.tsv"
$tmp = "$db.tmp"

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

# 1. --put：寫入兩批資料
$csv1 | .\build\lstore.exe --db $db --put --key-field ip --ttl 3600
$csv2 | .\build\lstore.exe --db $db --put --key-field ip --ttl 3600

# 2. --get：回傳最新記錄（應包含 503）
$latest = (& .\build\lstore.exe --db $db --get 192.168.0.4).Trim()
if ($latest -notmatch "503$") {
    throw "FAIL get latest value: $latest"
}
Write-Host "PASS: --get 回傳最新記錄（含 503）" -ForegroundColor Green

# 3. --delete：刪除指定 key
& .\build\lstore.exe --db $db --delete 192.168.0.3 | Out-Null
$afterDelete = & .\build\lstore.exe --db $db --list
if ($afterDelete -match "192\.168\.0\.3") {
    throw "FAIL: delete 未移除目標 key"
}
Write-Host "PASS: --delete 正確移除目標 key" -ForegroundColor Green

# 4. --cleanup：清除過期記錄
$expired = "192.168.0.9`t1`texpired-row"
Add-Content -Path $db -Value $expired -Encoding UTF8
& .\build\lstore.exe --db $db --cleanup | Out-Null
if ($LASTEXITCODE -ne 0) { throw "FAIL: --cleanup 回傳非零 exit code" }
$afterCleanup = Get-Content $db -Raw
if ($afterCleanup -match "expired-row") {
    throw "FAIL: --cleanup 未移除過期記錄"
}
Write-Host "PASS: --cleanup 正確移除過期記錄" -ForegroundColor Green

# 5. --count：計算有效筆數
$count = (& .\build\lstore.exe --db $db --count).Trim()
if ([int]$count -le 0) {
    throw "FAIL: --count 回傳值無效：$count"
}
Write-Host "PASS: --count 回傳 $count 筆有效記錄" -ForegroundColor Green

Write-Host ""
Write-Host "== all tests passed ==" -ForegroundColor Cyan
