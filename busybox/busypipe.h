/* busypipe.h — shared constants for BusyPipe BusyBox applets
 *
 * In a real BusyBox integration this would live in include/busypipe.h
 * or the constants would be inlined into libbb.h.
 */
#ifndef BUSYPIPE_H
#define BUSYPIPE_H

#include <ctype.h>

#define BP_MAX_LINE_LEN  4096
#define BP_MAX_FIELDS    64

typedef struct {
    char  *items[BP_MAX_FIELDS];
    size_t count;
} bp_list_t;

/* Shared helpers — implemented inline in each applet to avoid
 * adding a separate compilation unit in the BusyBox Kbuild.
 * In a production integration these would go into libbb/busypipe.c.
 */

static void bp_trim_newline(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == '\n' || s[n-1] == '\r')) s[--n] = '\0';
}

static bool bp_split(char *text, char delim, bp_list_t *out) {
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

static int bp_find_field(const bp_list_t *h, const char *name)
    __attribute__((unused));
static int bp_find_field(const bp_list_t *h, const char *name) {
    size_t i;
    for (i = 0; i < h->count; i++)
        if (strcmp(h->items[i], name) == 0) return (int)i;
    return -1;
}

static bool bp_is_number(const char *s) __attribute__((unused));
static bool bp_is_number(const char *s) {
    bool has = false;
    if (*s == '-' || *s == '+') s++;
    for (; *s; s++) {
        if (*s == '.') continue;
        if (!isdigit((unsigned char)*s)) return false;
        has = true;
    }
    return has;
}

static void bp_print_csv(FILE *f, const bp_list_t *row)
    __attribute__((unused));
static void bp_print_csv(FILE *f, const bp_list_t *row) {
    size_t i;
    for (i = 0; i < row->count; i++) {
        if (i) fputc(',', f);
        fputs(row->items[i], f);
    }
    fputc('\n', f);
}

/* JSON string escaping — handles ", \, and ASCII control characters. */
static void bp_json_escape(const char *s) __attribute__((unused));
static void bp_json_escape(const char *s) {
    while (*s) {
        unsigned char c = (unsigned char)*s;
        if      (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 0x20)              { printf("\\u%04x", (unsigned)c); }
        else                            { putchar(c); }
        s++;
    }
}

#endif /* BUSYPIPE_H */
