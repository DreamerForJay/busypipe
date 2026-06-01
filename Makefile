CC      ?= gcc
CFLAGS  ?= -Wall -Wextra -Werror -std=c11 -O2
CPPFLAGS?= -Iinclude
LDFLAGS ?=

BUILD_DIR := build
SRC_DIR   := src
MAN_DIR   := docs/man
DATA_DIR  := data

COMMON_OBJ := $(BUILD_DIR)/common.o

TARGETS := $(BUILD_DIR)/lparser $(BUILD_DIR)/lfilter $(BUILD_DIR)/lstore

.PHONY: all clean dirs install bench test test-bb help

all: dirs $(TARGETS)

dirs:
	@mkdir -p $(BUILD_DIR) $(DATA_DIR)

$(BUILD_DIR)/common.o: $(SRC_DIR)/common.c include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/lparser: $(SRC_DIR)/lparser.c $(COMMON_OBJ) include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(COMMON_OBJ) $(LDFLAGS) -o $@

$(BUILD_DIR)/lfilter: $(SRC_DIR)/lfilter.c $(COMMON_OBJ) include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(COMMON_OBJ) $(LDFLAGS) -o $@

$(BUILD_DIR)/lstore: $(SRC_DIR)/lstore.c $(COMMON_OBJ) include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(COMMON_OBJ) $(LDFLAGS) -o $@

# ── install (to /usr/local/bin by default) ──────────────────────────────────
PREFIX ?= /usr/local
install: all
	install -m 755 $(BUILD_DIR)/lparser  $(PREFIX)/bin/lparser
	install -m 755 $(BUILD_DIR)/lfilter  $(PREFIX)/bin/lfilter
	install -m 755 $(BUILD_DIR)/lstore   $(PREFIX)/bin/lstore
	@echo "Installed to $(PREFIX)/bin"

# ── man pages ───────────────────────────────────────────────────────────────
install-man:
	@mkdir -p $(PREFIX)/share/man/man1
	install -m 644 $(MAN_DIR)/lparser.1 $(PREFIX)/share/man/man1/lparser.1
	install -m 644 $(MAN_DIR)/lfilter.1 $(PREFIX)/share/man/man1/lfilter.1
	install -m 644 $(MAN_DIR)/lstore.1  $(PREFIX)/share/man/man1/lstore.1
	@echo "Man pages installed to $(PREFIX)/share/man/man1"

# ── functional smoke-tests ──────────────────────────────────────────────────
test: all
	@echo "=== lparser: access.log (CSV) ==="
	@./$(BUILD_DIR)/lparser \
	  --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
	  --fields ip,time,method,path,status --csv < samples/access.log
	@echo "=== lparser: access.log (JSON) ==="
	@./$(BUILD_DIR)/lparser \
	  --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
	  --fields ip,time,method,path,status --json < samples/access.log
	@echo "=== lparser: auth.log (CSV) ==="
	@./$(BUILD_DIR)/lparser \
	  --format auth --csv < samples/auth.log
	@echo "=== lfilter: status>=400 ==="
	@./$(BUILD_DIR)/lparser \
	  --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
	  --fields ip,time,method,path,status --csv < samples/access.log | \
	  ./$(BUILD_DIR)/lfilter --where 'status>=400' --select 'ip,path,status'
	@echo "=== lfilter: JSON output ==="
	@./$(BUILD_DIR)/lparser \
	  --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
	  --fields ip,time,method,path,status --csv < samples/access.log | \
	  ./$(BUILD_DIR)/lfilter --where 'status>=400' --format json
	@echo "=== lstore: put/get/list/cleanup ==="
	@rm -f $(DATA_DIR)/test.tsv
	@./$(BUILD_DIR)/lparser \
	  --regex '^([^ ]+) .* \[([^]]+)\] "([^ ]+) ([^ ]+) [^"]*" ([0-9]{3}) .*' \
	  --fields ip,time,method,path,status --csv < samples/access.log | \
	  ./$(BUILD_DIR)/lfilter --where 'status>=400' | \
	  ./$(BUILD_DIR)/lstore --db $(DATA_DIR)/test.tsv --put --key-field ip --ttl 3600
	@./$(BUILD_DIR)/lstore --db $(DATA_DIR)/test.tsv --list
	@./$(BUILD_DIR)/lstore --db $(DATA_DIR)/test.tsv --get 192.168.0.4
	@./$(BUILD_DIR)/lstore --db $(DATA_DIR)/test.tsv --cleanup --stats
	@rm -f $(DATA_DIR)/test.tsv
	@echo "=== All tests passed ==="

# ── BusyBox applet 適配版驗證 ─────────────────────────────────────────────
# 不需要 BusyBox 原始碼，直接以 gcc 編譯 busybox/libpipe.c + *_bb.c。
# 同時驗證 lXXX_main() 功能正確性與 standalone 輸出一致性（需先執行 make）。
test-bb: all
	@bash scripts/test_bb_applets.sh

# ── benchmark ───────────────────────────────────────────────────────────────
bench: all
	@bash scripts/benchmark.sh

# ── clean ───────────────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR)
	rm -f $(DATA_DIR)/*.tsv $(DATA_DIR)/*.csv

help:
	@echo "BusyPipe Makefile targets:"
	@echo "  all         build all tools (default)"
	@echo "  test        run smoke tests"
	@echo "  bench       run benchmark vs GNU tools"
	@echo "  install     install to PREFIX (default /usr/local)"
	@echo "  install-man install man pages"
	@echo "  clean       remove build artifacts"
