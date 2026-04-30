$ErrorActionPreference = "Stop"

Write-Host "== test lstore ==" -ForegroundColor Cyan

$db = "data\test_store.tsv"
$tmp = "$db.tmp"
if (Test-Path $db) {
    Remove-Item $db -Force
}
if (Test-Path $tmp) {
    Remove-Item $tmp -Force
}

$csv1 = @'
ip,time,method,path,status
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@

$csv2 = @'
ip,time,method,path,status
192.168.0.4,30/Apr/2026:09:00:03 +0800,POST,/login,503
'@

$csv1 | .\build\lstore.exe --db $db --put --key-field ip --ttl 3600
$csv2 | .\build\lstore.exe --db $db --put --key-field ip --ttl 3600

$latest = (& .\build\lstore.exe --db $db --get 192.168.0.4).Trim()
if ($latest -notmatch "503$") {
    throw "get latest value failed: $latest"
}
Write-Host "PASS: get returns latest row" -ForegroundColor Green

& .\build\lstore.exe --db $db --delete 192.168.0.3 | Out-Null
$afterDelete = & .\build\lstore.exe --db $db --list
if ($afterDelete -match "192\.168\.0\.3") {
    throw "delete did not remove target key"
}
Write-Host "PASS: delete removes target key" -ForegroundColor Green

$expired = "192.168.0.9`t1`texpired-row"
Add-Content -Path $db -Value $expired -Encoding UTF8
& .\build\lstore.exe --db $db --cleanup | Out-Null
$cleanupExit = $LASTEXITCODE
if ($cleanupExit -ne 0) {
    throw "cleanup failed with exit code $cleanupExit"
}
$afterCleanup = Get-Content $db -Raw
if ($afterCleanup -match "expired-row") {
    throw "cleanup did not remove expired row"
}
Write-Host "PASS: cleanup removes expired rows" -ForegroundColor Green

Write-Host "all tests passed" -ForegroundColor Cyan
