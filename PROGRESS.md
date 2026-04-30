# BusyPipe Progress

這份文件用來追蹤 BusyPipe 專案整體進度，避免資訊分散在 README、issue 與群組訊息中。

## 1. 專案總覽

- 專題方向：選項 B - BusyBox 工具擴充
- 實作主題：嵌入式資料管線工具（Embedded Data Pipeline）
- 專案名稱：BusyPipe
- 核心流程：`lparser | lfilter | lstore`

## 2. 目前完成項目

### 文件與協作

- [x] 提案書完成並提交
- [x] GitHub repo 建立
- [x] `README.md` 完成
- [x] `docs/spec.md` 完成
- [x] `CONTRIBUTING.md` 完成
- [x] `TASKS.md` 完成
- [x] GitHub issues 建立

### 工具與程式骨架

- [x] `src/common.c` / `include/common.h`
- [x] `src/lparser.c` 骨架建立
- [x] `src/lfilter.c` MVP 完成
- [x] `src/lstore.c` MVP 完成

### 測試與展示

- [x] Windows demo 腳本：`scripts/demo.ps1`
- [x] Windows store 測試腳本：`scripts/test_store.ps1`
- [x] Linux pipeline demo：`scripts/linux_pipeline_demo.sh`
- [x] Windows 啟動 Linux demo：`scripts/run_linux_demo.ps1`
- [x] Docker Linux 環境跑通 `lparser | lfilter | lstore`

## 3. 目前可展示成果

### Windows 本機

可直接展示：

- `lfilter` 條件過濾
- `lstore` 的 `put/get/delete/list/cleanup`
- demo 與基本測試流程

### Linux / Docker

可直接展示：

- `lparser` 正式 regex backend
- `lparser | lfilter | lstore` 完整流程
- access log 解析、過濾、存入、查詢

## 4. 尚未完成項目

### `lparser`

- [ ] 補 `samples/auth.log` 解析
- [ ] 補更完整 JSON / CSV 輸出測試
- [ ] 補非法 regex / 欄位數不符錯誤測試

### `lfilter`

- [ ] 補更完整字串比較測試
- [ ] 強化錯誤訊息
- [ ] 規劃欄位轉換能力

### `lstore`

- [ ] 規劃壓縮機制
- [ ] 規劃 buffered write
- [ ] 補更完整索引設計說明

### 整體專案

- [ ] benchmark 與效能比較
- [ ] BusyBox applet 整合規劃
- [ ] 期末報告與簡報內容補齊

## 5. 目前角色分工

- 楊杰倫（系統整合與測試）
  - 通用函式庫、GitHub 文件、測試驗證、自動化測試與 Demo 腳本
  - 效能比較、整體整合、展示流程

- 羅章弘（解析專家）
  - `lparser`
  - POSIX regex
  - JSON / CSV 輸出

- 吳佳泰（串流邏輯官）
  - `lfilter`
  - 串流條件過濾
  - 欄位轉換與 Pipe I/O 優化

- 潘彥霖（儲存架構師）
  - `lstore`
  - TTL
  - 壓縮與 key-value 索引規劃

## 6. GitHub Issue 對應

- Issue #1：Linux regex backend for `lparser`
- Issue #2：`auth.log` parsing example
- Issue #3：`lfilter` condition parsing and error handling
- Issue #4：`lstore` behavior and TTL tests
- Issue #5：協作與文件流程
- Issue #6：BusyBox integration plan
- Issue #7：integration / demo / benchmark workflow

## 7. 測試方式

### Windows 本機測試

```powershell
powershell -ExecutionPolicy Bypass -File scripts\demo.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\test_store.ps1
```

### Linux / Docker 完整測試

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1
```

## 8. 目前已知限制

- Windows + MinGW 缺少 POSIX `regex.h`
- 因此 `lparser` 在 Windows 上目前僅為 stub
- 完整 `lparser` 驗證需在 Linux / Docker 進行
- `build/` 與 `data/` 為執行產物，不應提交到 GitHub

## 9. 建議下一步

1. 完成 `lparser` 的第二種 log 範例
2. 開始 benchmark
3. 補 BusyBox 整合設計說明
4. 整理期末簡報與書面報告素材
