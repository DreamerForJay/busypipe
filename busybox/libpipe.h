/* libpipe.h — BusyPipe 共用函式庫介面
 *
 * 此檔案僅含宣告，無任何 static 實作。
 * 實作位於 libpipe.c，整合進 BusyBox 後應放置於：
 *   <busybox>/include/libpipe.h
 *
 * 舊有的 busypipe.h（static inline 做法）已廢除，
 * 改由本檔案 + libpipe.c 提供真正的共用函式庫。
 */
#ifndef BUSYPIPE_LIBPIPE_H
#define BUSYPIPE_LIBPIPE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#define BP_MAX_LINE_LEN  4096
#define BP_MAX_FIELDS    64

typedef struct {
    char  *items[BP_MAX_FIELDS];
    size_t count;
} bp_list_t;

/* BusyBox 建置時由 libbb.h 提供 MAIN_EXTERNALLY_VISIBLE；
 * 獨立編譯時定義為空以避免 undefined symbol。 */
#ifndef MAIN_EXTERNALLY_VISIBLE
#define MAIN_EXTERNALLY_VISIBLE
#endif

void bp_trim_newline(char *s);
bool bp_split(char *text, char delim, bp_list_t *out);
int  bp_find_field(const bp_list_t *h, const char *name);
bool bp_is_number(const char *s);
void bp_print_csv(FILE *f, const bp_list_t *row);
void bp_json_escape(const char *s);   /* 輸出至 stdout，含 "、\ 與控制字元跳脫 */

#endif /* BUSYPIPE_LIBPIPE_H */
