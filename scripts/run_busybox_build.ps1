$ErrorActionPreference = "Stop"

# Run BusyBox integration build inside Docker (for Windows).
# Result: build/busybox binary accessible on the host via volume mount.

Write-Host "== BusyPipe x BusyBox Integration Build ==" -ForegroundColor Cyan
Write-Host "Running inside Docker (gcc:14 / Debian)..." -ForegroundColor Cyan
Write-Host ""

$projectRoot = (Resolve-Path ".").Path
$mountPath   = ($projectRoot -replace "\\", "/") -replace "^([A-Za-z]):", '/$1'

docker run --rm `
    -v "${mountPath}:/work" `
    -w /work `
    gcc:14 `
    bash -c "apt-get install -y -q wget bzip2 2>/dev/null; bash scripts/build_busybox.sh"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Build succeeded." -ForegroundColor Green
    Write-Host "Binary: build\busybox (run inside Docker or Linux)"
} else {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}
