$ErrorActionPreference = "Stop"

Write-Host "== BusyPipe MVP Demo ==" -ForegroundColor Cyan

$csv = @'
ip,time,method,path,status
192.168.0.2,30/Apr/2026:08:00:00 +0800,GET,/index.html,200
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@

$inputPath = "data\demo_input.csv"
$dbPath = "data\demo.tsv"
$tmpPath = "$dbPath.tmp"

if (Test-Path $dbPath) {
    Remove-Item $dbPath -Force
}
if (Test-Path $tmpPath) {
    Remove-Item $tmpPath -Force
}

Set-Content -Path $inputPath -Value $csv -Encoding ascii

Write-Host ""
Write-Host "[1] Raw CSV" -ForegroundColor Yellow
Get-Content $inputPath

Write-Host ""
Write-Host "[2] Filter rows where status >= 400" -ForegroundColor Yellow
Get-Content $inputPath | .\build\lfilter.exe --where "status>=400" --select "ip,path,status"

Write-Host ""
Write-Host "[3] Store rows into demo.tsv" -ForegroundColor Yellow
Get-Content $inputPath | .\build\lstore.exe --db $dbPath --put --key-field ip --ttl 3600
Get-Content $dbPath

Write-Host ""
Write-Host "[4] Query key 192.168.0.4" -ForegroundColor Yellow
.\build\lstore.exe --db $dbPath --get 192.168.0.4
