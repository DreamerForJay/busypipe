/*
 * lfilter — CSV stream filter and field projector for BusyPipe
 *
 * Reads CSV from stdin (first line = header), applies optional filter
 * condition and optional field projection, writes filtered CSV or JSONL
 * to stdout.
 *
 * Usage:
 *   lfilter [--where expr] [--select f1,f2,...] [--format csv|json]
 *           [--contains field=substring]
 *
 * UNIX Philosophy: one task, stdio, composable.
 */

#include "common.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── operator enum ───────────────────────────────────────────────────────── */

typedef enum {
    OP_NONE,
    OP_EQ,
    OP_NE,
    OP_GT,
    OP_GE,
    OP_LT,
    OP_LE
} op_t;

/* ── output format ───────────────────────────────────────────────────────── */

typedef enum { FMT_CSV, FMT_JSON } fmt_t;

/* ── config ───────────────────────────────────────────────────────────────── */

typedef struct {
    /* --where */
    char  where_buffer[256];
    bool  has_where;
    char  where_field[128];
    char  where_value[128];
    op_t  where_op;

    /* --contains */
    bool  has_contains;
    char  contains_field[128];
    char  contains_value[128];

    /* --select */
    char          select_buffer[1024];
    bool          has_select;
    string_list_t select_fields;

    /* --format */
    fmt_t out_format;
} config_t;

/* ── usage / help ─────────────────────────────────────────────────────────── */

static void show_usage(FILE *out) {
    fprintf(out,
        "用法：lfilter [選項]\n"
        "\n"
        "從 stdin 讀取 CSV 資料流，進行條件過濾與欄位投影，\n"
        "結果輸出到 stdout。\n"
        "\n"
        "過濾選項：\n"
        "  --where  \"欄位<運算子>值\"   數值或字串比較過濾（僅限一次）\n"
        "      支援運算子：==  !=  >  >=  <  <=\n"
        "      若兩側均為數字則用數值比較，否則用字典順序比較\n"
        "  --contains \"欄位=子字串\"    欄位值包含指定子字串\n"
        "\n"
        "投影選項：\n"
        "  --select  \"f1,f2,...\"       只輸出指定欄位\n"
        "\n"
        "輸出格式（預設 csv）：\n"
        "  --format csv               輸出 CSV（含 header）\n"
        "  --format json              輸出 JSONL（每行一個 JSON 物件）\n"
        "\n"
        "其他：\n"
        "  --help                     顯示此說明\n"
        "\n"
        "範例：\n"
        "  lfilter --where 'status>=400' --select 'ip,path,status'\n"
        "  lfilter --contains 'user=admin' --format json\n"
        "  lfilter --where 'status>=400' | lfilter --where 'method==POST'\n"
        "      （多條件請串接多個 lfilter）\n"
        "\n"
        "完整管線：\n"
        "  lparser --format nginx --csv < access.log \\\n"
        "    | lfilter --where 'status>=400' --select 'ip,path,status' \\\n"
        "    | lstore  --db errors.tsv --put --key-field ip --ttl 3600\n");
}

/* Called on argument errors — print to stderr, exit 1. */
static void usage(void) {
    show_usage(stderr);
    exit(1);
}

/* Called for --help — print to stdout, exit 0. */
static void print_help(void) {
    show_usage(stdout);
    exit(0);
}

/* ── parse --where expression ─────────────────────────────────────────────── */

static bool parse_where_expr(char *buf,
                              char *field, size_t fsz,
                              char *value, size_t vsz,
                              op_t *op) {
    /* Try multi-char operators first so ">=" is not split as ">" */
    static const struct { const char *text; op_t op; } ops[] = {
        {">=", OP_GE}, {"<=", OP_LE}, {"==", OP_EQ}, {"!=", OP_NE},
        {">",  OP_GT}, {"<",  OP_LT},
    };
    size_t i;

    for (i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
        char *pos = strstr(buf, ops[i].text);
        if (pos != NULL) {
            size_t llen = (size_t)(pos - buf);
            size_t rlen = strlen(pos + strlen(ops[i].text));
            if (llen == 0 || rlen == 0 || llen >= fsz || rlen >= vsz)
                return false;
            memcpy(field, buf, llen);  field[llen] = '\0';
            memcpy(value, pos + strlen(ops[i].text), rlen); value[rlen] = '\0';
            *op = ops[i].op;
            return true;
        }
    }
    return false;
}

/* ── parse --contains expression ─────────────────────────────────────────── */

static bool parse_contains_expr(char *buf,
                                 char *field, size_t fsz,
                                 char *value, size_t vsz) {
    char *eq = strchr(buf, '=');
    if (eq == NULL) return false;
    size_t llen = (size_t)(eq - buf);
    size_t rlen = strlen(eq + 1);
    if (llen == 0 || rlen == 0 || llen >= fsz || rlen >= vsz) return false;
    memcpy(field, buf, llen); field[llen] = '\0';
    memcpy(value, eq + 1, rlen); value[rlen] = '\0';
    return true;
}

/* ── argument parsing ─────────────────────────────────────────────────────── */

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;
    memset(cfg, 0, sizeof(*cfg));
    cfg->out_format = FMT_CSV;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_help();
        } else if (strcmp(argv[i], "--where") == 0 && i + 1 < argc) {
            if (cfg->has_where) {
                die_usage("--where 只能指定一次（目前不支援多條件）\n"
                          "  若需同時過濾，可串接多個 lfilter");
            }
            strncpy(cfg->where_buffer, argv[++i],
                    sizeof(cfg->where_buffer) - 1);
            cfg->has_where = true;
        } else if (strcmp(argv[i], "--contains") == 0 && i + 1 < argc) {
            char tmp[256];
            strncpy(tmp, argv[++i], sizeof(tmp) - 1);
            if (!parse_contains_expr(tmp,
                    cfg->contains_field, sizeof(cfg->contains_field),
                    cfg->contains_value, sizeof(cfg->contains_value))) {
                die_usage("--contains 格式錯誤，應為 '欄位=子字串'");
            }
            cfg->has_contains = true;
        } else if (strcmp(argv[i], "--select") == 0 && i + 1 < argc) {
            strncpy(cfg->select_buffer, argv[++i],
                    sizeof(cfg->select_buffer) - 1);
            cfg->has_select = true;
        } else if (strcmp(argv[i], "--format") == 0 && i + 1 < argc) {
            const char *fmt = argv[++i];
            if (strcmp(fmt, "csv") == 0) {
                cfg->out_format = FMT_CSV;
            } else if (strcmp(fmt, "json") == 0) {
                cfg->out_format = FMT_JSON;
            } else {
                fprintf(stderr, "未知輸出格式：%s（支援 csv / json）\n", fmt);
                exit(1);
            }
        } else {
            fprintf(stderr, "未知選項：%s\n\n", argv[i]);
            usage();
        }
    }

    if (cfg->has_where) {
        if (!parse_where_expr(cfg->where_buffer,
                cfg->where_field,  sizeof(cfg->where_field),
                cfg->where_value,  sizeof(cfg->where_value),
                &cfg->where_op)) {
            die_usage("--where 運算式格式錯誤（例：status>=400）");
        }
    }
    if (cfg->has_select &&
        !split_list_inplace(cfg->select_buffer, &cfg->select_fields)) {
        die_usage("--select 欄位數超過上限");
    }
}

/* ── comparison helper ───────────────────────────────────────────────────── */

/* compare_cached: right-hand side is pre-analysed at startup.
 * rhs_is_num / rhs_double are computed once; only the left side
 * (per-row field value) needs fresh analysis each call. */
static int compare_cached(op_t op, const char *left,
                           bool rhs_is_num, double rhs_double,
                           const char *rhs_str) {
    if (rhs_is_num && is_number_string(left)) {
        double a = atof(left);
        switch (op) {
            case OP_EQ: return a == rhs_double;
            case OP_NE: return a != rhs_double;
            case OP_GT: return a >  rhs_double;
            case OP_GE: return a >= rhs_double;
            case OP_LT: return a <  rhs_double;
            case OP_LE: return a <= rhs_double;
            default:    return 0;
        }
    }
    int cmp = strcmp(left, rhs_str);
    switch (op) {
        case OP_EQ: return cmp == 0;
        case OP_NE: return cmp != 0;
        case OP_GT: return cmp >  0;
        case OP_GE: return cmp >= 0;
        case OP_LT: return cmp <  0;
        case OP_LE: return cmp <= 0;
        default:    return 0;
    }
}

/* emit_csv_row: write selected (or all) fields as a single fwrite.
 * Avoids per-field fputs/fputc overhead inside the hot loop. */
static void emit_csv_row(const string_list_t *row,
                          const int *idx, size_t n) {
    char   buf[MAX_LINE_LEN];
    size_t pos = 0;
    size_t i;

    for (i = 0; i < n; i++) {
        const char *fv  = row->items[idx ? idx[i] : (int)i];
        size_t      len = strlen(fv);
        if (i > 0 && pos < sizeof(buf) - 1) { buf[pos++] = ','; }
        if (pos + len < sizeof(buf) - 1) { memcpy(buf + pos, fv, len); pos += len; }
    }
    if (pos < sizeof(buf)) { buf[pos++] = '\n'; }
    fwrite(buf, 1, pos, stdout);
}

/* ── JSON output helpers ──────────────────────────────────────────────────── */

static void json_escape(const char *s) {
    while (*s) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 0x20)         { printf("\\u%04x", (unsigned)c); }
        else                        { putchar(c); }
        s++;
    }
}

static void print_json_row(const string_list_t *header,
                            const string_list_t *row,
                            const config_t *cfg,
                            const int *sel_idx) {
    size_t n = cfg->has_select ? cfg->select_fields.count : header->count;
    size_t i;
    putchar('{');
    for (i = 0; i < n; i++) {
        int col = cfg->has_select ? sel_idx[i] : (int)i;
        if (i > 0) putchar(',');
        putchar('"');
        json_escape(header->items[col]);
        printf("\":\"");
        json_escape(row->items[col]);
        putchar('"');
    }
    puts("}");
}

/* ── selected header (CSV) ───────────────────────────────────────────────── */

static void print_selected_header(const string_list_t *header,
                                   const config_t *cfg,
                                   int *indexes) {
    string_list_t out;
    size_t i;
    out.count = cfg->select_fields.count;
    for (i = 0; i < cfg->select_fields.count; i++) {
        indexes[i] = find_field_index(header, cfg->select_fields.items[i]);
        if (indexes[i] < 0) {
            fprintf(stderr,
                "執行錯誤：--select 欄位 '%s' 不存在於輸入中\n"
                "  可用欄位：",
                cfg->select_fields.items[i]);
            size_t j;
            for (j = 0; j < header->count; j++) {
                fprintf(stderr, "%s%s", j ? "," : "", header->items[j]);
            }
            fprintf(stderr, "\n");
            exit(1);
        }
        out.items[i] = header->items[indexes[i]];
    }
    print_csv_row(stdout, &out);
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    config_t      cfg;
    char          line[MAX_LINE_LEN];
    char          header_buf[MAX_LINE_LEN];
    string_list_t header;
    int           where_idx    = -1;
    int           contains_idx = -1;
    int           sel_idx[MAX_FIELDS];
    memset(sel_idx, 0, sizeof(sel_idx));

    parse_args(argc, argv, &cfg);

    setvbuf(stdin,  NULL, _IOFBF, 1 << 17);
    setvbuf(stdout, NULL, _IOFBF, 1 << 17);

    /* read header */
    if (fgets(header_buf, sizeof(header_buf), stdin) == NULL) return 0;
    trim_newline(header_buf);
    if (!split_csv_inplace(header_buf, &header))
        die_runtime("CSV header 解析失敗");

    /* resolve field indexes */
    if (cfg.has_where) {
        where_idx = find_field_index(&header, cfg.where_field);
        if (where_idx < 0) {
            fprintf(stderr,
                "執行錯誤：--where 欄位 '%s' 不存在於輸入中\n"
                "  可用欄位：",
                cfg.where_field);
            size_t j;
            for (j = 0; j < header.count; j++)
                fprintf(stderr, "%s%s", j ? "," : "", header.items[j]);
            fprintf(stderr, "\n");
            return 1;
        }
    }
    if (cfg.has_contains) {
        contains_idx = find_field_index(&header, cfg.contains_field);
        if (contains_idx < 0) {
            fprintf(stderr,
                "執行錯誤：--contains 欄位 '%s' 不存在\n", cfg.contains_field);
            return 1;
        }
    }

    /* print header */
    if (cfg.out_format == FMT_CSV) {
        if (cfg.has_select) {
            print_selected_header(&header, &cfg, sel_idx);
        } else {
            print_csv_row(stdout, &header);
        }
    } else {
        /* JSON: pre-resolve select indexes for header names */
        if (cfg.has_select) {
            size_t i;
            for (i = 0; i < cfg.select_fields.count; i++) {
                sel_idx[i] = find_field_index(&header,
                                              cfg.select_fields.items[i]);
                if (sel_idx[i] < 0) {
                    fprintf(stderr,
                        "執行錯誤：--select 欄位 '%s' 不存在\n",
                        cfg.select_fields.items[i]);
                    return 1;
                }
            }
        }
    }

    /* pre-compute RHS comparison values once — avoids atof/is_number per row */
    bool   rhs_is_num  = cfg.has_where && is_number_string(cfg.where_value);
    double rhs_double  = rhs_is_num ? atof(cfg.where_value) : 0.0;

    /* process rows */
    while (fgets(line, sizeof(line), stdin) != NULL) {
        string_list_t row;
        trim_newline(line);
        if (line[0] == '\0') { continue; }
        if (!split_csv_inplace(line, &row)) {
            fprintf(stderr, "警告：無法解析資料列，略過：%s\n", line);
            continue;
        }
        if (row.count != header.count) { continue; }

        /* apply --where (uses cached RHS) */
        if (cfg.has_where &&
            !compare_cached(cfg.where_op, row.items[where_idx],
                            rhs_is_num, rhs_double, cfg.where_value)) {
            continue;
        }

        /* apply --contains */
        if (cfg.has_contains &&
            strstr(row.items[contains_idx], cfg.contains_value) == NULL) {
            continue;
        }

        /* emit row (single fwrite per row) */
        if (cfg.out_format == FMT_JSON) {
            print_json_row(&header, &row, &cfg, sel_idx);
        } else if (cfg.has_select) {
            emit_csv_row(&row, sel_idx, cfg.select_fields.count);
        } else {
            emit_csv_row(&row, NULL, row.count);
        }
    }

    return 0;
}
