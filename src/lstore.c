#include "common.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef enum {
    MODE_NONE,
    MODE_PUT,
    MODE_GET,
    MODE_DELETE,
    MODE_LIST,
    MODE_CLEANUP
} mode_t;

typedef struct {
    mode_t mode;
    const char *db_path;
    const char *key_arg;
    char key_field[128];
    long ttl_seconds;
} config_t;

static void usage(void) {
    fprintf(stderr,
            "用法：lstore --db PATH [--put --key-field FIELD [--ttl SEC] | --get KEY | --delete KEY | --list | --cleanup]\n");
    exit(1);
}

static long now_epoch(void) {
    return (long)time(NULL);
}

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;
    memset(cfg, 0, sizeof(*cfg));

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--db") == 0 && i + 1 < argc) {
            cfg->db_path = argv[++i];
        } else if (strcmp(argv[i], "--put") == 0) {
            cfg->mode = MODE_PUT;
        } else if (strcmp(argv[i], "--get") == 0 && i + 1 < argc) {
            cfg->mode = MODE_GET;
            cfg->key_arg = argv[++i];
        } else if (strcmp(argv[i], "--delete") == 0 && i + 1 < argc) {
            cfg->mode = MODE_DELETE;
            cfg->key_arg = argv[++i];
        } else if (strcmp(argv[i], "--list") == 0) {
            cfg->mode = MODE_LIST;
        } else if (strcmp(argv[i], "--cleanup") == 0) {
            cfg->mode = MODE_CLEANUP;
        } else if (strcmp(argv[i], "--key-field") == 0 && i + 1 < argc) {
            strncpy(cfg->key_field, argv[++i], sizeof(cfg->key_field) - 1);
        } else if (strcmp(argv[i], "--ttl") == 0 && i + 1 < argc) {
            cfg->ttl_seconds = atol(argv[++i]);
        } else {
            usage();
        }
    }

    if (cfg->db_path == NULL || cfg->mode == MODE_NONE) {
        usage();
    }
    if (cfg->mode == MODE_PUT && cfg->key_field[0] == '\0') {
        die_usage("put mode requires --key-field");
    }
}

static FILE *open_db_for_read(const char *path) {
    FILE *fp = fopen(path, "r");
    if (fp == NULL && errno == ENOENT) {
        return NULL;
    }
    if (fp == NULL) {
        die_runtime("cannot open database for reading");
    }
    return fp;
}

static FILE *open_db_for_append(const char *path) {
    FILE *fp = fopen(path, "a");
    if (fp == NULL) {
        die_runtime("cannot open database for append");
    }
    return fp;
}

static bool is_expired(long expires_at) {
    return expires_at != 0 && expires_at <= now_epoch();
}

static bool parse_store_line(char *line, char **key, long *expires_at, char **value) {
    char *expires_text;

    trim_newline(line);
    *key = strtok(line, "\t");
    expires_text = strtok(NULL, "\t");
    *value = strtok(NULL, "");
    if (*key == NULL || expires_text == NULL || *value == NULL) {
        return false;
    }

    *expires_at = atol(expires_text);
    return true;
}

static void copy_file_contents(const char *src_path, const char *dst_path) {
    FILE *src = fopen(src_path, "rb");
    FILE *dst;
    char buffer[4096];
    size_t nread;

    if (src == NULL) {
        die_runtime("無法開啟暫存資料庫檔案以進行複製");
    }

    dst = fopen(dst_path, "wb");
    if (dst == NULL) {
        fclose(src);
        die_runtime("無法建立新的資料庫檔案");
    }

    while ((nread = fread(buffer, 1, sizeof(buffer), src)) > 0) {
        if (fwrite(buffer, 1, nread, dst) != nread) {
            fclose(src);
            fclose(dst);
            die_runtime("寫入資料庫檔案失敗");
        }
    }

    fclose(src);
    fclose(dst);
}

static void put_rows(const config_t *cfg) {
    char header_buf[MAX_LINE_LEN];
    char line[MAX_LINE_LEN];
    string_list_t header;
    FILE *db;
    int key_index;
    long expires_at = 0;

    if (fgets(header_buf, sizeof(header_buf), stdin) == NULL) {
        return;
    }
    trim_newline(header_buf);
    if (!split_csv_inplace(header_buf, &header)) {
        die_runtime("invalid CSV header");
    }

    key_index = find_field_index(&header, cfg->key_field);
    if (key_index < 0) {
        die_runtime("key field not found");
    }

    if (cfg->ttl_seconds > 0) {
        expires_at = now_epoch() + cfg->ttl_seconds;
    }

    db = open_db_for_append(cfg->db_path);
    while (fgets(line, sizeof(line), stdin) != NULL) {
        char row_buf[MAX_LINE_LEN];
        string_list_t row;
        trim_newline(line);
        strncpy(row_buf, line, sizeof(row_buf) - 1);
        row_buf[sizeof(row_buf) - 1] = '\0';
        if (!split_csv_inplace(row_buf, &row)) {
            continue;
        }
        if (row.count != header.count) {
            continue;
        }
        fprintf(db, "%s\t%ld\t%s\n", row.items[key_index], expires_at, line);
    }
    fclose(db);
}

static void scan_db(const config_t *cfg, bool rewrite, const char *match_key, bool delete_mode) {
    FILE *in = open_db_for_read(cfg->db_path);
    FILE *out = NULL;
    char line[MAX_LINE_LEN];
    char latest_value[MAX_LINE_LEN];
    bool found_latest = false;
    char tmp_path[MAX_LINE_LEN];

    if (in == NULL) {
        return;
    }
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", cfg->db_path);
    if (rewrite) {
        out = fopen(tmp_path, "w");
        if (out == NULL) {
            fclose(in);
            die_runtime("無法開啟暫存資料庫檔案");
        }
    }

    while (fgets(line, sizeof(line), in) != NULL) {
        char row_copy[MAX_LINE_LEN];
        char *key;
        char *value;
        long expires_at;
        bool matched;

        strncpy(row_copy, line, sizeof(row_copy) - 1);
        row_copy[sizeof(row_copy) - 1] = '\0';
        if (!parse_store_line(row_copy, &key, &expires_at, &value)) {
            continue;
        }
        if (is_expired(expires_at)) {
            continue;
        }

        matched = match_key != NULL && strcmp(key, match_key) == 0;

        if (cfg->mode == MODE_GET && matched) {
            strncpy(latest_value, value, sizeof(latest_value) - 1);
            latest_value[sizeof(latest_value) - 1] = '\0';
            found_latest = true;
        } else if (cfg->mode == MODE_LIST) {
            printf("%s\t%s\n", key, value);
        }

        if (rewrite) {
            if (delete_mode && matched) {
                continue;
            }
            fprintf(out, "%s\t%ld\t%s\n", key, expires_at, value);
        }
    }

    fclose(in);
    if (cfg->mode == MODE_GET && found_latest) {
        puts(latest_value);
    }
    if (rewrite) {
        fclose(out);
        if (remove(cfg->db_path) != 0 && errno != ENOENT) {
            die_runtime("無法刪除舊資料庫檔案");
        }
        if (rename(tmp_path, cfg->db_path) != 0) {
            copy_file_contents(tmp_path, cfg->db_path);
            if (remove(tmp_path) != 0) {
                die_runtime("無法移除暫存資料庫檔案");
            }
        }
    }
}

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
            scan_db(&cfg, true, cfg.key_arg, true);
            break;
        case MODE_LIST:
            scan_db(&cfg, false, NULL, false);
            break;
        case MODE_CLEANUP:
            scan_db(&cfg, true, NULL, false);
            break;
        default:
            usage();
    }

    return 0;
}
