# Jailbroken, rootful iOS 5+; app registration supplies the daemon's TCC identity.
IOS_ROOT := $(SOURCE_ROOT)/iOS-daemon
IOS_OUT := $(BUILD_ROOT)/iOS
IOS_SDK ?= /osxcross/modern/SDK/iPhoneOS8.4.sdk
IOS_BIN ?= /osxcross/modern/bin
IOS_CORE ?= /altivec/libs/core/build-phone
IOS_CC ?= /usr/bin/clang
IOS_FLAGS = $(IOS_TEST_FLAGS) -isysroot $(IOS_SDK) -B$(IOS_BIN) -std=c99 -O2 -g -Wall -Wextra -fblocks \
  -Wno-semicolon-before-method-body -I$(SHARED_SOURCE_ROOT) -I$(DAEMON_SOURCE_ROOT) -I$(IOS_ROOT) \
  -I$(IOS_CORE)/include -I$(IOS_SDK)/usr/include/libxml2 $(ICAL_FLAGS) $(LIBVC_FLAGS)
IOS_COMMON := $(SYNC_COMMON_SOURCES) RCLogger.m RCStatus.m RCMailProxy.c
IOS_PLATFORM := RCIOSNativeBackend.m RCIOSNativeStore.m RCIOSAccess.m RCIOSCredentials.c main.m
IOS_C := $(filter-out $(SHARED_SOURCE_ROOT)/RCICloudCredentials.c,$(SHARED_SOURCE_PATHS))
IOS_SOURCES := $(addprefix $(DAEMON_SOURCE_ROOT)/,$(IOS_COMMON)) $(addprefix $(IOS_ROOT)/,$(IOS_PLATFORM)) $(IOS_C) $(IOS_TEST_SOURCE)
IOS_HEADERS := $(wildcard $(DAEMON_SOURCE_ROOT)/*.h $(IOS_ROOT)/*.h $(SHARED_SOURCE_ROOT)/*.h)
IOS_LINK = -framework Foundation -framework UIKit -framework CoreGraphics -framework AddressBook -framework EventKit \
  -framework CoreFoundation -framework Security -framework SystemConfiguration -lxml2

define RC_IOS_ARCH
$(ICAL_ROOT)/libical-ios-$(1)/lib/libical.a: $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@bash "$$(ICAL_SCRIPT)" ios-$(1) "$$(ICAL_ROOT)" /osxcross/modern
$(LIBVC_ROOT)/libvc-ios-$(1)/libvc.a: $(LIBVC_PREPARE) $(LIBVC_SCRIPT) $(LIBVC_SUPPORT)
	@bash "$$(LIBVC_SCRIPT)" ios-$(1) "$$(LIBVC_ROOT)" /osxcross/modern
$(IOS_OUT)/$(1)/daemon.o: $(DAEMON_SOURCE_ROOT)/main.m $(IOS_HEADERS) $(ICAL_ROOT)/libical-ios-$(1)/lib/libical.a
	@mkdir -p "$$(dir $$@)"
	$$(IOS_CC) -target $(1)-apple-ios$(2) $$(IOS_FLAGS) -I$(ICAL_ROOT)/libical-ios-$(1)/src -Dmain=RCCloudDaemonMain -c "$$<" -o "$$@"
$(IOS_OUT)/$(1)/rCloud: $(IOS_SOURCES) $(IOS_HEADERS) $(IOS_OUT)/$(1)/daemon.o $(ICAL_ROOT)/libical-ios-$(1)/lib/libical.a $(LIBVC_ROOT)/libvc-ios-$(1)/libvc.a
	$$(IOS_CC) -target $(1)-apple-ios$(2) $$(IOS_FLAGS) -I$(ICAL_ROOT)/libical-ios-$(1)/src $$(IOS_SOURCES) $$(filter %.o %.a,$$^) $$(IOS_CORE)/lib/libAltivecCore.a $$(IOS_LINK) -o "$$@"
endef
$(eval $(call RC_IOS_ARCH,armv7,5.0))
$(eval $(call RC_IOS_ARCH,arm64,7.0))
$(IOS_OUT)/rCloud.app/rCloud: $(IOS_OUT)/armv7/rCloud $(IOS_OUT)/arm64/rCloud $(IOS_ROOT)/Entitlements.plist
	@mkdir -p "$(dir $@)"
	$(IOS_BIN)/lipo -create $(filter %/rCloud,$^) -output "$@"
	ldid -S$(IOS_ROOT)/Entitlements.plist "$@"
ios-release: $(IOS_OUT)/rCloud.app/rCloud
	cp $(IOS_ROOT)/Info.plist $(IOS_OUT)/rCloud.app/Info.plist
	cp $(IOS_CORE)/lib/cacert.pem $(IOS_OUT)/rCloud.app/cacert.pem
	cp -R $(ICAL_SOURCE)/zoneinfo $(IOS_OUT)/rCloud.app/
.PHONY: ios-release

ios-native-tests:
	$(MAKE) --no-print-directory ios-release IOS_OUT="$(BUILD_ROOT)/iOS-tests" IOS_TEST_FLAGS=-DRCIOS_NATIVE_TESTS=1 IOS_TEST_SOURCE="$(SOURCE_ROOT)/tests/iOS/native-stores/NativeStoreTests.m"
.PHONY: ios-native-tests
ios-package: ios-release
	bash "$(SOURCE_ROOT)/make/scripts/package-ios.sh" "$(IOS_OUT)" "$(SOURCE_ROOT)"
.PHONY: ios-package
test-ios-native-stores: ios-native-tests
	TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" python3 "$(SOURCE_ROOT)/tests/iOS/native-stores/run-remote.py"
analyze-ios: $(ICAL_ROOT)/libical-ios-armv7/lib/libical.a $(LIBVC_ROOT)/libvc-ios-armv7/libvc.a
	$(IOS_CC) -target armv7-apple-ios5.0 $(IOS_FLAGS) -I$(ICAL_ROOT)/libical-ios-armv7/src --analyze -Xanalyzer -analyzer-output=text $(IOS_SOURCES) $(DAEMON_SOURCE_ROOT)/main.m
.PHONY: test-ios-native-stores analyze-ios
