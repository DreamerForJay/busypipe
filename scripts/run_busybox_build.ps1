$ErrorActionPreference = "Stop"

# Run BusyBox integration build inside Docker (Windows launcher).
# Mounts the project directory so the result binary is accessible on the host.

Write-Host "== BusyPipe x BusyBox Integration Build ==" -ForegroundColor Cyan

$projectRoot = (Resolve-Path ".").Path
$mountPath   = ($projectRoot -replace "\\", "/") -replace "^([A-Za-z]):", '/$1'

docker run --rm `
    -v "${mountPath}:/work" `
    -w /work `
    gcc:14 `
    bash -c "apt-get install -y -q wget bzip2 2>/dev/null; rm -rf busybox-1.36.1 busybox-1.36.1.tar.bz2; bash scripts/build_busybox.sh"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Build succeeded. Binary: build/busybox" -ForegroundColor Green
} else {
    Write-Host "Build failed (exit $LASTEXITCODE)." -ForegroundColor Red
    exit 1
}
