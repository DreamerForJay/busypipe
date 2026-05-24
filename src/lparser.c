/*
 * lparser — structured log parser for BusyPipe
 *
 * Reads raw log lines from stdin, extracts fields with POSIX extended
 * regular expressions (capture groups), and writes structured CSV or
 * JSONL output to stdout.
 *
 * Usage:
 *   lparser --regex PATTERN --fields f1,f2,... [--csv|--json] [--stats]
 *   lparser --format nginx|apache|auth     [--csv|--json] [--stats]
 *
 * UNIX Philosophy: do one thing well, communicate through stdio.
 */

#include "common.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <regex.h>
#endif

/* ── built-in format definitions ─────────────────────────────────────────── */

typedef struct {
    const char *name;
    const char *regex;
    const char *fields;   /* comma-separated field names */
    const char *desc;
} builtin_format_t;

static const builtin_format_t BUILTIN_FORMATS[] = {
    {
        "nginx",
        "^([^ ]+) [^ ]+ [^ ]+ \\[([^]]+)\\] "
        "\"([A-Z]+) ([^ ]+) [^\"]*\" ([0-9]{3}) ([0-9]+)",
        "ip,time,method,path,status,bytes",
        "Nginx / Apache Combined Access Log"
    },
    {
        "apache",
        "^([^ ]+) [^ ]+ [^ ]+ \\[([^]]+)\\] "
        "\"([A-Z]+) ([^ ]+) [^\"]*\" ([0-9]{3}) ([0-9-]+)",
        "ip,time,method,path,status,bytes",
        "Apache Common Log Format"
    },
    {
        "auth",
        "^([A-Za-z]+ +[0-9]+ [0-9:]+) ([^ ]+) sshd\\[[0-9]+\\]: "
        "(Failed|Accepted) password for ([^ ]+) from ([^ ]+) port ([0-9]+)",
        "time,host,result,user,src_ip,port",
        "SSH auth.log (sshd password events)"
    },
    { NULL, NULL, NULL, NULL }
};

/* ── config ───────────────────────────────────────────────────────────────── */

typedef enum { OUTPUT_CSV, OUTPUT_JSON } output_format_t;

typedef struct {
    const char      *regex_pattern;
    char             fields_buffer[1024];
    string_list_t    fields;
    output_format_t  format;
    bool             stats;
} config_t;

/* ── helpers ──────────────────────────────────────────────────────────────── */

static void usage(void) {
    fprintf(stderr,
        "用法：lparser [選項]\n"
        "\n"
        "解析原始日誌並輸出結構化欄位。\n"
        "\n"
        "輸入來源（二擇一）：\n"
        "  --regex PATTERN    POSIX 擴充正規表示式（capture group 對應欄位）\n"
        "  --format NAME      使用預設格式（nginx | apache | auth）\n"
        "\n"
        "欄位定義（使用 --regex 時必填）：\n"
        "  --fields f1,f2,... 欄位名稱清單，數量須與 capture group 相符\n"
        "\n"
        "輸出格式（預設 CSV）：\n"
        "  --csv              輸出 CSV（第一行為 header）\n"
        "  --json             輸出 JSONL（每行一個 JSON 物件）\n"
        "\n"
        "其他選項：\n"
        "  --stats            將 matched/skipped 統計輸出到 stderr\n"
        "  --help             顯示此說明\n"
        "\n"
        "預設格式（--format）：\n"
        "  nginx   Nginx/Apache Combined Access Log\n"
        "  apache  Apache Common Log Format\n"
        "  auth    SSH auth.log (sshd Failed/Accepted password)\n"
        "\n"
        "範例：\n"
        "  lparser --format nginx --csv < /var/log/nginx/access.log\n"
        "  lparser --format auth  --json < /var/log/auth.log\n"
        "  lparser --regex '([0-9.]+) .* \"([A-Z]+) ([^ ]+)' \\\n"
        "          --fields ip,method,path --csv < access.log\n");
    exit(1);
}

static void print_help(void) {
    usage();
}

#ifndef _WIN32

static void print_json_escaped(const char *text) {
    while (*text != '\0') {
        unsigned char c = (unsigned char)*text;
        if (c == '"' || c == '\\') {
            putchar('\\');
            putchar(c);
        } else if (c < 0x20) {
            /* control characters */
            printf("\\u%04x", (unsigned)c);
        } else {
            putchar(c);
        }
        text++;
    }
}

static void print_csv_header(const config_t *cfg) {
    print_csv_row(stdout, &cfg->fields);
}

static void print_json_object(const config_t *cfg,
                               regmatch_t *matches,
                               const char *line) {
    size_t i;
    putchar('{');
    for (i = 0; i < cfg->fields.count; i++) {
        int    start = matches[i + 1].rm_so;
        int    end   = matches[i + 1].rm_eo;
        size_t len   = (size_t)(end - start);
        char   value[MAX_LINE_LEN];

        if (i > 0) putchar(',');

        if (len >= sizeof(value)) len = sizeof(value) - 1;
        memcpy(value, line + start, len);
        value[len] = '\0';

        printf("\"%s\":\"", cfg->fields.items[i]);
        print_json_escaped(value);
        putchar('"');
    }
    puts("}");
}

static void print_csv_match(const config_t *cfg,
                             regmatch_t *matches,
                             const char *line) {
    size_t i;
    for (i = 0; i < cfg->fields.count; i++) {
        int start = matches[i + 1].rm_so;
        int end   = matches[i + 1].rm_eo;
        if (i > 0) putchar(',');
        fwrite(line + start, 1, (size_t)(end - start), stdout);
    }
    putchar('\n');
}

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;
    const char *format_name = NULL;

    memset(cfg, 0, sizeof(*cfg));
    cfg->format = OUTPUT_CSV;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_help();
        } else if (strcmp(argv[i], "--regex") == 0 && i + 1 < argc) {
            cfg->regex_pattern = argv[++i];
        } else if (strcmp(argv[i], "--fields") == 0 && i + 1 < argc) {
            strncpy(cfg->fields_buffer, argv[++i],
                    sizeof(cfg->fields_buffer) - 1);
        } else if (strcmp(argv[i], "--format") == 0 && i + 1 < argc) {
            format_name = argv[++i];
        } else if (strcmp(argv[i], "--csv") == 0) {
            cfg->format = OUTPUT_CSV;
        } else if (strcmp(argv[i], "--json") == 0) {
            cfg->format = OUTPUT_JSON;
        } else if (strcmp(argv[i], "--stats") == 0) {
            cfg->stats = true;
        } else {
            fprintf(stderr, "未知選項：%s\n\n", argv[i]);
            usage();
        }
    }

    /* resolve --format */
    if (format_name != NULL) {
        const builtin_format_t *f;
        for (f = BUILTIN_FORMATS; f->name != NULL; f++) {
            if (strcmp(f->name, format_name) == 0) {
                cfg->regex_pattern = f->regex;
                strncpy(cfg->fields_buffer, f->fields,
                        sizeof(cfg->fields_buffer) - 1);
                break;
            }
        }
        if (f->name == NULL) {
            fprintf(stderr,
                "未知格式名稱：%s\n"
                "支援格式：nginx, apache, auth\n", format_name);
            exit(1);
        }
    }

    if (cfg->regex_pattern == NULL || cfg->fields_buffer[0] == '\0') {
        fprintf(stderr, "錯誤：需指定 --regex + --fields 或 --format\n\n");
        usage();
    }
    if (!split_list_inplace(cfg->fields_buffer, &cfg->fields)) {
        die_usage("too many fields");
    }
}

#endif /* !_WIN32 */

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
#ifdef _WIN32
    /* Check for --help even on Windows */
    int i;
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            fprintf(stderr,
                "lparser: 原始日誌結構化解析器\n"
                "  此工具需在 Linux 環境下使用（需要 POSIX regex.h）\n"
                "  請在 Linux / Docker 環境中執行。\n");
            return 0;
        }
    }
    (void)argc; (void)argv;
    fprintf(stderr,
        "lparser：此 Windows MinGW 環境缺少 POSIX regex.h。\n"
        "lparser：請在 Linux / Docker 環境建置並執行。\n");
    return 1;
#else
    config_t   cfg;
    regex_t    regex;
    regmatch_t matches[MAX_FIELDS + 1];
    char       line[MAX_LINE_LEN];
    unsigned long matched = 0, skipped = 0;
    int        rc;

    parse_args(argc, argv, &cfg);

    rc = regcomp(&regex, cfg.regex_pattern, REG_EXTENDED);
    if (rc != 0) {
        char errbuf[256];
        regerror(rc, &regex, errbuf, sizeof(errbuf));
        fprintf(stderr, "lparser：無效的 regex：%s\n", errbuf);
        return 1;
    }

    if (cfg.format == OUTPUT_CSV) {
        print_csv_header(&cfg);
    }

    while (fgets(line, sizeof(line), stdin) != NULL) {
        trim_newline(line);
        rc = regexec(&regex, line, cfg.fields.count + 1, matches, 0);
        if (rc != 0) {
            skipped++;
            continue;
        }
        matched++;
        if (cfg.format == OUTPUT_CSV) {
            print_csv_match(&cfg, matches, line);
        } else {
            print_json_object(&cfg, matches, line);
        }
    }

    if (cfg.stats) {
        fprintf(stderr, "matched=%lu skipped=%lu total=%lu\n",
                matched, skipped, matched + skipped);
    }

    regfree(&regex);
    return 0;
#endif
}
