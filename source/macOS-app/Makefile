# Retro Cloud Sync - legacy Mac application

APP_NAME := RetroCloudSync

MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_DIR := $(abspath $(MAKEFILE_DIR)/../..)
OUTPUT_ROOT := $(PROJECT_DIR)/build/macOS-app

LEGACY_TOOLCHAIN := /osxcross/legacy/target
LEGACY_BIN := $(LEGACY_TOOLCHAIN)/bin
SDK := $(LEGACY_TOOLCHAIN)/SDK/MacOSX10.5.sdk

PPC_CC := $(LEGACY_BIN)/oppc32-gcc
I386_CC := $(LEGACY_BIN)/o32-gcc
LIPO := $(LEGACY_BIN)/i386-apple-darwin9-lipo
ANALYZER := /usr/bin/clang

SOURCES := main.m AppDelegate.m
SOURCE_PATHS := $(addprefix $(MAKEFILE_DIR)/,$(SOURCES))
RESOURCES_DIR := $(MAKEFILE_DIR)/Resources
INFO_PLIST := $(RESOURCES_DIR)/Info.plist

MACOSX_DEPLOYMENT_TARGET := 10.4
COMMON_FLAGS := -g -std=c99 -Wall -Wextra -fno-stack-protector \
	-fno-common -fno-zero-initialized-in-bss
LINK_FLAGS := -framework AppKit -lobjc -lgcc_s.10.4

CONFIG ?= release
ifeq ($(CONFIG),debug)
  OPT_FLAGS := -O0
else
  OPT_FLAGS := -O3
endif

BUILD_DIR := $(OUTPUT_ROOT)/$(CONFIG)
INTERMEDIATES_DIR := $(BUILD_DIR)/Intermediates
BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
ZIP_FILE := $(BUILD_DIR)/$(APP_NAME).zip
UNIVERSAL_BINARY := $(INTERMEDIATES_DIR)/$(APP_NAME)-universal
PPC_OBJECTS := $(addprefix $(INTERMEDIATES_DIR)/ppc/,$(SOURCES:.m=.o))
I386_OBJECTS := $(addprefix $(INTERMEDIATES_DIR)/i386/,$(SOURCES:.m=.o))

.DEFAULT_GOAL := release

release: validate-build
	@echo "--- Building macOS App Release (-O3) ---"
	@$(MAKE) --no-print-directory $(OUTPUT_ROOT)/release/$(APP_NAME).zip \
		CONFIG=release

debug: validate-build
	@echo "--- Building macOS App Debug (-O0) ---"
	@$(MAKE) --no-print-directory $(OUTPUT_ROOT)/debug/$(APP_NAME).zip \
		CONFIG=debug

clean:
	@echo "Cleaning macOS app build artifacts..."
	@rm -rf "$(OUTPUT_ROOT)"

analyze: validate-analyzer
	@echo "--- Running Clang Static Analyzer (i386, Mac OS X 10.5 SDK) ---"
	@echo "  > analyzing app sources; diagnostics follow"
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

$(ZIP_FILE): $(BUNDLE)
	@echo " [5/5] Zipping app..."
	@cd "$(BUILD_DIR)" && zip -rqy "$(APP_NAME).zip" "$(APP_NAME).app"

$(BUNDLE): $(UNIVERSAL_BINARY) $(INFO_PLIST)
	@echo " [4/5] Building app bundle..."
	@mkdir -p "$@/Contents/MacOS" "$@/Contents/Resources"
	@cp "$(UNIVERSAL_BINARY)" "$@/Contents/MacOS/$(APP_NAME)"
	@cp "$(INFO_PLIST)" "$@/Contents/Info.plist"
	@printf 'APPL????' > "$@/Contents/PkgInfo"

$(UNIVERSAL_BINARY): $(INTERMEDIATES_DIR)/ppc.bin \
		$(INTERMEDIATES_DIR)/i386.bin
	@echo " [3/5] Merging universal binary (ppc, i386)..."
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
	@if [ "$(notdir $<)" = "$(firstword $(SOURCES))" ]; then \
		echo " [1/5] Compiling ppc (10.5 SDK, 10.4 minimum)..."; \
	fi
	@echo "  > ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(INTERMEDIATES_DIR)/i386/%.o: $(MAKEFILE_DIR)/%.m
	@mkdir -p "$(dir $@)"
	@if [ "$(notdir $<)" = "$(firstword $(SOURCES))" ]; then \
		echo " [2/5] Compiling i386 (10.5 SDK, 10.4 minimum)..."; \
	fi
	@echo "  > i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

.PHONY: release debug clean analyze validate-build validate-analyzer
