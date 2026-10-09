# Standalone, non-shipped probe. Build in Altivec; never execute Mach-O here.
# Invoke: make -C source/probes/iOS/native-access all analyze
# Run the appropriate signed slice as mobile on a test phone. Exit zero means
# the inspection completed, not that access was granted: inspect authorization
# output. A temporary RunAtLoad launchd job (UserName/GroupName mobile, no
# KeepAlive) tests daemon context. Remove that job and executable afterwards.
# This probe deliberately does not request permissions or bypass TCC.
# Observed on koolphone5 / iOS 8.4.1 (12H321): both SSH su-mobile and launchd
# returned contacts.authorization=denied and calendars.authorization=denied.
# Follow-up: an installed/registered rCloud.app executable launched as mobile
# can request normal TCC prompts. After user approval, a fresh launchd process
# opened both stores on the same phone. See the root README's iOS instructions.
# The armv7 binary targets iOS 5.0; that runtime still needs device validation.
SDK ?= /osxcross/modern/SDK/iPhoneOS8.4.sdk
BIN ?= /osxcross/modern/bin
CLANG ?= /usr/bin/clang
LDID ?= ldid
OUT ?= ../../../../build/probes/iOS/native-access
FLAGS = -isysroot $(SDK) -B$(BIN) -fno-objc-arc -Wall -Wextra -Werror
FRAMEWORKS = -framework Foundation -framework AddressBook -framework EventKit

.PHONY: all analyze
all: $(OUT)/probe-armv7 $(OUT)/probe-arm64

$(OUT)/probe-armv7: main.m Entitlements.plist Makefile
	@mkdir -p $(OUT)
	$(CLANG) -target armv7-apple-ios5.0 $(FLAGS) main.m $(FRAMEWORKS) -o $@
	$(LDID) -SEntitlements.plist $@

$(OUT)/probe-arm64: main.m Entitlements.plist Makefile
	@mkdir -p $(OUT)
	$(CLANG) -target arm64-apple-ios7.0 $(FLAGS) main.m $(FRAMEWORKS) -o $@
	$(LDID) -SEntitlements.plist $@

analyze:
	$(CLANG) -target armv7-apple-ios5.0 $(FLAGS) --analyze -Xanalyzer -analyzer-output=text main.m
	$(CLANG) -target arm64-apple-ios7.0 $(FLAGS) --analyze -Xanalyzer -analyzer-output=text main.m
