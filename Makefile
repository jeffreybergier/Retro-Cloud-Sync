# Retro Cloud Sync

.DEFAULT_GOAL := release

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE_ROOT := $(PROJECT_ROOT)/source
BUILD_ROOT ?= $(PROJECT_ROOT)/build

include $(SOURCE_ROOT)/make/legacy-mac.mk
include $(SOURCE_ROOT)/make/shared.mk
include $(SOURCE_ROOT)/make/daemon.mk
include $(SOURCE_ROOT)/make/app.mk
include $(SOURCE_ROOT)/make/test.mk

release:
	@echo "--- Building Retro Cloud Sync Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		build-all

debug:
	@echo "--- Building Retro Cloud Sync Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		build-all

app-release:
	@echo "--- Building macOS App Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		app-config

app-debug:
	@echo "--- Building macOS App Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		app-config

daemon-release:
	@echo "--- Building macOS Daemon Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		daemon-config

daemon-debug:
	@echo "--- Building macOS Daemon Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		daemon-config

shared-release:
	@echo "--- Building Shared Library Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		shared-config

shared-debug:
	@echo "--- Building Shared Library Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		shared-config

test-build:
	@echo "--- Building macOS GUI Test Harness Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		test-config

test-debug:
	@echo "--- Building macOS GUI Test Harness Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		test-config

test-analyze: validate-analyzer
	@echo "--- Analyzing macOS GUI Test Harness ---"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		$(TEST_SOURCE_PATHS)

test-gui:
	@$(MAKE) --no-print-directory release test-build
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" \
		PROJECT_ROOT="$(PROJECT_ROOT)" \
		/bin/bash "$(SOURCE_ROOT)/macOS-test/run-remote.sh"

build-all: validate-build app-config

analyze: validate-analyzer
	@echo "--- Running Clang Static Analyzer (i386, Mac OS X 10.5 SDK) ---"
	@echo "  > analyzing app, daemon, and shared sources; diagnostics follow"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		-I"$(SHARED_SOURCE_ROOT)" -I"$(ALTIVECCORE_ROOT)/include" \
		$(ALL_SOURCE_PATHS)

clean:
	@case "$(BUILD_ROOT)" in \
		""|"/"|"$(PROJECT_ROOT)") \
			echo " [!] ERROR: Refusing unsafe BUILD_ROOT: $(BUILD_ROOT)"; \
			exit 1 ;; \
	esac
	@echo "Cleaning build artifacts at $(BUILD_ROOT)..."
	@rm -rf "$(BUILD_ROOT)"

.PHONY: release debug app-release app-debug daemon-release daemon-debug \
	shared-release shared-debug test-build test-debug test-analyze test-gui \
	build-all analyze clean
