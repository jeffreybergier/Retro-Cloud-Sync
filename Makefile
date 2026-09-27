# Retro Cloud Sync

.DEFAULT_GOAL := release

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE_ROOT := $(PROJECT_ROOT)/source
BUILD_ROOT ?= $(PROJECT_ROOT)/build

# Primary commands. Run these from the repository root.
# The Mac suites cross-compile here and run on TEST_HOST (default: x4-vm).
release:
	@echo "--- Building Retro Cloud Sync Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		build-all

debug:
	@echo "--- Building Retro Cloud Sync Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		build-all

clean:
	@case "$(BUILD_ROOT)" in \
		""|"/"|"$(PROJECT_ROOT)") \
			echo " [!] ERROR: Refusing unsafe BUILD_ROOT: $(BUILD_ROOT)"; \
			exit 1 ;; \
	esac
	@echo "Cleaning build artifacts at $(BUILD_ROOT)..."
	@rm -rf "$(BUILD_ROOT)"

test-business-linux: test-host

# Run native integration suites sequentially, including under make -j.
test-business-mac:
	@$(MAKE) --no-print-directory test-mac-logging
	@$(MAKE) --no-print-directory test-mac-shutdown
	@$(MAKE) --no-print-directory test-mac-contacts-syncservices
	@$(MAKE) --no-print-directory test-mac-calendars-syncservices
	@$(MAKE) --no-print-directory test-mac-conflicts
	@$(MAKE) --no-print-directory test-mac-two-way TWO_WAY_TEST_MODE=full
	@$(MAKE) --no-print-directory test-mac-two-way TWO_WAY_TEST_MODE=fields

test-ui-mac:
	@$(MAKE) --no-print-directory test-mac-app

.PHONY: release debug clean test-business-linux test-business-mac test-ui-mac

# Advanced and internal build rules follow. The six commands above are the
# supported entry points; the included files also expose narrower diagnostics.
include $(SOURCE_ROOT)/make/legacy-mac.mk
include $(SOURCE_ROOT)/make/libical.mk
include $(SOURCE_ROOT)/make/libvc.mk
include $(SOURCE_ROOT)/make/shared.mk
include $(SOURCE_ROOT)/make/daemon.mk
include $(SOURCE_ROOT)/make/carddav-probe.mk
include $(SOURCE_ROOT)/make/caldav-probe.mk
include $(SOURCE_ROOT)/make/app.mk
include $(SOURCE_ROOT)/make/mac-app-tests.mk
include $(SOURCE_ROOT)/make/mac-network-tests.mk
include $(SOURCE_ROOT)/make/host-contacts-tests.mk
include $(SOURCE_ROOT)/make/libicalvcal-comparison.mk
include $(SOURCE_ROOT)/make/host-calendars-tests.mk
include $(SOURCE_ROOT)/make/host-write-tests.mk
include $(SOURCE_ROOT)/make/host-sync-tests.mk
include $(SOURCE_ROOT)/make/host-policy-tests.mk
include $(SOURCE_ROOT)/make/mac-calendars-syncservices-tests.mk
include $(SOURCE_ROOT)/make/mac-contacts-syncservices-tests.mk
include $(SOURCE_ROOT)/make/mac-conflict-tests.mk
include $(SOURCE_ROOT)/make/mac-logging-tests.mk
include $(SOURCE_ROOT)/make/tests.mk

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

build-mac-carddav-probe:
	@echo "--- Building read-only CardDAV probe (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		carddav-probe-config

build-mac-carddav-probe-debug:
	@echo "--- Building read-only CardDAV probe (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		carddav-probe-config

shared-release:
	@echo "--- Building Shared Library Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		shared-config

shared-debug:
	@echo "--- Building Shared Library Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		shared-config

build-mac-app-tests:
	@echo "--- Building macOS GUI Test Harness Release (-O3) ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		test-config

build-mac-app-tests-debug:
	@echo "--- Building macOS GUI Test Harness Debug (-O0) ---"
	@$(MAKE) --no-print-directory CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		test-config

analyze-mac-app-tests: validate-analyzer $(ICAL_I386_LIBRARY)
	@echo "--- Analyzing macOS GUI Test Harness ---"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		$(TEST_SOURCE_PATHS)

test-mac-app:
	@$(MAKE) --no-print-directory release build-mac-app-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" \
		PROJECT_ROOT="$(PROJECT_ROOT)" \
		/bin/bash "$(SOURCE_ROOT)/tests/macOS/app/run-remote.sh"

test-host-contacts:
	@echo "--- Testing portable vCard and SQLite layers ---"
	@$(MAKE) --no-print-directory BUILD_ROOT="$(BUILD_ROOT)" shared-test-run

build-mac-contacts-syncservices-tests:
	@echo "--- Building offline Sync Services test tools ---"
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		syncservices-test-config

analyze-mac-contacts-syncservices-tests: validate-analyzer $(ICAL_I386_LIBRARY)
	@echo "--- Analyzing offline Sync Services verifier ---"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		$(SYNC_TEST_VERIFIER_SOURCE)

test-mac-contacts-syncservices:
	@$(MAKE) --no-print-directory release build-mac-contacts-syncservices-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" \
		/bin/bash "$(SOURCE_ROOT)/tests/macOS/contacts-syncservices/run-remote.sh"

build-all: validate-build app-config

analyze: validate-analyzer $(ICAL_I386_LIBRARY) $(LIBVC_I386_LIBRARY)
	@echo "--- Running Clang Static Analyzer (i386, Mac OS X 10.5 SDK) ---"
	@echo "  > analyzing app, daemon, and shared sources; diagnostics follow"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		$(ICAL_FLAGS) $(LIBVC_FLAGS) -I$(ICAL_ROOT)/libical-i386/src \
		-I"$(SHARED_SOURCE_ROOT)" -I"$(ALTIVECCORE_ROOT)/include" \
		-I"$(SDK)/usr/include/libxml2" \
		-I"$(ALTIVECCOCOA_ROOT)/include" \
		$(ALL_SOURCE_PATHS)

.PHONY: app-release app-debug daemon-release daemon-debug \
	build-mac-carddav-probe build-mac-carddav-probe-debug \
	shared-release shared-debug build-mac-app-tests build-mac-app-tests-debug analyze-mac-app-tests test-mac-app \
	test-host-contacts \
	build-mac-contacts-syncservices-tests analyze-mac-contacts-syncservices-tests test-mac-contacts-syncservices \
	build-all analyze

include $(SOURCE_ROOT)/make/mac-two-way-tests.mk
