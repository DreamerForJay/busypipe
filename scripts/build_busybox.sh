#!/usr/bin/env bash
# =============================================================================
# build_busybox.sh — BusyPipe 第三層驗證：完整 BusyBox 整合自動建置
#
# 設計原則：
#   - Config.in 用 printf '\t' 寫入，避免 heredoc tab/space 歧義
#   - applets.h 用 awk 在正確字母順序位置插入（維持 binary search 正確性）
#   - make defconfig 尊重 Config.in 的 default y，自動啟用三個 applet
#   - sed 只停用 networking/tc.c（BusyBox 1.36.x + kernel 6.x header 不相容）
#   - 不使用 make oldconfig（避免重新處理覆蓋設定）
#   - nm 診斷確認 lXXX_main 確實編進 binary
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BB_VERSION="1.36.1"
BB_TARBALL="busybox-${BB_VERSION}.tar.bz2"
BB_DIR="${ROOT}/busybox-${BB_VERSION}"
BB_URL="https://busybox.net/downloads/${BB_TARBALL}"

echo "============================================================"
echo "  BusyPipe x BusyBox ${BB_VERSION} 整合建置"
echo "============================================================"

for cmd in gcc make wget tar awk sed nm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "[ERROR] 找不到 $cmd"; exit 1; }
done

# --- 1. 下載並解壓縮 ---
echo ""
echo "=== 步驟 1：下載 BusyBox ${BB_VERSION} ==="
cd "$ROOT"
if [ ! -d "$BB_DIR" ]; then
    [ -f "$BB_TARBALL" ] || wget -q --show-progress "$BB_URL"
    tar xf "$BB_TARBALL"
else
    echo "已存在 ${BB_DIR}，跳過。（重新建置請先 rm -rf ${BB_DIR}）"
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
echo "  miscutils/{lparser,lfilter,lstore}.c"
echo "  libbb/busypipe_lib.c  include/libpipe.h"

# --- 3. Patch BusyBox 建置設定檔 ---
echo ""
echo "=== 步驟 3：Patch BusyBox 建置設定檔 ==="

# 3a. include/applets.h — 用 awk 在字母順序正確位置插入 IF_XXX(APPLET())
#     字母順序：lfilter(lfi) < link(li)，lparser(lpa) < ls，lstore(lst) < lsusb(lsu)
#     BusyBox 用 binary search 查 applet，需維持排序正確性。
if ! grep -q "IF_LPARSER" include/applets.h; then
    awk '
        # lfilter 插在第一個 IF_LI* 或 IF_LS* 前（lf < li < ln < lo < ls）
        /^IF_LI[A-Z_]*\(|^IF_LN\(|^IF_LO[A-Z_]*\(/ && !f {
            print "IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))"
            f=1
        }
        # lparser 插在第一個 IF_LS* 前（lp < ls）
        /^IF_LS[A-Z_]*\(|^IF_LS\(/ && !p {
            print "IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))"
            p=1
        }
        # lstore 插在 IF_LSUSB 或第一個 IF_LT*/IF_M* 前（lst < lsu < lt < m）
        /^IF_LSUSB\(|^IF_LT[A-Z_]*\(|^IF_M[A-Z_]*\(/ && !s {
            print "IF_LSTORE( APPLET(lstore,  BB_DIR_USR_BIN, BB_SUID_DROP))"
            s=1
        }
        { print }
        END {
            if (!f) print "IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))"
            if (!p) print "IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))"
            if (!s) print "IF_LSTORE( APPLET(lstore,  BB_DIR_USR_BIN, BB_SUID_DROP))"
        }
    ' include/applets.h > include/applets.h.new
    mv include/applets.h.new include/applets.h
    echo "  [PATCH] include/applets.h（awk 字母順序插入）"
    echo "  [DIAG]  applets.h 中 LPARSER 附近內容："
    grep -n "LPARSER\|LFILTER\|LSTORE" include/applets.h
else
    echo "  [SKIP]  include/applets.h"
fi

# 3b. miscutils/Config.in — 用 printf '\t' 確保真正的 tab 字元
#     避免 heredoc 在 shell 腳本中 tab/space 混淆（Kconfig 解析靜默失敗的根因）
if ! grep -q "config LPARSER" miscutils/Config.in; then
    {
        printf '\nconfig LPARSER\n'
        printf '\tbool "lparser"\n'
        printf '\tdefault y\n'
        printf '\thelp\n'
        printf '\t  Log parser applet. Part of BusyPipe embedded ETL pipeline.\n'
        printf '\nconfig LFILTER\n'
        printf '\tbool "lfilter"\n'
        printf '\tdefault y\n'
        printf '\thelp\n'
        printf '\t  CSV stream filter applet. Part of BusyPipe.\n'
        printf '\nconfig LSTORE\n'
        printf '\tbool "lstore"\n'
        printf '\tdefault y\n'
        printf '\thelp\n'
        printf '\t  File-backed key-value store applet. Part of BusyPipe.\n'
    } >> miscutils/Config.in
    echo "  [PATCH] miscutils/Config.in（printf 確保 tab 字元）"
    echo "  [DIAG]  Config.in 最後 15 行（^I = tab）："
    tail -15 miscutils/Config.in | cat -A
else
    echo "  [SKIP]  miscutils/Config.in"
fi

# 3c. miscutils/Kbuild — Kconfig 控制編譯 + -DBUSYBOX_BUILD
if ! grep -q "CONFIG_LPARSER" miscutils/Kbuild; then
    printf 'lib-$(CONFIG_LPARSER) += lparser.o\n' >> miscutils/Kbuild
    printf 'CFLAGS_lparser.o     += -DBUSYBOX_BUILD\n' >> miscutils/Kbuild
    printf 'lib-$(CONFIG_LFILTER) += lfilter.o\n' >> miscutils/Kbuild
    printf 'CFLAGS_lfilter.o     += -DBUSYBOX_BUILD\n' >> miscutils/Kbuild
    printf 'lib-$(CONFIG_LSTORE)  += lstore.o\n' >> miscutils/Kbuild
    printf 'CFLAGS_lstore.o      += -DBUSYBOX_BUILD\n' >> miscutils/Kbuild
    echo "  [PATCH] miscutils/Kbuild"
else
    echo "  [SKIP]  miscutils/Kbuild"
fi

# 3d. libbb/Kbuild — 共用函式庫加入 libbb.a
if ! grep -q "busypipe_lib" libbb/Kbuild; then
    printf 'lib-y += busypipe_lib.o\n' >> libbb/Kbuild
    echo "  [PATCH] libbb/Kbuild"
else
    echo "  [SKIP]  libbb/Kbuild"
fi

# --- 4. 設定並編譯 ---
echo ""
echo "=== 步驟 4：設定 BusyBox ==="

# make defconfig 尊重 Config.in 的 default y，
# 若 Config.in 正確解析，CONFIG_LPARSER=y 會自動出現。
make defconfig

echo "--- .config 中 applet 狀態 ---"
grep -E 'CONFIG_LPARSER|CONFIG_LFILTER|CONFIG_LSTORE|CONFIG_TC' .config \
    || echo "  (LPARSER/LFILTER/LSTORE 未出現 — Config.in 解析仍失敗)"

# 停用 networking/tc（BusyBox 1.36.x 使用已從 kernel 6.x headers 移除的 TCA_CBQ_MAX 等常數）
if grep -q "^CONFIG_TC=y" .config; then
    sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
    echo "  [SED] CONFIG_TC=y → n"
fi

# 若 defconfig 未設定（Config.in 解析成功但 default 未生效），用 sed 補救
for sym in LPARSER LFILTER LSTORE; do
    if grep -q "# CONFIG_${sym} is not set" .config; then
        sed -i "s/# CONFIG_${sym} is not set/CONFIG_${sym}=y/" .config
        echo "  [SED] # CONFIG_${sym} is not set → CONFIG_${sym}=y"
    fi
done

echo "--- .config 最終狀態 ---"
grep -E 'CONFIG_LPARSER|CONFIG_LFILTER|CONFIG_LSTORE|CONFIG_TC' .config

echo ""
echo "開始編譯（make -j$(nproc)）..."
make -j"$(nproc)"

# --- 5. 診斷與驗證 ---
echo ""
echo "=== 步驟 5：診斷 — nm 確認 symbol ==="
echo "--- nm: lXXX_main in binary ---"
nm busybox 2>/dev/null | grep -E 'lparser_main|lfilter_main|lstore_main' \
    || echo "  [WARN] lXXX_main 不在 binary 中（compile/link 問題）"

echo ""
echo "=== 步驟 6：複製 busybox binary 至 build/ ==="
mkdir -p "${ROOT}/build"
cp busybox "${ROOT}/build/busybox"
echo "  build/busybox ← ${BB_DIR}/busybox"

echo ""
echo "=== 步驟 7：驗證 applet ==="
echo "--- busybox --list ---"
./busybox --list

for applet in lparser lfilter lstore; do
    if ./busybox --list | grep -q "^${applet}$"; then
        echo "[PASS] ${applet} 在 busybox --list 中"
    else
        echo "[FAIL] ${applet} 未出現在 busybox --list"
        exit 1
    fi
done

echo ""
echo "--- lparser --help ---"
./busybox lparser --help 2>&1 | head -5 || true

echo ""
echo "--- 管線測試 ---"
rm -f /tmp/bp_test.tsv
printf '%s\n' \
    '192.168.0.3 - - [30/Apr/2026:08:00:01 +0800] "GET /admin HTTP/1.1" 404 128' \
    '192.168.0.4 - - [30/Apr/2026:08:00:02 +0800] "POST /login HTTP/1.1" 500 64' \
    | ./busybox lparser --format nginx --csv \
    | ./busybox lfilter --where 'status>=400' \
    | ./busybox lstore  --db /tmp/bp_test.tsv --put --key-field ip --ttl 3600 --stats

echo "--- lstore --list ---"
./busybox lstore --db /tmp/bp_test.tsv --list
rm -f /tmp/bp_test.tsv

echo ""
echo "============================================================"
echo "  整合建置完成！binary：${ROOT}/build/busybox"
echo "  ./build/busybox lparser --format nginx --csv < samples/access.log"
echo "============================================================"
