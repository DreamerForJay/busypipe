# BusyPipe × BusyBox Integration Guide

This document explains how to integrate the three BusyPipe applets
(`lparser`, `lfilter`, `lstore`) into a BusyBox source tree so they are
compiled into the single `busybox` multi-call binary.

---

## 1. BusyBox Applet Architecture

BusyBox is a collection of Unix utilities compiled into one binary.
Each utility is called an **applet**.  The binary dispatches to the right
applet via `argv[0]` (or the first argument when invoked as
`busybox <applet> …`).

### Key source files to understand

| File | Purpose |
|---|---|
| `include/applets.h` | Declares every applet with `APPLET(name, …)` macros |
| `include/applet_tables.h` | Generated applet lookup table |
| `Config.in` (top-level) | Kconfig menu entries for each applet |
| `miscutils/` | Where new misc applets typically live |
| `libbb/` | Shared utility library (like BusyPipe's `common.c`) |

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

## 3. Source Adaptations Required

BusyBox applets follow a strict naming convention:

### 3.1 Entry point rename

Each applet's `main()` must be renamed to `<applet>_main()`:

```c
/* standalone: */   int main(int argc, char **argv) { … }
/* BusyBox:    */   int lparser_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
```

### 3.2 Remove `#include <stdio.h>` / system headers

Replace with BusyBox's `libbb.h`:

```c
/* standalone */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* BusyBox */
#include "libbb.h"
```

### 3.3 Replace `die_usage()` / `die_runtime()` with BusyBox helpers

```c
/* standalone */
die_usage("message");
die_runtime("message");

/* BusyBox */
bb_show_usage();          /* prints USAGE_lparser and exits */
bb_error_msg_and_die("message");
```

### 3.4 `--help` / usage string

BusyBox uses a special comment format for the usage string:

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

## 4. Register the Applet

### 4.1 `include/applets.h`

Add one `APPLET()` line per tool (in alphabetical order):

```c
IF_LFILTER(APPLET(lfilter, BB_DIR_USR_BIN, BB_SUID_DROP))
IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
IF_LSTORE( APPLET(lstore,  BB_DIR_USR_BIN, BB_SUID_DROP))
```

### 4.2 `Config.in` (top-level)

Add a `config` block for each applet (e.g. under `menu "Miscellaneous"`):

```kconfig
config LPARSER
    bool "lparser"
    default y
    help
      lparser reads raw log lines from stdin and extracts named fields
      using POSIX extended regular expressions, writing structured CSV
      or JSONL output to stdout.

      Part of the BusyPipe embedded ETL pipeline.

config LFILTER
    bool "lfilter"
    default y
    help
      lfilter reads CSV from stdin, filters rows by condition, projects
      fields, and writes CSV or JSONL output to stdout.

config LSTORE
    bool "lstore"
    default y
    help
      lstore is a file-backed key-value store with TTL support.
      It provides put/get/delete/list/cleanup/count operations.
```

### 4.3 `miscutils/Kbuild`

```make
lib-$(CONFIG_LPARSER) += lparser.o
lib-$(CONFIG_LFILTER) += lfilter.o
lib-$(CONFIG_LSTORE)  += lstore.o
```

### 4.4 `libbb/Kbuild`

在現有 `lib-y` 清單後加入：

```make
lib-y += busypipe_lib.o
```

此行使 `busypipe_lib.c`（由 `busybox/libpipe.c` 複製而來）編譯進 `libbb.a`，
三個 applet 共享同一份實作，不需各自內嵌 static 函式。

---

## 5. Build & Test

```bash
# Download BusyBox source
wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2
cd busybox-1.36.1

# Copy adapted sources
cp /path/to/busypipe/busybox/lparser_bb.c miscutils/lparser.c
cp /path/to/busypipe/busybox/lfilter_bb.c miscutils/lfilter.c
cp /path/to/busypipe/busybox/lstore_bb.c  miscutils/lstore.c

# Patch applets.h, Config.in, miscutils/Kbuild  (see §4)

# Configure (enable our three applets)
make defconfig
echo "CONFIG_LPARSER=y" >> .config
echo "CONFIG_LFILTER=y" >> .config
echo "CONFIG_LSTORE=y"  >> .config
make oldconfig

# Build
make -j$(nproc)

# Verify
./busybox lparser --help
./busybox lfilter --help
./busybox lstore  --help

# Test pipeline
echo '192.168.0.2 - - [30/Apr/2026:08:00:00 +0800] "GET /index.html HTTP/1.1" 404 128' | \
  ./busybox lparser --format nginx --csv | \
  ./busybox lfilter --where 'status>=400' | \
  ./busybox lstore  --db /tmp/test.tsv --put --key-field ip --ttl 3600

./busybox lstore --db /tmp/test.tsv --list
```

---

## 6. Toybox / GNU Interface Compatibility

| Feature | BusyPipe | GNU / Toybox equivalent |
|---|---|---|
| Field extraction | `lparser --regex P --fields …` | `awk '{match(…)}'` |
| Row filter | `lfilter --where 'f>=v'` | `awk -F, '$N>=v'` |
| Field projection | `lfilter --select f1,f2` | `cut -d, -f1,2` |
| Key-value store | `lstore --put/get/delete` | none (custom) |
| CSV output | RFC-4180 subset | `awk/sed` pipelines |
| JSONL output | `--format json` | `jq -R` pipelines |

CLI option style follows GNU long-option conventions (`--option value`),
compatible with BusyBox's `getopt_ulflags()` / `opt_complementary`.

---

## 7. 本目錄檔案一覽

| 檔案 | 說明 |
|---|---|
| `lparser_bb.c` | lparser applet（入口：`lparser_main`，含 `MAIN_EXTERNALLY_VISIBLE`）|
| `lfilter_bb.c` | lfilter applet（入口：`lfilter_main`，含 `MAIN_EXTERNALLY_VISIBLE`）|
| `lstore_bb.c`  | lstore applet（入口：`lstore_main`，含 `MAIN_EXTERNALLY_VISIBLE`）|
| `libpipe.c`    | 共用函式庫實作（對應 `libbb/busypipe_lib.c`）|
| `libpipe.h`    | 共用函式庫介面（純宣告，無 static inline）|
