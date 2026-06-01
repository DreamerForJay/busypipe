#!/usr/bin/env bash
# =============================================================================
# build_busybox.sh — BusyPipe 第三層驗證：完整 BusyBox 整合自動建置腳本
#
# 執行步驟：
#   1. 下載 BusyBox 1.36.1 原始碼
#   2. 複製 BusyPipe applet 檔案與共用函式庫
#   3. Patch 四個 BusyBox 建置設定檔
#   4. make defconfig + 啟用三個 applet + make
#   5. 驗證 --help 與完整管線
#   6. 將編譯完成的 busybox binary 複製至 build/busybox
#
# 使用方式（在專案根目錄，需要 Linux / Docker）：
#   bash scripts/build_busybox.sh
#
# 或透過 Docker（Windows）：
#   powershell -ExecutionPolicy Bypass -File scripts\run_busybox_build.ps1
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BB_VERSION="1.36.1"
BB_TARBALL="busybox-${BB_VERSION}.tar.bz2"
BB_DIR="${ROOT}/busybox-${BB_VERSION}"
BB_URL="https://busybox.net/downloads/${BB_TARBALL}"

echo "============================================================"
echo "  BusyPipe × BusyBox ${BB_VERSION} 整合建置"
echo "============================================================"

# --- 0. 確認必要工具 ---
for cmd in gcc make wget tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[錯誤] 找不到 $cmd，請先安裝。"
        exit 1
    fi
done

# --- 1. 下載並解壓縮 BusyBox 原始碼 ---
echo ""
echo "=== 步驟 1：下載 BusyBox ${BB_VERSION} ==="
cd "$ROOT"
if [ ! -d "$BB_DIR" ]; then
    if [ ! -f "$BB_TARBALL" ]; then
        echo "下載 ${BB_URL} ..."
        wget -q --show-progress "$BB_URL"
    fi
    echo "解壓縮 ${BB_TARBALL} ..."
    tar xf "$BB_TARBALL"
else
    echo "已存在 ${BB_DIR}，跳過下載與解壓縮。"
    echo "若需從頭重新建置，請先刪除該目錄：rm -rf ${BB_DIR}"
fi

cd "$BB_DIR"

# --- 2. 複製 BusyPipe 檔案 ---
echo ""
echo "=== 步驟 2：複製 BusyPipe 檔案至 BusyBox 原始碼樹 ==="

cp "${ROOT}/busybox/lparser_bb.c"  miscutils/lparser.c
cp "${ROOT}/busybox/lfilter_bb.c"  miscutils/lfilter.c
cp "${ROOT}/busybox/lstore_bb.c"   miscutils/lstore.c
cp "${ROOT}/busybox/libpipe.c"     libbb/busypipe_lib.c
cp "${ROOT}/busybox/libpipe.h"     include/libpipe.h

echo "  miscutils/lparser.c   ← lparser_bb.c"
echo "  miscutils/lfilter.c   ← lfilter_bb.c"
echo "  miscutils/lstore.c    ← lstore_bb.c"
echo "  libbb/busypipe_lib.c  ← libpipe.c"
echo "  include/libpipe.h     ← libpipe.h"

# --- 3. Patch BusyBox 建置設定檔 ---
echo ""
echo "=== 步驟 3：Patch BusyBox 建置設定檔 ==="

# 3a. include/applets.h — 加入三個 APPLET() 宣告
if ! grep -q "IF_LPARSER" include/applets.h; then
    cat >> include/applets.h << 'EOF'
IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))
IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
IF_LSTORE( APPLET(lstore,  BB_DIR_USR_BIN, BB_SUID_DROP))
EOF
    echo "  [PATCH] include/applets.h — 加入 IF_LFILTER / IF_LPARSER / IF_LSTORE"
else
    echo "  [SKIP]  include/applets.h — 已存在，略過"
fi

# 3b. miscutils/Config.in — 加入三個 config block
if ! grep -q "config LPARSER" miscutils/Config.in; then
    cat >> miscutils/Config.in << 'EOF'

config LPARSER
	bool "lparser"
	default y
	help
	  lparser reads raw log lines from stdin and extracts named fields
	  using POSIX extended regular expressions, writing structured CSV
	  or JSONL output to stdout. Part of the BusyPipe ETL pipeline.

config LFILTER
	bool "lfilter"
	default y
	help
	  lfilter reads CSV from stdin, filters rows by condition, projects
	  fields, and writes CSV or JSONL output to stdout.

config LSTORE
	bool "lstore"
	default y
	help
	  lstore is a file-backed key-value store with TTL support.
	  It provides put/get/delete/list/cleanup/count operations.
EOF
    echo "  [PATCH] miscutils/Config.in — 加入 LPARSER / LFILTER / LSTORE config"
else
    echo "  [SKIP]  miscutils/Config.in — 已存在，略過"
fi

# 3c. miscutils/Kbuild — 加入目的檔規則與 -DBUSYBOX_BUILD
if ! grep -q "CONFIG_LPARSER" miscutils/Kbuild; then
    cat >> miscutils/Kbuild << 'EOF'
lib-$(CONFIG_LPARSER) += lparser.o
CFLAGS_lparser.o     += -DBUSYBOX_BUILD
lib-$(CONFIG_LFILTER) += lfilter.o
CFLAGS_lfilter.o     += -DBUSYBOX_BUILD
lib-$(CONFIG_LSTORE)  += lstore.o
CFLAGS_lstore.o      += -DBUSYBOX_BUILD
EOF
    echo "  [PATCH] miscutils/Kbuild — 加入 lparser / lfilter / lstore 規則"
else
    echo "  [SKIP]  miscutils/Kbuild — 已存在，略過"
fi

# 3d. libbb/Kbuild — 將共用函式庫加入 libbb.a
if ! grep -q "busypipe_lib" libbb/Kbuild; then
    echo "lib-y += busypipe_lib.o" >> libbb/Kbuild
    echo "  [PATCH] libbb/Kbuild — 加入 busypipe_lib.o"
else
    echo "  [SKIP]  libbb/Kbuild — 已存在，略過"
fi

# --- 4. 設定並編譯 ---
echo ""
echo "=== 步驟 4：設定 BusyBox 並編譯 ==="

make defconfig
# 啟用 BusyPipe applet
printf 'CONFIG_LPARSER=y\nCONFIG_LFILTER=y\nCONFIG_LSTORE=y\n' >> .config
# BusyBox 1.36.x 的 networking/tc.c 使用已從新版 kernel headers（6.x）移除的
# CBQ 常數（TCA_CBQ_MAX 等），在 gcc:14 / Debian bookworm 環境下會編譯失敗。
# 停用 tc applet 以迴避此上游相容性問題。
printf 'CONFIG_TC=n\n' >> .config
make oldconfig

echo ""
echo "開始編譯（make -j$(nproc)）..."
make -j"$(nproc)"

# --- 5. 複製結果 ---
echo ""
echo "=== 步驟 5：複製 busybox binary 至 build/ ==="
mkdir -p "${ROOT}/build"
cp busybox "${ROOT}/build/busybox"
echo "  build/busybox ← ${BB_DIR}/busybox"

# --- 6. 驗證 ---
echo ""
echo "=== 步驟 6：驗證 applet ==="

echo "--- ./busybox lparser --help ---"
./busybox lparser --help 2>&1 | head -5

echo ""
echo "--- ./busybox lfilter --help ---"
./busybox lfilter --help 2>&1 | head -5

echo ""
echo "--- ./busybox lstore --help ---"
./busybox lstore  --help 2>&1 | head -5

echo ""
echo "--- 完整管線測試 ---"
rm -f /tmp/bp_test.tsv

echo '192.168.0.2 - - [30/Apr/2026:08:00:00 +0800] "GET /index.html HTTP/1.1" 200 512' \
     '
192.168.0.3 - - [30/Apr/2026:08:00:01 +0800] "GET /admin HTTP/1.1" 404 128
192.168.0.4 - - [30/Apr/2026:08:00:02 +0800] "POST /login HTTP/1.1" 500 64' | \
    tr ' ' '\n' | grep -v '^$' | \
    awk 'NR==1{line=$0} NR>1{line=line" "$0} NR%11==0{print line; line=""} END{if(line!="")print line}' \
    > /tmp/bp_access.log 2>/dev/null || true

# 直接用 echo 產生單行測試資料
printf '%s\n' \
    '192.168.0.3 - - [30/Apr/2026:08:00:01 +0800] "GET /admin HTTP/1.1" 404 128' \
    '192.168.0.4 - - [30/Apr/2026:08:00:02 +0800] "POST /login HTTP/1.1" 500 64' \
    | ./busybox lparser --format nginx --csv \
    | ./busybox lfilter --where 'status>=400' \
    | ./busybox lstore  --db /tmp/bp_test.tsv --put --key-field ip --ttl 3600 --stats

echo ""
echo "--- lstore --list ---"
./busybox lstore --db /tmp/bp_test.tsv --list

echo ""
echo "--- lstore --count ---"
./busybox lstore --db /tmp/bp_test.tsv --count

rm -f /tmp/bp_test.tsv /tmp/bp_access.log

echo ""
echo "============================================================"
echo "  BusyBox 整合建置完成！"
echo "  binary 位置：${ROOT}/build/busybox"
echo "  使用方式：./build/busybox lparser --help"
echo "============================================================"
