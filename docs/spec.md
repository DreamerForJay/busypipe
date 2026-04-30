# BusyPipe 開發規格

## 1. 專案目標

BusyPipe 要實作一套適用於資源受限 Linux 環境的輕量級 ETL 工具鏈：

1. `lparser`：從原始日誌中擷取欄位
2. `lfilter`：對結構化資料做過濾與轉換
3. `lstore`：將結果寫入檔案式儲存

第一階段先完成可獨立執行的 MVP，之後再移植到 BusyBox applet。

目標平台：

- 主要平台：Linux / BusyBox 相容環境
- 次要平台：Windows 僅作為部分模組的開發主機

## 2. 串流資料格式

### 2.1 MVP 內部標準格式

MVP 階段工具間的標準格式先統一為 CSV。

- 第一行：header
- 後續每行：一筆資料
- 分隔符號：逗號
- 轉義處理：目前只做最小支援，完整 quoted CSV 後續再補

範例：

```csv
ip,time,method,path,status
192.168.0.2,30/Apr/2026:08:00:00 +0800,GET,/index.html,200
192.168.0.3,30/Apr/2026:08:00:02 +0800,GET,/admin,404
```

### 2.2 後續擴充方向

- `lfilter` 支援 JSONL 輸入與輸出
- 更緊湊的內部記錄格式
- `lstore` 壓縮機制

## 3. 工具規格

## 3.1 `lparser`

用途：

- 從標準輸入讀入原始文字
- 以 POSIX regex 進行欄位擷取
- 輸出結構化資料

必要參數：

- `--regex <pattern>`
- `--fields <name1,name2,...>`

輸出參數：

- `--csv`
- `--json`
- 預設：CSV

操作參數：

- `--stats`：將 matched/skipped 統計輸出到 stderr

行為定義：

- Capture group 數量需與欄位數一致
- 不符合 regex 的行直接略過
- regex 或 CLI 參數錯誤時需回傳非零 exit code

## 3.2 `lfilter`

用途：

- 從標準輸入讀取 CSV
- 依條件過濾資料列
- 可選擇只輸出部分欄位

參數：

- `--where "<field><op><value>"`
- `--select "field1,field2,..."`

支援運算子：

- `==`
- `!=`
- `>`
- `>=`
- `<`
- `<=`

行為定義：

- 第一列視為 header
- 若左右兩側都看起來是數字，就採用數值比較
- 輸出維持 CSV + header

## 3.3 `lstore`

用途：

- 將標準輸入資料寫入檔案式 store
- 後續提供查詢、刪除與清理功能

模式：

- `--put`
- `--get <key>`
- `--delete <key>`
- `--list`
- `--cleanup`

必要參數：

- `--db <path>`

`put` 模式參數：

- `--key-field <name>`
- `--ttl <seconds>`，可省略

儲存格式：

```text
key<TAB>expires_at_epoch<TAB>raw_csv_row
```

行為定義：

- `--put` 會從 stdin 讀入 CSV 並逐列寫入
- `expires_at_epoch=0` 代表永不過期
- `--cleanup` 會重寫資料檔，移除已過期資料

## 4. 共用函式庫範圍

`libpipe` 目前提供：

- 去除換行
- 逗號切欄
- 欄位名稱查找
- 數值字串判斷
- 基本錯誤輸出

後續可加入：

- quoted CSV 解析
- JSON helper
- BusyBox applet 封裝

## 5. 開發里程碑

1. 先穩定獨立 CLI 工具行為
2. 補 sample fixture 與回歸測試
3. 擴充 CSV / JSONL 支援
4. 在 `lstore` 加入壓縮與 buffered write
5. 移植為 BusyBox applet
