# Optional modern native-store harness. Production signing is owned by Altivec.
NATIVE_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/native-stores
NATIVE_TEST_INFO := $(SOURCE_ROOT)/tests/macOS/native-stores/Info.plist
NATIVE_TEST_SOURCES := $(SOURCE_ROOT)/tests/macOS/native-stores/NativeStoreTests.m $(filter-out $(DAEMON_SOURCE_ROOT)/main.m $(DAEMON_SOURCE_ROOT)/RCMailProxy.c,$(DAEMON_SOURCE_PATHS))
$(NATIVE_TEST_ROOT)/NativeStoreTests: $(MODERN_SIGN_DEPS) $(NATIVE_TEST_INFO) $(NATIVE_TEST_SOURCES) $(wildcard $(SOURCE_ROOT)/tests/macOS/native-stores/*.h) $(wildcard $(DAEMON_SOURCE_ROOT)/*.h) $(SHARED_BUILD_ROOT)/x86_64/libRetroCloudShared.a $(ALTIVECCORE_ROOT)/lib/libAltivecCore.a $(ICAL_x86_64_LIBRARY) $(LIBVC_x86_64_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.9 $(MODERN_x86_64_CC) $(filter-out -O%,$(MODERN_x86_64_FLAGS)) -O0 $(DAEMON_COMPILE_FLAGS) -I$(ICAL_ROOT)/libical-x86_64/src -Wno-semicolon-before-method-body $(NATIVE_TEST_SOURCES) $(filter %.a,$^) --ld-path=/usr/bin/ld64.lld $(subst $(DAEMON_INFO_PLIST),$(NATIVE_TEST_INFO),$(MODERN_DAEMON_LINK)) -framework AppKit -o "$@"
	@bash "$(MODERN_SIGN_SCRIPT)" "$@" com.altivecintelligence.rcloud.native-tests "$(NATIVE_TEST_INFO)" "$(RCLOUD_SIGNING_PEM)" x86_64
$(NATIVE_TEST_ROOT)/bundle.stamp: $(NATIVE_TEST_ROOT)/NativeStoreTests $(NATIVE_TEST_INFO) $(ALTIVEC_ROOT)/make/sign-mac-bundle.sh
	@mkdir -p "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app/Contents/MacOS"
	@cp "$(NATIVE_TEST_ROOT)/NativeStoreTests" "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app/Contents/MacOS/NativeStoreTests"
	@cp "$(NATIVE_TEST_INFO)" "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app/Contents/Info.plist"
	@bash "$(ALTIVEC_ROOT)/make/sign-mac-bundle.sh" "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app" "$(RCLOUD_SIGNING_PEM)" "$(LIPO)"
	@touch "$@"
build-mac-native-tests: $(NATIVE_TEST_ROOT)/bundle.stamp
.PHONY: build-mac-native-tests

test-mac-native-stores: build-mac-native-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" python3 "$(SOURCE_ROOT)/tests/macOS/native-stores/run-remote.py"
.PHONY: test-mac-native-stores

CALENDAR_RECOVERY_ROOT := $(BUILD_ROOT)/tools/macOS/calendar-recovery
CALENDAR_RECOVERY_INFO := $(SOURCE_ROOT)/tools/macOS/calendar-recovery/Info.plist
CALENDAR_RECOVERY_MAIN := $(SOURCE_ROOT)/tools/macOS/calendar-recovery/main.m
$(CALENDAR_RECOVERY_ROOT)/CalendarRecovery: $(MODERN_SIGN_DEPS) $(CALENDAR_RECOVERY_INFO) $(CALENDAR_RECOVERY_MAIN) $(NATIVE_TEST_SOURCES) $(wildcard $(SOURCE_ROOT)/tests/macOS/native-stores/*.h) $(wildcard $(DAEMON_SOURCE_ROOT)/*.h) $(SHARED_BUILD_ROOT)/x86_64/libRetroCloudShared.a $(ALTIVECCORE_ROOT)/lib/libAltivecCore.a $(ICAL_x86_64_LIBRARY) $(LIBVC_x86_64_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.9 $(MODERN_x86_64_CC) $(filter-out -O%,$(MODERN_x86_64_FLAGS)) -O0 $(DAEMON_COMPILE_FLAGS) -I$(ICAL_ROOT)/libical-x86_64/src $(CALENDAR_RECOVERY_MAIN) $(filter-out $(SOURCE_ROOT)/tests/macOS/native-stores/NativeStoreTests.m,$(NATIVE_TEST_SOURCES)) $(filter %.a,$^) --ld-path=/usr/bin/ld64.lld $(MODERN_DAEMON_LINK) -framework AppKit -o "$@"
	@bash "$(MODERN_SIGN_SCRIPT)" "$@" com.altivecintelligence.rcloud.calendar-recovery "$(CALENDAR_RECOVERY_INFO)" "$(RCLOUD_SIGNING_PEM)" x86_64
build-calendar-recovery: $(CALENDAR_RECOVERY_ROOT)/CalendarRecovery
	@mkdir -p "$(CALENDAR_RECOVERY_ROOT)/rCloud Calendar Recovery.app/Contents/MacOS"
	@cp "$<" "$(CALENDAR_RECOVERY_ROOT)/rCloud Calendar Recovery.app/Contents/MacOS/CalendarRecovery"
	@cp "$(CALENDAR_RECOVERY_INFO)" "$(CALENDAR_RECOVERY_ROOT)/rCloud Calendar Recovery.app/Contents/Info.plist"
	@bash "$(ALTIVEC_ROOT)/make/sign-mac-bundle.sh" "$(CALENDAR_RECOVERY_ROOT)/rCloud Calendar Recovery.app" "$(RCLOUD_SIGNING_PEM)" "$(LIPO)"
.PHONY: build-calendar-recovery
