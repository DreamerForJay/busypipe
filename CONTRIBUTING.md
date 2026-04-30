# Contributing Guide

這份文件提供 BusyPipe 小組協作時的基本規則，避免多人同時修改時產生混亂。

## 1. 開發原則

- 每個人優先處理自己被分配的 issue
- 不要直接在 `main` 分支上開發
- 每次修改前先確認自己要改的檔案範圍
- 不要隨意重寫別人的功能或覆蓋未合併的工作

## 2. Git 工作流程

### 建議流程

1. 先同步最新版本
2. 從 `main` 開新 branch
3. 在 branch 上開發
4. 完成後 push 到 GitHub
5. 建立 Pull Request

### 建議 branch 命名

```text
feature/lparser-regex
feature/lfilter-where
feature/lstore-ttl
docs/contributing
```

### 建議 commit message

```text
feat: add Linux regex parsing for lparser
fix: handle missing field in lfilter
test: add TTL cleanup test for lstore
docs: add collaboration guide
```

## 3. 測試方式

### Windows 本機

可直接驗證：

- `lfilter`
- `lstore`

建議先跑：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\demo.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\test_store.ps1
```

### Linux / Docker

完整 pipeline 驗證：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_linux_demo.ps1
```

此流程會驗證：

- `lparser`
- `lfilter`
- `lstore`
- access log 解析與過濾

## 4. 檔案修改責任建議

- `src/lparser.c`
  主要由 parser 負責同學維護

- `src/lfilter.c`
  主要由 filter 負責同學維護

- `src/lstore.c`
  主要由 store / test 負責同學維護

- `README.md`、`docs/`、`CONTRIBUTING.md`
  文件負責同學與組長共同維護

## 5. 注意事項

- 不要提交 `build/` 與 `data/` 內容
- 不要提交真實帳號密碼、token、或含個資的 log
- 若修改 CLI 參數或輸出格式，請同步更新 README 與測試腳本
- 若發現他人工作和自己衝突，先在 issue 或群組內確認再改

## 6. Pull Request 建議內容

PR 內容至少包含：

1. 這次改了什麼
2. 對應哪個 issue
3. 怎麼測試
4. 有沒有已知限制
