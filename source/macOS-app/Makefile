ALTIVEC_ROOT ?= /altivec
include $(ALTIVEC_ROOT)/make/entry.mk
ifeq ($(_altivec_relocated),)
PROJECT_ROOT := $(abspath $(dir $(firstword $(MAKEFILE_LIST)))/../..)
DEPENDENCIES = libical libvc
SOURCE_DIRS = ../shared ../macOS-daemon
BUILD_FLAGS = -I../shared -I../macOS-daemon
PRODUCTS = rCloud rcloudd RetroCloudShared
PACKAGE_PRODUCTS = rCloud
RetroCloudShared_TYPE = static
RetroCloudShared_SOURCES = $(wildcard ../shared/*.c)
RetroCloudShared_CORE = static
RetroCloudShared_DEPENDENCIES = libical libvc
rCloud_TYPE = app
rCloud_SOURCES = $(wildcard *.m) ../shared/RCICloudCredentials.m
rCloud_DEPS = RetroCloudShared
rCloud_COCOA = static
rCloud_DEPENDENCIES = libvc
rCloud_PLIST = Resources/Info.plist
rCloud_RESOURCES = $(filter-out Resources/Info.plist,$(wildcard Resources/*)) $(ALTIVECCORE_DIR)/lib/cacert.pem
rCloud_RESOURCE_MAP = $(LIBICAL_PREPARED)/zoneinfo=zoneinfo $(LIBICAL_SOURCE)/LICENSE.MPL2.txt=LICENSE-libical.txt $(LIBVC_SOURCE)/COPYING.LIB=LICENSE-libvc.txt
rCloud_INPUTS = $(DEPENDENCY_ROOT)/libical-source.stamp
rCloud_RESOURCE_EXCLUDES = zoneinfo/CMakeLists.txt zoneinfo/zones.h
rCloud_EMBED = rcloudd
rCloud_LDFLAGS = -framework AppKit -framework CoreServices -framework ApplicationServices -framework Security -lobjc
rcloudd_TYPE = daemon
rcloudd_SOURCES = ../shared/RCICloudCredentials.m $(wildcard ../macOS-daemon/*.m) ../macOS-daemon/RCMailProxy.c
rcloudd_DEPS = RetroCloudShared
rcloudd_CORE = static
rcloudd_COCOA = static
rcloudd_DEPENDENCIES = libical libvc
rcloudd_INPUTS = ../macOS-daemon/Info.plist
rcloudd_LDFLAGS = -framework Foundation -framework CoreFoundation -framework SystemConfiguration -framework Security -framework SyncServices -lxml2 -lobjc -Wl,-sectcreate,__TEXT,__info_plist,../macOS-daemon/Info.plist
rcloudd_LDFLAGS_x86_64 = -framework AddressBook -weak_framework EventKit -framework CoreServices
rcloudd_LDFLAGS_arm64 = $(rcloudd_LDFLAGS_x86_64)
rcloudd_FLAGS_x86_64 = -fblocks
rcloudd_FLAGS_arm64 = -fblocks
rCloud_FLAGS_x86_64 = -fblocks
rCloud_FLAGS_arm64 = -fblocks
# libxml headers follow each declared SDK.
$(foreach a,ppc i386 x86_64 arm64,$(eval rcloudd_FLAGS_$(a) += -I$$(SDK_$(a))/usr/include/libxml2)$(eval RetroCloudShared_FLAGS_$(a) += -I$$(SDK_$(a))/usr/include/libxml2))
rCloud_MAC_SIGN = 1
rcloudd_MAC_SIGN = 1
rcloudd_SIGN_PLIST = ../macOS-daemon/Info.plist
rcloudd_IDENTIFIER = com.altivecintelligence.rcloudd
include $(ALTIVEC_ROOT)/altivec_common_mac.mk

# Check even when cached signed outputs would otherwise be reused.
.PHONY: check-mac-signing
check-mac-signing:
	@bash "$(ALTIVEC_ROOT)/make/check-mac-signing.sh" \
	  $(call q,$(rCloud_SIGN_PEM)) \
	  $(if $(and $(filter release,$(CONFIG)),$(filter x86_64 arm64,$(ARCHS))),required,optional)
	@bash "$(ALTIVEC_ROOT)/make/check-mac-signing.sh" \
	  $(call q,$(rcloudd_SIGN_PEM)) \
	  $(if $(and $(filter release,$(CONFIG)),$(filter x86_64 arm64,$(ARCHS))),required,optional)
validate: check-mac-signing
$(call signed,rCloud) $(call signed,rcloudd): | check-mac-signing
endif
