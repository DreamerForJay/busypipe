# BusyPipe Tasks

這份文件整理目前專案的角色分工方式，並對應 GitHub issue。  
目前先採用「角色制」，等組內最終確認後，再把成員 A / B / C 對應到實際姓名。

## 目前 GitHub Issues

- Issue #1: implement Linux regex backend for lparser
- Issue #2: extend lparser to support auth.log parsing example
- Issue #3: improve lfilter condition parsing and error handling
- Issue #4: improve lstore storage behavior and TTL tests
- Issue #5: add collaboration guide and contribution workflow
- Issue #6: prepare BusyBox integration plan for standalone tools

## 角色分工

### 楊杰倫（系統整合與測試）

負責內容：

- 通用函式庫開發與整體整合
- 自動化測試腳本
- Demo 腳本
- 效能對比與 benchmark
- 專案整體 review 與最後整合

建議對應 issue：

- Issue #4
- Issue #5
- Issue #6

建議工作：

- 維護 `scripts/`
- 維護 `docs/`
- 規劃 `libpipe` / 共用函式庫邊界
- 補 benchmark 與測試流程
- 準備最後展示流程

### 成員 A（解析專家）

負責內容：

- `lparser` 工具開發
- POSIX 正規表示式解析
- 多格式輸出（CSV / JSON）

建議對應 issue：

- Issue #1
- Issue #2

建議工作：

- 完成 Linux regex backend
- 支援 `samples/access.log`
- 支援 `samples/auth.log`
- 確認 CSV / JSONL 輸出格式正確

### 成員 B（串流邏輯官）

負責內容：

- `lfilter` 工具開發
- 串流條件過濾
- 欄位轉換與 Pipe I/O 優化

建議對應 issue：

- Issue #3

建議工作：

- 強化 `--where`
- 補欄位不存在錯誤處理
- 補字串 / 數值比較測試
- 規劃後續欄位轉換能力

### 成員 C（儲存架構師）

負責內容：

- `lstore` 工具開發
- TTL 自動過期管理
- 資料壓縮與檔案式索引設計

建議對應 issue：

- Issue #4

建議工作：

- 強化 `put/get/delete/list/cleanup`
- 補 TTL 測試
- 規劃 buffered write / compression
- 整理檔案儲存格式與索引策略

## 建議開發順序

1. 先完成 Issue #1，確保 `lparser` 正式可用
2. 接著完成 Issue #3 與 Issue #4，讓 pipeline 穩定
3. 再做 Issue #2，補第二種 log 範例
4. 同步補 Issue #5 文件與協作規則
5. 最後做 Issue #6，準備 BusyBox applet 整合

## 目前可驗證內容

### Windows 本機

- `scripts/demo.ps1`
- `scripts/test_store.ps1`

### Linux / Docker

- `scripts/run_linux_demo.ps1`
- `scripts/linux_pipeline_demo.sh`

## 完整 Demo 目標

最後展示時，至少要能完整跑出：

```bash
lparser --regex ... --fields ... --csv < samples/access.log | \
lfilter --where "status>=400" --select "ip,path,status" | \
lstore --db data/linux/errors.tsv --put --key-field ip --ttl 3600
```

並且可再用：

```bash
lstore --db data/linux/errors.tsv --get 192.168.0.4
```

展示查詢結果。

## 後續更新方式

當組內正式決定成員對應後，可把下面這段補上：

```text
成員 A = ______
成員 B = ______
成員 C = ______
```
