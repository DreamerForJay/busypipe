#!/usr/bin/env sh
# =============================================================================
# BusyPipe Demo — auth.log SSH 登入事件分析管線
#
# 展示完整的 lparser | lfilter | lstore 管線：
#   - 解析 SSH auth.log 中的 Failed/Accepted 事件
#   - 過濾出失敗登入嘗試
#   - 存入 key-value store（以來源 IP 為 key）
#   - 查詢、統計與清理
#
# 使用方式：
#   bash scripts/demo_auth.sh
#
# 建置需求：
#   先執行  make  或  bash scripts/linux_pipeline_demo.sh
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
DATA="$ROOT/data"
SAMPLES="$ROOT/samples"

cd "$ROOT"
mkdir -p "$DATA/auth"
rm -f "$DATA/auth/failed.tsv" "$DATA/auth/failed.tsv.tmp"

# ── 0. 確認工具已建置 ─────────────────────────────────────────────────────────
if [ ! -x "$BUILD/lparser" ] || [ ! -x "$BUILD/lfilter" ] || [ ! -x "$BUILD/lstore" ]; then
    echo "[demo] 工具尚未建置，執行 make ..."
    make -C "$ROOT"
fi

echo "=========================================================="
echo "  BusyPipe Demo — SSH auth.log 分析管線"
echo "=========================================================="
echo ""

# ── 1. 原始 auth.log 內容 ────────────────────────────────────────────────────
echo "--- 原始 auth.log ---"
cat "$SAMPLES/auth.log"
echo ""

# ── 2. 解析 auth.log（CSV 輸出） ──────────────────────────────────────────────
echo "--- lparser --format auth --csv ---"
"$BUILD/lparser" --format auth --csv < "$SAMPLES/auth.log"
echo ""

# ── 3. 解析 auth.log（JSONL 輸出） ───────────────────────────────────────────
echo "--- lparser --format auth --json ---"
"$BUILD/lparser" --format auth --json < "$SAMPLES/auth.log"
echo ""

# ── 4. 過濾：只保留 Failed 登入 ──────────────────────────────────────────────
echo "--- lparser | lfilter --contains result=Failed ---"
"$BUILD/lparser" --format auth --csv < "$SAMPLES/auth.log" | \
    "$BUILD/lfilter" --contains 'result=Failed' --select 'time,user,src_ip,port'
echo ""

# ── 5. 完整管線：解析 → 過濾 → 存入 store ───────────────────────────────────
echo "--- 完整管線：lparser | lfilter | lstore --put ---"
"$BUILD/lparser" --format auth --csv < "$SAMPLES/auth.log" | \
    "$BUILD/lfilter" --contains 'result=Failed' | \
    "$BUILD/lstore" --db "$DATA/auth/failed.tsv" \
        --put --key-field src_ip --ttl 86400 --stats
echo ""

# ── 6. 查詢 store ─────────────────────────────────────────────────────────────
echo "--- lstore --list（所有有效失敗登入記錄） ---"
"$BUILD/lstore" --db "$DATA/auth/failed.tsv" --list
echo ""

echo "--- lstore --get 10.0.0.8（查詢特定來源 IP） ---"
"$BUILD/lstore" --db "$DATA/auth/failed.tsv" --get 10.0.0.8
echo ""

echo "--- lstore --count（目前有效筆數） ---"
"$BUILD/lstore" --db "$DATA/auth/failed.tsv" --count
echo ""

# ── 7. stats 與 cleanup ───────────────────────────────────────────────────────
echo "--- lstore --cleanup --stats ---"
"$BUILD/lstore" --db "$DATA/auth/failed.tsv" --cleanup --stats
echo ""

# ── 8. 延伸：自訂 regex 解析 auth.log ────────────────────────────────────────
echo "--- 自訂 regex（只抓 Failed，含 user 與 IP）---"
"$BUILD/lparser" \
    --regex '^([A-Za-z]+ +[0-9]+ [0-9:]+) .* Failed password for ([^ ]+) from ([^ ]+) port ([0-9]+)' \
    --fields 'time,user,src_ip,port' \
    --csv < "$SAMPLES/auth.log"
echo ""

# ── 9. 連同 access.log 一起演示：雙來源管線 ─────────────────────────────────
echo "--- 雙來源展示：access.log 錯誤 + auth.log 失敗登入 ---"
echo "(兩個資料流分別存入不同 DB)"

"$BUILD/lparser" --format nginx --csv < "$SAMPLES/access.log" | \
    "$BUILD/lfilter" --where 'status>=400' | \
    "$BUILD/lstore" --db "$DATA/auth/http_errors.tsv" \
        --put --key-field ip --ttl 3600
echo "HTTP errors store:"
"$BUILD/lstore" --db "$DATA/auth/http_errors.tsv" --list

"$BUILD/lparser" --format auth --csv < "$SAMPLES/auth.log" | \
    "$BUILD/lfilter" --contains 'result=Failed' | \
    "$BUILD/lstore" --db "$DATA/auth/ssh_failed.tsv" \
        --put --key-field src_ip --ttl 86400
echo "SSH failed store:"
"$BUILD/lstore" --db "$DATA/auth/ssh_failed.tsv" --list

echo ""
echo "=========================================================="
echo "  Demo 完成。資料檔案："
echo "    $DATA/auth/failed.tsv"
echo "    $DATA/auth/http_errors.tsv"
echo "    $DATA/auth/ssh_failed.tsv"
echo "=========================================================="
