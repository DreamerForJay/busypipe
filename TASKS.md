# BusyPipe Tasks

這份文件整理目前專案的正式分工方式，並對應 GitHub issue。

---

## GitHub Issues 現況

| Issue | 標題 | 狀態 |
|-------|------|------|
| #1 | implement Linux regex backend for lparser | ✅ 完成 |
| #2 | extend lparser to support auth.log parsing | ✅ 完成 |
| #3 | improve lfilter condition parsing and error handling | ✅ 完成 |
| #4 | improve lstore storage behavior and TTL tests | ✅ 完成 |
| #5 | add collaboration guide and contribution workflow | ✅ 完成 |
| #6 | prepare BusyBox integration plan for standalone tools | ✅ 完成 |
| #7 | add integration, demo, and benchmark workflow | ✅ 完成 |

---

## 角色分工

### 楊杰倫（系統整合與測試）

負責內容：
- 通用函式庫開發與整體整合
- `Makefile`（Linux 相容、install/test/bench target）
- 自動化測試腳本（`make test`）
- Demo 腳本（`linux_pipeline_demo.sh`、`demo_auth.sh`）
- 效能對比 `benchmark.sh`（BusyPipe vs GNU awk）
- GitHub 文件（README、PROGRESS、TASKS、man pages）
- BusyBox 整合規劃與 `busybox/` 目錄

對應 issue：#4 #5 #6 #7

### 羅章弘（解析專家）

負責內容：
- `src/lparser.c` 工具開發
- POSIX 正規表示式解析引擎（`regcomp`/`regexec`）
- 預設格式支援：`--format nginx / apache / auth`
- CSV 輸出（含 header）
- JSONL 輸出（含 JSON escape 處理）
- `--stats` matched/skipped 統計

對應 issue：#1 #2

### 吳佳泰（串流邏輯官）

負責內容：
- `src/lfilter.c` 工具開發
- `--where` 數值/字串比較過濾（6 種運算子）
- `--contains` 子字串過濾
- `--select` 欄位投影
- `--format csv/json` 輸出格式支援
- 欄位不存在時的詳細錯誤訊息

對應 issue：#3

### 潘彥霖（儲存架構師）

負責內容：
- `src/lstore.c` 工具開發
- `--put/get/delete/list/cleanup/count` 完整 CRUD
- TTL 自動過期管理
- Buffered write（每 64 行或 128 KiB flush）
- Atomic rewrite（`rename()` + cross-device fallback）
- `--stats` 操作統計

對應 issue：#4

---

## 完整 Demo 流程

### Pipeline 1：access.log HTTP 錯誤分析

```bash
lparser --format nginx --csv < samples/access.log \
  | lfilter --where 'status>=400' --select 'ip,path,status' \
  | lstore --db data/errors.tsv --put --key-field ip --ttl 3600

lstore --db data/errors.tsv --get 192.168.0.4
lstore --db data/errors.tsv --list
```

### Pipeline 2：auth.log SSH 失敗登入分析

```bash
lparser --format auth --csv < samples/auth.log \
  | lfilter --contains 'result=Failed' \
  | lstore --db data/ssh_fail.tsv --put --key-field src_ip --ttl 86400

lstore --db data/ssh_fail.tsv --list
lstore --db data/ssh_fail.tsv --get 10.0.0.8
```

### 執行 Demo 腳本

```bash
# 完整雙管線
bash scripts/linux_pipeline_demo.sh

# auth.log 管線
bash scripts/demo_auth.sh

# Benchmark
bash scripts/benchmark.sh --lines 50000 --repeat 3
```

---

## 目前可驗證內容

### Windows 本機

```powershell
powershell -ExecutionPolicy Bypass -File scripts\demo.ps1
powershell -ExecutionPolicy Bypass -File scripts\test_store.ps1
```

### Linux / Docker

```bash
make test                              # smoke test
bash scripts/linux_pipeline_demo.sh   # 完整 Demo
bash scripts/demo_auth.sh             # auth Demo
make bench                            # Benchmark
```

---

## BusyBox 整合快速指引

詳見 `busybox/README-integration.md`。

```bash
# 下載 BusyBox 1.36
wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2 && cd busybox-1.36.1

# 複製 applet 適配版本
cp ../busypipe/busybox/lparser_bb.c miscutils/lparser.c
cp ../busypipe/busybox/lfilter_bb.c miscutils/lfilter.c
cp ../busypipe/busybox/lstore_bb.c  miscutils/lstore.c

# 複製共用函式庫（libpipe）
cp ../busypipe/busybox/libpipe.c    libbb/busypipe_lib.c
cp ../busypipe/busybox/libpipe.h    include/libpipe.h

# 修改 include/applets.h、Config.in、miscutils/Kbuild
# (詳見 busybox/README-integration.md §4)

# 在 libbb/Kbuild 加入共用函式庫
echo "lib-y += busypipe_lib.o" >> libbb/Kbuild

# KCONFIG_ALLCONFIG 強制啟用指定選項，搭配 allnoconfig 避免 kernel headers 相容性問題
printf 'CONFIG_LPARSER=y\nCONFIG_LFILTER=y\nCONFIG_LSTORE=y\n' > /tmp/bp_forced.config
KCONFIG_ALLCONFIG=/tmp/bp_forced.config make allnoconfig && make -j$(nproc)

./busybox lparser --format nginx --csv < access.log \
  | ./busybox lfilter --where 'status>=400' \
  | ./busybox lstore  --db errors.tsv --put --key-field ip --ttl 3600
```
