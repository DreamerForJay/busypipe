# BusyPipe Progress

這份文件追蹤 BusyPipe 專案整體進度。

## 1. 專案總覽

- 專題方向：選項 B — BusyBox 工具擴充
- 實作主題：嵌入式資料管線工具（Embedded Data Pipeline）
- 專案名稱：BusyPipe
- 核心流程：`lparser | lfilter | lstore`

---

## 2. 已完成項目

### 程式碼

- [x] `src/common.c` / `include/common.h` — 共用函式庫
- [x] `src/lparser.c` — 完整 Linux regex backend
  - [x] POSIX 擴充正規表示式解析
  - [x] CSV 輸出（含 header）
  - [x] JSONL 輸出（JSON 轉義正確）
  - [x] `--format nginx/apache/auth` 預設格式
  - [x] `--stats` matched/skipped 統計
  - [x] `--help` 詳細說明
- [x] `src/lfilter.c` — 完整 CSV 串流過濾器
  - [x] `--where` 數值/字串比較過濾（`==` `!=` `>` `>=` `<` `<=`）
  - [x] `--contains` 子字串過濾
  - [x] `--select` 欄位投影
  - [x] `--format csv/json` 輸出格式
  - [x] 欄位不存在時的錯誤訊息（含可用欄位清單）
  - [x] `--help` 詳細說明
- [x] `src/lstore.c` — 完整 key-value store
  - [x] `--put`（含 buffered write，每 64 行或 128 KiB flush）
  - [x] `--get`（回傳最新有效記錄）
  - [x] `--delete`（atomic rewrite）
  - [x] `--list`
  - [x] `--cleanup`（atomic rewrite，移除過期記錄）
  - [x] `--count`（計算有效筆數）
  - [x] `--ttl` TTL 自動過期
  - [x] `--stats` 操作統計
  - [x] `--help` 詳細說明

### BusyBox 整合

- [x] `busybox/libpipe.h` — 共用函式庫介面（純宣告，無 static inline）
- [x] `busybox/libpipe.c` — 共用函式庫實作（整合後放入 `libbb/busypipe_lib.c`）
- [x] `busybox/lparser_bb.c` — BusyBox applet 適配版（入口：`lparser_main`）
- [x] `busybox/lfilter_bb.c` — BusyBox applet 適配版（入口：`lfilter_main`）
- [x] `busybox/lstore_bb.c`  — BusyBox applet 適配版（入口：`lstore_main`）
- [x] `busybox/README-integration.md` — 完整整合指南（含 applets.h / Config.in / miscutils/Kbuild / libbb/Kbuild 修改說明）
- [x] 所有 bb 版本編譯驗證通過

### 文件

- [x] `README.md` — 完整使用說明、範例、Benchmark、BusyBox 整合說明
- [x] `docs/spec.md` — 開發規格
- [x] `docs/man/lparser.1` — man page
- [x] `docs/man/lfilter.1` — man page
- [x] `docs/man/lstore.1` — man page
- [x] `CONTRIBUTING.md` — 協作指南
- [x] `TASKS.md` — 任務分工
- [x] GitHub issues 建立

### 建置與測試

- [x] `Makefile`（Linux 相容）
  - [x] `make`          — 建置
  - [x] `make test`     — smoke test（9 個場景）
  - [x] `make bench`    — benchmark
  - [x] `make install`  — 安裝到 PREFIX
  - [x] `make install-man` — 安裝 man pages
  - [x] `make clean`
- [x] `scripts/linux_pipeline_demo.sh` — 完整雙管線 Demo
- [x] `scripts/demo_auth.sh` — auth.log 管線 Demo
- [x] `scripts/benchmark.sh` — BusyPipe vs GNU awk 效能比較
- [x] `scripts/demo.ps1` — Windows PowerShell Demo
- [x] `scripts/test_store.ps1` — lstore 回歸測試
- [x] `scripts/run_linux_demo.ps1` — Windows 啟動 Docker Demo
- [x] `samples/nginx.log` — Nginx Combined Log Format 樣本（`--format nginx`）
- [x] `samples/apache.log` — Apache Common Log Format 樣本（`--format apache`，含 `-` bytes）
- [x] `samples/custom.log` — 應用程式事件日誌樣本（自訂 `--regex + --fields`）

### 功能驗證

- [x] `lparser | lfilter | lstore` 完整 access.log 管線
- [x] `lparser | lfilter | lstore` 完整 auth.log 管線
- [x] CSV 與 JSONL 輸出格式
- [x] TTL 自動過期機制
- [x] 欄位不存在時的錯誤處理
- [x] BusyBox 適配版本功能驗證

---

## 3. 全面驗證流程

### 第一層：獨立工具（standalone）

| 指令 | 說明 | 環境 |
|------|------|------|
| `make test` | 9 個 smoke test | Linux / Docker |
| `bash scripts/linux_pipeline_demo.sh` | access.log + auth.log 雙管線展示 | Linux / Docker |
| `bash scripts/demo_auth.sh` | auth.log SSH 失敗登入分析 | Linux / Docker |
| `make bench` | BusyPipe vs GNU awk 效能比較 | Linux / Docker |
| `powershell scripts\test_store.ps1` | lstore CRUD 回歸測試 | Windows |
| `powershell scripts\demo.ps1` | lfilter / lstore 展示 | Windows |

### 第二層：BusyBox Applet 適配版

驗證 `libpipe.c`（共用函式庫）與各 `*_bb.c` 的整合，**不需要 BusyBox 原始碼**。

| 指令 | 說明 |
|------|------|
| `make test-bb` | 完整 22 項驗證（編譯 + 功能 + 一致性）|
| `bash scripts/test_bb_applets.sh` | 同上，直接執行腳本 |

驗證項目涵蓋：
- `libpipe.c` 獨立編譯為目的檔
- 三個 `*_bb.c` 連結 `libpipe.o` 成功
- `lparser_main / lfilter_main / lstore_main` 功能正確（各 CLI 選項）
- 完整管線（access.log + auth.log）
- applet 版輸出與 standalone 版本完全相同

> Windows 使用者：
> ```powershell
> docker run --rm -v "${PWD}:/work" -w /work gcc:14 sh scripts/test_bb_applets.sh
> ```

### 第三層：完整 BusyBox 整合（✅ 已驗證通過）

| 指令 | 說明 |
|------|------|
| `powershell scripts\run_busybox_build.ps1` | 一鍵建置（Windows Docker）|
| `bash scripts/build_busybox.sh` | 一鍵建置（Linux）|
| `./busybox --list \| grep -E 'lparser\|lfilter\|lstore'` | 確認三個 applet 存在 |
| `./busybox lparser --format nginx --csv \| lfilter \| lstore` | 完整管線驗證 |

**已驗證功能：**
- `[PASS] lparser 在 busybox binary 中`
- `[PASS] lfilter 在 busybox binary 中`
- `[PASS] lstore 在 busybox binary 中`
- 完整 access.log + auth.log 雙管線
- `./busybox lparser --help` 輸出正確說明

詳見 `busybox/README-integration.md` 與 `docs/troubleshooting.md`。

---

## 4. 架構亮點

### POSIX regex + 預設格式（lparser）
- `--format nginx/apache/auth` 讓使用者免寫 regex
- 自訂 `--regex` 支援任意日誌格式
- JSON 輸出含正確 escape（控制字元 `\uXXXX`）

### 串流過濾（lfilter）
- 自動判斷數值 vs 字串比較
- `--contains` 子字串過濾（補 `--where` 無法處理的場景）
- `--format json` 直接輸出 JSONL，方便後端處理
- 錯誤欄位名稱時輸出可用欄位清單

### Buffered Write（lstore）
- 每 64 行或 128 KiB 執行一次 `fflush()`
- 減少高吞吐量場景下的 syscall 次數

### Atomic Rewrite（lstore）
- `--cleanup` / `--delete` 先寫 `.tmp` 再 `rename()`
- 跨裝置時 fallback 為 copy + remove，確保不遺失資料

### BusyBox applet 架構
- `main()` 改名為 `lXXX_main()` 並標記 `MAIN_EXTERNALLY_VISIBLE`
- `libpipe.c` + `libpipe.h` 取代舊有 `busypipe.h` 的 static inline 做法
- 三個 applet 共享同一份 `busypipe_lib.o`（對應 `libbb/busypipe_lib.c`）
- `#ifndef BUSYBOX_BUILD` 包裝維持獨立編譯能力（不需完整 BusyBox 環境）
- 使用 BusyBox `//usage:` 格式撰寫 help string

---

## 5. 角色分工

| 成員 | 角色 | 主要貢獻 |
|------|------|---------|
| 楊杰倫 | 系統整合與測試 | Makefile、共用函式庫、測試腳本、benchmark、BusyBox 整合、GitHub 文件 |
| 羅章弘 | 解析專家 | `lparser`（POSIX regex、預設格式、CSV/JSONL 輸出） |
| 吳佳泰 | 串流邏輯官 | `lfilter`（過濾、投影、JSON 輸出、錯誤處理） |
| 潘彥霖 | 儲存架構師 | `lstore`（TTL、buffered write、atomic rewrite、索引） |

---

## 6. GitHub Issue 對應

| Issue | 狀態 | 說明 |
|-------|------|------|
| #1 Linux regex backend for lparser | ✅ 完成 | `--format` 預設格式 + 自訂 regex |
| #2 auth.log parsing example | ✅ 完成 | `--format auth` + `demo_auth.sh` |
| #3 lfilter condition parsing | ✅ 完成 | `--contains` + JSON 輸出 + 錯誤訊息 |
| #4 lstore behavior and TTL | ✅ 完成 | buffered write + atomic rewrite + stats |
| #5 協作與文件流程 | ✅ 完成 | README / CONTRIBUTING / man pages |
| #6 BusyBox integration plan | ✅ 完成 | busybox/ 目錄 + README-integration.md |
| #7 integration / demo / benchmark | ✅ 完成 | linux_pipeline_demo.sh + benchmark.sh |

---

## 7. 已知限制

- `lparser` 在 Windows + MinGW 上僅為提示用 stub（缺少 `regex.h`）
- 不支援含逗號的 quoted CSV 欄位
- 單行超過 4096 bytes 會被截斷
- `lstore` 不支援並發寫入（無 file locking）
- benchmark 需要 python3 產生測試資料

---

## 8. 建議下一步（擴充方向）

1. **Quoted CSV 支援** — 處理欄位值含逗號的情況
2. **lstore 壓縮** — 使用 zlib 或 LZ4 壓縮 TSV 資料
3. **lstore file locking** — 支援並發安全寫入
4. **lfilter 多條件 AND/OR** — 支援 `--where A --where B`（目前限單條件）
5. **實際 BusyBox 整合** — 在 BusyBox 1.36 上完成完整編譯與測試
6. **更多預設格式** — syslog、journald、CSV 直通模式
