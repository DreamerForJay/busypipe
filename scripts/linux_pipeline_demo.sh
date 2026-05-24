#!/usr/bin/env sh
# =============================================================================
# BusyPipe Linux Pipeline Demo
#
# 完整展示兩條資料管線：
#   Pipeline 1: Nginx/Apache access.log → HTTP 4xx/5xx 錯誤
#   Pipeline 2: SSH auth.log → Failed password 事件
#
# 使用方式（在專案根目錄）：
#   bash scripts/linux_pipeline_demo.sh
#
# 或透過 Docker（Windows）：
#   powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1
# =============================================================================
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p build/linux data/linux
rm -f data/linux/errors.tsv  data/linux/errors.tsv.tmp
rm -f data/linux/ssh_fail.tsv data/linux/ssh_fail.tsv.tmp

# ── 0. 編譯 ──────────────────────────────────────────────────────────────────
echo "=== Building ==="
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 -c src/common.c  -o build/linux/common.o
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    src/lparser.c build/linux/common.o -o build/linux/lparser
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    src/lfilter.c build/linux/common.o -o build/linux/lfilter
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    src/lstore.c  build/linux/common.o -o build/linux/lstore

# ── 共用變數 ──────────────────────────────────────────────────────────────────
NGINX_REGEX='^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9][0-9][0-9]) .*'
NGINX_FIELDS='ip,time,method,path,status'

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Pipeline 1: access.log → HTTP 錯誤 (status >= 400)      ║"
echo "╚══════════════════════════════════════════════════════════╝"

echo ""
echo "--- 步驟 1：解析 access.log (CSV) ---"
./build/linux/lparser \
    --regex "$NGINX_REGEX" --fields "$NGINX_FIELDS" --csv \
    < samples/access.log

echo ""
echo "--- 步驟 2：過濾 status >= 400，投影欄位 ---"
./build/linux/lparser \
    --regex "$NGINX_REGEX" --fields "$NGINX_FIELDS" --csv \
    < samples/access.log | \
  ./build/linux/lfilter --where 'status>=400' --select 'ip,path,status'

echo ""
echo "--- 步驟 3：完整管線寫入 store ---"
./build/linux/lparser \
    --regex "$NGINX_REGEX" --fields "$NGINX_FIELDS" --csv \
    < samples/access.log | \
  ./build/linux/lfilter --where 'status>=400' | \
  ./build/linux/lstore \
    --db data/linux/errors.tsv --put --key-field ip --ttl 3600 --stats

echo ""
echo "--- 步驟 4：查詢 store ---"
echo "[--list]"
./build/linux/lstore --db data/linux/errors.tsv --list
echo "[--get 192.168.0.4]"
./build/linux/lstore --db data/linux/errors.tsv --get 192.168.0.4
echo "[--count]"
./build/linux/lstore --db data/linux/errors.tsv --count

echo ""
echo "--- 步驟 5：JSON 輸出格式 ---"
./build/linux/lparser \
    --regex "$NGINX_REGEX" --fields "$NGINX_FIELDS" --json \
    < samples/access.log | head -3

echo ""
echo "--- 步驟 6：lfilter JSON 輸出 ---"
./build/linux/lparser \
    --regex "$NGINX_REGEX" --fields "$NGINX_FIELDS" --csv \
    < samples/access.log | \
  ./build/linux/lfilter --where 'status>=400' --format json

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Pipeline 2: auth.log → SSH Failed password 事件         ║"
echo "╚══════════════════════════════════════════════════════════╝"

echo ""
echo "--- 步驟 1：解析 auth.log (--format auth, CSV) ---"
./build/linux/lparser --format auth --csv < samples/auth.log

echo ""
echo "--- 步驟 2：過濾 Failed 事件 ---"
./build/linux/lparser --format auth --csv < samples/auth.log | \
  ./build/linux/lfilter --contains 'result=Failed' \
                        --select 'time,user,src_ip,port'

echo ""
echo "--- 步驟 3：完整管線寫入 store ---"
./build/linux/lparser --format auth --csv < samples/auth.log | \
  ./build/linux/lfilter --contains 'result=Failed' | \
  ./build/linux/lstore \
    --db data/linux/ssh_fail.tsv --put --key-field src_ip --ttl 86400 --stats

echo ""
echo "--- 步驟 4：查詢 SSH 攻擊來源 ---"
./build/linux/lstore --db data/linux/ssh_fail.tsv --list
./build/linux/lstore --db data/linux/ssh_fail.tsv --get 10.0.0.8

echo ""
echo "--- 步驟 5：JSONL 輸出 ---"
./build/linux/lparser --format auth --json < samples/auth.log

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Demo 完成                                                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "輸出資料："
echo "  data/linux/errors.tsv   — HTTP 錯誤記錄"
echo "  data/linux/ssh_fail.tsv — SSH 失敗登入記錄"
echo ""
echo "使用 --help 查看各工具說明："
echo "  ./build/linux/lparser --help"
echo "  ./build/linux/lfilter --help"
echo "  ./build/linux/lstore  --help"
