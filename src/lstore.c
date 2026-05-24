/*
 * lstore — file-based key-value store for BusyPipe
 *
 * Provides persistent, TTL-aware storage backed by a plain-text TSV file.
 * Designed for low-overhead use in embedded / BusyBox environments.
 *
 * Storage format (one record per line):
 *   key<TAB>expires_at_epoch<TAB>raw_csv_row\n
 *
 * expires_at_epoch == 0  → never expires
 *
 * Usage:
 *   lstore --db PATH --put  --key-field FIELD [--ttl SEC] [--stats]
 *   lstore --db PATH --get    KEY
 *   lstore --db PATH --delete KEY
 *   lstore --db PATH --list
 *   lstore --db PATH --cleanup [--stats]
 *   lstore --db PATH --count
 *
 * UNIX Philosophy: small, composable, stdio-friendly.
 */

#include "common.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ── write-buffer tuneable ───────────────────────────────────────────────── */
#define WRITE_BUF_LINES  64          /* flush every N lines */
#define WRITE_BUF_BYTES  (128*1024)  /* or every 128 KiB    */

/* ── mode enum ───────────────────────────────────────────────────────────── */

typedef enum {
    MODE_NONE,
    MODE_PUT,
    MODE_GET,
    MODE_DELETE,
    MODE_LIST,
    MODE_CLEANUP,
    MODE_COUNT
} mode_t;

/* ── config ───────────────────────────────────────────────────────────────── */

typedef struct {
    mode_t      mode;
    const char *db_path;
    const char *key_arg;
    char        key_field[128];
    long        ttl_seconds;
    bool        stats;
} config_t;

/* ── usage / help ─────────────────────────────────────────────────────────── */

static void usage(void) {
    fprintf(stderr,
        "用法：lstore --db PATH <模式> [選項]\n"
        "\n"
        "將 CSV 串流資料寫入檔案式 key-value store，支援 TTL 與 CRUD 操作。\n"
        "\n"
        "必要參數：\n"
        "  --db PATH            資料庫檔案路徑（TSV 格式）\n"
        "\n"
        "模式（擇一）：\n"
        "  --put                從 stdin 讀取 CSV，寫入 store\n"
        "    --key-field FIELD  指定作為 key 的欄位名稱（put 模式必填）\n"
        "    --ttl SEC          設定資料存活時間（秒），0 = 永不過期\n"
        "  --get KEY            查詢並輸出最新一筆 key 對應的資料\n"
        "  --delete KEY         刪除所有符合 key 的資料\n"
        "  --list               列出所有有效資料（格式：key<TAB>value）\n"
        "  --cleanup            移除所有已過期資料（重寫資料檔）\n"
        "  --count              輸出目前有效資料筆數\n"
        "\n"
        "其他選項：\n"
        "  --stats              輸出操作統計到 stderr\n"
        "  --help               顯示此說明\n"
        "\n"
        "資料儲存格式（TSV）：\n"
        "  key<TAB>expires_at_epoch<TAB>raw_csv_row\n"
        "  expires_at_epoch = 0 代表永不過期\n"
        "\n"
        "範例：\n"
        "  # 寫入（TTL 1 小時）\n"
        "  lparser --format nginx --csv < access.log \\\n"
        "    | lfilter --where 'status>=400' \\\n"
        "    | lstore --db errors.tsv --put --key-field ip --ttl 3600\n"
        "\n"
        "  # 查詢\n"
        "  lstore --db errors.tsv --get 192.168.0.4\n"
        "\n"
        "  # 列出全部\n"
        "  lstore --db errors.tsv --list\n"
        "\n"
        "  # 清理過期資料\n"
        "  lstore --db errors.tsv --cleanup --stats\n");
    exit(1);
}

/* ── helpers ──────────────────────────────────────────────────────────────── */

static long now_epoch(void) {
    return (long)time(NULL);
}

static bool is_expired(long expires_at) {
    return expires_at != 0 && expires_at <= now_epoch();
}

static bool parse_store_line(char *line,
                              char **key,
                              long  *expires_at,
                              char **value) {
    char *expires_text;
    trim_newline(line);
    *key         = strtok(line, "\t");
    expires_text = strtok(NULL, "\t");
    *value       = strtok(NULL, "");
    if (*key == NULL || expires_text == NULL || *value == NULL) return false;
    *expires_at  = atol(expires_text);
    return true;
}

/* ── db file operations ──────────────────────────────────────────────────── */

static FILE *open_db_read(const char *path) {
    FILE *fp = fopen(path, "r");
    if (fp == NULL && errno == ENOENT) return NULL;
    if (fp == NULL) die_runtime("cannot open database for reading");
    return fp;
}

static FILE *open_db_append(const char *path) {
    FILE *fp = fopen(path, "a");
    if (fp == NULL) die_runtime("cannot open database for writing");
    return fp;
}

static void copy_file(const char *src, const char *dst) {
    FILE  *in  = fopen(src, "rb");
    FILE  *out;
    char   buf[4096];
    size_t n;

    if (in == NULL) die_runtime("copy: cannot open source file");
    out = fopen(dst, "wb");
    if (out == NULL) { fclose(in); die_runtime("copy: cannot open dest file"); }

    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) {
            fclose(in); fclose(out);
            die_runtime("copy: write error");
        }
    }
    fclose(in);
    fclose(out);
}

static void atomic_replace(const char *tmp_path, const char *final_path) {
    if (rename(tmp_path, final_path) == 0) return;
    /* fallback for cross-device rename */
    copy_file(tmp_path, final_path);
    remove(tmp_path);
}

/* ── parse arguments ──────────────────────────────────────────────────────── */

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;
    memset(cfg, 0, sizeof(*cfg));

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage();
        } else if (strcmp(argv[i], "--db") == 0 && i + 1 < argc) {
            cfg->db_path = argv[++i];
        } else if (strcmp(argv[i], "--put") == 0) {
            cfg->mode = MODE_PUT;
        } else if (strcmp(argv[i], "--get") == 0 && i + 1 < argc) {
            cfg->mode   = MODE_GET;
            cfg->key_arg = argv[++i];
        } else if (strcmp(argv[i], "--delete") == 0 && i + 1 < argc) {
            cfg->mode   = MODE_DELETE;
            cfg->key_arg = argv[++i];
        } else if (strcmp(argv[i], "--list") == 0) {
            cfg->mode = MODE_LIST;
        } else if (strcmp(argv[i], "--cleanup") == 0) {
            cfg->mode = MODE_CLEANUP;
        } else if (strcmp(argv[i], "--count") == 0) {
            cfg->mode = MODE_COUNT;
        } else if (strcmp(argv[i], "--key-field") == 0 && i + 1 < argc) {
            strncpy(cfg->key_field, argv[++i], sizeof(cfg->key_field) - 1);
        } else if (strcmp(argv[i], "--ttl") == 0 && i + 1 < argc) {
            cfg->ttl_seconds = atol(argv[++i]);
        } else if (strcmp(argv[i], "--stats") == 0) {
            cfg->stats = true;
        } else {
            fprintf(stderr, "未知選項：%s\n\n", argv[i]);
            usage();
        }
    }

    if (cfg->db_path == NULL || cfg->mode == MODE_NONE) {
        fprintf(stderr, "錯誤：需指定 --db 與操作模式\n\n");
        usage();
    }
    if (cfg->mode == MODE_PUT && cfg->key_field[0] == '\0') {
        die_usage("--put 模式需要 --key-field");
    }
}

/* ── MODE_PUT (with buffered write) ──────────────────────────────────────── */

static void put_rows(const config_t *cfg) {
    char          header_buf[MAX_LINE_LEN];
    char          line[MAX_LINE_LEN];
    string_list_t header;
    FILE         *db;
    int           key_index;
    long          expires_at = 0;
    unsigned long written = 0, skipped = 0;
    unsigned long buf_lines = 0;
    size_t        buf_bytes = 0;

    if (fgets(header_buf, sizeof(header_buf), stdin) == NULL) return;
    trim_newline(header_buf);
    if (!split_csv_inplace(header_buf, &header))
        die_runtime("invalid CSV header");

    key_index = find_field_index(&header, cfg->key_field);
    if (key_index < 0) {
        fprintf(stderr, "執行錯誤：key-field '%s' 不存在於 header\n"
                        "  可用欄位：", cfg->key_field);
        size_t j;
        for (j = 0; j < header.count; j++)
            fprintf(stderr, "%s%s", j ? "," : "", header.items[j]);
        fprintf(stderr, "\n");
        exit(1);
    }

    if (cfg->ttl_seconds > 0)
        expires_at = now_epoch() + cfg->ttl_seconds;

    db = open_db_append(cfg->db_path);

    while (fgets(line, sizeof(line), stdin) != NULL) {
        char          row_buf[MAX_LINE_LEN];
        string_list_t row;
        int           n;

        trim_newline(line);
        if (line[0] == '\0') continue;

        strncpy(row_buf, line, sizeof(row_buf) - 1);
        row_buf[sizeof(row_buf) - 1] = '\0';

        if (!split_csv_inplace(row_buf, &row) || row.count != header.count) {
            skipped++;
            continue;
        }

        n = fprintf(db, "%s\t%ld\t%s\n",
                    row.items[key_index], expires_at, line);
        if (n > 0) {
            written++;
            buf_lines++;
            buf_bytes += (size_t)n;
        }

        /* buffered flush */
        if (buf_lines >= WRITE_BUF_LINES || buf_bytes >= WRITE_BUF_BYTES) {
            fflush(db);
            buf_lines = 0;
            buf_bytes = 0;
        }
    }

    fflush(db);
    fclose(db);

    if (cfg->stats) {
        fprintf(stderr, "put: written=%lu skipped=%lu\n", written, skipped);
    }
}

/* ── scan_db: shared implementation for get/list/delete/cleanup/count ─────── */

static void scan_db(const config_t *cfg,
                    bool rewrite, const char *match_key, bool delete_mode) {
    FILE *in = open_db_read(cfg->db_path);
    FILE *out = NULL;
    char  line[MAX_LINE_LEN];
    char  latest_value[MAX_LINE_LEN];
    bool  found_latest = false;
    char  tmp_path[MAX_LINE_LEN];
    unsigned long kept = 0, removed = 0, total = 0;

    if (in == NULL) {
        if (cfg->stats)
            fprintf(stderr, "scan: db empty or not found\n");
        return;
    }

    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", cfg->db_path);
    if (rewrite) {
        out = fopen(tmp_path, "w");
        if (out == NULL) {
            fclose(in);
            die_runtime("cannot open tmp file for rewrite");
        }
    }

    while (fgets(line, sizeof(line), in) != NULL) {
        char  row_copy[MAX_LINE_LEN];
        char *key, *value;
        long  expires_at;
        bool  matched;

        total++;
        strncpy(row_copy, line, sizeof(row_copy) - 1);
        row_copy[sizeof(row_copy) - 1] = '\0';

        if (!parse_store_line(row_copy, &key, &expires_at, &value))
            continue;

        if (is_expired(expires_at)) {
            removed++;
            /* expired: do not write to out */
            continue;
        }

        matched = (match_key != NULL && strcmp(key, match_key) == 0);

        if (cfg->mode == MODE_GET && matched) {
            strncpy(latest_value, value, sizeof(latest_value) - 1);
            latest_value[sizeof(latest_value) - 1] = '\0';
            found_latest = true;
            /* keep scanning for a newer entry */
        } else if (cfg->mode == MODE_LIST) {
            printf("%s\t%s\n", key, value);
            kept++;
        } else if (cfg->mode == MODE_COUNT) {
            kept++;
        }

        if (rewrite) {
            if (delete_mode && matched) {
                removed++;
                continue;
            }
            fprintf(out, "%s\t%ld\t%s\n", key, expires_at, value);
            kept++;
        }
    }

    fclose(in);

    if (cfg->mode == MODE_GET) {
        if (found_latest) {
            puts(latest_value);
        } else {
            fprintf(stderr, "lstore: key '%s' 不存在或已過期\n",
                    match_key ? match_key : "");
        }
    }

    if (cfg->mode == MODE_COUNT) {
        printf("%lu\n", kept);
    }

    if (rewrite) {
        fclose(out);
        if (remove(cfg->db_path) != 0 && errno != ENOENT)
            die_runtime("cannot remove old db file");
        atomic_replace(tmp_path, cfg->db_path);
    }

    if (cfg->stats) {
        fprintf(stderr, "scan: total=%lu kept=%lu removed=%lu\n",
                total, kept, removed);
    }
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    config_t cfg;
    parse_args(argc, argv, &cfg);

    switch (cfg.mode) {
        case MODE_PUT:
            put_rows(&cfg);
            break;
        case MODE_GET:
            scan_db(&cfg, false, cfg.key_arg, false);
            break;
        case MODE_DELETE:
            scan_db(&cfg, true,  cfg.key_arg, true);
            break;
        case MODE_LIST:
            scan_db(&cfg, false, NULL, false);
            break;
        case MODE_CLEANUP:
            scan_db(&cfg, true,  NULL, false);
            break;
        case MODE_COUNT:
            scan_db(&cfg, false, NULL, false);
            break;
        default:
            usage();
    }

    return 0;
}
