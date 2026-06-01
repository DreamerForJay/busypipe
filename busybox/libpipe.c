/* libpipe.c — BusyPipe 共用函式庫實作
 *
 * 三個 applet（lparser、lfilter、lstore）共用此模組，
 * 每個函式只編譯一份，避免舊有 static inline 各自複製的問題。
 *
 * 整合進 BusyBox 時的放置位置：
 *   cp busybox/libpipe.c  <busybox>/libbb/busypipe_lib.c
 *   cp busybox/libpipe.h  <busybox>/include/libpipe.h
 * 並在 libbb/Kbuild 加入：
 *   lib-y += busypipe_lib.o
 */

#include "libpipe.h"
#include <ctype.h>
#include <string.h>

/* 去除行尾的 \n 與 \r */
void bp_trim_newline(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == '\n' || s[n-1] == '\r')) s[--n] = '\0';
}

/* 以 delim 為分隔符號原地切割 text，結果指標存入 out */
bool bp_split(char *text, char delim, bp_list_t *out) {
    char *p = text;
    out->count = 0;
    if (!*p) return true;
    while (*p) {
        if (out->count >= BP_MAX_FIELDS) return false;
        out->items[out->count++] = p;
        while (*p && *p != delim) p++;
        if (*p == delim) { *p++ = '\0'; }
    }
    return true;
}

/* 在 header 中尋找欄位名稱，回傳索引；找不到回傳 -1 */
int bp_find_field(const bp_list_t *h, const char *name) {
    size_t i;
    for (i = 0; i < h->count; i++)
        if (strcmp(h->items[i], name) == 0) return (int)i;
    return -1;
}

/* 判斷字串是否為有效數值（整數或浮點數） */
bool bp_is_number(const char *s) {
    bool has = false;
    if (*s == '-' || *s == '+') s++;
    for (; *s; s++) {
        if (*s == '.') continue;
        if (!isdigit((unsigned char)*s)) return false;
        has = true;
    }
    return has;
}

/* 將 row 各欄位以逗號連接輸出至 f，結尾加換行 */
void bp_print_csv(FILE *f, const bp_list_t *row) {
    size_t i;
    for (i = 0; i < row->count; i++) {
        if (i) fputc(',', f);
        fputs(row->items[i], f);
    }
    fputc('\n', f);
}

/* 將字串 s 以 JSON 規格跳脫後輸出至 stdout */
void bp_json_escape(const char *s) {
    while (*s) {
        unsigned char c = (unsigned char)*s;
        if      (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 0x20)              { printf("\\u%04x", (unsigned)c); }
        else                            { putchar(c); }
        s++;
    }
}
