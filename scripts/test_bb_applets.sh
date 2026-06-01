#!/usr/bin/env sh
# =============================================================================
# test_bb_applets.sh — BusyBox applet 適配版全面驗證腳本
#
# 涵蓋三層驗證：
#   1. 編譯驗證：以 gcc 獨立建置 busybox/libpipe.c + *_bb.c
#      （不需要 BusyBox 原始碼；#ifndef BUSYBOX_BUILD 包裝提供 main()）
#   2. 功能驗證：lparser_main / lfilter_main / lstore_main 各自的行為正確性
#   3. 一致性驗證：applet 版輸出與 standalone 版本完全相同
#
# 使用方式（在專案根目錄）：
#   bash scripts/test_bb_applets.sh         # 直接執行
#   make test-bb                             # 透過 Makefile
#
# 或透過 Docker（Windows）：
#   docker run --rm -v "$PWD:/work" -w /work gcc:14 sh scripts/test_bb_applets.sh
#
# 注意：
#   第三層一致性驗證需要先執行 make 建置 standalone 版本。
#   完整 BusyBox 整合驗證（將 busybox binary 編入 busybox multi-call binary）
#   詳見 busybox/README-integration.md §5，需要下載 BusyBox 原始碼。
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_BB="$ROOT/build/bb_test"
BUILD_SA="$ROOT/build"
DATA_BB="$ROOT/data/bb_test"

mkdir -p "$BUILD_BB" "$DATA_BB"

PASS=0
FAIL=0
SKIP=0

ok()   { printf "[PASS] %s\n" "$*"; PASS=$((PASS+1)); }
fail() { printf "[FAIL] %s\n" "$*"; FAIL=$((FAIL+1)); }
skip() { printf "[SKIP] %s\n" "$*"; SKIP=$((SKIP+1)); }

CC="${CC:-gcc}"
CFLAGS="-Wall -Wextra -Werror -std=c11 -O2 -Ibusybox"

# =============================================================================
# 1. 編譯驗證
#    libpipe.c 作為獨立共用函式庫，與每個 *_bb.c 分開編譯後連結。
#    不定義 BUSYBOX_BUILD，讓 #ifndef 包裝提供 main() 入口。
# =============================================================================
echo "=== 1. 編譯驗證（libpipe.c + *_bb.c，不需要 BusyBox 原始碼）==="

# 先將 libpipe.c 編譯為目的檔（驗證共用函式庫可獨立編譯）
if $CC $CFLAGS -c busybox/libpipe.c -o "$BUILD_BB/libpipe.o" 2>&1; then
    ok "libpipe.c 獨立編譯為目的檔（libpipe.o）"
else
    fail "libpipe.c 編譯失敗"
fi

compile_applet() {
    local name="$1" src="$2"
    if $CC $CFLAGS "$src" "$BUILD_BB/libpipe.o" -o "$BUILD_BB/$name" 2>&1; then
        ok "$name：$src 連結 libpipe.o 成功"
    else
        fail "$name：$src 連結 libpipe.o 失敗"
    fi
}

compile_applet lparser busybox/lparser_bb.c
compile_applet lfilter busybox/lfilter_bb.c
compile_applet lstore  busybox/lstore_bb.c

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "編譯失敗，後續驗證中止。"
    echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
    exit 1
fi

# =============================================================================
# 2. lparser_main() 功能驗證
# =============================================================================
echo ""
echo "=== 2. lparser_main() 功能驗證 ==="

# 2a. --format nginx CSV header
HDR=$("$BUILD_BB/lparser" --format nginx --csv < samples/access.log | head -1)
if [ "$HDR" = "ip,time,method,path,status,bytes" ]; then
    ok "lparser --format nginx CSV header 正確"
else
    fail "lparser --format nginx CSV header 錯誤：$HDR"
fi

# 2b. --format auth CSV header
HDR=$("$BUILD_BB/lparser" --format auth --csv < samples/auth.log | head -1)
if [ "$HDR" = "time,host,result,user,src_ip,port" ]; then
    ok "lparser --format auth CSV header 正確"
else
    fail "lparser --format auth CSV header 錯誤：$HDR"
fi

# 2c. --json 輸出（第一行應以 { 開頭）
FIRST=$("$BUILD_BB/lparser" --format nginx --json < samples/access.log | head -1)
case "$FIRST" in
    "{"*) ok "lparser --json 輸出格式正確（以 { 開頭）" ;;
    *)    fail "lparser --json 輸出格式錯誤：$FIRST" ;;
esac

# 2d. --stats 統計輸出至 stderr
STATS=$("$BUILD_BB/lparser" --format auth --csv --stats < samples/auth.log 2>&1 >/dev/null || true)
case "$STATS" in
    *matched=*) ok "lparser --stats 正確輸出 matched= 統計" ;;
    *)          fail "lparser --stats 未輸出統計：$STATS" ;;
esac

# 2e. 自訂 --regex + --fields
OUT=$("$BUILD_BB/lparser" \
    --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
    --fields 'ip,time,method,path,status' --csv < samples/access.log | head -1)
if [ "$OUT" = "ip,time,method,path,status" ]; then
    ok "lparser --regex + --fields 自訂解析正確"
else
    fail "lparser --regex + --fields 自訂解析錯誤：$OUT"
fi

# =============================================================================
# 3. lfilter_main() 功能驗證
# =============================================================================
echo ""
echo "=== 3. lfilter_main() 功能驗證 ==="

CSV=$("$BUILD_BB/lparser" --format nginx --csv < samples/access.log)

# 3a. --where 數值比較（status>=400）
FILTERED=$(printf '%s\n' "$CSV" | "$BUILD_BB/lfilter" --where 'status>=400')
TOTAL_ROWS=$(printf '%s\n' "$CSV" | tail -n +2 | wc -l | tr -d ' ')
FILTER_ROWS=$(printf '%s\n' "$FILTERED" | tail -n +2 | wc -l | tr -d ' ')
if [ "$FILTER_ROWS" -lt "$TOTAL_ROWS" ] && [ "$FILTER_ROWS" -gt 0 ]; then
    ok "lfilter --where status>=400 正確過濾（$TOTAL_ROWS → $FILTER_ROWS 列）"
else
    fail "lfilter --where status>=400 過濾異常（輸入 $TOTAL_ROWS 列，輸出 $FILTER_ROWS 列）"
fi

# 3b. --select 欄位投影
HDR=$(printf '%s\n' "$CSV" | "$BUILD_BB/lfilter" --select 'ip,status' | head -1)
if [ "$HDR" = "ip,status" ]; then
    ok "lfilter --select ip,status 投影 header 正確"
else
    fail "lfilter --select ip,status header 錯誤：$HDR"
fi

# 3c. --format json 輸出
JFIRST=$(printf '%s\n' "$CSV" | "$BUILD_BB/lfilter" --where 'status>=400' --format json | head -1)
case "$JFIRST" in
    "{"*) ok "lfilter --format json 輸出格式正確" ;;
    *)    fail "lfilter --format json 格式錯誤：$JFIRST" ;;
esac

# 3d. --contains 子字串過濾
AUTH_CSV=$("$BUILD_BB/lparser" --format auth --csv < samples/auth.log)
CONT=$(printf '%s\n' "$AUTH_CSV" | "$BUILD_BB/lfilter" --contains 'result=Failed')
CONT_ROWS=$(printf '%s\n' "$CONT" | tail -n +2 | wc -l | tr -d ' ')
if [ "$CONT_ROWS" -gt 0 ]; then
    ok "lfilter --contains result=Failed 回傳 $CONT_ROWS 列"
else
    fail "lfilter --contains result=Failed 無輸出"
fi

# 3e. 組合：--where + --select
COMBO=$(printf '%s\n' "$CSV" | "$BUILD_BB/lfilter" --where 'status>=400' --select 'ip,path,status' | head -1)
if [ "$COMBO" = "ip,path,status" ]; then
    ok "lfilter --where + --select 組合使用 header 正確"
else
    fail "lfilter --where + --select 組合使用錯誤：$COMBO"
fi

# =============================================================================
# 4. lstore_main() 功能驗證
# =============================================================================
echo ""
echo "=== 4. lstore_main() 功能驗證 ==="

DB="$DATA_BB/test.tsv"
rm -f "$DB" "$DB.tmp"

# 4a. --put 寫入資料
printf '%s\n' "$CSV" | "$BUILD_BB/lfilter" --where 'status>=400' | \
    "$BUILD_BB/lstore" --db "$DB" --put --key-field ip --ttl 3600
if [ -s "$DB" ]; then
    ok "lstore --put 成功寫入資料（$(wc -l < "$DB" | tr -d ' ') 列）"
else
    fail "lstore --put 未寫入資料"
fi

# 4b. --list 列出有效記錄
LIST=$("$BUILD_BB/lstore" --db "$DB" --list)
LIST_ROWS=$(printf '%s\n' "$LIST" | grep -c '.' || true)
if [ "$LIST_ROWS" -gt 0 ]; then
    ok "lstore --list 回傳 $LIST_ROWS 筆有效記錄"
else
    fail "lstore --list 無輸出"
fi

# 4c. --count 計算有效筆數
COUNT=$("$BUILD_BB/lstore" --db "$DB" --count)
if [ "$COUNT" -gt 0 ] 2>/dev/null; then
    ok "lstore --count 回傳 $COUNT（正整數）"
else
    fail "lstore --count 回傳值無效：$COUNT"
fi

# 4d. --get 查詢特定 key
FIRST_KEY=$(printf '%s\n' "$LIST" | head -1 | cut -f1)
GET_RESULT=$("$BUILD_BB/lstore" --db "$DB" --get "$FIRST_KEY" 2>/dev/null || true)
if [ -n "$GET_RESULT" ]; then
    ok "lstore --get $FIRST_KEY 回傳記錄"
else
    fail "lstore --get $FIRST_KEY 無輸出"
fi

# 4e. --cleanup 清除過期記錄（寫入一筆 epoch=1 的過期資料後執行清理）
printf 'expired_key\t1\told,row,data\n' >> "$DB"
BEFORE=$(wc -l < "$DB" | tr -d ' ')
STATS=$("$BUILD_BB/lstore" --db "$DB" --cleanup --stats 2>&1 || true)
AFTER=$(wc -l < "$DB" | tr -d ' ')
case "$STATS" in
    *removed=1*) ok "lstore --cleanup 正確清除 1 筆過期記錄（--stats 確認）" ;;
    *)
        if [ "$AFTER" -lt "$BEFORE" ]; then
            ok "lstore --cleanup 清除過期記錄（$BEFORE → $AFTER 列）"
        else
            fail "lstore --cleanup 未清除過期記錄（前後各 $BEFORE/$AFTER 列）"
        fi
        ;;
esac

# 4f. --delete 刪除指定 key
"$BUILD_BB/lstore" --db "$DB" --delete "$FIRST_KEY"
DEL_RESULT=$("$BUILD_BB/lstore" --db "$DB" --get "$FIRST_KEY" 2>&1 || true)
case "$DEL_RESULT" in
    *"not found"*) ok "lstore --delete $FIRST_KEY 刪除成功（--get 確認 not found）" ;;
    "")            ok "lstore --delete $FIRST_KEY 刪除成功（--get 無輸出）" ;;
    *)             fail "lstore --delete 後仍可查到記錄：$DEL_RESULT" ;;
esac

# =============================================================================
# 5. 完整 applet 管線驗證
# =============================================================================
echo ""
echo "=== 5. 完整 applet 管線驗證（lparser | lfilter | lstore）==="

DB_ACC="$DATA_BB/access_errors.tsv"
DB_SSH="$DATA_BB/ssh_failed.tsv"
rm -f "$DB_ACC" "$DB_ACC.tmp" "$DB_SSH" "$DB_SSH.tmp"

# Pipeline 1：access.log → HTTP 錯誤
WRITTEN=$("$BUILD_BB/lparser" --format nginx --csv < samples/access.log | \
    "$BUILD_BB/lfilter" --where 'status>=400' --select 'ip,path,status' | \
    "$BUILD_BB/lstore" --db "$DB_ACC" --put --key-field ip --ttl 3600 --stats 2>&1 || true)
case "$WRITTEN" in
    *written=*) ok "Pipeline 1（access.log 錯誤管線）正常執行（$WRITTEN）" ;;
    *)          fail "Pipeline 1 執行異常：$WRITTEN" ;;
esac

# Pipeline 2：auth.log → SSH 失敗登入
WRITTEN=$("$BUILD_BB/lparser" --format auth --csv < samples/auth.log | \
    "$BUILD_BB/lfilter" --contains 'result=Failed' | \
    "$BUILD_BB/lstore" --db "$DB_SSH" --put --key-field src_ip --ttl 86400 --stats 2>&1 || true)
case "$WRITTEN" in
    *written=*) ok "Pipeline 2（auth.log SSH 管線）正常執行（$WRITTEN）" ;;
    *)          fail "Pipeline 2 執行異常：$WRITTEN" ;;
esac

# =============================================================================
# 6. 輸出一致性驗證（applet 版 vs standalone 版）
# =============================================================================
echo ""
echo "=== 6. 輸出一致性驗證（applet 版 vs standalone 版）==="

if [ -x "$BUILD_SA/lparser" ] && [ -x "$BUILD_SA/lfilter" ]; then
    OUT_SA=$("$BUILD_SA/lparser" --format nginx --csv < samples/access.log | \
             "$BUILD_SA/lfilter" --where 'status>=400' --select 'ip,path,status')
    OUT_BB=$("$BUILD_BB/lparser" --format nginx --csv < samples/access.log | \
             "$BUILD_BB/lfilter" --where 'status>=400' --select 'ip,path,status')
    if [ "$OUT_SA" = "$OUT_BB" ]; then
        ok "access.log 管線：applet 與 standalone 輸出完全相同"
    else
        fail "access.log 管線：applet 與 standalone 輸出不一致"
    fi

    OUT_SA=$("$BUILD_SA/lparser" --format auth --csv < samples/auth.log | \
             "$BUILD_SA/lfilter" --contains 'result=Failed')
    OUT_BB=$("$BUILD_BB/lparser" --format auth --csv < samples/auth.log | \
             "$BUILD_BB/lfilter" --contains 'result=Failed')
    if [ "$OUT_SA" = "$OUT_BB" ]; then
        ok "auth.log 管線：applet 與 standalone 輸出完全相同"
    else
        fail "auth.log 管線：applet 與 standalone 輸出不一致"
    fi
else
    skip "未找到 standalone binaries（$BUILD_SA/lparser），略過一致性比對"
    skip "先執行 make 後再次執行 make test-bb 可驗證此項目"
fi

# =============================================================================
# 結果摘要
# =============================================================================
rm -rf "$DATA_BB"

echo ""
echo "============================================================"
printf "  BusyBox Applet 驗證結果：PASS=%d  FAIL=%d  SKIP=%d\n" \
    "$PASS" "$FAIL" "$SKIP"
echo "============================================================"
echo ""
echo "後續驗證（需要 BusyBox 原始碼）："
echo "  詳見 busybox/README-integration.md §5"
echo ""

[ "$FAIL" -eq 0 ]
