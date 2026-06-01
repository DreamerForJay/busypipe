# BusyPipe × BusyBox 整合指南

本文說明如何將三個 BusyPipe applet（`lparser`、`lfilter`、`lstore`）
整合進 BusyBox 原始碼樹，使其編譯為單一 `busybox` multi-call binary。

---

## 1. BusyBox Applet 架構

BusyBox 是將眾多 Unix 工具集合成一支執行檔的工具集。
每個工具稱為 **applet**，執行檔透過 `argv[0]`（或 `busybox <applet> …` 的第一個參數）
派發至對應 applet。

### 關鍵原始碼檔案

| 檔案 | 用途 |
|---|---|
| `include/applets.h` | 以 `APPLET(name, …)` 巨集宣告每個 applet |
| `include/applet_tables.h` | 建置時自動產生的 applet 查找表 |
| `Config.in`（頂層）| 每個 applet 的 Kconfig 選單項目 |
| `miscutils/` | 新雜項 applet 的慣用放置目錄 |
| `libbb/` | 共用工具函式庫（對應 BusyPipe 的 `common.c`）|

---

## 2. 需要加入的檔案

將以下檔案複製至 BusyBox 原始碼樹：

```
busybox-source/
  miscutils/
    lparser.c          ← busybox/lparser_bb.c（applet 入口：lparser_main）
    lfilter.c          ← busybox/lfilter_bb.c（applet 入口：lfilter_main）
    lstore.c           ← busybox/lstore_bb.c （applet 入口：lstore_main）
  libbb/
    busypipe_lib.c     ← busybox/libpipe.c（共用函式庫實作，編譯進 libbb.a）
  include/
    libpipe.h          ← busybox/libpipe.h（共用函式庫介面，僅宣告）
```

---

## 3. 需要的原始碼調整

BusyBox applet 遵循嚴格的命名規範，以下說明各項調整（均已在 `*_bb.c` 中完成）。

### 3.1 入口函式重新命名

每個 applet 的 `main()` 必須改名為 `<applet>_main()`，
並加上 `MAIN_EXTERNALLY_VISIBLE` 屬性：

```c
/* 獨立執行版 */   int main(int argc, char **argv) { … }
/* BusyBox 版  */  int lparser_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
```

`#ifndef BUSYBOX_BUILD` 包裝提供獨立編譯時的 `main()` 入口，
BusyBox 建置時透過 `-DBUSYBOX_BUILD` 停用它（見 §4.3）。

### 3.2 系統標頭替換

BusyBox 整合後，將獨立的系統標頭替換為 BusyBox 的統一標頭：

```c
/* 獨立編譯 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* BusyBox 整合後替換為 */
#include "libbb.h"
```

### 3.3 錯誤處理函式替換

```c
/* 獨立編譯 */
die_usage("message");
die_runtime("message");

/* BusyBox 整合後替換為 */
bb_show_usage();                   /* 輸出 USAGE_lparser 後結束 */
bb_error_msg_and_die("message");
```

### 3.4 說明字串格式

BusyBox 使用特殊的 `//usage:` 註解格式撰寫說明字串（已在 `*_bb.c` 中完成）：

```c
//usage:#define lparser_trivial_usage \
//usage:    "--regex PATTERN --fields f1,f2 [--csv|--json] [--stats]"
//usage:#define lparser_full_usage "\n\n" \
//usage:    "Parse raw log lines into structured CSV or JSONL.\n" \
//usage:    …
```

### 3.5 共用函式庫（`libpipe.c` → `libbb/`）

共用邏輯已提取為獨立的 `libpipe.c` + `libpipe.h`，取代舊有 `busypipe.h`
的 `static inline` 做法（每個 applet 各複製一份）。

整合步驟：

1. 複製 `busybox/libpipe.c` 至 `<busybox>/libbb/busypipe_lib.c`
2. 複製 `busybox/libpipe.h` 至 `<busybox>/include/libpipe.h`
3. 在 `libbb/Kbuild` 加入（見 §4.4）：
   ```make
   lib-y += busypipe_lib.o
   ```

如此三個 applet 共享同一份 `busypipe_lib.o`，符合 BusyBox `libbb` 的函式庫架構。

---

## 4. 向 BusyBox 建置系統註冊 Applet

### 4.1 `include/applets.h`

依字母順序加入三行 `APPLET()` 宣告：

```c
IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))
IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
IF_LSTORE( APPLET(lstore,  BB_DIR_USR_BIN, BB_SUID_DROP))
```

### 4.2 `miscutils/Config.in`

在 `miscutils/Config.in` 末尾加入三個 `config` 區塊：

```kconfig
config LPARSER
    bool "lparser"
    default y
    help
      lparser 從 stdin 讀取原始日誌，以 POSIX 擴充正規表示式
      擷取欄位，輸出結構化 CSV 或 JSONL。
      BusyPipe 嵌入式 ETL 管線的一部分。

config LFILTER
    bool "lfilter"
    default y
    help
      lfilter 從 stdin 讀取 CSV，依條件過濾資料列、
      投影欄位，並輸出 CSV 或 JSONL。

config LSTORE
    bool "lstore"
    default y
    help
      lstore 是支援 TTL 的檔案式 key-value store，
      提供 put/get/delete/list/cleanup/count 操作。
```

### 4.3 `miscutils/Kbuild`

加入三行目的檔規則，並設定 `-DBUSYBOX_BUILD` 停用獨立執行包裝：

```make
lib-$(CONFIG_LPARSER) += lparser.o
CFLAGS_lparser.o     += -DBUSYBOX_BUILD
lib-$(CONFIG_LFILTER) += lfilter.o
CFLAGS_lfilter.o     += -DBUSYBOX_BUILD
lib-$(CONFIG_LSTORE)  += lstore.o
CFLAGS_lstore.o      += -DBUSYBOX_BUILD
```

### 4.4 `libbb/Kbuild`

在現有 `lib-y` 清單後加入：

```make
lib-y += busypipe_lib.o
```

此行使 `busypipe_lib.c`（由 `busybox/libpipe.c` 複製而來）編譯進 `libbb.a`，
三個 applet 共享同一份實作，不需各自內嵌 static 函式。

---

## 5. 建置與驗證

```bash
# 下載並解壓縮 BusyBox 原始碼
wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2
cd busybox-1.36.1

# 複製 BusyPipe 檔案（以下路徑依實際位置調整）
cp /path/to/busypipe/busybox/lparser_bb.c  miscutils/lparser.c
cp /path/to/busypipe/busybox/lfilter_bb.c  miscutils/lfilter.c
cp /path/to/busypipe/busybox/lstore_bb.c   miscutils/lstore.c
cp /path/to/busypipe/busybox/libpipe.c     libbb/busypipe_lib.c
cp /path/to/busypipe/busybox/libpipe.h     include/libpipe.h

# 修改 include/applets.h、miscutils/Config.in、
# miscutils/Kbuild、libbb/Kbuild（見 §4）

# 最小化設定：allnoconfig 預設停用所有 applet，避免 defconfig 啟用的
# 大量 applet 與新版 kernel headers（6.x）產生相容性問題。
make allnoconfig
printf 'CONFIG_LPARSER=y\nCONFIG_LFILTER=y\nCONFIG_LSTORE=y\n' >> .config
make oldconfig

# 編譯
make -j"$(nproc)"

# 驗證 --help
./busybox lparser --help
./busybox lfilter --help
./busybox lstore  --help

# 完整管線測試
echo '192.168.0.2 - - [30/Apr/2026:08:00:00 +0800] "GET /index.html HTTP/1.1" 404 128' | \
  ./busybox lparser --format nginx --csv | \
  ./busybox lfilter --where 'status>=400' | \
  ./busybox lstore  --db /tmp/test.tsv --put --key-field ip --ttl 3600

./busybox lstore --db /tmp/test.tsv --list
```

> **自動化建置**：上述步驟已封裝於 `scripts/build_busybox.sh`，
> 搭配 Docker 可從 Windows 一鍵執行：
> ```powershell
> powershell -ExecutionPolicy Bypass -File scripts\run_busybox_build.ps1
> ```

---

## 6. Toybox / GNU 介面相容性

| 功能 | BusyPipe | GNU / Toybox 等效 |
|---|---|---|
| 欄位擷取 | `lparser --regex P --fields …` | `awk '{match(…)}'` |
| 資料列過濾 | `lfilter --where 'f>=v'` | `awk -F, '$N>=v'` |
| 欄位投影 | `lfilter --select f1,f2` | `cut -d, -f1,2` |
| Key-value 儲存 | `lstore --put/get/delete` | 無對應單一工具 |
| CSV 輸出 | RFC-4180 子集 | `awk/sed` 管線 |
| JSONL 輸出 | `--format json` | `jq -R` 管線 |

CLI 選項風格遵循 GNU long-option 慣例（`--option value`），
相容於 BusyBox 的 `getopt_ulflags()` / `opt_complementary`。

---

## 7. 本目錄檔案一覽

| 檔案 | 說明 |
|---|---|
| `lparser_bb.c` | lparser applet（入口：`lparser_main`，含 `MAIN_EXTERNALLY_VISIBLE`）|
| `lfilter_bb.c` | lfilter applet（入口：`lfilter_main`，含 `MAIN_EXTERNALLY_VISIBLE`）|
| `lstore_bb.c`  | lstore applet（入口：`lstore_main`，含 `MAIN_EXTERNALLY_VISIBLE`）|
| `libpipe.c`    | 共用函式庫實作（對應 `libbb/busypipe_lib.c`）|
| `libpipe.h`    | 共用函式庫介面（純宣告，無 static inline）|
