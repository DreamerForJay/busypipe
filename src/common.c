#include "common.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

void die_usage(const char *message) {
    fprintf(stderr, "參數錯誤：%s\n", message);
    exit(1);
}

void die_runtime(const char *message) {
    fprintf(stderr, "執行錯誤：%s\n", message);
    exit(1);
}

void trim_newline(char *s) {
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r')) {
        s[--len] = '\0';
    }
}

static bool split_inplace(char *text, char delim, string_list_t *out) {
    char *cursor = text;
    out->count = 0;

    if (*cursor == '\0') {
        return true;
    }

    while (*cursor != '\0') {
        if (out->count >= MAX_FIELDS) {
            return false;
        }
        out->items[out->count++] = cursor;
        while (*cursor != '\0' && *cursor != delim) {
            cursor++;
        }
        if (*cursor == delim) {
            *cursor = '\0';
            cursor++;
        }
    }

    return true;
}

bool split_csv_inplace(char *line, string_list_t *out) {
    return split_inplace(line, ',', out);
}

bool split_list_inplace(char *text, string_list_t *out) {
    return split_inplace(text, ',', out);
}

int find_field_index(const string_list_t *header, const char *name) {
    size_t i;
    for (i = 0; i < header->count; i++) {
        if (strcmp(header->items[i], name) == 0) {
            return (int)i;
        }
    }
    return -1;
}

bool is_number_string(const char *text) {
    bool has_digit = false;
    const unsigned char *cursor = (const unsigned char *)text;

    if (*cursor == '-' || *cursor == '+') {
        cursor++;
    }

    while (*cursor != '\0') {
        if (*cursor == '.') {
            cursor++;
            continue;
        }
        if (!isdigit(*cursor)) {
            return false;
        }
        has_digit = true;
        cursor++;
    }

    return has_digit;
}

void print_csv_row(FILE *stream, const string_list_t *row) {
    size_t i;
    for (i = 0; i < row->count; i++) {
        if (i > 0) {
            fputc(',', stream);
        }
        fputs(row->items[i], stream);
    }
    fputc('\n', stream);
}
