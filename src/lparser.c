#include "common.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <regex.h>
#endif

typedef enum {
    OUTPUT_CSV,
    OUTPUT_JSON
} output_format_t;

typedef struct {
    const char *regex_pattern;
    char fields_buffer[1024];
    string_list_t fields;
    output_format_t format;
    bool stats;
} config_t;

#ifndef _WIN32
static void usage(void) {
    fprintf(stderr,
            "用法：lparser --regex PATTERN --fields f1,f2 [--csv|--json] [--stats]\n");
    exit(1);
}

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;

    memset(cfg, 0, sizeof(*cfg));
    cfg->format = OUTPUT_CSV;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--regex") == 0 && i + 1 < argc) {
            cfg->regex_pattern = argv[++i];
        } else if (strcmp(argv[i], "--fields") == 0 && i + 1 < argc) {
            strncpy(cfg->fields_buffer, argv[++i], sizeof(cfg->fields_buffer) - 1);
        } else if (strcmp(argv[i], "--csv") == 0) {
            cfg->format = OUTPUT_CSV;
        } else if (strcmp(argv[i], "--json") == 0) {
            cfg->format = OUTPUT_JSON;
        } else if (strcmp(argv[i], "--stats") == 0) {
            cfg->stats = true;
        } else {
            usage();
        }
    }

    if (cfg->regex_pattern == NULL || cfg->fields_buffer[0] == '\0') {
        usage();
    }
    if (!split_list_inplace(cfg->fields_buffer, &cfg->fields)) {
        die_usage("too many fields");
    }
}

static void print_json_escaped(const char *text) {
    while (*text != '\0') {
        if (*text == '"' || *text == '\\') {
            putchar('\\');
        }
        putchar(*text);
        text++;
    }
}

static void print_csv_header(const config_t *cfg) {
    print_csv_row(stdout, &cfg->fields);
}

static void print_json_object(const config_t *cfg, regmatch_t *matches, const char *line) {
    size_t i;
    putchar('{');
    for (i = 0; i < cfg->fields.count; i++) {
        int start = matches[i + 1].rm_so;
        int end = matches[i + 1].rm_eo;
        char value[MAX_LINE_LEN];
        size_t len = (size_t)(end - start);

        if (i > 0) {
            putchar(',');
        }

        if (len >= sizeof(value)) {
            len = sizeof(value) - 1;
        }
        memcpy(value, line + start, len);
        value[len] = '\0';

        printf("\"%s\":\"", cfg->fields.items[i]);
        print_json_escaped(value);
        putchar('"');
    }
    puts("}");
}

static void print_csv_match(const config_t *cfg, regmatch_t *matches, const char *line) {
    size_t i;
    for (i = 0; i < cfg->fields.count; i++) {
        int start = matches[i + 1].rm_so;
        int end = matches[i + 1].rm_eo;
        if (i > 0) {
            putchar(',');
        }
        fwrite(line + start, 1, (size_t)(end - start), stdout);
    }
    putchar('\n');
}
#endif

int main(int argc, char **argv) {
#ifdef _WIN32
    (void)argc;
    (void)argv;
    fprintf(stderr, "lparser：目前這個 Windows MinGW 環境沒有 POSIX regex 後端。\n");
    fprintf(stderr, "lparser：請改在 Linux 環境建置與執行，才能使用 regex 解析功能。\n");
    return 1;
#else
    config_t cfg;
    regex_t regex;
    regmatch_t matches[MAX_FIELDS + 1];
    char line[MAX_LINE_LEN];
    unsigned long matched = 0;
    unsigned long skipped = 0;
    int rc;

    parse_args(argc, argv, &cfg);

    rc = regcomp(&regex, cfg.regex_pattern, REG_EXTENDED);
    if (rc != 0) {
        die_runtime("invalid regex");
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
        fprintf(stderr, "matched=%lu skipped=%lu\n", matched, skipped);
    }

    regfree(&regex);
    return 0;
#endif
}
