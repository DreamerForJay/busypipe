# BusyPipe × BusyBox 整合除錯紀錄

本文件整理將 BusyPipe 整合進 BusyBox 1.36.1 建置流程時，
實際遇到的所有問題與最終解決方案，供報告撰寫與日後參考使用。

---

## 目錄

1. [環境背景](#環境背景)
2. [問題總覽](#問題總覽)
3. [問題詳細記錄](#問題詳細記錄)
4. [最終成功流程](#最終成功流程)
5. [關鍵知識整理](#關鍵知識整理)

---

## 環境背景

| 項目 | 版本 |
|------|------|
| 開發環境 | Windows 11 + PowerShell 5.1 |
| 建置環境 | Docker `gcc:14`（Debian bookworm）|
| BusyBox | 1.36.1 |
| gcc | 14.x（Docker 容器內）|
| 整合目標 | lparser、lfilter、lstore 三個 applet + libpipe 共用函式庫 |

---

## 問題總覽

| # | 症狀 | 根因 | 解法 |
|---|------|------|------|
| 1 | applet 不出現在 `busybox --list` | 手動 patch `applets.h`，但該檔為 generated file | 改用 `//applet:` directive |
| 2 | `CONFIG_LPARSER` 符號不被 Kconfig 識別 | `miscutils/Config.in` patch 靜默失敗（tab/space 問題）| `printf '\t'` 確保 tab + `//config:` directive |
| 3 | `make allnoconfig` + append 無效 | allnoconfig 先寫否定行，oldconfig 採用先出現值 | 改用 `make defconfig`（尊重 `default y`）|
| 4 | `KCONFIG_ALLCONFIG` 無效 | BusyBox 1.36.x Kconfig 版本不保證支援此機制 | 放棄此機制，改用 directive-based 方案 |
| 5 | `networking/tc.c` 編譯失敗 | BusyBox 1.36.x 使用 `TCA_CBQ_MAX` 等已從 kernel 6.x headers 移除的常數 | `sed 's/^CONFIG_TC=y/CONFIG_TC=n/'` 停用 tc applet |
| 6 | `stray '\' in usage.h` | `//usage:` 行末有 `\`，gen_build_files.sh 自己再加一個 `\` | 行末不加 `\`，用相鄰字串串接 |
| 7 | `Overlong line` in Config.in | Windows CRLF 行尾讓 Kconfig 誤判行長度 | `sed 's/\r//'` 轉換 CRLF → LF |
| 8 | `bp_split` 等函式 undefined reference | `libbb/Kbuild` patch 在 gen_build_files.sh 前，被覆蓋 | patch 移到 gen 後；libpipe.c 加 `//kbuild:` directive |
| 9 | `mode_t` conflicting types（Windows MSYS2）| MSYS2 ucrt64 `pthread_compat.h` 已定義 `mode_t` | 重新命名為 `store_op_t` |
| 10 | Windows `lstore.exe` not found | 腳本未包含建置步驟，直接呼叫不存在的執行檔 | 加入 `Ensure-Built` 自動建置函式 |
| 11 | PS1 `ParseException`（`}`unexpected）| UTF-8 無 BOM 檔案在繁中 Windows 以 Big5 讀取，中文字節序造成語法錯誤 | PS1 腳本全改為 ASCII/English |
| 12 | PS1 `"$var.ext"` 成空字串 | PowerShell 把 `.ext` 解釋為 `$var` 的屬性存取 | 改用 `${var}.ext` 或 `$var + ".ext"` |
| 13 | `include/applets.h: No such file` | 誤以為 tarball 內有 `applets.h`；實際是 generated file | 改為檢查 `include/applets.src.h` |
| 14 | tarball 解壓縮後目錄不完整 | 上次失敗的不完整 tarball 被重用，`tar xf` 靜默部分解壓 | 加 `tar tf` 驗證；改用明確的 `tar xjf`（-j = bzip2）|
| 15 | 每次缺少不同 applet（隨機性）| `//config:` 的 `help` 區塊觸發 Kconfig "Overlong line"，落在錯誤位置的 applet 不寫入 `autoconf.h` | 完全移除 `//config:` 的 `help` 區塊（Kconfig help 為選用）|
| 16 | 增量建置中隨機 applet 缺失（問題 15 修復後仍復發）| BusyBox `applet_tables.c` 寫入順序造成時戳反轉；make -j 在此時戳反轉下將 applet_tables 重建與 applets.o 編譯排成競態 | `make silentoldconfig` 先行、序列化產生 applet_tables、`touch` 修正時戳；驗證改用 `busybox applet --help` |

---

## 問題詳細記錄

### 問題 1：手動 patch `applets.h` 無效

**症狀：** 建置成功但 `./busybox --list` 不包含 lparser/lfilter/lstore。

**根本原因：**
在 BusyBox 1.36.x 中，`include/applets.h` 是 **generated file**，
由 `scripts/gen_build_files.sh` 從 `include/applets.src.h` 和各 `.c` 檔案的
`//applet:` directive 自動生成。
手動 patch `applets.h` 後，`gen_build_files.sh` 一執行就會覆蓋我們的修改。

```
# 錯誤做法（applets.h 會被覆蓋）
cat >> include/applets.h << 'EOF'
IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
EOF
```

**解決方案：**
在 `*_bb.c` 原始檔中加入 `//applet:` directive，讓 gen_build_files.sh 自動處理：

```c
//applet:IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
```

---

### 問題 2 & 3：Kconfig 符號不被識別，allnoconfig 設定失效

**症狀：** `.config` 中找不到 `CONFIG_LPARSER`；或 append `CONFIG_LPARSER=y` 後
`make oldconfig` 仍把它設為 `n`。

**根本原因（問題 2）：**
`miscutils/Config.in` 的 patch 使用 heredoc，在 shell 腳本檔案中 tab/space 不確定，
Kconfig 解析失敗但不報錯，符號完全不存在於 `.config`。

**根本原因（問題 3）：**
`make allnoconfig` 先將所有選項寫為否定行（`# CONFIG_LPARSER is not set`），
之後 append `CONFIG_LPARSER=y` 使 `.config` 有衝突項目；
`make oldconfig` 採用「先出現的值」，結果仍為否定。

**解決方案：**
1. 使用 `printf '\t'` 確保 tab 字元（避免 heredoc 歧義）
2. 在 `*_bb.c` 加入 `//config:` directive（gen_build_files.sh 處理）
3. 使用 `make defconfig` 取代 `allnoconfig`（`defconfig` 尊重 `default y`）

```c
//config:config LPARSER
//config:	bool "lparser"
//config:	default y
//config:	help
//config:	  Log parser. Part of BusyPipe embedded ETL pipeline.
```

---

### 問題 4：KCONFIG_ALLCONFIG 無效

**症狀：** 即使使用 `KCONFIG_ALLCONFIG=/tmp/forced.config make allnoconfig`，
applet 仍未被啟用。

**原因：** BusyBox 1.36.x 使用的 Kconfig 版本可能不完整支援此環境變數。

**解決方案：** 放棄此機制，改用 directive-based 方案配合 `make defconfig`。

---

### 問題 5：`networking/tc.c` 編譯失敗

**症狀：**
```
networking/tc.c:236:27: error: 'TCA_CBQ_MAX' undeclared
```

**原因：**
BusyBox 1.36.x 的 `networking/tc.c` 使用 `TCA_CBQ_MAX`、`TCA_CBQ_RATE` 等 CBQ 相關常數，
這些常數在 Linux kernel headers 6.x 中已被移除。
Docker `gcc:14`（Debian bookworm）使用 kernel 6.x headers，導致編譯失敗。

**解決方案：** 停用 `tc` applet：

```bash
sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
```

---

### 問題 6：`stray '\' in usage.h`

**症狀：**
```
include/usage.h:3297:31: error: stray '\' in program
 3297 | #define lfilter_trivial_usage \ \
```

**原因：**
`gen_build_files.sh` 在每個 `//usage:` 行末加入 `\`（行連接符）以合併多行。
我們的 `//usage:` 行末已有 `\`，造成 `\ \`（雙重反斜線）。

**錯誤格式：**
```c
//usage:#define lfilter_full_usage "\n\n" \
//usage:    "Filter...\n" \
```

**正確格式（BusyBox 慣例，行末無 `\`）：**
```c
//usage:#define lfilter_full_usage "\n\n"
//usage:    "Filter...\n"
```

gen_build_files.sh 自動處理行連接，C 編譯器則以相鄰字串自動串接。

---

### 問題 7：`Overlong line` in Config.in

**症狀：**
```
miscutils/Config.in:600 error: Overlong line
```

**原因：**
`*_bb.c` 檔案由 Windows 工具建立，含 CRLF（`\r\n`）行尾。
Linux Kconfig 解析器以 `\r` 作為行內容的一部分，使每行看起來比實際更長。

**解決方案：** 在 `gen_build_files.sh` 之前轉換行尾：

```bash
sed -i 's/\r//' miscutils/lparser.c miscutils/lfilter.c miscutils/lstore.c libbb/busypipe_lib.c
```

---

### 問題 8：`bp_split` 等函式 undefined reference

**症狀：**
```
/usr/bin/ld: miscutils/lib.a(lfilter.o): undefined reference to `bp_split'
/usr/bin/ld: miscutils/lib.a(lfilter.o): undefined reference to `bp_trim_newline'
```

**原因：**
`libbb/busypipe_lib.c` 需要 `lib-y += busypipe_lib.o` 加入 `libbb/Kbuild`，
才能編譯進 `libbb.a` 並在連結時提供 `bp_*` 函式。
我們先手動 patch `libbb/Kbuild`，但 `gen_build_files.sh` 可能從
`libbb/Kbuild.src` 重新生成 `libbb/Kbuild`，覆蓋我們的修改。

**解決方案：**
1. 在 `libpipe.c` 加入 `//kbuild:` directive（gen_build_files.sh 自動處理）：

```c
//kbuild:lib-y += busypipe_lib.o
```

2. 另在建置腳本的 `gen_build_files.sh` **之後**補加保底 patch：

```bash
if ! grep -q "busypipe_lib" libbb/Kbuild; then
    printf 'lib-y += busypipe_lib.o\n' >> libbb/Kbuild
fi
```

---

### 問題 9：`mode_t` conflicting types（Windows MSYS2 環境）

**症狀：**
```
src\lstore.c:46:3: error: conflicting types for 'mode_t'
D:/msys64/ucrt64/include/pthread_compat.h:84:24: note: previous declaration 'mode_t'
```

**原因：**
`src/lstore.c` 自訂 `typedef enum { ... } mode_t`，
但 MSYS2 ucrt64 的 `pthread_compat.h` 已宣告 `typedef unsigned short mode_t`，
`mode_t` 是 POSIX 保留名稱。

**解決方案：** 重新命名為 `store_op_t`（`src/lstore.c` 與 `busybox/lstore_bb.c`）。

---

### 問題 10 & 11 & 12：Windows PowerShell 腳本問題

**問題 10：`lstore.exe` not found**
腳本直接呼叫 `.\build\lstore.exe` 但沒有建置步驟。
**解法：** 加入 `Ensure-Built` 函式，偵測到執行檔不存在時自動以 gcc 建置。

**問題 11：PS1 ParseException（`}` unexpected）**
UTF-8 無 BOM 的 `.ps1` 在繁中 Windows 以 Big5（CP950）讀取，
中文字的多位元組序列破壞腳本語法。
**解法：** PS1 腳本全部改為純 ASCII/English。

**問題 12：`"$var.ext"` 變成空字串**
PowerShell 字串插值中 `$var.ext` 嘗試存取 `$var` 的 `.ext` 屬性，
不存在則回傳 `$null`，字串變空。
**解法：** 改用 `"${var}.ext"` 或 `$var + ".ext"`。

---

### 問題 13 & 14：BusyBox tarball 與解壓縮問題

**問題 13：`include/applets.h: No such file`**
誤以為 BusyBox tarball 包含 `applets.h`，
但該檔是 generated file，tarball 只包含 `applets.src.h`。
**解法：** 改為檢查 `include/applets.src.h`（tarball 中確實存在的檔案）。

**問題 14：tarball 解壓縮後目錄不完整**
上次失敗執行留下的不完整 `.tar.bz2` 被重用；
`tar xf`（不指定壓縮格式）在失敗時靜默回傳 0，留下空目錄。
**解法：**
- 解壓前用 `tar tf` 驗證 tarball 完整性
- 改用 `tar xjf`（明確指定 `-j` = bzip2）
- `run_busybox_build.ps1` 同時清除 tarball（`rm -rf busybox-1.36.1.tar.bz2`）

---

### 問題 15：每次缺少不同 applet（`//config: help` 觸發 Overlong line）

**症狀：** 每次建置隨機缺少一個 applet（不固定是哪個），`busybox --list` 不包含它。

**根本原因：**
`//config:` 的 `help` 區塊行長超過 Kconfig 的 line length 限制，
觸發 "Overlong line" 錯誤，導致該 applet 的 `CONFIG_*` 符號未寫入 `autoconf.h`。
哪個 applet 受影響取決於 gen_build_files.sh 的掃描順序（非確定性）。

**解決方案：** 完全移除 `//config:` 的 `help` 區塊（Kconfig help 為選用欄位）：

```c
// 修正後（移除 help 區塊）
//config:config LPARSER
//config:	bool "lparser"
//config:	default y
```

---

### 問題 16：增量建置中隨機 applet 缺失（`applet_tables` 競態）

**症狀：**
問題 15 修復後，全新建置（`rm -rf busybox-1.36.1`）穩定通過，
但**重複執行**（重用既有 `busybox-1.36.1/` 目錄）仍隨機缺失一個 applet，
且每次缺少的 applet 不同。

診斷確認三個 applet 都在 `include/applet_tables.h`（C1/C2 通過）、
`lXXX_main` 符號都在 `busybox_unstripped`（nm 通過），
但 `busybox --list` 漏列其中一個，且 `grep` 驗證報 FAIL。

---

#### 根因一：`applet_tables.c` 時戳反轉（最根本原因）

`applet_tables.c`（第 239–241 行）固定先 rename `applet_tables.h`（T1），
後 rename `NUM_APPLETS.h`（T2），導致 **T2 > T1** 永遠成立：

```c
rename(tmp1, argv[1]);   /* applet_tables.h  ← 先寫，T1 */
rename(tmp2, argv[2]);   /* NUM_APPLETS.h    ← 後寫，T2 > T1 */
```

BusyBox 自己的 `applets/Kbuild.src`（第 47–53 行）承認此問題：

```makefile
# In fact, include/applet_tables.h depends only on applets/applet_tables,
# and is generated by it. But specifying only it can run
# applets/applet_tables twice, possibly in parallel.
# We say that it also needs NUM_APPLETS.h
#
# Unfortunately, we need to list the same command,
# and it can be executed twice (sequentially).
```

Kbuild 試圖以 `NUM_APPLETS.h` 作為中繼目標來序列化，
但因為 T2 > T1，`make -j$(nproc)` 仍會在啟動後看到：

- `include/applet_tables.h`（T1）< `include/NUM_APPLETS.h`（T2）
  → 排程**再次**重建 `applet_tables.h`（Job C）
- `applets/applets.c` 依賴 `include/applet_tables.h`（T1 已更新）
  → 排程編譯 `applets/applets.c`（Job B）

Job B 與 Job C 進入競態：Job C 寫入 `applet_tables.h` 時，
Job B 可能同時讀取它，造成 `applets/applets.c` 編譯進不完整的 applet 表。

#### 根因二：`autoconf.h` 的 stale 殘留（增量建置輔助因素）

`make defconfig` 只寫 `.config`，不更新 `include/autoconf.h`。
重複執行時，舊建置殘留的 `autoconf.h` 可能在 `make -j$(nproc)` 啟動時仍為過期版本。
若 `applet_tables.c` 在 `silentoldconfig`（make -j 的第一步）完成前就被編譯，
可能使用到錯誤的 `autoconf.h`，進一步影響 applet 表的生成。

#### 根因三：驗證腳本誤判（`set -o pipefail` + SIGPIPE）

`busybox --list` 採用 `dup2(1, 2)` + `full_write2_str`（寫 fd 2）輸出 applet 清單。
在 `set -o pipefail` 下執行 `./busybox --list | grep -q "^lfilter$"` 時：

1. `grep -q` 找到早出現的 `lfilter`（在字母排序中位置較前）後立即退出（exit 0）
2. busybox 繼續寫入剩餘內容時收到 SIGPIPE → 以非零 exit code（141）退出
3. `pipefail` 傳回 busybox 的非零 exit code，即使 `grep` 自身已成功找到 `lfilter`

`lparser` 位置較後，busybox 輸出完畢時 grep 可能尚未關閉 pipe，
因此不觸發 SIGPIPE，驗證通過。這造成「lfilter 失敗、lparser 通過」的假象。

> **注意**：此行為只影響驗證腳本的準確性，不影響 binary 本身的正確性。
> `busybox lfilter` 實際上可正常執行。

---

#### 解決方案

**步驟 4b：`make silentoldconfig`（確保 autoconf.h 正確）**

在 `make -j$(nproc)` 前先同步執行 `make silentoldconfig`，
確保 `include/autoconf.h` 由當前 `.config` 重新生成完畢。
這消除根因二，並讓後續的 applet_tables 編譯使用正確的 autoconf.h。

**步驟 4c：序列化產生 `applet_tables` + 修正時戳反轉**

```bash
make applets/applet_tables                        # 編譯 host binary
make include/NUM_APPLETS.h include/applet_tables.h  # 序列化產生兩個表
touch include/applet_tables.h                     # 修正 T1 < T2 的時戳反轉
```

`touch include/applet_tables.h` 使其時戳 = NOW > T(NUM_APPLETS.h)，
`make -j$(nproc)` 因此認定 `applet_tables.h` 已是最新，不再排程重建，
競態條件完全消除。

**驗證方式改為直接呼叫 applet**

```bash
# 改用：直接測試 applet 是否可執行，迴避 pipefail/SIGPIPE 問題
./busybox "${applet}" --help > /dev/null 2>&1
```

---

#### 附：診斷過程中的誤判警告

| 警告訊息 | 實際意義 | 是否為真正問題 |
|----------|----------|---------------|
| `# define IF_LFILTER(...) __VA_ARGS__ "CONFIG_LFILTER"` 出現在 `autoconf.h` | BusyBox `confdata.c`（第 489–493 行）刻意在 `#ifdef MAKE_SUID` 分支加入 config 名稱字串，用於 SUID table 產生；正常編譯不走此分支 | **非問題**，為正常格式 |
| `nm busybox` 找不到 `lXXX_main` 符號 | BusyBox 預設 strip 最終 binary；需改查 `busybox_unstripped` | **非問題**，診斷工具應針對 unstripped binary |

---

## 最終成功流程

```
*_bb.c 與 libpipe.c 中的 directive
        │
        ▼
scripts/gen_build_files.sh . .
        │
        ├──→ include/applets.h（含 IF_LPARSER/LFILTER/LSTORE）
        ├──→ miscutils/Config.in（含 config LPARSER/LFILTER/LSTORE，default y）
        ├──→ miscutils/Kbuild（含 lib-$(CONFIG_LXXX) += lxxx.o）
        └──→ libbb/Kbuild（含 lib-y += busypipe_lib.o）
        │
        ▼
make defconfig（CONFIG_LPARSER=y 因 default y 自動設定）
        │
        ▼
sed 停用 CONFIG_TC（kernel 6.x headers 不相容）
        │
        ▼
make silentoldconfig（確保 autoconf.h 已由當前 .config 更新）
        │
        ▼
make applets/applet_tables               ← 序列化編譯 host binary
make include/NUM_APPLETS.h \
     include/applet_tables.h             ← 序列化產生兩個表（消除競態）
touch include/applet_tables.h            ← 修正時戳反轉，防止 make -j 重建
        │
        ▼
make -j$(nproc)
        │
        ├── CC miscutils/lparser.o（with -DBUSYBOX_BUILD）
        ├── CC miscutils/lfilter.o（with -DBUSYBOX_BUILD）
        ├── CC miscutils/lstore.o（with -DBUSYBOX_BUILD）
        ├── CC libbb/busypipe_lib.o
        └── LINK busybox（含三個 applet 與 libpipe 共用函式庫）
        │
        ▼
./busybox lparser --help  → exit 0  ✓
./busybox lfilter --help  → exit 0  ✓
./busybox lstore  --help  → exit 0  ✓
        │
        ▼
./busybox lparser | ./busybox lfilter | ./busybox lstore ✓
```

---

## 效能最佳化記錄

### 問題：lparser 比 GNU awk 慢 2.5 倍

**症狀（最佳化前）：**
```
lparser --regex ...      = 440 ms
GNU awk '{...}' access.log = 174 ms  (2.53× 差距，超過 50% 目標)
```

**根本原因：**
POSIX `regexec()` 對每一行做完整的 NFA/DFA 比對，開銷遠高於
AWK 的內建空白欄位切割（僅需線性掃描）。

**解決方案：快速路徑解析（Fast-Path Parser）**

在 `lparser.c` / `lparser_bb.c` 中，對已知的內建格式（`--format nginx/apache/auth`）
新增手工 C 字串掃描函式 `parse_nginx_fast()` / `parse_auth_fast()`：

```
while (*p && *p != ' ') p++;   // 掃描到下一個空格
while (*p && *p != '[') p++;   // 掃描到 '['
...
```

- 時間複雜度：O(line_length)，與 AWK 相同
- 不需要 NFA 狀態機 → 平均快 3–4×

**同步採用的其他最佳化：**
1. `setvbuf(stdin/stdout, NULL, _IOFBF, 1<<17)` — 128 KiB I/O 緩衝，減少 read/write syscall
2. CSV 輸出從每欄多次 `putchar/fwrite` 改為單行整體 `fwrite(buf, pos, stdout)`
3. 編譯旗標 `-O2 → -O3`

**最佳化後結果（50,000 行，best-of-3）：**
```
lparser --format nginx = 140 ms  (GNU awk = 178 ms)  → BusyPipe 快 21%  ✓
lparser --format auth  = 164 ms  (GNU awk = 201 ms)  → BusyPipe 快 18%  ✓
完整管線 lparser|lfilter = 159 ms (GNU awk 122 ms)   → 差距 32%，在 50% 內  ✓
```

---

## 效能問題：lstore 比 GNU awk 慢（第二階段）

**症狀：**
```
store write (lstore vs awk, CSV→TSV)   BP = 332 ms   GNU = 264 ms   GNU faster
```

**分析過程：**

即使改用 `extract_nth_field`（避免 strncpy+full split），lstore 仍慢 25%。
診斷後發現問題出在**手動 fflush 頻率過高**：

```
WRITE_BUF_LINES = 64  → 50000 / 64 = 781 次 fflush()
stdio 預設 8 KB buffer → 每 8192 bytes 自動 flush
平均每行 108 bytes × 64 行 = 6912 bytes < 8 KB
→ 手動 flush 比 stdio 自動 flush 更頻繁
→ 781 次 write() syscall，比 stdio 自然的 659 次還多
```

**根本原因：** 
- `WRITE_BUF_LINES = 64` 讓 fflush 在 stdio buffer 填滿**之前**就觸發
- 等同於把 stdio buffer 縮小到 ~6.9 KB，比預設 8 KB 更小
- 相比之下，GNU awk 的內建輸出緩衝更高效

**解決方案：**
1. `setvbuf(db, NULL, _IOFBF, 1<<17)` — 將 db 檔案的 stdio 緩衝擴大至 128 KiB
2. `WRITE_BUF_LINES = 4096` — 安全 checkpoint 每 4096 行一次（間距拉大）
3. 移除 `buf_bytes` 計數器（不再需要）

**優化後結果：**
```
store write (lstore vs awk, CSV→TSV)   BP = 273 ms   GNU = 303 ms   BusyPipe ✓
```

---

## benchmark.sh 公平性問題

**症狀（第一輪優化後）：**
```
▶  4. Combined pipeline  lparser | lfilter  vs  awk
   BP = 165 ms   GNU = 125 ms   GNU faster

▶  5. Store write  (lstore --put vs awk >> file)
   BP = 285 ms   GNU = 255 ms   GNU faster
```

**根本原因：比較不公平**

| 測試 | BusyPipe 做了什麼 | GNU awk 做了什麼 |
|------|-------------------|-----------------|
| Test 4 | lparser（解析 raw log）\| lfilter（過濾） | awk 只讀 **已解析的 CSV** 過濾 |
| Test 5 | lparser（解析 raw log）\| lstore（寫入） | awk 只讀 **已解析的 CSV** 轉格式 |

BP 需要做的工作遠比 GNU 多，比較無意義。

**解決方案：修改 benchmark 讓兩邊讀相同輸入**
- Test 4：lfilter 讀 CSVFILE vs awk 讀 CSVFILE（公平）
- Test 5：lstore 讀 CSVFILE vs awk 讀 CSVFILE（公平）
- Test 7（新增）：完整管線展示，標明非等效比較

---

## 關鍵知識整理

### BusyBox 1.36.x 建置系統重要規則

1. **`include/applets.h` 是 generated file**
   必須用 `//applet:` directive，不能手動修改。

2. **`gen_build_files.sh` 的時序**
   - 掃描所有 `.c` 檔（包含 `libbb/`、`miscutils/` 等）
   - 提取 `//applet:` `//kbuild:` `//config:` `//usage:` directive
   - 重新生成對應的 `*.h`、`Kbuild`、`Config.in` 檔案
   - 手動對 generated files 的修改必須在 gen 之後進行

3. **`make defconfig` vs `make allnoconfig`**
   - `defconfig`：尊重 `default y`，自動啟用有 `default y` 的新 applet
   - `allnoconfig`：忽略 `default`，全部設為 `n`；需要額外機制啟用 applet

4. **`//usage:` 格式規則**
   - 行末不加 `\`（gen_build_files.sh 自己加）
   - 多行使用相鄰字串串接：`"first.\n" "second.\n"`

5. **CRLF 行尾**
   Windows 工具建立的 `.c` 檔需在 `gen_build_files.sh` 前轉換：
   `sed -i 's/\r//' file.c`

6. **`-DBUSYBOX_BUILD` 旗標**
   必須透過 `CFLAGS_xxx.o += -DBUSYBOX_BUILD`（在 `//kbuild:` directive 中）
   停用獨立執行的 `main()` 包裝，否則多個 applet 各自定義 `main()` 造成連結錯誤。

7. **`make defconfig` 不更新 `include/autoconf.h`**
   `make defconfig` 只寫 `.config`；`autoconf.h` 需由 `make silentoldconfig`（或
   `make -j` 的第一步）重新生成。在重複執行的增量建置中，必須在平行建置前
   明確執行 `make silentoldconfig`，否則 applet_tables 可能用到過期的 autoconf.h。

### BusyBox 1.36.x `applet_tables` 已知競態問題

BusyBox `applets/Kbuild.src`（第 47–53 行）自承：
`applets/applet_tables` 可能被平行執行兩次。

根本原因：`applet_tables.c` 固定**先**寫 `applet_tables.h`、**後**寫 `NUM_APPLETS.h`，
造成 `T(NUM_APPLETS.h) > T(applet_tables.h)` 永遠成立。
make 每次都認定 `applet_tables.h` 需重建，並可能與 `applets/applets.c` 編譯產生競態。

**繞過方式：**
在平行建置前序列化完成所有相關目標，並以 `touch` 修正時戳反轉：

```bash
make applets/applet_tables
make include/NUM_APPLETS.h include/applet_tables.h
touch include/applet_tables.h   # 使 T(applet_tables.h) > T(NUM_APPLETS.h)
```

### BusyBox 1.36.x `autoconf.h` 格式說明

`include/autoconf.h` 中的 `IF_LFILTER` 定義形如：

```c
#ifdef MAKE_SUID
# define IF_LFILTER(...) __VA_ARGS__ "CONFIG_LFILTER"
#else
# define IF_LFILTER(...) __VA_ARGS__
#endif
```

`#ifdef MAKE_SUID` 分支僅用於 SUID table 產生（`busybox.mksuid` 腳本），
正常建置不定義 `MAKE_SUID`，使用 `#else` 分支（`__VA_ARGS__`）。
此格式由 `scripts/kconfig/confdata.c`（第 489–493 行）刻意生成，**非異常**。

### BusyBox binary 符號診斷

BusyBox 預設以 `strip` 移除最終 binary 的符號表。
`nm busybox` 查詢不到任何符號屬正常現象，需改用：

```bash
nm busybox_unstripped | grep -E 'lparser_main|lfilter_main|lstore_main'
```

### BusyBox 1.36.x + kernel 6.x 相容性問題

`make defconfig` 啟用的部分 applet 與新版 kernel headers 不相容：

| Applet | 問題 | 解法 |
|--------|------|------|
| `networking/tc` | `TCA_CBQ_MAX` 等常數已移除 | `CONFIG_TC=n` |

其他 applet（modutils、shell/hush、networking/tftp）只有 warning，不影響建置。

### `set -o pipefail` 與 `busybox --list` 的交互

`busybox --list` 透過 `dup2(1, 2)` + `full_write2_str` 將輸出寫入 fd 2（重定向到
pipe）。在 `set -o pipefail` 環境下，若管線右側（`grep -q`）找到 pattern 後提前
退出，左側的 `busybox` 在後續寫入時收到 SIGPIPE 而以非零 exit code 退出；
`pipefail` 會把此非零 code 傳回，導致驗證誤判。

**字母排序靠前的 applet**（如 lfilter 相對於 lparser）因 grep 更早退出而更容易
觸發此行為。

**解法：** 驗證 applet 是否存在時改用直接呼叫：

```bash
./busybox "${applet}" --help > /dev/null 2>&1
```
