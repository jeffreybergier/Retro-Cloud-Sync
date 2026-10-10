PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ALTIVEC_ROOT ?= /altivec
PLATFORMS = macOS iOS
PROJECT_macOS_DIR = source/macOS-app
PROJECT_iOS_DIR = source/iOS-daemon
TEST_HOST_COMMAND = $(MAKE) -f source/tests/Makefile test-host
TEST_NATIVE_COMMAND = $(MAKE) -f source/tests/Makefile test-business-mac TEST_HOST=$(TEST_HOST)
include $(ALTIVEC_ROOT)/make/projects.mk
ios-package: iOS-release
app-release daemon-release shared-release: macOS-release
app-debug daemon-debug shared-debug: macOS-debug
test: test-host
# Existing specialized offline integration suites retain their public names.
analyze-ios: iOS-analyze ;
test-% build-% analyze-% compare-%:
	+$(MAKE) -f source/tests/Makefile $@ BUILD_ROOT="$(abspath $(BUILD_ROOT))"

carddav-probe carddav-probe-debug caldav-probe:
	+$(MAKE) -f source/tests/Makefile $@ BUILD_ROOT="$(abspath $(BUILD_ROOT))"
