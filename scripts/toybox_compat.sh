#!/usr/bin/env bash
# =============================================================================
# BusyPipe Toybox / GNU Compatibility Test
#
# Tests that BusyPipe output formats are compatible with Toybox and GNU tools.
# Usage: bash scripts/toybox_compat.sh
# =============================================================================
set -euo pipefail

PASS=0; FAIL=0; SKIP=0
ok()   { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
skip() { echo "[SKIP] $1 (tool unavailable)"; SKIP=$((SKIP+1)); }

BUILD="${BUILD:-./build}"
SAMPLE_ACCESS="./samples/access.log"
SAMPLE_AUTH="./samples/auth.log"

# ── Detect tools ────────────────────────────────────────────────────────────
TOYBOX=$(command -v toybox 2>/dev/null || command -v toybox-x86_64 2>/dev/null || true)
if [ -z "$TOYBOX" ]; then
    echo "ERROR: toybox not found in PATH"
    exit 1
fi

# Check which toybox sub-commands exist
has_toybox_cmd() { "$TOYBOX" --help 2>&1 | grep -qw "$1"; }

TOYBOX_HAS_AWK=false;  has_toybox_cmd awk  && TOYBOX_HAS_AWK=true  || true
TOYBOX_HAS_CUT=false;  has_toybox_cmd cut  && TOYBOX_HAS_CUT=true  || true
TOYBOX_HAS_GREP=false; has_toybox_cmd grep && TOYBOX_HAS_GREP=true || true

# Fall back to GNU tools if toybox doesn't have the command
if $TOYBOX_HAS_AWK;  then AWK="$TOYBOX awk";   else AWK=$(command -v gawk || command -v awk); fi
if $TOYBOX_HAS_CUT;  then CUT="$TOYBOX cut";   else CUT=$(command -v cut); fi
if $TOYBOX_HAS_GREP; then GREP="$TOYBOX grep"; else GREP=$(command -v grep); fi

echo "============================================================"
echo "  BusyPipe Toybox / GNU Compatibility Test"
echo "  Toybox: $($TOYBOX --version 2>/dev/null || echo 'installed')"
printf "  toybox awk=%s  cut=%s  grep=%s\n" \
    "$TOYBOX_HAS_AWK" "$TOYBOX_HAS_CUT" "$TOYBOX_HAS_GREP"
echo "============================================================"

# Compile if needed
if [ ! -x "$BUILD/lparser" ]; then
    echo "Building..."
    make -s
fi

# ── Pre-generate parsed CSV ─────────────────────────────────────────────────
PARSED=$("$BUILD/lparser" --format nginx --csv < "$SAMPLE_ACCESS")
TMP_DB=$(mktemp)
trap 'rm -f "$TMP_DB"' EXIT

# ── Test Group 1: lparser output readable by toybox/GNU cut ─────────────────
echo ""
echo "▶  Group 1: lparser CSV → toybox/GNU cut"

# T1: cut can read the header
header=$(echo "$PARSED" | $CUT -d, -f1 | head -1)
[ "$header" = "ip" ] \
    && ok "lparser CSV header readable by cut" \
    || fail "lparser CSV header: expected 'ip', got '$header'"

# T2: cut can extract status column (col 5)
status_vals=$(echo "$PARSED" | $CUT -d, -f5 | tail -n +2 | head -3)
[ -n "$status_vals" ] \
    && ok "lparser CSV col5 (status) extractable by cut" \
    || fail "lparser CSV col5 not readable"

# T3: cut can extract ip+status (col 1,5)
two_cols=$(echo "$PARSED" | $CUT -d, -f1,5 | head -2 | wc -l)
[ "$two_cols" -eq 2 ] \
    && ok "lparser CSV multi-column extraction by cut" \
    || fail "lparser CSV multi-column extraction failed"

# ── Test Group 2: lfilter --where matches awk ───────────────────────────────
echo ""
if $TOYBOX_HAS_AWK; then
    echo "▶  Group 2: lfilter --where vs toybox awk"
else
    echo "▶  Group 2: lfilter --where vs GNU awk (toybox awk unavailable in this build)"
fi

# T4: row count matches
bp_count=$(echo "$PARSED" | "$BUILD/lfilter" --where 'status>=400' | tail -n +2 | wc -l)
awk_count=$(echo "$PARSED" | $AWK -F, 'NR>1 && $5+0>=400' | wc -l)
[ "$bp_count" = "$awk_count" ] \
    && ok "lfilter --where 'status>=400' row count matches awk ($bp_count rows)" \
    || fail "lfilter --where count mismatch: lfilter=$bp_count awk=$awk_count"

# T5: lfilter --select output equals cut output
bp_sel=$(echo "$PARSED" | "$BUILD/lfilter" --select 'ip,status' | tail -n +2 | sort)
cut_sel=$(echo "$PARSED" | $CUT -d, -f1,5 | tail -n +2 | sort)
[ "$bp_sel" = "$cut_sel" ] \
    && ok "lfilter --select 'ip,status' output identical to cut -f1,5" \
    || fail "lfilter --select output differs from cut"

# ── Test Group 3: lfilter --contains matches grep ───────────────────────────
echo ""
if $TOYBOX_HAS_GREP; then
    echo "▶  Group 3: lfilter --contains vs toybox grep"
else
    echo "▶  Group 3: lfilter --contains vs GNU grep (toybox grep unavailable in this build)"
fi

AUTH_PARSED=$("$BUILD/lparser" --format auth --csv < "$SAMPLE_AUTH")

# T6: --contains 'result=Failed' row count matches grep
bp_fail=$(echo "$AUTH_PARSED" | "$BUILD/lfilter" --contains 'result=Failed' | tail -n +2 | wc -l)
grep_fail=$(echo "$AUTH_PARSED" | $GREP -c 'Failed' || true)
[ "$bp_fail" = "$grep_fail" ] \
    && ok "lfilter --contains 'result=Failed' matches grep count ($bp_fail rows)" \
    || fail "lfilter --contains count: lfilter=$bp_fail grep=$grep_fail"

# ── Test Group 4: lstore TSV readable by awk/cut ────────────────────────────
echo ""
echo "▶  Group 4: lstore TSV format readable by standard tools"

echo "$PARSED" | "$BUILD/lfilter" --where 'status>=400' \
    | "$BUILD/lstore" --db "$TMP_DB" --put --key-field ip --ttl 3600

# T7: awk can read key column
tsv_keys=$($AWK -F'\t' 'NF==3{print $1}' "$TMP_DB" | wc -l)
[ "$tsv_keys" -gt 0 ] \
    && ok "lstore TSV key column readable by awk ($tsv_keys records)" \
    || fail "lstore TSV not readable by awk"

# T8: cut can read TSV field 3 (raw CSV value)
tsv_vals=$($CUT -f3 "$TMP_DB" | wc -l)
[ "$tsv_vals" -gt 0 ] \
    && ok "lstore TSV field-3 (raw CSV) readable by cut ($tsv_vals records)" \
    || fail "lstore TSV field-3 not readable by cut"

# T9: lstore --list output readable line by line
list_out=$("$BUILD/lstore" --db "$TMP_DB" --list | wc -l)
[ "$list_out" -gt 0 ] \
    && ok "lstore --list output is non-empty ($list_out lines)" \
    || fail "lstore --list produced no output"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
printf "  Results:  PASS=%d  FAIL=%d  SKIP=%d\n" "$PASS" "$FAIL" "$SKIP"
echo "============================================================"
[ "$FAIL" -eq 0 ]