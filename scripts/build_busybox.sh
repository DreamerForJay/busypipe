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

echo "--- 診斷 A：gen_build_files.sh 後的結果 ---"
echo "[A1] applets.h IF_LXXX 項目（最後 20 行 + 搜尋）："
tail -20 include/applets.h
echo "---"
grep -n "IF_LPARSER\|IF_LFILTER\|IF_LSTORE" include/applets.h \
    || echo "  [A1-FAIL] IF_LXXX 未在 applets.h（directive 未被處理）"
echo "[A2] Config.in LPARSER 項目："
grep -n "LPARSER\|LFILTER\|LSTORE" miscutils/Config.in || echo "  (未找到)"
echo "[A3] Kbuild LPARSER 項目："
grep -n "LPARSER\|LFILTER\|LSTORE" miscutils/Kbuild || echo "  (未找到)"
echo "[A4] libbb/Kbuild busypipe_lib 項目："
grep -n "busypipe_lib" libbb/Kbuild || echo "  [A4-FAIL] busypipe_lib 未在 libbb/Kbuild"

# --- 4. 設定並編譯 ---
echo ""
echo "=== 步驟 4：make defconfig ==="
# make defconfig 尊重 Config.in 的 default y，CONFIG_LPARSER=y 自動設定
make defconfig

echo "--- 診斷 B：make defconfig 後 ---"
echo "[B1] .config 中 applet 狀態："
grep -E 'CONFIG_LPARSER|CONFIG_LFILTER|CONFIG_LSTORE|CONFIG_TC' .config \
    || echo "  [B1-FAIL] LPARSER/LFILTER/LSTORE 未出現"

# 停用 networking/tc（BusyBox 1.36.x + kernel 6.x header TCA_CBQ_MAX 不相容）
if grep -q "^CONFIG_TC=y" .config; then
    sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
    echo "  [SED] CONFIG_TC=y → n（避免 kernel 6.x header 編譯錯誤）"
fi

echo "[B2] autoconf.h 中 CONFIG_LXXX（make defconfig 後，silentoldconfig 前）："
grep -E 'CONFIG_LPARSER|CONFIG_LFILTER|CONFIG_LSTORE' include/autoconf.h 2>/dev/null \
    | grep -v 'MAKE_SUID\|IF_NOT_\|ENABLE_' \
    || echo "  [B2-FAIL] CONFIG_LXXX 未在 autoconf.h（Kconfig 未正確寫入）"

# silentoldconfig：確保 autoconf.h 在平行建置開始前已正確產生。
# BusyBox 1.36.x confdata.c 在 #ifdef MAKE_SUID 分支產生
#   "# define IF_LFILTER(...) __VA_ARGS__ \"CONFIG_LFILTER\""
# 這是刻意設計（用於 SUID table），正常編譯不走此分支，完全無害。
echo ""
echo "=== 步驟 4b：silentoldconfig（確保 autoconf.h 正確再平行建置）==="
make silentoldconfig

echo "[B3] autoconf.h CONFIG_LXXX（silentoldconfig 後，僅顯示 #define 行）："
grep -E '^#define CONFIG_L(PARSER|FILTER|STORE) ' include/autoconf.h 2>/dev/null \
    || echo "  [B3-FAIL] CONFIG_LXXX #define 未在 autoconf.h"

echo ""
echo "=== 步驟 4c：序列化產生 applet_tables（消除 -j 競態）==="
# BusyBox Kbuild.src 自己承認（第 47-53 行）：
#   include/NUM_APPLETS.h 和 include/applet_tables.h 都由
#   applets/applet_tables 產生。make -j 可能同時觸發兩個建置目標，
#   第一次執行寫入 applet_tables.h(T1) 後再寫 NUM_APPLETS.h(T2)，
#   造成 T2 > T1。make 看到此 timestamp 反轉，排程第二次執行；
#   同時 applets/applets.c（依賴 applet_tables.h）也被排程編譯——
#   兩個 job 同時讀/寫 applet_tables.h，導致半寫入的檔案被編譯，
#   隨機缺失一個 applet。
# 解法：在 -j 建置前序列化完成 applet_tables 全部相關目標。
make applets/applet_tables
make include/NUM_APPLETS.h include/applet_tables.h
# applet_tables.c 固定先 rename applet_tables.h、後 rename NUM_APPLETS.h
# （見原始碼第 239-241 行），所以每次執行後 T(NUM_APPLETS.h) > T(applet_tables.h)。
# make -j8 看到此 timestamp 反轉，仍會排程重建 applet_tables.h，
# 與 applets/applets.c 的編譯形成競態。
# 修法：touch applet_tables.h 使其 timestamp > NUM_APPLETS.h，
# 讓 make -j8 認為它已是最新，不再重建。
touch include/applet_tables.h

echo "[C1] applet_tables.h 中 lXXX 項目（序列化後）："
grep -n '"lparser"\|"lfilter"\|"lstore"' include/applet_tables.h 2>/dev/null \
    || echo "  [C1-FAIL] lXXX 未在 applet_tables.h——applet_tables host binary 問題"

echo ""
echo "=== 步驟 5：make -j$(nproc) ==="
# 以 tee 保存 make 輸出，同時顯示；失敗時輸出最後 40 行供診斷
MAKE_LOG=$(mktemp)
make -j"$(nproc)" 2>&1 | tee "$MAKE_LOG"; MAKE_RC=${PIPESTATUS[0]}
if [ "$MAKE_RC" -ne 0 ]; then
    echo "  [MAKE-FAIL] make 回傳 $MAKE_RC，最後 40 行："
    tail -40 "$MAKE_LOG"
    rm -f "$MAKE_LOG"
    exit "$MAKE_RC"
fi
rm -f "$MAKE_LOG"

# --- 6. 診斷：nm 確認 symbol（需用 unstripped binary）---
echo ""
echo "=== 步驟 6：nm 診斷 ==="
# BusyBox 預設 strip busybox，需用 busybox_unstripped 確認符號
NM_TARGET="busybox_unstripped"
[ -f "$NM_TARGET" ] || NM_TARGET="busybox"
nm "$NM_TARGET" 2>/dev/null | grep -E 'lparser_main|lfilter_main|lstore_main' \
    && echo "  [OK] lXXX_main symbols 在 ${NM_TARGET} 中" \
    || echo "  [NM-WARN] lXXX_main 不在 ${NM_TARGET}（${NM_TARGET} 可能已 strip 或 compile/link 失敗）"

# applet_tables.h 診斷：確認 make -j 後 lXXX 仍在排序表（偵測 race condition 回覆）
echo "[C2] applet_tables.h 中 lXXX 項目（make -j 後）："
grep -n '"lparser"\|"lfilter"\|"lstore"' include/applet_tables.h 2>/dev/null \
    || echo "  [C2-FAIL] lXXX 不在 applet_tables.h（make -j 的 race condition 仍存在）"

# --- 7. 複製結果並驗證 ---
echo ""
echo "=== 步驟 7：複製 binary 並驗證 ==="
mkdir -p "${ROOT}/build"
cp busybox "${ROOT}/build/busybox"
echo "  build/busybox ← ${BB_DIR}/busybox"

echo ""
echo "--- busybox --list ---"
./busybox --list

# busybox --list 用 full_write2_str (fd 2) 輸出，不是 fd 1。
# 在 pipe 中 dup2(1,2) 將 fd 2 重定向到 pipe，但 set -o pipefail 下
# 若 busybox 在 grep 找到 pattern 後關閉 pipe 端時收到 SIGPIPE，
# pipefail 會把 SIGPIPE 的非零 exit code 傳回，造成誤判。
# 改用直接呼叫 applet --help 測試（回傳 0 = applet 存在且正常）。
for applet in lparser lfilter lstore; do
    if ./busybox "${applet}" --help > /dev/null 2>&1; then
        echo "[PASS] ${applet} 在 busybox binary 中"
    else
        echo "[FAIL] ${applet} 未出現或無法執行"
        # 輔助診斷：用兩種方式確認 applet 是否在 --list
        echo "  [DBG] --list 搜尋結果："
        ./busybox --list 2>&1 | { grep "${applet}" || echo "  (未找到)"; }
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
