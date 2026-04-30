# BusyPipe

BusyPipe 是一個為 UNIX 系統程式設計期末專題所實作的輕量級 ETL（Extract, Transform, Load）工具鏈。  
專案目標是在資源受限的 Linux / BusyBox 環境中，提供一組可透過 UNIX pipe 串接的小型資料處理工具，實踐 UNIX Philosophy：

- 一個工具只做好一件事
- 工具之間透過標準輸入 / 輸出協同工作
- 保持低依賴、可組合、可移植

目前專案以獨立命令列工具為第一階段目標，待功能穩定後，再整合進 BusyBox applet 架構。

## 專案目標

BusyPipe 專注於「嵌入式資料管線工具」場景，預計完成三個核心工具：

1. `lparser`
將原始日誌或純文字資料解析為結構化欄位。

2. `lfilter`
對結構化資料進行條件篩選、欄位投影與格式轉換。

3. `lstore`
將處理後的資料寫入檔案式 key-value store，並支援 TTL 與基本查詢操作。

## 小組分工

- 楊杰倫（系統整合與測試）
  - 負責通用函式庫開發、GitHub 文件、測試驗證、自動化測試與 Demo 腳本
  - 執行與原版工具之效能比較、整體整合與展示流程整理

- 羅章弘（解析專家）
  - 負責 `lparser`
  - 實作 POSIX 正規表示式解析引擎
  - 實作 JSON / CSV 結構化輸出

- 吳佳泰（串流邏輯官）
  - 負責 `lfilter`
  - 設計串流條件過濾、欄位轉換機制
  - 處理 Pipe I/O 行為與相關優化

- 潘彥霖（儲存架構師）
  - 負責 `lstore`
  - 實作 TTL 自動過期管理
  - 規劃資料壓縮與檔案式 key-value 索引

## 目前功能

### `lparser`

- 設計目標：使用 POSIX regex 擷取欄位
- 支援輸出 CSV / JSONL
- Windows + MinGW 環境下因缺少 `regex.h`，目前編譯為提示用 stub
- Linux 環境將作為正式解析後端

### `lfilter`

- 從 `stdin` 讀取 CSV 串流
- 支援 `--where` 條件式過濾
- 支援 `--select` 欄位投影
- 預設保留 header 並輸出 CSV

### `lstore`

- 使用檔案式 TSV 格式保存資料
- 支援：
  - `--put`
  - `--get`
  - `--delete`
  - `--list`
  - `--cleanup`
- 支援 `--ttl`
- `--get` 的語意為：若同一個 key 有多筆有效資料，回傳最新寫入的一筆

## 專案結構

```text
busypipe/
  docs/
    spec.md              # 開發規格
  include/
    common.h             # 共用標頭
  src/
    common.c             # 共用函式
    lparser.c            # 解析器
    lfilter.c            # 過濾器
    lstore.c             # 儲存器
  samples/
    access.log           # 範例 access log
    auth.log             # 範例 auth log
  scripts/
    demo.ps1             # MVP 示範腳本
    test_store.ps1       # lstore 回歸測試
    run_linux_demo.ps1   # Windows 啟動 Linux container demo
    linux_pipeline_demo.sh
  data/                  # 執行時輸出資料
  Makefile
```

## 目前狀態

- Windows 本機可直接驗證：
  - `lfilter`
  - `lstore`
  - `scripts/demo.ps1`
  - `scripts/test_store.ps1`

- Linux / Docker 已驗證完整 pipeline：
  - `lparser | lfilter | lstore`
  - `scripts/run_linux_demo.ps1`
  - `scripts/linux_pipeline_demo.sh`

- GitHub 協作文件已建立：
  - `README.md`
  - `docs/spec.md`
  - `CONTRIBUTING.md`
  - `TASKS.md`

- GitHub issues 已建立，可直接分工認領

## 建置方式

### 使用 `make`

```bash
make
```

### 使用 `gcc` 直接編譯

如果環境沒有 `make`，可直接手動編譯：

```bash
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 -c src/common.c -o build/common.o
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 src/lfilter.c build/common.o -o build/lfilter.exe
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 src/lstore.c build/common.o -o build/lstore.exe
gcc -Iinclude -Wall -Wextra -Werror -std=c11 -O2 src/lparser.c build/common.o -o build/lparser.exe
```

## 快速開始

### 1. 執行 MVP Demo

```powershell
powershell -ExecutionPolicy Bypass -File scripts\demo.ps1
```

### 2. 執行 `lstore` 回歸測試

```powershell
powershell -ExecutionPolicy Bypass -File scripts\test_store.ps1
```

### 3. 在 Linux container 中跑完整 pipeline

如果你和組員目前主要在 Windows 開發，可以直接透過 Docker 啟動 Linux 環境，驗證真正的 `lparser | lfilter | lstore`：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1
```

這個腳本會在 Linux container 內：

- 編譯 `lparser`
- 編譯 `lfilter`
- 編譯 `lstore`
- 解析 `samples/access.log`
- 過濾 `status >= 400`
- 將結果寫入 `data/linux/errors.tsv`

### 4. 手動測試 `lfilter`

```powershell
@'
ip,time,method,path,status
192.168.0.2,30/Apr/2026:08:00:00 +0800,GET,/index.html,200
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@ | build\lfilter.exe --where "status>=400" --select "ip,path,status"
```

### 5. 手動測試 `lstore`

```powershell
@'
ip,time,method,path,status
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
192.168.0.4,30/Apr/2026:08:00:03 +0800,POST,/login,500
'@ | build\lstore.exe --db data\errors.tsv --put --key-field ip --ttl 3600
```

查詢：

```powershell
build\lstore.exe --db data\errors.tsv --get 192.168.0.4
```

列出全部：

```powershell
build\lstore.exe --db data\errors.tsv --list
```

清理過期資料：

```powershell
build\lstore.exe --db data\errors.tsv --cleanup
```

## 平台說明

專案目標執行平台是 Linux。  
目前這台 Windows + MinGW 開發環境沒有提供 POSIX `regex.h`，因此：

- `lparser` 在本機僅能編譯為提示用版本
- `lfilter` 與 `lstore` 可正常開發與驗證
- 真正的 regex 解析功能需在 Linux 環境測試

## 開發里程碑

1. 穩定 standalone CLI 工具行為
2. 補 sample fixture 與回歸測試
3. 強化 CSV / JSONL 支援
4. 為 `lstore` 加入壓縮與 buffered write
5. 整合進 BusyBox applet

## 專題背景

本專案對應 UNIX 系統程式設計期末專題：

- 主題：BusyBox 工具擴充
- 方向：嵌入式資料管線工具（Embedded Data Pipeline）

BusyPipe 的設計核心，是將日誌解析、串流過濾與資料保存拆分為三個可組合的命令列工具，並以標準輸入輸出作為模組邊界，建立可展示、可擴充、可測試的系統程式設計作品。
