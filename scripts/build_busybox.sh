#!/usr/bin/env bash
# =============================================================================
# build_busybox.sh — BusyPipe x BusyBox 整合建置（directive-based 方案）
#
# 現代 BusyBox（1.36.x）以 scripts/gen_build_files.sh 掃描 .c 原始檔中的：
#   //applet:  → 自動寫入 include/applets.src.h
#   //kbuild:  → 自動寫入 miscutils/Kbuild
#   //config:  → 自動寫入 miscutils/Config.in
# 只要 *_bb.c 包含這些 directive，gen_build_files.sh 就會產生正確的 patch。
# 這是 BusyBox 官方推薦的 applet 整合方式，不需要手動修改任何 generated file。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BB_VERSION="1.36.1"
BB_TARBALL="busybox-${BB_VERSION}.tar.bz2"
BB_DIR="${ROOT}/busybox-${BB_VERSION}"
BB_URL="https://busybox.net/downloads/${BB_TARBALL}"

echo "============================================================"
echo "  BusyPipe x BusyBox ${BB_VERSION} 整合建置（directive-based）"
echo "============================================================"

for cmd in gcc make wget tar awk sed nm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] 找不到 $cmd"; exit 1; }
done

# --- 1. 下載並解壓縮 ---
echo ""
echo "=== 步驟 1：下載 BusyBox ${BB_VERSION} ==="
cd "$ROOT"
if [ ! -d "$BB_DIR" ]; then
    # 下載前先驗證既有 tarball；若損壞則刪除重新下載
    if [ -f "$BB_TARBALL" ]; then
        echo "  驗證既有 tarball 完整性..."
        if ! tar tf "$BB_TARBALL" >/dev/null 2>&1; then
            echo "  tarball 不完整，刪除後重新下載..."
            rm -f "$BB_TARBALL"
        fi
    fi
    [ -f "$BB_TARBALL" ] || wget -q --show-progress "$BB_URL"
    echo "  解壓縮 ${BB_TARBALL} ..."
    tar xjf "$BB_TARBALL"   # 明確指定 -j（bzip2），避免自動偵測失敗
    if [ ! -f "${BB_DIR}/include/applets.src.h" ]; then
        echo "[ERROR] 解壓縮後找不到 include/applets.src.h"
        echo "  已解壓縮的檔案："
        ls "${BB_DIR}/" 2>/dev/null || echo "  (目錄不存在)"
        exit 1
    fi
    echo "  解壓縮完成。"
else
    echo "  已存在 ${BB_DIR}，跳過下載。"
    if [ ! -f "${BB_DIR}/include/applets.src.h" ]; then
        echo "[ERROR] ${BB_DIR}/include/applets.src.h 不存在（不完整的舊目錄）。"
        echo "  解決方法：rm -rf '${BB_DIR}' 後重新執行。"
        exit 1
    fi
fi

cd "$BB_DIR"

# --- 2. 複製 BusyPipe 檔案 ---
echo ""
echo "=== 步驟 2：複製 BusyPipe 檔案 ==="
cp "${ROOT}/busybox/lparser_bb.c"  miscutils/lparser.c
cp "${ROOT}/busybox/lfilter_bb.c"  miscutils/lfilter.c
cp "${ROOT}/busybox/lstore_bb.c"   miscutils/lstore.c
cp "${ROOT}/busybox/libpipe.c"     libbb/busypipe_lib.c
cp "${ROOT}/busybox/libpipe.h"     include/libpipe.h
echo "  miscutils/{lparser,lfilter,lstore}.c（含 //applet: //kbuild: //config: directive）"
echo "  libbb/busypipe_lib.c（含 //kbuild:lib-y += busypipe_lib.o）  include/libpipe.h"

# --- 3. 執行 gen_build_files.sh ---
echo ""
echo "=== 步驟 3：執行 gen_build_files.sh（處理 //applet: //kbuild: //config:）==="

# 轉換 Windows CRLF → Unix LF（檔案由 Windows 工具建立，CRLF 會導致
# Kconfig "Overlong line" 錯誤與 usage.h 中的 stray '\' 問題）
for f in miscutils/lparser.c miscutils/lfilter.c miscutils/lstore.c libbb/busypipe_lib.c; do
    sed -i 's/\r//' "$f"
done
echo "  [CRLF] 已轉換 miscutils/*.c libbb/busypipe_lib.c 為 Unix LF"
bash scripts/gen_build_files.sh . .

# libbb/Kbuild 的 patch 必須在 gen_build_files.sh 之後——
# gen_build_files.sh 可能從 Kbuild.src 重新生成 libbb/Kbuild，
# 覆蓋我們先前的手動 patch。
# busypipe_lib.c 的 //kbuild: directive 應已處理，此行為保底。
if ! grep -q "busypipe_lib" libbb/Kbuild; then
    printf 'lib-y += busypipe_lib.o\n' >> libbb/Kbuild
    echo "  [PATCH] libbb/Kbuild += busypipe_lib.o（gen 後補）"
fi

echo "--- 診斷：gen_build_files.sh 後的結果 ---"
echo "[applets.h] IF_LPARSER 項目："
grep -n "IF_LPARSER\|IF_LFILTER\|IF_LSTORE" include/applets.h 2>/dev/null \
    || grep -n "LPARSER\|LFILTER\|LSTORE" include/applets.src.h 2>/dev/null \
    || echo "  (未找到)"
echo "[Config.in] LPARSER 項目："
grep -n "LPARSER\|LFILTER\|LSTORE" miscutils/Config.in || echo "  (未找到)"
echo "[Kbuild] LPARSER 項目："
grep -n "LPARSER\|LFILTER\|LSTORE" miscutils/Kbuild || echo "  (未找到)"
echo "[Config.in] 行 595-610（診斷 Overlong line 位置）："
sed -n '595,610p' miscutils/Config.in | cat -A

# --- 4. 設定並編譯 ---
echo ""
echo "=== 步驟 4：make defconfig ==="
# make defconfig 尊重 Config.in 的 default y，CONFIG_LPARSER=y 自動設定
make defconfig

echo "--- .config 中 applet 狀態 ---"
grep -E 'CONFIG_LPARSER|CONFIG_LFILTER|CONFIG_LSTORE|CONFIG_TC' .config \
    || echo "  (LPARSER/LFILTER/LSTORE 未出現 — gen_build_files.sh 可能未正確處理)"

# 停用 networking/tc（BusyBox 1.36.x + kernel 6.x header TCA_CBQ_MAX 不相容）
if grep -q "^CONFIG_TC=y" .config; then
    sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
    echo "  [SED] CONFIG_TC=y → n（避免 kernel 6.x header 編譯錯誤）"
fi

echo ""
echo "=== 步驟 5：make -j$(nproc) ==="
make -j"$(nproc)"

# --- 6. 診斷：nm 確認 symbol ---
echo ""
echo "=== 步驟 6：nm 診斷 ==="
nm busybox 2>/dev/null | grep -E 'lparser_main|lfilter_main|lstore_main' \
    && echo "  [OK] lXXX_main symbols 在 binary 中" \
    || echo "  [WARN] lXXX_main 不在 binary（compile/link 問題）"

# --- 7. 複製結果並驗證 ---
echo ""
echo "=== 步驟 7：複製 binary 並驗證 ==="
mkdir -p "${ROOT}/build"
cp busybox "${ROOT}/build/busybox"
echo "  build/busybox ← ${BB_DIR}/busybox"

echo ""
echo "--- busybox --list ---"
./busybox --list

for applet in lparser lfilter lstore; do
    if ./busybox --list | grep -q "^${applet}$"; then
        echo "[PASS] ${applet} 在 busybox binary 中"
    else
        echo "[FAIL] ${applet} 未出現（見上方診斷輸出）"
        exit 1
    fi
done

echo ""
echo "--- lparser --help ---"
./busybox lparser --help 2>&1 | head -6 || true

echo ""
echo "--- 完整管線測試 ---"
rm -f /tmp/bp_test.tsv
printf '%s\n' \
    '192.168.0.3 - - [30/Apr/2026:08:00:01 +0800] "GET /admin HTTP/1.1" 404 128' \
    '192.168.0.4 - - [30/Apr/2026:08:00:02 +0800] "POST /login HTTP/1.1" 500 64' \
    | ./busybox lparser --format nginx --csv \
    | ./busybox lfilter --where 'status>=400' \
    | ./busybox lstore  --db /tmp/bp_test.tsv --put --key-field ip --ttl 3600 --stats

./busybox lstore --db /tmp/bp_test.tsv --list
rm -f /tmp/bp_test.tsv

echo ""
echo "============================================================"
echo "  BusyBox 整合建置完成！"
echo "  binary：${ROOT}/build/busybox"
echo "============================================================"
