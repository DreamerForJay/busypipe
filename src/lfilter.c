#include "common.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum {
    OP_NONE,
    OP_EQ,
    OP_NE,
    OP_GT,
    OP_GE,
    OP_LT,
    OP_LE
} op_t;

typedef struct {
    char where_buffer[256];
    char select_buffer[1024];
    bool has_where;
    bool has_select;
    char where_field[128];
    char where_value[128];
    op_t where_op;
    string_list_t select_fields;
} config_t;

static void usage(void) {
    fprintf(stderr, "用法：lfilter [--where expr] [--select f1,f2,...]\n");
    exit(1);
}

static bool parse_where_expr(config_t *cfg) {
    static const struct {
        const char *text;
        op_t op;
    } ops[] = {
        {">=", OP_GE},
        {"<=", OP_LE},
        {"==", OP_EQ},
        {"!=", OP_NE},
        {">", OP_GT},
        {"<", OP_LT},
    };
    size_t i;

    for (i = 0; i < sizeof(ops) / sizeof(ops[0]); i++) {
        char *pos = strstr(cfg->where_buffer, ops[i].text);
        if (pos != NULL) {
            size_t left_len = (size_t)(pos - cfg->where_buffer);
            size_t right_len = strlen(pos + strlen(ops[i].text));
            if (left_len == 0 || right_len == 0 ||
                left_len >= sizeof(cfg->where_field) ||
                right_len >= sizeof(cfg->where_value)) {
                return false;
            }
            memcpy(cfg->where_field, cfg->where_buffer, left_len);
            cfg->where_field[left_len] = '\0';
            memcpy(cfg->where_value, pos + strlen(ops[i].text), right_len);
            cfg->where_value[right_len] = '\0';
            cfg->where_op = ops[i].op;
            return true;
        }
    }
    return false;
}

static void parse_args(int argc, char **argv, config_t *cfg) {
    int i;
    memset(cfg, 0, sizeof(*cfg));

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--where") == 0 && i + 1 < argc) {
            strncpy(cfg->where_buffer, argv[++i], sizeof(cfg->where_buffer) - 1);
            cfg->has_where = true;
        } else if (strcmp(argv[i], "--select") == 0 && i + 1 < argc) {
            strncpy(cfg->select_buffer, argv[++i], sizeof(cfg->select_buffer) - 1);
            cfg->has_select = true;
        } else {
            usage();
        }
    }

    if (cfg->has_where && !parse_where_expr(cfg)) {
        die_usage("invalid --where expression");
    }
    if (cfg->has_select && !split_list_inplace(cfg->select_buffer, &cfg->select_fields)) {
        die_usage("too many selected fields");
    }
}

static int compare_values(op_t op, const char *left, const char *right) {
    if (is_number_string(left) && is_number_string(right)) {
        double a = atof(left);
        double b = atof(right);
        switch (op) {
            case OP_EQ: return a == b;
            case OP_NE: return a != b;
            case OP_GT: return a > b;
            case OP_GE: return a >= b;
            case OP_LT: return a < b;
            case OP_LE: return a <= b;
            default: return 0;
        }
    }

    switch (op) {
        case OP_EQ: return strcmp(left, right) == 0;
        case OP_NE: return strcmp(left, right) != 0;
        case OP_GT: return strcmp(left, right) > 0;
        case OP_GE: return strcmp(left, right) >= 0;
        case OP_LT: return strcmp(left, right) < 0;
        case OP_LE: return strcmp(left, right) <= 0;
        default: return 0;
    }
}

static void print_selected_header(const string_list_t *header, const config_t *cfg, int *indexes) {
    string_list_t out;
    size_t i;
    out.count = cfg->select_fields.count;
    for (i = 0; i < cfg->select_fields.count; i++) {
        indexes[i] = find_field_index(header, cfg->select_fields.items[i]);
        if (indexes[i] < 0) {
            die_runtime("selected field not found");
        }
        out.items[i] = header->items[indexes[i]];
    }
    print_csv_row(stdout, &out);
}

int main(int argc, char **argv) {
    config_t cfg;
    char line[MAX_LINE_LEN];
    char header_buf[MAX_LINE_LEN];
    string_list_t header;
    int where_index = -1;
    int selected_indexes[MAX_FIELDS];
    bool header_printed = false;

    parse_args(argc, argv, &cfg);

    if (fgets(header_buf, sizeof(header_buf), stdin) == NULL) {
        return 0;
    }
    trim_newline(header_buf);
    if (!split_csv_inplace(header_buf, &header)) {
        die_runtime("invalid header");
    }

    if (cfg.has_where) {
        where_index = find_field_index(&header, cfg.where_field);
        if (where_index < 0) {
            die_runtime("where field not found");
        }
    }

    if (cfg.has_select) {
        print_selected_header(&header, &cfg, selected_indexes);
    } else {
        print_csv_row(stdout, &header);
    }
    header_printed = true;

    while (fgets(line, sizeof(line), stdin) != NULL) {
        string_list_t row;
        trim_newline(line);
        if (!split_csv_inplace(line, &row)) {
            die_runtime("invalid CSV row");
        }
        if (row.count != header.count) {
            continue;
        }
        if (cfg.has_where &&
            !compare_values(cfg.where_op, row.items[where_index], cfg.where_value)) {
            continue;
        }

        if (cfg.has_select) {
            string_list_t out;
            size_t i;
            out.count = cfg.select_fields.count;
            for (i = 0; i < cfg.select_fields.count; i++) {
                out.items[i] = row.items[selected_indexes[i]];
            }
            print_csv_row(stdout, &out);
        } else if (header_printed) {
            print_csv_row(stdout, &row);
        }
    }

    return 0;
}
