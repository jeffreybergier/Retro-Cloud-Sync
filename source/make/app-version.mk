# Use the release source for every production HTTP client and host harness.
RC_VERSION_PLIST := $(PROJECT_ROOT)/source/macOS-app/Resources/Info.plist
RC_VERSION_SCRIPT := $(PROJECT_ROOT)/source/make/scripts/ios-version.py
RC_APP_VERSION := $(shell python3 "$(RC_VERSION_SCRIPT)" "$(PROJECT_ROOT)/source" "$(RC_VERSION_PLIST)")
ifeq ($(strip $(RC_APP_VERSION)),)
$(error Could not read the app release version)
endif
RC_VERSION_FLAGS := -DRC_APP_VERSION=\"$(RC_APP_VERSION)\"
