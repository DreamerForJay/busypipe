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

## 2. Files to Add

Copy or symlink the following into the BusyBox source tree:

```
busybox-source/
  miscutils/
    lparser.c        ← src/lparser.c (adapted; see §3)
    lfilter.c        ← src/lfilter.c (adapted; see §3)
    lstore.c         ← src/lstore.c  (adapted; see §3)
  include/
    busypipe.h       ← busybox/busypipe.h (shared constants)
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

### 3.5 Common library (`common.c` → `libbb` or inline)

Either:
- Move shared functions (`split_csv_inplace`, `print_csv_row`, etc.) into
  `libbb/` as `busypipe_common.c`, or
- Include them as a static helper file compiled into each applet.

The simpler path for first integration is to `#include "busypipe_common.c"`
directly — not ideal but functional for a prototype.

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

## 7. Prototype BusyBox-adapted Sources

See the files in this directory:

| File | Description |
|---|---|
| `lparser_bb.c` | lparser adapted for BusyBox applet ABI |
| `lfilter_bb.c` | lfilter adapted for BusyBox applet ABI |
| `lstore_bb.c`  | lstore adapted for BusyBox applet ABI |
| `busypipe.h`   | Shared constants (MAX_LINE_LEN, MAX_FIELDS, …) |
