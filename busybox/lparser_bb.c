/* lparser_bb.c — lparser 的 BusyBox applet 適配版
 *
 * 整合至 BusyBox 原始碼樹：
 *   cp lparser_bb.c   <busybox>/miscutils/lparser.c
 *   cp libpipe.c      <busybox>/libbb/busypipe_lib.c
 *   cp libpipe.h      <busybox>/include/libpipe.h
 *
 * 執行 scripts/gen_build_files.sh 後，下方 //applet: //kbuild: //config: 指令
 * 會自動生成 include/applets.h、miscutils/Kbuild、miscutils/Config.in 的對應項目。
 */
//applet:IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
//kbuild:lib-$(CONFIG_LPARSER) += lparser.o
//kbuild:CFLAGS_lparser.o += -DBUSYBOX_BUILD
//config:config LPARSER
//config:	bool "lparser"
//config:	default y


//usage:#define lparser_trivial_usage "--regex PATTERN --fields f1,f2[,...] [--csv|--json] [--stats]"
//usage:    "  or: --format nginx|apache|auth [--csv|--json] [--stats]"
//usage:#define lparser_full_usage "\n\n"
//usage:    "Parse raw log lines into structured CSV or JSONL output.\n"
//usage:    "\n"
//usage:    "Options:\n"
//usage:    "  --regex PATTERN   POSIX extended regex (capture groups = fields)\n"
//usage:    "  --fields f1,...   Field names (count must match capture groups)\n"
//usage:    "  --format NAME     Built-in format: nginx, apache, auth\n"
//usage:    "  --csv             Output CSV with header (default)\n"
//usage:    "  --json            Output JSONL\n"
//usage:    "  --stats           Print matched/skipped stats to stderr\n"
//usage:    "\nBuilt-in formats: nginx  apache  auth\n"

/* ── 獨立編譯時使用；BusyBox 整合時將以下替換為 #include "libbb.h" ── */
#include <stdlib.h>
#include <string.h>
#include <regex.h>
#include "libpipe.h"

/* ── Built-in log format definitions ─────────────────────────────── */
typedef struct { const char *name, *regex, *fields; } bp_format_t;
static const bp_format_t BP_FORMATS[] = {
    { "nginx",
      "^([^ ]+) [^ ]+ [^ ]+ \\[([^]]+)\\] "
      "\"([A-Z]+) ([^ ]+) [^\"]*\" ([0-9]{3}) ([0-9]+)",
      "ip,time,method,path,status,bytes" },
    { "apache",
      "^([^ ]+) [^ ]+ [^ ]+ \\[([^]]+)\\] "
      "\"([A-Z]+) ([^ ]+) [^\"]*\" ([0-9]{3}) ([0-9-]+)",
      "ip,time,method,path,status,bytes" },
    { "auth",
      "^([A-Za-z]+ +[0-9]+ [0-9:]+) ([^ ]+) sshd\\[[0-9]+\\]: "
      "(Failed|Accepted) password for ([^ ]+) from ([^ ]+) port ([0-9]+)",
      "time,host,result,user,src_ip,port" },
    { NULL, NULL, NULL }
};

/* ── fast-path parsers (bypass regexec for built-in formats) ─────── */
typedef enum { FAST_NONE = 0, FAST_NGINX, FAST_AUTH } bp_fast_fmt_t;

static bool bp_parse_nginx_fast(const char *line, regmatch_t *m) {
    const char *p = line, *s;
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[1].rm_so = (int)(s-line); m[1].rm_eo = (int)(p-line);
    while (*p && *p != '[') { p++; }
    if (!*p) { return false; }
    p++;
    s = p;
    while (*p && *p != ']') { p++; }
    if (!*p) { return false; }
    m[2].rm_so = (int)(s-line); m[2].rm_eo = (int)(p-line);
    p++;
    if (*p == ' ') { p++; }
    if (*p != '"') { return false; }
    p++;
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[3].rm_so = (int)(s-line); m[3].rm_eo = (int)(p-line); p++;
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[4].rm_so = (int)(s-line); m[4].rm_eo = (int)(p-line);
    while (*p && *p != '"') { p++; }
    if (!*p) { return false; }
    p++; if (*p == ' ') { p++; }
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[5].rm_so = (int)(s-line); m[5].rm_eo = (int)(p-line); p++;
    s = p;
    while (*p && *p != ' ' && *p != '\n' && *p != '\r') { p++; }
    m[6].rm_so = (int)(s-line); m[6].rm_eo = (int)(p-line);
    return m[6].rm_so < m[6].rm_eo;
}

static const char *bp_next_tok(const char *p) {
    while (*p && *p != ' ') { p++; }
    if (*p == ' ') { p++; }
    return p;
}

static bool bp_parse_auth_fast(const char *line, regmatch_t *m) {
    const char *p = line, *s;
    int i;
    s = p;
    for (i = 0; i < 3; i++) {
        while (*p && *p != ' ') { p++; }
        if (!*p) { return false; }
        if (i < 2) { p++; }
    }
    m[1].rm_so = (int)(s-line); m[1].rm_eo = (int)(p-line);
    if (*p == ' ') { p++; }
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[2].rm_so = (int)(s-line); m[2].rm_eo = (int)(p-line); p++;
    if (strncmp(p, "sshd[", 5) != 0) { return false; }
    p = bp_next_tok(p);
    if (!*p) { return false; }
    if (strncmp(p,"Failed",6)!=0 && strncmp(p,"Accepted",8)!=0) { return false; }
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[3].rm_so = (int)(s-line); m[3].rm_eo = (int)(p-line); p++;
    p = bp_next_tok(p); p = bp_next_tok(p); /* password for */
    if (!*p) { return false; }
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[4].rm_so = (int)(s-line); m[4].rm_eo = (int)(p-line); p++;
    p = bp_next_tok(p); /* from */
    if (!*p) { return false; }
    s = p;
    while (*p && *p != ' ') { p++; }
    if (!*p) { return false; }
    m[5].rm_so = (int)(s-line); m[5].rm_eo = (int)(p-line); p++;
    p = bp_next_tok(p); /* port */
    if (!*p) { return false; }
    s = p;
    while (*p && *p != ' ' && *p != '\n' && *p != '\r') { p++; }
    m[6].rm_so = (int)(s-line); m[6].rm_eo = (int)(p-line);
    return m[6].rm_so < m[6].rm_eo;
}

/* ── BusyBox 整合入口 ──────────────────────────────────────────── */
int lparser_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
int lparser_main(int argc, char **argv) {
    const char   *regex_pat = NULL;
    char          fields_buf[1024] = {0};
    bp_list_t     fields;
    bool          use_json  = false;
    bool          stats     = false;
    bp_fast_fmt_t fast_fmt  = FAST_NONE;
    int i;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i],"--regex")  && i+1<argc) { regex_pat = argv[++i]; }
        else if (!strcmp(argv[i],"--fields") && i+1<argc)
            { strncpy(fields_buf, argv[++i], sizeof(fields_buf)-1); }
        else if (!strcmp(argv[i],"--format") && i+1<argc) {
            const bp_format_t *f;
            ++i;
            for (f = BP_FORMATS; f->name; f++) {
                if (!strcmp(f->name, argv[i])) {
                    regex_pat = f->regex;
                    strncpy(fields_buf, f->fields, sizeof(fields_buf)-1);
                    if (!strcmp(f->name,"nginx") || !strcmp(f->name,"apache"))
                        fast_fmt = FAST_NGINX;
                    else if (!strcmp(f->name,"auth"))
                        fast_fmt = FAST_AUTH;
                    break;
                }
            }
            if (!f->name) {
                fprintf(stderr, "lparser: unknown format '%s'\n", argv[i]);
                return 1;
            }
        }
        else if (!strcmp(argv[i],"--json"))  { use_json = true; }
        else if (!strcmp(argv[i],"--csv"))   { use_json = false; }
        else if (!strcmp(argv[i],"--stats")) { stats = true; }
        else if (!strcmp(argv[i],"--help") || !strcmp(argv[i],"-h")) {
            fprintf(stderr,
                "用法：lparser --regex PATTERN --fields f1,f2 [--csv|--json]\n"
                "      lparser --format nginx|apache|auth [--csv|--json]\n");
            return 0;
        } else {
            fprintf(stderr, "lparser: unknown option '%s'\n", argv[i]);
            return 1;
        }
    }

    if (!regex_pat || !fields_buf[0]) {
        fprintf(stderr, "lparser: --regex+--fields or --format required\n");
        return 1;
    }

    if (!bp_split(fields_buf, ',', &fields)) {
        fprintf(stderr, "lparser: too many fields\n"); return 1;
    }

    regex_t    re;
    regmatch_t m[BP_MAX_FIELDS + 1];
    char       line[BP_MAX_LINE_LEN];
    unsigned long matched = 0, skipped = 0;

    if (regcomp(&re, regex_pat, REG_EXTENDED) != 0) {
        fprintf(stderr, "lparser: invalid regex\n"); return 1;
    }

    setvbuf(stdin,  NULL, _IOFBF, 1 << 17);
    setvbuf(stdout, NULL, _IOFBF, 1 << 17);

    if (!use_json) { bp_print_csv(stdout, &fields); }

    while (fgets(line, sizeof(line), stdin)) {
        bool ok;
        if (fast_fmt == FAST_NGINX) {
            ok = bp_parse_nginx_fast(line, m);
        } else if (fast_fmt == FAST_AUTH) {
            ok = bp_parse_auth_fast(line, m);
        } else {
            bp_trim_newline(line);
            ok = (regexec(&re, line, fields.count+1, m, 0) == 0);
        }
        if (!ok) { skipped++; continue; }
        matched++;
        if (!use_json) {
            char   buf[BP_MAX_LINE_LEN];
            size_t pos = 0, j;
            for (j = 0; j < fields.count; j++) {
                int    s   = m[j+1].rm_so;
                int    e   = m[j+1].rm_eo;
                size_t len = (size_t)(e - s);
                if (j > 0 && pos < sizeof(buf)-1) { buf[pos++] = ','; }
                if (pos + len < sizeof(buf)-1) {
                    memcpy(buf+pos, line+s, len); pos += len;
                }
            }
            if (pos < sizeof(buf)) { buf[pos++] = '\n'; }
            fwrite(buf, 1, pos, stdout);
        } else {
            size_t j;
            putchar('{');
            for (j = 0; j < fields.count; j++) {
                size_t len = (size_t)(m[j+1].rm_eo - m[j+1].rm_so);
                char val[BP_MAX_LINE_LEN];
                if (len >= sizeof(val)) { len = sizeof(val) - 1; }
                memcpy(val, line + m[j+1].rm_so, len);
                val[len] = '\0';
                if (j) { putchar(','); }
                printf("\"%s\":\"", fields.items[j]);
                bp_json_escape(val);
                putchar('"');
            }
            puts("}");
        }
    }

    if (stats)
        fprintf(stderr, "matched=%lu skipped=%lu\n", matched, skipped);

    regfree(&re);
    return 0;
}

/* 獨立執行入口（非 BusyBox 環境，不定義 BUSYBOX_BUILD 時編譯） */
#ifndef BUSYBOX_BUILD
int main(int argc, char **argv) { return lparser_main(argc, argv); }
#endif
