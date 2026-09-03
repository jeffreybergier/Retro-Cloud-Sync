# Retro Cloud Sync graphical application and product bundle.

APP_NAME := RetroCloudSync
APP_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-app
APP_BUILD_ROOT := $(BUILD_ROOT)/macOS-app/$(CONFIG)
APP_SOURCES := main.m AppDelegate.m PreferencesWindowController.m \
	DaemonStatusView.m DaemonLogView.m MailServerView.m RCConfiguration.m \
	ContactsView.m RCServiceController.m
APP_SOURCE_PATHS := $(addprefix $(APP_SOURCE_ROOT)/,$(APP_SOURCES))
APP_RESOURCES_ROOT := $(APP_SOURCE_ROOT)/Resources
APP_INFO_PLIST := $(APP_RESOURCES_ROOT)/Info.plist
APP_INTERMEDIATES := $(APP_BUILD_ROOT)/Intermediates
APP_BUNDLE := $(APP_BUILD_ROOT)/$(APP_NAME).app
APP_ZIP := $(APP_BUILD_ROOT)/$(APP_NAME).zip
APP_UNIVERSAL_BINARY := $(APP_INTERMEDIATES)/$(APP_NAME)-universal
APP_PPC_OBJECTS := $(addprefix $(APP_INTERMEDIATES)/ppc/,$(APP_SOURCES:.m=.o))
APP_I386_OBJECTS := $(addprefix $(APP_INTERMEDIATES)/i386/,$(APP_SOURCES:.m=.o))
ALTIVECCOCOA_ROOT ?= /altivec/libs/cocoa/build-mac
ALTIVECCOCOA_STATIC_LIBRARY := $(ALTIVECCOCOA_ROOT)/lib/libAltivecCocoa.a
ALTIVECCOCOA_FONT_ROOT := $(ALTIVECCOCOA_ROOT)/Resources/Fonts
ALTIVECCOCOA_FONTS := $(ALTIVECCOCOA_FONT_ROOT)/FA7-Solid-900.otf \
	$(ALTIVECCOCOA_FONT_ROOT)/FA7-Regular-400.otf \
	$(ALTIVECCOCOA_FONT_ROOT)/FA7-Brands-400.otf
ALTIVECCOCOA_FONT_LICENSE := \
	$(ALTIVECCOCOA_FONT_ROOT)/LICENSE-Font-Awesome.txt
APP_PPC_ALTIVECCOCOA := \
	$(APP_INTERMEDIATES)/ppc/libAltivecCocoa.a
APP_I386_ALTIVECCOCOA := \
	$(APP_INTERMEDIATES)/i386/libAltivecCocoa.a
APP_COMPILE_FLAGS := -I$(ALTIVECCOCOA_ROOT)/include
APP_LINK_FLAGS := -framework AppKit -framework CoreServices \
	-framework ApplicationServices -framework Security -lobjc -lgcc_s.10.4

ALL_SOURCE_PATHS = $(APP_SOURCE_PATHS) $(DAEMON_SOURCE_PATHS) \
	$(SHARED_SOURCE_PATHS) $(TEST_SOURCE_PATHS) $(CARDDAV_PROBE_SOURCE)

app-config: validate-build daemon-config $(APP_ZIP)

$(APP_ZIP): $(APP_UNIVERSAL_BINARY) $(DAEMON_OUTPUT) $(APP_INFO_PLIST) \
		$(ALTIVECCORE_CA_CERTS) $(ALTIVECCOCOA_FONTS) \
		$(ALTIVECCOCOA_FONT_LICENSE)
	@echo " [4/5] Building app bundle and embedding daemon..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" \
		"$(APP_BUNDLE)/Contents/Resources" \
		"$(APP_BUNDLE)/Contents/Library/LaunchServices"
	@cp "$(APP_UNIVERSAL_BINARY)" \
		"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp "$(DAEMON_OUTPUT)" \
		"$(APP_BUNDLE)/Contents/Library/LaunchServices/$(DAEMON_NAME)"
	@chmod +x \
		"$(APP_BUNDLE)/Contents/Library/LaunchServices/$(DAEMON_NAME)"
	@cp "$(APP_INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@cp "$(ALTIVECCORE_CA_CERTS)" \
		"$(APP_BUNDLE)/Contents/Resources/cacert.pem"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources/Fonts"
	@cp $(ALTIVECCOCOA_FONTS) \
		"$(APP_BUNDLE)/Contents/Resources/Fonts/"
	@cp "$(ALTIVECCOCOA_FONT_LICENSE)" \
		"$(APP_BUNDLE)/Contents/Resources/Fonts/"
	@printf 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	@echo " [5/5] Zipping app..."
	@rm -f "$@"
	@cd "$(APP_BUILD_ROOT)" && zip -rqy "$(APP_NAME).zip" \
		"$(APP_NAME).app"

$(APP_UNIVERSAL_BINARY): $(APP_INTERMEDIATES)/ppc.bin \
		$(APP_INTERMEDIATES)/i386.bin
	@echo " [3/5] Merging app universal binary (ppc, i386)..."
	@$(LIPO) -create $^ -output "$@"

$(APP_INTERMEDIATES)/ppc.bin: $(APP_PPC_OBJECTS) $(PPC_SHARED_LIBRARY) \
		$(APP_PPC_ALTIVECCOCOA)
	@echo "  > linking app ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(APP_LINK_FLAGS) -o "$@"

$(APP_INTERMEDIATES)/i386.bin: $(APP_I386_OBJECTS) $(I386_SHARED_LIBRARY) \
		$(APP_I386_ALTIVECCOCOA)
	@echo "  > linking app i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(APP_LINK_FLAGS) -o "$@"

$(APP_INTERMEDIATES)/ppc/%.o: $(APP_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@if [ "$(notdir $<)" = "$(firstword $(APP_SOURCES))" ]; then \
		echo " [1/5] Compiling app ppc (10.5 SDK, 10.4 minimum)..."; \
	fi
	@echo "  > app ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(APP_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(APP_INTERMEDIATES)/i386/%.o: $(APP_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@if [ "$(notdir $<)" = "$(firstword $(APP_SOURCES))" ]; then \
		echo " [2/5] Compiling app i386 (10.5 SDK, 10.4 minimum)..."; \
	fi
	@echo "  > app i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(APP_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(APP_PPC_ALTIVECCOCOA): $(ALTIVECCOCOA_STATIC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > thinning AltivecCocoa static library to ppc"
	@$(LIPO) "$<" -thin ppc -output "$@"

$(APP_I386_ALTIVECCOCOA): $(ALTIVECCOCOA_STATIC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > thinning AltivecCocoa static library to i386"
	@$(LIPO) "$<" -thin i386 -output "$@"

.PHONY: app-config
