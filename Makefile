CC ?= gcc
CFLAGS ?= -Wall -Wextra -Werror -std=c11 -O2
CPPFLAGS ?= -Iinclude
LDFLAGS ?=

BUILD_DIR := build
SRC_DIR := src

COMMON_OBJ := $(BUILD_DIR)/common.o

.PHONY: all clean dirs

all: dirs $(BUILD_DIR)/lparser $(BUILD_DIR)/lfilter $(BUILD_DIR)/lstore

dirs:
	if not exist $(BUILD_DIR) mkdir $(BUILD_DIR)
	if not exist data mkdir data

$(BUILD_DIR)/common.o: $(SRC_DIR)/common.c include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/lparser: $(SRC_DIR)/lparser.c $(COMMON_OBJ) include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(COMMON_OBJ) $(LDFLAGS) -o $@

$(BUILD_DIR)/lfilter: $(SRC_DIR)/lfilter.c $(COMMON_OBJ) include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(COMMON_OBJ) $(LDFLAGS) -o $@

$(BUILD_DIR)/lstore: $(SRC_DIR)/lstore.c $(COMMON_OBJ) include/common.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(COMMON_OBJ) $(LDFLAGS) -o $@

clean:
	if exist $(BUILD_DIR) rmdir /s /q $(BUILD_DIR)
