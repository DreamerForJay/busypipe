#!/usr/bin/env bash
# =============================================================================
# BusyPipe Benchmark — compare BusyPipe tools vs GNU awk / grep
#
# Measures throughput (lines/sec) and wall-clock time for 6 tasks.
# Usage: bash scripts/benchmark.sh [--lines N] [--repeat N]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
DATA="$ROOT/data"
TMP="$DATA/bench"

NLINES=50000
REPEAT=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lines)  NLINES="$2"; shift 2 ;;
        --repeat) REPEAT="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'
hdr() { echo -e "\n${YLW}▶  $*${NC}"; }
TIMEFORMAT='%R'

# time_ms VARNAME fn_name  — call fn_name() REPEAT times, best ms
time_ms() {
    local var="$1" fn="$2"
    local best=999999 i raw ms
    for ((i=0; i<REPEAT; i++)); do
        raw=$( { time "$fn" > /dev/null; } 2>&1 )
        ms=$(awk "BEGIN{printf \"%d\", $raw * 1000}")
        (( ms < best )) && best=$ms
    done
    printf -v "$var" "%d" "$best"
}

tp() {
    local ms=$1 lines=$2
    (( ms == 0 )) && printf "%8s" "∞" && return
    awk "BEGIN{printf \"%8.0f\", ($lines*1000.0)/$ms}"
}

cmp_row() {
    local task="$1" bp=$2 gnu=$3 lines=$4
    local bptp gntp winner
    bptp=$(tp "$bp" "$lines"); gntp=$(tp "$gnu" "$lines")
    (( bp <= gnu )) && winner="${GRN}BusyPipe ✓${NC}" || winner="${RED}GNU faster${NC}"
    printf "  %-44s  BP=%5d ms (%s ln/s)  GNU=%5d ms (%s ln/s)  %b\n" \
        "$task" "$bp" "$bptp" "$gnu" "$gntp" "$winner"
}

# ── setup ──────────────────────────────────────────────────────────────────────
mkdir -p "$TMP"
make -C "$ROOT" -s

LOGFILE="$TMP/access.log"
AUTHLOG="$TMP/auth.log"
CSVFILE="$TMP/parsed.csv"
DB_FILE="$TMP/bench.tsv"
GNU_DB="$TMP/bench_gnu.tsv"

hdr "Generating $NLINES-line synthetic logs …"

python3 - "$NLINES" "$LOGFILE" <<'PYEOF'
import sys, random
n, out = int(sys.argv[1]), sys.argv[2]
methods=["GET","POST","PUT","DELETE"]
paths=["/index.html","/api/data","/login","/admin","/static/app.js"]
codes=[200,200,200,301,404,404,500]
ips=[f"10.0.{r}.{c}" for r in range(1,5) for c in range(1,51)]
random.seed(42)
with open(out,"w") as f:
    for i in range(n):
        ip=random.choice(ips); m=random.choice(methods)
        p=random.choice(paths); s=random.choice(codes)
        sz=random.randint(64,8192)
        f.write(f'{ip} - - [30/Apr/2026:{i//3600:02d}:{(i//60)%60:02d}:{i%60:02d} +0800]'
                f' "{m} {p} HTTP/1.1" {s} {sz}\n')
PYEOF

python3 - "$NLINES" "$AUTHLOG" <<'PYEOF'
import sys, random
n, out = int(sys.argv[1]), sys.argv[2]
users=["root","admin","test","user1","deploy"]
ips=[f"10.0.{r}.{c}" for r in range(1,5) for c in range(1,11)]
months=["Jan","Feb","Mar","Apr","May"]
random.seed(7)
with open(out,"w") as f:
    for i in range(n):
        mo=random.choice(months); dy=random.randint(1,28)
        hh,mm,ss=i//3600,(i//60)%60,i%60
        res=random.choice(["Failed","Accepted"])
        user=random.choice(users); ip=random.choice(ips)
        port=random.randint(10000,65535)
        f.write(f"{mo} {dy:2d} {hh:02d}:{mm:02d}:{ss:02d} router sshd[{1000+i}]: "
                f"{res} password for {user} from {ip} port {port} ssh2\n")
PYEOF

REGEX='^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) ([0-9]+)'
FIELDS='ip,time,method,path,status,bytes'
"$BUILD/lparser" --format nginx --csv \
    < "$LOGFILE" > "$CSVFILE"

CSVLINES=$(( $(wc -l < "$CSVFILE") - 1 ))
echo "  access.log:  $(wc -l < "$LOGFILE") lines"
echo "  auth.log:    $(wc -l < "$AUTHLOG") lines"
echo "  parsed.csv:  $(wc -l < "$CSVFILE") rows (incl. header)"

echo ""
echo "============================================================"
printf "  BusyPipe Benchmark  (N=%d, repeat=%d)\n" "$NLINES" "$REPEAT"
echo "============================================================"

# ── 1. Field extraction ────────────────────────────────────────────────────────
hdr "1. Field extraction  (lparser --format nginx vs awk)"

# GNU awk equivalent: use field positions in access.log
# ip=$1, time=$4 (strip "["), method=$7 (strip '"'), path=$8, status=$9, bytes=$10

b1_bp() {
    "$BUILD/lparser" --format nginx --csv < "$LOGFILE"
}
b1_gnu() {
    awk '{
        ip=$1
        # time is $4 stripped of "[" and $5 stripped of "]"
        t=substr($4,2) " " substr($5,1,length($5)-1)
        # method is $7 stripped of leading "
        m=substr($7,2)
        path=$8
        status=$9
        bytes=$10
        print ip","t","m","path","status","bytes
    }' "$LOGFILE"
}
time_ms BP_MS  b1_bp
time_ms GNU_MS b1_gnu
cmp_row "field extraction (lparser vs awk)" "$BP_MS" "$GNU_MS" "$NLINES"

# ── 2. Row filtering ───────────────────────────────────────────────────────────
hdr "2. Row filtering  (lfilter vs awk)  [status>=400]"

b2_bp() { "$BUILD/lfilter" --where 'status>=400' < "$CSVFILE"; }
b2_gnu() { awk -F',' 'NR==1{print;next} $5+0>=400{print}' "$CSVFILE"; }
time_ms BP_MS  b2_bp
time_ms GNU_MS b2_gnu
cmp_row "row filter (lfilter vs awk)" "$BP_MS" "$GNU_MS" "$CSVLINES"

# ── 3. Field projection ────────────────────────────────────────────────────────
hdr "3. Field projection  (lfilter --select vs awk)"

b3_bp() { "$BUILD/lfilter" --select 'ip,path,status' < "$CSVFILE"; }
b3_gnu() {
    awk -F',' 'NR==1{print $1","$4","$5;next}{print $1","$4","$5}' "$CSVFILE"
}
time_ms BP_MS  b3_bp
time_ms GNU_MS b3_gnu
cmp_row "field projection (lfilter vs awk)" "$BP_MS" "$GNU_MS" "$CSVLINES"

# ── 4. Combined pipeline ───────────────────────────────────────────────────────
hdr "4. Combined pipeline  lparser | lfilter  vs  awk"

b4_bp() {
    "$BUILD/lparser" --format nginx --csv < "$LOGFILE" | \
    "$BUILD/lfilter" --where 'status>=400' --select 'ip,path,status'
}
b4_gnu() {
    awk -F',' 'NR>1 && $5+0>=400 {print $1","$4","$5}' "$CSVFILE"
}
time_ms BP_MS  b4_bp
time_ms GNU_MS b4_gnu
cmp_row "full pipeline (BP vs awk on CSV)" "$BP_MS" "$GNU_MS" "$NLINES"

# ── 5. Store write ─────────────────────────────────────────────────────────────
hdr "5. Store write  (lstore --put vs awk >> file)"

b5_bp() {
    rm -f "$DB_FILE"
    "$BUILD/lparser" --format nginx --csv < "$LOGFILE" | \
    "$BUILD/lstore" --db "$DB_FILE" --put --key-field ip
}
b5_gnu() {
    rm -f "$GNU_DB"
    awk -F',' 'NR>1{print $1"\t0\t"$0}' "$CSVFILE" > "$GNU_DB"
}
time_ms BP_MS  b5_bp
time_ms GNU_MS b5_gnu
cmp_row "store write (lstore vs awk>file)" "$BP_MS" "$GNU_MS" "$NLINES"

# ── 6. auth.log parsing ────────────────────────────────────────────────────────
hdr "6. auth.log parsing  (lparser --format auth vs awk)"

b6_bp() { "$BUILD/lparser" --format auth --csv < "$AUTHLOG"; }
b6_gnu() {
    awk '/sshd\[/ && /password for/ {
        # Fields: 1=month 2=day 3=time 4=host 5=sshd[pid]: 6=Failed/Accepted 7=password 8=for 9=user 10=from 11=ip 12=port 13=portnum
        result=$6; user=$9; src=$11; port=$13
        t=$1" "$2" "$3; host=$4
        print t","host","result","user","src","port
    }' "$AUTHLOG"
}
time_ms BP_MS  b6_bp
time_ms GNU_MS b6_gnu
cmp_row "auth.log parse (lparser vs awk)" "$BP_MS" "$GNU_MS" "$NLINES"

# ── summary ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
printf "  Done.  Wall-clock real time, best-of-%d runs.\n" "$REPEAT"
printf "  Test data: %d lines per benchmark\n" "$NLINES"
printf "  Binaries:  %s\n" "$BUILD"
echo "============================================================"

rm -f "$DB_FILE" "$GNU_DB"
