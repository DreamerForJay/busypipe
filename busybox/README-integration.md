# BusyPipe × BusyBox 整合指南

本文說明如何將三個 BusyPipe applet（`lparser`、`lfilter`、`lstore`）
整合進 BusyBox 原始碼樹，使其編譯為單一 `busybox` multi-call binary。

---

## 1. BusyBox Applet 架構

BusyBox 是將眾多 Unix 工具集合成一支執行檔的工具集。
每個工具稱為 **applet**，執行檔透過 `argv[0]`（或 `busybox <applet> …` 的第一個參數）
派發至對應 applet。

### 關鍵設計：Directive-Based 自動生成

BusyBox 1.36.x 使用 `scripts/gen_build_files.sh` 掃描所有 `.c` 原始檔，
提取嵌入的 directive 並自動生成建置系統所需的檔案：

| Directive | 生成目標 | 說明 |
|---|---|---|
| `//applet:` | `include/applets.h` | 向 binary 的 applet 派發表宣告 applet |
| `//kbuild:` | `*/Kbuild` | 控制哪些 `.o` 檔案被編譯 |
| `//config:` | `*/Config.in` | 建立 Kconfig 選單項目（`make menuconfig` 可見）|
| `//usage:` | `include/usage.h` | `--help` 說明文字 |

> **重要**：`include/applets.h` 是 **generated file**，由
> `gen_build_files.sh` 從 `include/applets.src.h` + `//applet:` directive 生成。
> 直接修改 `applets.h` 會在下次 `gen_build_files.sh` 執行時被覆蓋。

---

## 2. 需要加入的檔案

將以下檔案複製至 BusyBox 原始碼樹：

```
busybox-source/
  miscutils/
    lparser.c          ← busybox/lparser_bb.c（含 //applet: //kbuild: //config: directive）
    lfilter.c          ← busybox/lfilter_bb.c（同上）
    lstore.c           ← busybox/lstore_bb.c （同上）
  libbb/
    busypipe_lib.c     ← busybox/libpipe.c（含 //kbuild:lib-y += busypipe_lib.o）
  include/
    libpipe.h          ← busybox/libpipe.h（共用函式庫介面）
```

複製後執行 `scripts/gen_build_files.sh . .`，讓 BusyBox 自動處理所有 directive。

---

## 3. 各 Applet 的 Directive 說明

### `lparser_bb.c`（→ `miscutils/lparser.c`）

```c
//applet:IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
//kbuild:lib-$(CONFIG_LPARSER) += lparser.o
//kbuild:CFLAGS_lparser.o += -DBUSYBOX_BUILD
//config:config LPARSER
//config:	bool "lparser"
//config:	default y
//config:	help
//config:	  Log parser applet. Part of BusyPipe embedded ETL pipeline.
```

### `lfilter_bb.c`（→ `miscutils/lfilter.c`）

```c
//applet:IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))
//kbuild:lib-$(CONFIG_LFILTER) += lfilter.o
//kbuild:CFLAGS_lfilter.o += -DBUSYBOX_BUILD
//config:config LFILTER
//config:	bool "lfilter"
//config:	default y
//config:	help
//config:	  CSV stream filter applet. Part of BusyPipe embedded ETL pipeline.
```

### `lstore_bb.c`（→ `miscutils/lstore.c`）

```c
//applet:IF_LSTORE(APPLET(lstore, BB_DIR_USR_BIN, BB_SUID_DROP))
//kbuild:lib-$(CONFIG_LSTORE) += lstore.o
//kbuild:CFLAGS_lstore.o += -DBUSYBOX_BUILD
//config:config LSTORE
//config:	bool "lstore"
//config:	default y
//config:	help
//config:	  File-backed key-value store applet. Part of BusyPipe embedded ETL pipeline.
```

### `libpipe.c`（→ `libbb/busypipe_lib.c`）

共用函式庫，三個 applet 共享，進入 `libbb.a`：

```c
//kbuild:lib-y += busypipe_lib.o
```

---

## 4. 重要注意事項

### 4.1 `-DBUSYBOX_BUILD` 旗標

每個 `*_bb.c` 都包含：

```c
#ifndef BUSYBOX_BUILD
int main(int argc, char **argv) { return lparser_main(argc, argv); }
#endif
```

在 BusyBox 建置環境下，`CFLAGS_lparser.o += -DBUSYBOX_BUILD` 
（由 `//kbuild:` directive 設定）停用此 `main()`，
否則多個 applet 各自定義 `main()` 會造成連結錯誤。

### 4.2 `//usage:` 格式規則

BusyBox `//usage:` 行末**不能**有 `\`——`gen_build_files.sh` 自行加入行連接符。
多行說明使用相鄰字串串接：

```c
//usage:#define lparser_trivial_usage "usage string"
//usage:#define lparser_full_usage "\n\n"
//usage:    "First line.\n"
//usage:    "Second line.\n"
```

### 4.3 CRLF 行尾

Windows 工具建立的 `.c` 檔案可能有 CRLF 行尾。
在 `gen_build_files.sh` 執行前需轉換：

```bash
sed -i 's/\r//' miscutils/lparser.c miscutils/lfilter.c miscutils/lstore.c libbb/busypipe_lib.c
```

---

## 5. 自動化建置（一鍵執行）

```bash
# Linux / Docker 環境
bash scripts/build_busybox.sh

# Windows（透過 Docker）
powershell -ExecutionPolicy Bypass -File scripts\run_busybox_build.ps1
```

腳本執行流程：
1. 下載 BusyBox 1.36.1 tarball 並解壓縮
2. 複製 BusyPipe 檔案至 BusyBox 原始碼樹
3. CRLF 轉換（`sed 's/\r//'`）
4. `scripts/gen_build_files.sh . .`（自動生成 applets.h、Kbuild、Config.in）
5. `make defconfig`（`default y` 自動啟用三個 applet）
6. `sed` 停用 `networking/tc`（BusyBox 1.36.x 與 kernel 6.x headers 不相容）
7. `make -j$(nproc)` 編譯
8. 驗證：`busybox --list`、`busybox lparser --help`、完整管線測試

---

## 6. 驗證結果

成功建置後可執行：

```bash
./busybox lparser --help
./busybox lfilter --help
./busybox lstore  --help

# 完整管線
printf '%s\n' \
    '1.2.3.4 - - [01/Jun/2026:12:00:00 +0800] "GET /admin HTTP/1.1" 404 128' \
    '5.6.7.8 - - [01/Jun/2026:12:00:01 +0800] "POST /login HTTP/1.1" 500 64' \
  | ./busybox lparser --format nginx --csv \
  | ./busybox lfilter --where 'status>=400' \
  | ./busybox lstore  --db /tmp/test.tsv --put --key-field ip --ttl 3600

./busybox lstore --db /tmp/test.tsv --list
```

---

## 7. 本目錄檔案一覽

| 檔案 | 說明 |
|---|---|
| `lparser_bb.c` | lparser applet（入口：`lparser_main`，含完整 directive）|
| `lfilter_bb.c` | lfilter applet（入口：`lfilter_main`，含完整 directive）|
| `lstore_bb.c`  | lstore applet（入口：`lstore_main`，含完整 directive）|
| `libpipe.c`    | 共用函式庫實作（含 `//kbuild:lib-y += busypipe_lib.o`）|
| `libpipe.h`    | 共用函式庫介面（純宣告）|
