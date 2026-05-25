# BusyPipe

BusyPipe 是一個以 C 語言實作的嵌入式 ETL 工具鏈，為 UNIX 系統程式設計期末專題。  
專案目標是在資源受限的 Linux / BusyBox 環境中，提供三個可透過 UNIX pipe 串接的小型資料處理工具：

```
lparser  →  lfilter  →  lstore
（解析）    （過濾）    （儲存）
```

## 設計原則

- **一個工具只做好一件事**
- **透過標準輸入 / 輸出協同工作**
- **低依賴、可組合、可移植（POSIX C11）**
- **可整合進 BusyBox multi-call binary**

---

## 工具說明

### `lparser` — 原始日誌解析器

從 stdin 讀取原始日誌，以 POSIX 正規表示式擷取欄位，輸出 CSV 或 JSONL。

```bash
# 使用預設格式（nginx / apache / auth）
lparser --format nginx --csv < access.log
lparser --format auth  --json < auth.log

# 使用自訂 regex
lparser --regex '^([0-9.]+) .* "([A-Z]+) ([^ ]+)' \
        --fields ip,method,path --csv < access.log

# 統計輸出
lparser --format nginx --csv --stats < access.log
```

**預設格式（`--format`）：**

| 名稱 | 說明 | 輸出欄位 |
|------|------|---------|
| `nginx` | Nginx/Apache Combined Log | `ip,time,method,path,status,bytes` |
| `apache` | Apache Common Log Format | `ip,time,method,path,status,bytes` |
| `auth` | SSH auth.log sshd 事件 | `time,host,result,user,src_ip,port` |

### `lfilter` — CSV 串流過濾器

從 stdin 讀取 CSV，依條件篩選、投影欄位，輸出 CSV 或 JSONL。

```bash
# 數值比較過濾
lfilter --where 'status>=400'

# 字串包含過濾
lfilter --contains 'result=Failed'

# 欄位投影
lfilter --select 'ip,path,status'

# JSONL 輸出
lfilter --where 'status>=400' --format json

# 組合使用
lfilter --where 'status>=400' --select 'ip,path,status'
```

**支援運算子（`--where`）：** `==` `!=` `>` `>=` `<` `<=`

### `lstore` — 檔案式 key-value store

將 CSV 資料寫入帶 TTL 的 TSV 資料庫，支援 CRUD 與清理。

```bash
# 寫入（TTL 1 小時）
lstore --db errors.tsv --put --key-field ip --ttl 3600

# 查詢最新記錄
lstore --db errors.tsv --get 192.168.0.4

# 列出所有有效記錄
lstore --db errors.tsv --list

# 計算有效筆數
lstore --db errors.tsv --count

# 刪除特定 key
lstore --db errors.tsv --delete 192.168.0.4

# 清理過期記錄（含統計）
lstore --db errors.tsv --cleanup --stats
```

**儲存格式（TSV）：**
```
key<TAB>expires_at_epoch<TAB>raw_csv_row
```
`expires_at_epoch = 0` 代表永不過期。

---

## 完整管線展示

### Pipeline 1：Nginx access.log → HTTP 錯誤儲存

```bash
lparser --format nginx --csv < access.log \
  | lfilter --where 'status>=400' --select 'ip,path,status' \
  | lstore  --db errors.tsv --put --key-field ip --ttl 3600

# 查詢
lstore --db errors.tsv --get 192.168.0.4
lstore --db errors.tsv --list
```

### Pipeline 2：SSH auth.log → 失敗登入分析

```bash
lparser --format auth --csv < /var/log/auth.log \
  | lfilter --contains 'result=Failed' \
  | lstore  --db ssh_fail.tsv --put --key-field src_ip --ttl 86400

# 查詢攻擊來源
lstore --db ssh_fail.tsv --list
lstore --db ssh_fail.tsv --get 10.0.0.8
```

### 自訂 regex

```bash
lparser \
  --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
  --fields ip,time,method,path,status --csv < access.log \
  | lfilter --where 'status>=400' --format json
```

---

## 快速開始

### 建置

```bash
make
```

### 執行測試

```bash
make test
```

### 執行 Benchmark

```bash
make bench
# 或自訂參數
bash scripts/benchmark.sh --lines 50000 --repeat 3
```

### 查看說明

```bash
./build/lparser --help
./build/lfilter --help
./build/lstore  --help
man docs/man/lparser.1
```

### 完整 Demo

```bash
# access.log + auth.log 雙管線
bash scripts/linux_pipeline_demo.sh

# 單獨 auth.log 管線
bash scripts/demo_auth.sh
```

---

## 專案結構

```text
busypipe/
├── src/
│   ├── common.c           共用函式（CSV解析、欄位操作、錯誤處理）
│   ├── lparser.c          原始日誌解析器
│   ├── lfilter.c          CSV 串流過濾器
│   └── lstore.c           檔案式 key-value store
├── include/
│   └── common.h           共用標頭
├── busybox/
│   ├── busypipe.h         BusyBox 版本共用標頭
│   ├── lparser_bb.c       BusyBox applet 適配版
│   ├── lfilter_bb.c       BusyBox applet 適配版
│   ├── lstore_bb.c        BusyBox applet 適配版
│   └── README-integration.md  BusyBox 整合指南
├── docs/
│   ├── spec.md            開發規格
│   └── man/
│       ├── lparser.1      man page
│       ├── lfilter.1      man page
│       └── lstore.1       man page
├── samples/
│   ├── access.log         範例 Nginx access log
│   └── auth.log           範例 SSH auth.log
├── scripts/
│   ├── linux_pipeline_demo.sh   完整 Linux 雙管線 Demo
│   ├── demo_auth.sh             auth.log 管線 Demo
│   ├── benchmark.sh             效能比較腳本
│   ├── demo.ps1                 Windows PowerShell Demo
│   ├── test_store.ps1           lstore 回歸測試（PowerShell）
│   └── run_linux_demo.ps1       Windows 啟動 Docker Demo
├── Makefile
├── CONTRIBUTING.md
├── TASKS.md
├── PROGRESS.md
└── report.md            期末書面報告
```

---

## 建置方式

### 使用 `make`（推薦）

```bash
make            # 建置全部工具
make test       # 執行 smoke test
make bench      # 執行 benchmark（需要 python3）
make install    # 安裝到 /usr/local/bin（可自訂 PREFIX=…）
make install-man # 安裝 man pages
make clean
```

### 手動 `gcc`

```bash
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    -c src/common.c -o build/common.o
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    src/lparser.c build/common.o -o build/lparser
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    src/lfilter.c build/common.o -o build/lfilter
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 \
    src/lstore.c  build/common.o -o build/lstore
```

---

## Benchmark 結果（參考）

以 50,000 行合成日誌測試，BusyPipe vs GNU awk（best-of-3 runs）：

| 測試項目 | BusyPipe | GNU awk | 說明 |
|--------|---------|---------|------|
| 欄位擷取 | ~180 ms | ~70 ms | lparser 有 regex 編譯開銷 |
| 行過濾 | ~50 ms | ~50 ms | **相當** |
| 欄位投影 | ~50 ms | ~50 ms | **相當** |
| 完整管線 | ~200 ms | ~60 ms | 含 process spawn overhead |
| Store 寫入 | ~200 ms | ~120 ms | 含 CSV 解析與 key lookup |
| auth.log 解析 | ~180 ms | ~75 ms | 同 lparser overhead |

**結論：** `lfilter` 和 `lstore` 的處理速度與 awk 相當；`lparser` 的 POSIX regex 編譯有固定開銷，大量資料時吞吐量達 **10 萬行/秒以上**，足以應付嵌入式環境需求。

---

## BusyBox 整合

詳見 [busybox/README-integration.md](busybox/README-integration.md)。

整合步驟摘要：

1. 將 `busybox/lparser_bb.c`、`lfilter_bb.c`、`lstore_bb.c` 複製到 `<busybox>/miscutils/`
2. 在 `include/applets.h` 加入三個 `APPLET()` 宣告
3. 在 `Config.in` 加入 Kconfig block
4. 在 `miscutils/Kbuild` 加入 `lib-$(CONFIG_…)` 行
5. `make defconfig && make -j$(nproc)`

---

## Toybox / GNU 相容性

| BusyPipe | 等效 GNU/Toybox 工具 |
|----------|-------------------|
| `lparser --regex P --fields …` | `awk '{match($0,/P/,a); …}'` |
| `lfilter --where 'f>=v'` | `awk -F, '$N>=v'` |
| `lfilter --select f1,f2` | `cut -d, -f1,2` |
| `lfilter --contains f=s` | `awk -F, '$N ~ /s/'` |
| `lfilter --format json` | `python3 -c 'import csv,json,sys; …'` |
| `lstore --put/get/delete` | 無對應單一工具 |

CLI 選項風格遵循 GNU long-option 慣例（`--option value`）。

---

## 小組分工

| 成員 | 角色 | 負責內容 |
|------|------|---------|
| 楊杰倫 | 系統整合與測試 | 共用函式庫、Makefile、測試腳本、benchmark、GitHub 文件 |
| 羅章弘 | 解析專家 | `lparser`、POSIX regex、多格式輸出 |
| 吳佳泰 | 串流邏輯官 | `lfilter`、串流過濾、欄位轉換 |
| 潘彥霖 | 儲存架構師 | `lstore`、TTL、buffered write、key-value 索引 |

---

## 常見問題

### `lparser` 在 Windows 上不能使用

原因：Windows + MinGW 缺少 POSIX `regex.h`。  
解法：在 Linux / Docker 執行完整管線：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1
```

### `lstore --get` 沒有輸出

可能原因：
- 尚未用 `--put` 寫入資料
- 查詢的 key 不存在或已過期

解法：先用 `--list` 確認有效資料，再查詢。

### benchmark 需要 python3

benchmark 腳本使用 python3 產生大量測試資料。若環境沒有 python3，可手動準備測試資料後單獨執行工具計時。

---

## 專題背景

本專案對應 UNIX 系統程式設計期末專題：

- 主題：BusyBox 工具擴充（選項 B）
- 方向：嵌入式資料管線工具（Embedded Data Pipeline）
- 技術：C、POSIX API、pipe、fork/exec、file I/O、regex
- 平台：Linux / BusyBox 嵌入式環境

BusyPipe 的設計核心，是將日誌解析、串流過濾與資料保存拆分為三個可組合的命令列工具，以標準輸入輸出作為模組邊界，實現 UNIX Philosophy：**Write programs that do one thing and do it well. Write programs to work together.**
