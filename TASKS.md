# BusyPipe Tasks

這份文件整理目前小組建議分工，並對應 GitHub issue。

## 目前 GitHub Issues

- Issue #1: implement Linux regex backend for lparser
- Issue #2: extend lparser to support auth.log parsing example
- Issue #3: improve lfilter condition parsing and error handling
- Issue #4: improve lstore storage behavior and TTL tests
- Issue #5: add collaboration guide and contribution workflow
- Issue #6: prepare BusyBox integration plan for standalone tools

## 建議分工

### 楊杰倫

負責：

- Issue #6
- 專案整體架構
- BusyBox 整合規劃
- GitHub repo 管理
- 最後整合與期末報告統整

建議工作：

- 補 architecture note
- 決定 `libpipe` 與 applet 邊界
- review 其他人 PR

### 羅章弘

負責：

- Issue #1
- Issue #2

建議工作：

- 完成 `lparser` Linux regex 解析
- 支援 `samples/access.log`
- 補 `samples/auth.log` 範例
- 確認 CSV / JSONL 輸出正確

### 吳佳泰

負責：

- Issue #3

建議工作：

- 強化 `lfilter --where`
- 補欄位不存在錯誤處理
- 補數值 / 字串比較測試

### 潘彥霖

負責：

- Issue #4
- Issue #5

建議工作：

- 強化 `lstore`
- 補 TTL / cleanup 測試
- 整理協作文件
- 維護 README / CONTRIBUTING / demo 說明

## 建議開發順序

1. 先完成 Issue #1，確保 `lparser` 正式可用
2. 接著完成 Issue #3 與 Issue #4，讓 pipeline 穩定
3. 再做 Issue #2，增加第二種 log 範例
4. 同步補 Issue #5 文件
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
