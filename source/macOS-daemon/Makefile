# Retro Cloud Sync - legacy Mac background process

DAEMON_NAME := RetroCloudSyncDaemon

MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_DIR := $(abspath $(MAKEFILE_DIR)/../..)
OUTPUT_ROOT := $(PROJECT_DIR)/build/macOS-daemon

LEGACY_TOOLCHAIN := /osxcross/legacy/target
LEGACY_BIN := $(LEGACY_TOOLCHAIN)/bin
SDK := $(LEGACY_TOOLCHAIN)/SDK/MacOSX10.5.sdk

PPC_CC := $(LEGACY_BIN)/oppc32-gcc
I386_CC := $(LEGACY_BIN)/o32-gcc
LIPO := $(LEGACY_BIN)/i386-apple-darwin9-lipo
ANALYZER := /usr/bin/clang

SOURCES := main.m
SOURCE_PATHS := $(addprefix $(MAKEFILE_DIR)/,$(SOURCES))

MACOSX_DEPLOYMENT_TARGET := 10.4
COMMON_FLAGS := -g -std=c99 -Wall -Wextra -fno-stack-protector \
	-fno-common -fno-zero-initialized-in-bss
LINK_FLAGS := -framework Foundation -lobjc -lgcc_s.10.4

CONFIG ?= release
ifeq ($(CONFIG),debug)
  OPT_FLAGS := -O0
else
  OPT_FLAGS := -O3
endif

BUILD_DIR := $(OUTPUT_ROOT)/$(CONFIG)
INTERMEDIATES_DIR := $(BUILD_DIR)/Intermediates
OUTPUT := $(BUILD_DIR)/$(DAEMON_NAME)
PPC_OBJECTS := $(addprefix $(INTERMEDIATES_DIR)/ppc/,$(SOURCES:.m=.o))
I386_OBJECTS := $(addprefix $(INTERMEDIATES_DIR)/i386/,$(SOURCES:.m=.o))

.DEFAULT_GOAL := release

release: validate-build
	@echo "--- Building macOS Daemon Release (-O3) ---"
	@$(MAKE) --no-print-directory $(OUTPUT_ROOT)/release/$(DAEMON_NAME) \
		CONFIG=release

debug: validate-build
	@echo "--- Building macOS Daemon Debug (-O0) ---"
	@$(MAKE) --no-print-directory $(OUTPUT_ROOT)/debug/$(DAEMON_NAME) \
		CONFIG=debug

clean:
	@echo "Cleaning macOS daemon build artifacts..."
	@rm -rf "$(OUTPUT_ROOT)"

analyze: validate-analyzer
	@echo "--- Running Clang Static Analyzer (i386, Mac OS X 10.5 SDK) ---"
	@echo "  > analyzing daemon sources; diagnostics follow"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics $(SOURCE_PATHS)

validate-build:
	@if [ ! -x "$(PPC_CC)" ]; then \
		echo " [!] ERROR: Legacy PowerPC compiler missing: $(PPC_CC)"; \
		exit 1; \
	fi
	@if [ ! -x "$(I386_CC)" ]; then \
		echo " [!] ERROR: Legacy i386 compiler missing: $(I386_CC)"; \
		exit 1; \
	fi
	@if [ ! -x "$(LIPO)" ]; then \
		echo " [!] ERROR: Legacy lipo missing: $(LIPO)"; \
		exit 1; \
	fi
	@if [ ! -d "$(SDK)" ]; then \
		echo " [!] ERROR: Mac OS X 10.5 SDK missing: $(SDK)"; \
		exit 1; \
	fi

validate-analyzer:
	@if [ ! -d "$(SDK)" ]; then \
		echo " [!] ERROR: Mac OS X 10.5 SDK missing: $(SDK)"; \
		exit 1; \
	fi
	@if [ ! -x "$(ANALYZER)" ]; then \
		echo " [!] ERROR: Clang static analyzer missing: $(ANALYZER)"; \
		exit 1; \
	fi

$(OUTPUT): $(INTERMEDIATES_DIR)/ppc.bin $(INTERMEDIATES_DIR)/i386.bin
	@echo " [3/3] Merging universal binary (ppc, i386)..."
	@mkdir -p "$(dir $@)"
	@$(LIPO) -create $^ -output $@

$(INTERMEDIATES_DIR)/ppc.bin: $(PPC_OBJECTS)
	@echo "  > linking ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(LINK_FLAGS) -o $@

$(INTERMEDIATES_DIR)/i386.bin: $(I386_OBJECTS)
	@echo "  > linking i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(LINK_FLAGS) -o $@

$(INTERMEDIATES_DIR)/ppc/%.o: $(MAKEFILE_DIR)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(INTERMEDIATES_DIR)/i386/%.o: $(MAKEFILE_DIR)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

.PHONY: release debug clean analyze validate-build validate-analyzer
