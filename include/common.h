#ifndef BUSYPIPE_COMMON_H
#define BUSYPIPE_COMMON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#define MAX_LINE_LEN 4096
#define MAX_FIELDS 64

typedef struct {
    char *items[MAX_FIELDS];
    size_t count;
} string_list_t;

void die_usage(const char *message);
void die_runtime(const char *message);
void trim_newline(char *s);
bool split_csv_inplace(char *line, string_list_t *out);
bool split_list_inplace(char *text, string_list_t *out);
int find_field_index(const string_list_t *header, const char *name);
bool is_number_string(const char *text);
void print_csv_row(FILE *stream, const string_list_t *row);

#endif
