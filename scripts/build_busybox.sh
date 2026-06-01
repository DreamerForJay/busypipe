#!/usr/bin/env bash
# =============================================================================
# build_busybox.sh — BusyPipe 第三層驗證：完整 BusyBox 整合自動建置腳本
#
# 執行步驟：
#   1. 下載 BusyBox 1.36.1 原始碼
#   2. 複製 BusyPipe applet 檔案與共用函式庫
#   3. Patch 四個 BusyBox 建置設定檔
#   4. make allnoconfig + 啟用三個 applet + make
#      （allnoconfig 只啟用我們指定的 applet，避免 defconfig 啟用的大量
#        applet 與新版 kernel headers 產生相容性問題）
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

# 3a. include/applets.h — 直接用 APPLET() 宣告（不用 IF_XXX 包裝）
# IF_LPARSER() 需要 Kconfig 先定義 CONFIG_LPARSER，才能展開。
# 直接用 APPLET() 完全繞過 Kconfig，確保 applet 一定被編進 binary。
if ! grep -q "APPLET(lparser" include/applets.h; then
    cat >> include/applets.h << 'EOF'
APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP)
APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP)
APPLET(lstore,  BB_DIR_USR_BIN, BB_SUID_DROP)
EOF
    echo "  [PATCH] include/applets.h — 加入 APPLET(lfilter/lparser/lstore)"
else
    echo "  [SKIP]  include/applets.h — 已存在，略過"
fi

# 3b. miscutils/Config.in — 加入 config block（menuconfig 顯示用，不影響編譯）
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
    echo "  [PATCH] miscutils/Config.in — 加入 LPARSER / LFILTER / LSTORE config（選用）"
else
    echo "  [SKIP]  miscutils/Config.in — 已存在，略過"
fi

# 3c. miscutils/Kbuild — 用 lib-y 無條件編譯（不依賴 CONFIG_LPARSER）
# lib-$(CONFIG_LPARSER) 需要 Kconfig 認識符號才有效；
# lib-y 直接加入 Kbuild，確保 lparser.o / lfilter.o / lstore.o 一定被編譯。
if ! grep -q "lparser.o" miscutils/Kbuild; then
    cat >> miscutils/Kbuild << 'EOF'
lib-y            += lparser.o
CFLAGS_lparser.o += -DBUSYBOX_BUILD
lib-y            += lfilter.o
CFLAGS_lfilter.o += -DBUSYBOX_BUILD
lib-y            += lstore.o
CFLAGS_lstore.o  += -DBUSYBOX_BUILD
EOF
    echo "  [PATCH] miscutils/Kbuild — 加入 lparser / lfilter / lstore（lib-y）"
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

# applet 編譯完全由 lib-y 與直接 APPLET() 宣告控制，不依賴 Kconfig。
# allnoconfig 只用來產生乾淨的基底設定，不需要 oldconfig 或 sed。
make allnoconfig

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

# 先確認三個 applet 都已編譯進 binary
echo "--- ./busybox --list ---"
./busybox --list

for applet in lparser lfilter lstore; do
    if ./busybox --list | grep -q "^${applet}$"; then
        echo "[PASS] ${applet} 已編譯進 busybox binary"
    else
        echo "[FAIL] ${applet} 未出現在 busybox --list"
        exit 1
    fi
done

echo ""
echo "--- lparser --help（前 5 行）---"
./busybox lparser --help 2>&1 | head -5 || true

echo ""
echo "--- lfilter --help（前 5 行）---"
./busybox lfilter --help 2>&1 | head -5 || true

echo ""
echo "--- lstore --help（前 5 行）---"
./busybox lstore  --help 2>&1 | head -5 || true

echo ""
echo "--- 完整管線測試 ---"
rm -f /tmp/bp_test.tsv

# 產生測試資料（兩筆 4xx/5xx 記錄）
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
