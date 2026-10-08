# Same isolated compilers/SDKs and LLVM x86_64 linker as ENIL's Altivec build.
# Keep our existing per-object rules and test targets; extend product assembly.
RCLOUD_SIGNING_PEM ?= /rcloud-signing/development.pem
MODERN_SIGN_SCRIPT := $(SOURCE_ROOT)/make/scripts/sign-modern.sh
MODERN_SIGN_DEPS := $(MODERN_SIGN_SCRIPT) $(wildcard $(RCLOUD_SIGNING_PEM))
MODERN_TOOLCHAIN ?= /osxcross/modern
MODERN_SDK := $(MODERN_TOOLCHAIN)/SDK/MacOSX11.3.sdk
MODERN_LIPO := $(MODERN_TOOLCHAIN)/bin/lipo
MODERN_AR := $(MODERN_TOOLCHAIN)/bin/ar
MODERN_RANLIB := $(MODERN_TOOLCHAIN)/bin/ranlib
MODERN_x86_64_CC := $(firstword $(wildcard $(MODERN_TOOLCHAIN)/bin/x86_64-apple-darwin*-clang))
MODERN_arm64_CC := $(firstword $(wildcard $(MODERN_TOOLCHAIN)/bin/arm64-apple-darwin*-clang))
MODERN_x86_64_MIN := 10.9
MODERN_arm64_MIN := 11.0
MODERN_FLAGS = -g -std=c99 -Wall -Wextra -Wno-deprecated-declarations -Wno-semicolon-before-method-body -fblocks -I$(SOURCE_ROOT)/shared
MODERN_DAEMON_LINK = $(filter-out -lgcc_s.10.4,$(DAEMON_LINK_FLAGS)) -framework AddressBook -weak_framework EventKit -framework CoreServices

validate-build: validate-modern-build
validate-modern-build:
	@test -x "$(MODERN_x86_64_CC)" -a -x "$(MODERN_arm64_CC)" -a -d "$(MODERN_SDK)" || { echo 'Modern Altivec compilers or macOS 11.3 SDK missing'; exit 1; }
.PHONY: validate-modern-build

define RC_MODERN_ARCH
ICAL_$(1)_LIBRARY := $(ICAL_ROOT)/libical-$(1)/lib/libical.a
LIBVC_$(1)_LIBRARY := $(LIBVC_ROOT)/libvc-$(1)/libvc.a
MODERN_$(1)_FLAGS = $$(MODERN_FLAGS) -target $(1)-apple-macos$$(MODERN_$(1)_MIN) -isysroot "$$(MODERN_SDK)" $$(OPT_FLAGS)
$(ICAL_ROOT)/libical-$(1)/lib/libical.a: $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@bash "$$(ICAL_SCRIPT)" $(1) "$$(ICAL_ROOT)" "$$(MODERN_TOOLCHAIN)"
$(LIBVC_ROOT)/libvc-$(1)/libvc.a: $(LIBVC_PREPARE) $(LIBVC_SCRIPT) $(LIBVC_SUPPORT)
	@bash "$$(LIBVC_SCRIPT)" $(1) "$$(LIBVC_ROOT)" "$$(MODERN_TOOLCHAIN)"

$(SHARED_BUILD_ROOT)/$(1)/%.o: $(SHARED_SOURCE_ROOT)/%.c $(wildcard $(SHARED_SOURCE_ROOT)/*.h) $(ICAL_ROOT)/libical-$(1)/lib/libical.a $(LIBVC_ROOT)/libvc-$(1)/libvc.a
	@mkdir -p "$$(dir $$@)"
	@MACOSX_DEPLOYMENT_TARGET=$$(MODERN_$(1)_MIN) $$(MODERN_$(1)_CC) $$(MODERN_$(1)_FLAGS) $$(ICAL_FLAGS) $$(LIBVC_FLAGS) -I$$(ALTIVECCORE_ROOT)/include -I$$(MODERN_SDK)/usr/include/libxml2 -I$$(ICAL_ROOT)/libical-$(1)/src -c "$$<" -o "$$@"
$(SHARED_BUILD_ROOT)/$(1)/libRetroCloudShared.a: $(addprefix $(SHARED_BUILD_ROOT)/$(1)/,$(SHARED_SOURCE_NAMES:.c=.o))
	@$$(MODERN_AR) rcs "$$@" $$^
	@$$(MODERN_RANLIB) "$$@"
$(DAEMON_INTERMEDIATES)/$(1)/%.o: $(DAEMON_SOURCE_ROOT)/%.m $(wildcard $(DAEMON_SOURCE_ROOT)/*.h) $(wildcard $(SHARED_SOURCE_ROOT)/*.h) $(ICAL_ROOT)/libical-$(1)/lib/libical.a
	@mkdir -p "$$(dir $$@)"
	@MACOSX_DEPLOYMENT_TARGET=$$(MODERN_$(1)_MIN) $$(MODERN_$(1)_CC) $$(MODERN_$(1)_FLAGS) $$(DAEMON_COMPILE_FLAGS) -I$$(ICAL_ROOT)/libical-$(1)/src -c "$$<" -o "$$@"
$(DAEMON_INTERMEDIATES)/$(1)/%.o: $(DAEMON_SOURCE_ROOT)/%.c $(wildcard $(DAEMON_SOURCE_ROOT)/*.h) $(wildcard $(SHARED_SOURCE_ROOT)/*.h) $(ICAL_ROOT)/libical-$(1)/lib/libical.a
	@mkdir -p "$$(dir $$@)"
	@MACOSX_DEPLOYMENT_TARGET=$$(MODERN_$(1)_MIN) $$(MODERN_$(1)_CC) $$(MODERN_$(1)_FLAGS) $$(DAEMON_COMPILE_FLAGS) -I$$(ICAL_ROOT)/libical-$(1)/src -c "$$<" -o "$$@"
$(DAEMON_INTERMEDIATES)/$(1)/libAltivecCore.a: $(ALTIVECCORE_STATIC_LIBRARY)
	@mkdir -p "$$(dir $$@)"
	@$$(LIPO) "$$<" -thin $(1) -output "$$@"
$(DAEMON_INTERMEDIATES)/$(1).bin: $(addprefix $(DAEMON_INTERMEDIATES)/$(1)/,$(DAEMON_OBJECT_NAMES)) $(SHARED_BUILD_ROOT)/$(1)/libRetroCloudShared.a $(DAEMON_INTERMEDIATES)/$(1)/libAltivecCore.a $(ICAL_ROOT)/libical-$(1)/lib/libical.a $(LIBVC_ROOT)/libvc-$(1)/libvc.a $(DAEMON_INFO_PLIST) $(MODERN_SIGN_DEPS)
	@MACOSX_DEPLOYMENT_TARGET=$$(MODERN_$(1)_MIN) $$(MODERN_$(1)_CC) $$(MODERN_$(1)_FLAGS) --ld-path=/usr/bin/ld64.lld -Wl,-platform_version,macos,$$(MODERN_$(1)_MIN),11.3 $$(filter %.o %.a,$$^) $$(MODERN_DAEMON_LINK) -o "$$@"
	@bash "$$(MODERN_SIGN_SCRIPT)" "$$@" com.altivecintelligence.rcloudd "$$(DAEMON_INFO_PLIST)" "$$(RCLOUD_SIGNING_PEM)" $(1)

$(APP_INTERMEDIATES)/$(1)/%.o: $(APP_SOURCE_ROOT)/%.m $(wildcard $(APP_SOURCE_ROOT)/*.h) $(SOURCE_ROOT)/make/modern-mac.mk
	@mkdir -p "$$(dir $$@)"
	@MACOSX_DEPLOYMENT_TARGET=$$(MODERN_$(1)_MIN) $$(MODERN_$(1)_CC) $$(MODERN_$(1)_FLAGS) $$(APP_COMPILE_FLAGS) -c "$$<" -o "$$@"
$(APP_INTERMEDIATES)/$(1)/libAltivecCocoa.a: $(ALTIVECCOCOA_STATIC_LIBRARY)
	@mkdir -p "$$(dir $$@)"
	@$$(LIPO) "$$<" -thin $(1) -output "$$@"
$(APP_INTERMEDIATES)/$(1).bin: $(addprefix $(APP_INTERMEDIATES)/$(1)/,$(APP_SOURCES:.m=.o)) $(SHARED_BUILD_ROOT)/$(1)/libRetroCloudShared.a $(APP_INTERMEDIATES)/$(1)/libAltivecCocoa.a $(LIBVC_ROOT)/libvc-$(1)/libvc.a $(APP_INFO_PLIST) $(MODERN_SIGN_DEPS)
	@MACOSX_DEPLOYMENT_TARGET=$$(MODERN_$(1)_MIN) $$(MODERN_$(1)_CC) $$(MODERN_$(1)_FLAGS) --ld-path=/usr/bin/ld64.lld -Wl,-platform_version,macos,$$(MODERN_$(1)_MIN),11.3 $$(filter %.o %.a,$$^) $$(filter-out -lgcc_s.10.4,$$(APP_LINK_FLAGS)) -o "$$@"
	@bash "$$(MODERN_SIGN_SCRIPT)" "$$@" com.altivecintelligence.rcloud "$$(APP_INFO_PLIST)" "$$(RCLOUD_SIGNING_PEM)" $(1)
endef
$(foreach arch,x86_64 arm64,$(eval $(call RC_MODERN_ARCH,$(arch))))
$(DAEMON_OUTPUT): $(DAEMON_INTERMEDIATES)/x86_64.bin $(DAEMON_INTERMEDIATES)/arm64.bin
$(APP_UNIVERSAL_BINARY): $(APP_INTERMEDIATES)/x86_64.bin $(APP_INTERMEDIATES)/arm64.bin

NATIVE_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/native-stores
NATIVE_TEST_INFO := $(SOURCE_ROOT)/tests/macOS/native-stores/Info.plist
NATIVE_TEST_SOURCES := $(SOURCE_ROOT)/tests/macOS/native-stores/NativeStoreTests.m $(filter-out $(DAEMON_SOURCE_ROOT)/main.m $(DAEMON_SOURCE_ROOT)/RCMailProxy.c,$(DAEMON_SOURCE_PATHS))
$(NATIVE_TEST_ROOT)/NativeStoreTests: $(MODERN_SIGN_DEPS) $(NATIVE_TEST_INFO) $(NATIVE_TEST_SOURCES) $(wildcard $(DAEMON_SOURCE_ROOT)/*.h) $(SHARED_BUILD_ROOT)/x86_64/libRetroCloudShared.a $(DAEMON_INTERMEDIATES)/x86_64/libAltivecCore.a $(ICAL_x86_64_LIBRARY) $(LIBVC_x86_64_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.9 $(MODERN_x86_64_CC) $(filter-out -O%,$(MODERN_x86_64_FLAGS)) -O0 $(DAEMON_COMPILE_FLAGS) -I$(ICAL_ROOT)/libical-x86_64/src $(NATIVE_TEST_SOURCES) $(filter %.a,$^) --ld-path=/usr/bin/ld64.lld $(subst $(DAEMON_INFO_PLIST),$(NATIVE_TEST_INFO),$(MODERN_DAEMON_LINK)) -framework AppKit -o "$@"
	@bash "$(MODERN_SIGN_SCRIPT)" "$@" com.altivecintelligence.rcloud.native-tests "$(NATIVE_TEST_INFO)" "$(RCLOUD_SIGNING_PEM)" x86_64
$(NATIVE_TEST_ROOT)/bundle.stamp: $(NATIVE_TEST_ROOT)/NativeStoreTests $(NATIVE_TEST_INFO) $(SOURCE_ROOT)/make/scripts/sign-bundle.sh
	@mkdir -p "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app/Contents/MacOS"
	@cp "$(NATIVE_TEST_ROOT)/NativeStoreTests" "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app/Contents/MacOS/NativeStoreTests"
	@cp "$(NATIVE_TEST_INFO)" "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app/Contents/Info.plist"
	@bash "$(SOURCE_ROOT)/make/scripts/sign-bundle.sh" "$(NATIVE_TEST_ROOT)/rCloud Native Tests.app" "$(RCLOUD_SIGNING_PEM)" "$(LIPO)"
	@touch "$@"
build-mac-native-tests: $(NATIVE_TEST_ROOT)/bundle.stamp
.PHONY: build-mac-native-tests

test-mac-native-stores: build-mac-native-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" python3 "$(SOURCE_ROOT)/tests/macOS/native-stores/run-remote.py"
.PHONY: test-mac-native-stores
