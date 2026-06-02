CC     ?= gcc
CFLAGS ?= -Wall -Wextra -std=c11 -O2
BUILD  := build

.PHONY: all clean

all: $(BUILD)/gen_log

$(BUILD)/gen_log: gen_log.c | $(BUILD)
	$(CC) $(CFLAGS) $< -o $@

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
