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
make -j$(nproc)
        │
        ├── CC miscutils/lparser.o（with -DBUSYBOX_BUILD）
        ├── CC miscutils/lfilter.o（with -DBUSYBOX_BUILD）
        ├── CC miscutils/lstore.o（with -DBUSYBOX_BUILD）
        ├── CC libbb/busypipe_lib.o
        └── LINK busybox（含三個 applet 與 libpipe 共用函式庫）
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

### BusyBox 1.36.x + kernel 6.x 相容性問題

`make defconfig` 啟用的部分 applet 與新版 kernel headers 不相容：

| Applet | 問題 | 解法 |
|--------|------|------|
| `networking/tc` | `TCA_CBQ_MAX` 等常數已移除 | `CONFIG_TC=n` |

其他 applet（modutils、shell/hush、networking/tftp）只有 warning，不影響建置。
