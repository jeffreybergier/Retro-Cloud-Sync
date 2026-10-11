ALTIVEC_ROOT ?= /altivec
include $(ALTIVEC_ROOT)/make/entry.mk
ifeq ($(_altivec_relocated),)
PROJECT_ROOT := $(abspath $(dir $(firstword $(MAKEFILE_LIST)))/../..)
DEPENDENCIES = libical libvc
SOURCE_DIRS = ../shared ../macOS-daemon
BUILD_FLAGS = -I../shared -I../macOS-daemon
PRODUCTS = rCloud
rCloud_TYPE = app
rCloud_SOURCES += $(RC_TEST_SOURCE)
rCloud_GROUPS = daemon_entry
GROUP_daemon_entry_SOURCES = ../macOS-daemon/main.m
GROUP_daemon_entry_FLAGS = -Dmain=RCCloudDaemonMain
rCloud_SOURCES += $(wildcard *.m) RCIOSCredentials.c $(filter-out ../shared/RCICloudCredentials.c,$(wildcard ../shared/*.c)) \
 $(addprefix ../macOS-daemon/,RCContactGraph.m RCCalendarGraph.m RCTwoWaySync.m RCNativeExchange.m RCNativeSystemStore.m RCPlatformDate.m RCTwoWayFields.m RCContactTwoWay.m RCContactPhotoCache.m RCCalendarTwoWay.m RCCalendarOperations.m RCLogger.m RCStatus.m RCMailProxy.c)
rCloud_CORE = static
rCloud_COCOA = static
rCloud_DEPENDENCIES = libical libvc
rCloud_FLAGS = -I. -fblocks
# LLVM 21 ARM FastISel crashes on these MRC methods at -O0.
rCloud_OBJCFLAGS_armv7 = $(if $(filter debug,$(CONFIG)),-mllvm -fast-isel=false)
rCloud_SANDBOX = unsandboxed
rCloud_FLAGS_armv7 = -I$(SDK_armv7)/usr/include/libxml2
rCloud_FLAGS_arm64 = -I$(SDK_arm64)/usr/include/libxml2
rCloud_LDFLAGS = -framework Foundation -framework UIKit -framework CoreGraphics -framework AddressBook -framework EventKit -framework CoreText -framework CoreFoundation -framework Security -framework SystemConfiguration -lxml2
rCloud_PLIST = $(OUTPUT_DIR)/generated/Info.plist
GENERATORS = plist
GEN_plist_OUTPUT = $(rCloud_PLIST)
GEN_plist_INPUTS = Info.plist ../macOS-app/Resources/Info.plist ../make/scripts/ios-version.py
GEN_plist_COMMAND = mkdir -p $(dir $(rCloud_PLIST)); cp Info.plist $(rCloud_PLIST); python3 ../make/scripts/ios-version.py .. $(rCloud_PLIST) --stamp $(if $(filter 1,$(RC_UI_TESTS)),--ui-tests)
ifeq ($(RC_UI_TESTS),1)
rCloud_LDFLAGS += -framework QuartzCore
endif
rCloud_RESOURCES = $(wildcard Resources/*.png) package/Config.example.plist
rCloud_RESOURCE_MAP = $(LIBICAL_PREPARED)/zoneinfo=zoneinfo
rCloud_ENTITLEMENTS = Entitlements.plist
rCloud_PACKAGES = deb-rootful
rCloud_PACKAGE_ID = com.altivecintelligence.rcloud
rCloud_PACKAGE_ARCH = iphoneos-arm
rCloud_VERSION := $(shell python3 ../make/scripts/ios-version.py .. Info.plist)
rCloud_LAUNCHD = package/com.altivecintelligence.rcloudd.plist
rCloud_PACKAGE_SCRIPTS = package/preinst package/postinst package/prerm package/postrm
rCloud_LIFECYCLE = package/lifecycle.sh
rCloud_PACKAGE_FILES = package/Config.example.plist=usr/share/rcloud/Config.example.plist
include $(ALTIVEC_ROOT)/altivec_common_phone.mk
endif
