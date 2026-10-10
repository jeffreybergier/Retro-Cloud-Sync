# Offline harness orchestration; production builds live in platform Makefiles.
PROJECT_ROOT := $(CURDIR)
SOURCE_ROOT := $(PROJECT_ROOT)/source
BUILD_ROOT ?= $(PROJECT_ROOT)/build
override BUILD_ROOT := $(abspath $(BUILD_ROOT))
ALTIVEC_ROOT ?= /altivec
CONFIG ?= release
ALTIVEC_PLATFORM := macOS
ARCHS := ppc i386 x86_64 arm64 host
DEPENDENCIES := libical libvc
include $(ALTIVEC_ROOT)/altivec_toolchains.mk
include $(ALTIVEC_ROOT)/make/dependencies.mk
include $(SOURCE_ROOT)/make/legacy-mac.mk
SHARED_SOURCE_ROOT := $(SOURCE_ROOT)/shared
SHARED_SOURCE_PATHS := $(wildcard $(SHARED_SOURCE_ROOT)/*.c)
DAEMON_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-daemon
DAEMON_SOURCE_PATHS := $(wildcard $(DAEMON_SOURCE_ROOT)/*.m) $(DAEMON_SOURCE_ROOT)/RCMailProxy.c
APP_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-app
APP_SOURCE_PATHS := $(wildcard $(APP_SOURCE_ROOT)/*.m)
ALTIVECCORE_ROOT := $(ALTIVEC_ROOT)/libs/core/build-mac
ALTIVECCORE_CA_CERTS := $(ALTIVECCORE_ROOT)/lib/cacert.pem
ALTIVECCOCOA_ROOT := $(ALTIVEC_ROOT)/libs/cocoa/build-mac
DAEMON_PPC_ALTIVECCORE := $(ALTIVECCORE_ROOT)/lib/libAltivecCore.a
DAEMON_I386_ALTIVECCORE := $(DAEMON_PPC_ALTIVECCORE)
DAEMON_INFO_PLIST := $(DAEMON_SOURCE_ROOT)/Info.plist
DAEMON_LINK_FLAGS := -framework Foundation -framework CoreFoundation -framework SystemConfiguration -framework Security -framework SyncServices -lxml2 -lobjc -lgcc_s.10.4
DAEMON_COMPILE_FLAGS = -I$(SDK)/usr/include/libxml2 $(ICAL_FLAGS) -I$(ALTIVECCORE_ROOT)/include
DAEMON_OUTPUT := $(BUILD_ROOT)/macOS/$(CONFIG)/Intermediates/rcloudd/signed/rcloudd
PPC_SHARED_LIBRARY := $(BUILD_ROOT)/macOS/$(CONFIG)/Intermediates/RetroCloudShared/ppc/libRetroCloudShared.a
I386_SHARED_LIBRARY := $(BUILD_ROOT)/macOS/$(CONFIG)/Intermediates/RetroCloudShared/i386/libRetroCloudShared.a
ICAL_ROOT = $(DEPENDENCY_ROOT)
ICAL_SOURCE = $(LIBICAL_PREPARED)
ICAL_SCRIPT = $(ALTIVEC_ROOT)/make/dependencies/build-libical.sh
ICAL_FLAGS = $(LIBICAL_FLAGS)
ICAL_HOST_FLAGS = $(ICAL_FLAGS) -I$(ICAL_ROOT)/libical-host/src
ICAL_HOST_LIBRARY = $(call libical,host)
ICAL_PPC_LIBRARY = $(call libical,ppc)
ICAL_I386_LIBRARY = $(call libical,i386)
LIBVC_HOST_LIBRARY = $(call libvc,host)
LIBVC_PPC_LIBRARY = $(call libvc,ppc)
LIBVC_I386_LIBRARY = $(call libvc,i386)
SYNC_COMMON_SOURCES = RCContactGraph.m RCCalendarGraph.m RCTwoWaySync.m RCNativeExchange.m RCNativeSystemStore.m RCPlatformDate.m RCTwoWayFields.m RCContactTwoWay.m RCContactPhotoCache.m RCCalendarTwoWay.m RCCalendarOperations.m
MAC_SYNC_SOURCES = RCMacSyncBackend.m RCSyncServicesBackend.m RCSyncServicesBridge.m RCCalendarSyncServicesBridge.m RCSyncConflictSession.m RCContactConflictResolver.m RCMacNativeBackend.m RCMacNativeStore.m

release debug:
	+$(MAKE) -C $(PROJECT_ROOT) $@ BUILD_ROOT="$(BUILD_ROOT)"
app-config daemon-config shared-config:
	+$(MAKE) -C $(PROJECT_ROOT)/source/macOS-app $(CONFIG) BUILD_ROOT="$(BUILD_ROOT)"
$(PPC_SHARED_LIBRARY) $(I386_SHARED_LIBRARY) $(BUILD_ROOT)/macOS/$(CONFIG)/Intermediates/RetroCloudShared/x86_64/libRetroCloudShared.a $(DAEMON_OUTPUT): | shared-config
	@test -f "$@"
test-host-contacts: shared-test-run
test-business-linux: test-host
test-business-mac:
	+$(MAKE) -f source/tests/Makefile test-mac-logging
	+$(MAKE) -f source/tests/Makefile test-mac-shutdown
	+$(MAKE) -f source/tests/Makefile test-mac-contacts-syncservices
	+$(MAKE) -f source/tests/Makefile test-mac-calendars-syncservices
	+$(MAKE) -f source/tests/Makefile test-mac-conflicts
	+$(MAKE) -f source/tests/Makefile test-mac-two-way TWO_WAY_TEST_MODE=full
	+$(MAKE) -f source/tests/Makefile test-mac-two-way TWO_WAY_TEST_MODE=fields
build-mac-app-tests: test-config
build-mac-contacts-syncservices-tests: syncservices-test-config
test-mac-app: release build-mac-app-tests
	TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" bash $(SOURCE_ROOT)/tests/macOS/app/run-remote.sh
test-mac-contacts-syncservices: release build-mac-contacts-syncservices-tests
	TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" bash $(SOURCE_ROOT)/tests/macOS/contacts-syncservices/run-remote.sh
include $(SOURCE_ROOT)/make/carddav-probe.mk
include $(SOURCE_ROOT)/make/caldav-probe.mk
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
include $(SOURCE_ROOT)/make/mac-two-way-tests.mk

MODERN_TOOLCHAIN = /osxcross/modern
MODERN_SDK = $(MODERN_TOOLCHAIN)/SDK/MacOSX11.3.sdk
MODERN_AR = $(AR_MODERN)
MODERN_RANLIB = $(RANLIB_MODERN)
MODERN_x86_64_CC = $(COMPILER_X64)
MODERN_x86_64_FLAGS = -g -std=c99 -Wall -Wextra -fblocks -target x86_64-apple-macos10.9 -isysroot $(MODERN_SDK) -I$(SHARED_SOURCE_ROOT)
MODERN_DAEMON_LINK = $(filter-out -lgcc_s.10.4,$(DAEMON_LINK_FLAGS)) -framework AddressBook -weak_framework EventKit -framework CoreServices
SHARED_BUILD_ROOT = $(BUILD_ROOT)/macOS/$(CONFIG)/Intermediates/RetroCloudShared
DAEMON_INTERMEDIATES = $(BUILD_ROOT)/macOS/$(CONFIG)/Intermediates/rcloudd
ICAL_x86_64_LIBRARY = $(call libical,x86_64)
LIBVC_x86_64_LIBRARY = $(call libvc,x86_64)
MODERN_SIGN_SCRIPT = $(ALTIVEC_ROOT)/make/sign-mac-slice.sh
MODERN_SIGN_DEPS = $(MODERN_SIGN_SCRIPT)
include $(SOURCE_ROOT)/make/modern-mac.mk

include $(SOURCE_ROOT)/make/ios.mk

test-ui-mac:
	@$(MAKE) --no-print-directory -f source/tests/Makefile test-mac-app

build-mac-carddav-probe:
	@echo "--- Building read-only CardDAV probe (-O3) ---"
	@$(MAKE) --no-print-directory -f source/tests/Makefile CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" \
		carddav-probe-config

build-mac-carddav-probe-debug:
	@echo "--- Building read-only CardDAV probe (-O0) ---"
	@$(MAKE) --no-print-directory -f source/tests/Makefile CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		carddav-probe-config

build-mac-app-tests-debug:
	@echo "--- Building macOS GUI Test Harness Debug (-O0) ---"
	@$(MAKE) --no-print-directory -f source/tests/Makefile CONFIG=debug BUILD_ROOT="$(BUILD_ROOT)" \
		test-config

analyze-mac-app-tests: validate-analyzer $(ICAL_I386_LIBRARY)
	@echo "--- Analyzing macOS GUI Test Harness ---"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		$(TEST_SOURCE_PATHS)

analyze-mac-contacts-syncservices-tests: validate-analyzer $(ICAL_I386_LIBRARY)
	@echo "--- Analyzing offline Sync Services verifier ---"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(ANALYZER) \
		--analyze -Xanalyzer -analyzer-output=text \
		-target i386-apple-darwin9 -arch i386 -isysroot "$(SDK)" \
		-std=c99 -Wall -Wextra -fno-color-diagnostics \
		$(SYNC_TEST_VERIFIER_SOURCE)

.PHONY: test-ui-mac build-mac-carddav-probe build-mac-carddav-probe-debug build-mac-app-tests-debug analyze-mac-app-tests analyze-mac-contacts-syncservices-tests
