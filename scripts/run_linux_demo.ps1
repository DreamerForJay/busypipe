$ErrorActionPreference = "Stop"

Write-Host "== run BusyPipe Linux demo in Docker ==" -ForegroundColor Cyan

$projectRoot = (Resolve-Path ".").Path
$mountPath = $projectRoot -replace "\\", "/"
$mountPath = $mountPath -replace "^([A-Za-z]):", '$1:'

docker run --rm -v "${mountPath}:/work" -w /work gcc:14 sh scripts/linux_pipeline_demo.sh
