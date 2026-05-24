/* lparser_bb.c — BusyBox applet adaptation of lparser
 *
 * To integrate into BusyBox source tree:
 *   cp lparser_bb.c  <busybox>/miscutils/lparser.c
 *
 * Then patch:
 *   include/applets.h  — add  IF_LPARSER(APPLET(lparser, BB_DIR_USR_BIN, BB_SUID_DROP))
 *   Config.in          — add  config LPARSER block
 *   miscutils/Kbuild   — add  lib-$(CONFIG_LPARSER) += lparser.o
 */

/*
//usage:#define lparser_trivial_usage \
//usage:    "--regex PATTERN --fields f1,f2[,...] [--csv|--json] [--stats]\n" \
//usage:    "  or: --format nginx|apache|auth [--csv|--json] [--stats]"
//usage:#define lparser_full_usage "\n\n" \
//usage:    "Parse raw log lines into structured CSV or JSONL output.\n" \
//usage:    "\n" \
//usage:    "Options:\n" \
//usage:    "  --regex PATTERN   POSIX extended regex (capture groups = fields)\n" \
//usage:    "  --fields f1,...   Field names (count must match capture groups)\n" \
//usage:    "  --format NAME     Built-in format: nginx, apache, auth\n" \
//usage:    "  --csv             Output CSV with header (default)\n" \
//usage:    "  --json            Output JSONL\n" \
//usage:    "  --stats           Print matched/skipped stats to stderr\n" \
//usage:    "\nBuilt-in formats:\n" \
//usage:    "  nginx   Nginx/Apache Combined Access Log\n" \
//usage:    "  apache  Apache Common Log Format\n" \
//usage:    "  auth    SSH auth.log (sshd Failed/Accepted password)\n"
*/

/* ── In BusyBox: replace these includes with #include "libbb.h" ── */
#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <regex.h>
#include "busypipe.h"

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

/* ── BusyBox entry point (rename main → lparser_main) ──────────── */
/* int lparser_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE; */
int main(int argc, char **argv) {   /* standalone build */
    const char *regex_pat = NULL;
    char fields_buf[1024] = {0};
    bp_list_t fields;
    bool use_json = false;
    bool stats    = false;
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
                    break;
                }
            }
            if (!f->name) {
                fprintf(stderr, "lparser: unknown format '%s'\n", argv[i]);
                return 1;
            }
        }
        else if (!strcmp(argv[i],"--json"))  use_json = true;
        else if (!strcmp(argv[i],"--csv"))   use_json = false;
        else if (!strcmp(argv[i],"--stats")) stats = true;
        else if (!strcmp(argv[i],"--help") || !strcmp(argv[i],"-h")) {
            /* In BusyBox: bb_show_usage() */
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

    if (!use_json) bp_print_csv(stdout, &fields);

    while (fgets(line, sizeof(line), stdin)) {
        bp_trim_newline(line);
        if (regexec(&re, line, fields.count+1, m, 0) != 0) { skipped++; continue; }
        matched++;
        if (!use_json) {
            size_t j;
            for (j = 0; j < fields.count; j++) {
                if (j) putchar(',');
                fwrite(line + m[j+1].rm_so, 1,
                       (size_t)(m[j+1].rm_eo - m[j+1].rm_so), stdout);
            }
            putchar('\n');
        } else {
            size_t j;
            putchar('{');
            for (j = 0; j < fields.count; j++) {
                size_t len = (size_t)(m[j+1].rm_eo - m[j+1].rm_so);
                if (j) putchar(',');
                printf("\"%s\":\"", fields.items[j]);
                fwrite(line + m[j+1].rm_so, 1, len, stdout);
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
