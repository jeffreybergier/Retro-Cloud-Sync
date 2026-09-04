# Retro Cloud Sync background process.

DAEMON_NAME := RetroCloudSyncDaemon
DAEMON_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-daemon
DAEMON_BUILD_ROOT := $(BUILD_ROOT)/macOS-daemon/$(CONFIG)
DAEMON_SOURCES := main.m RCSyncServicesBridge.m RCMailProxy.c
DAEMON_SOURCE_PATHS := $(addprefix $(DAEMON_SOURCE_ROOT)/,$(DAEMON_SOURCES))
DAEMON_INTERMEDIATES := $(DAEMON_BUILD_ROOT)/Intermediates
DAEMON_OUTPUT := $(DAEMON_BUILD_ROOT)/$(DAEMON_NAME)
ALTIVECCORE_ROOT ?= /altivec/libs/core/build-mac
ALTIVECCORE_STATIC_LIBRARY := $(ALTIVECCORE_ROOT)/lib/libAltivecCore.a
ALTIVECCORE_CA_CERTS := $(ALTIVECCORE_ROOT)/lib/cacert.pem
DAEMON_PPC_ALTIVECCORE := $(DAEMON_INTERMEDIATES)/ppc/libAltivecCore.a
DAEMON_I386_ALTIVECCORE := $(DAEMON_INTERMEDIATES)/i386/libAltivecCore.a
DAEMON_OBJECT_NAMES := $(addsuffix .o,$(basename $(DAEMON_SOURCES)))
DAEMON_PPC_OBJECTS := $(addprefix \
	$(DAEMON_INTERMEDIATES)/ppc/,$(DAEMON_OBJECT_NAMES))
DAEMON_I386_OBJECTS := $(addprefix \
	$(DAEMON_INTERMEDIATES)/i386/,$(DAEMON_OBJECT_NAMES))
DAEMON_COMPILE_FLAGS := -I$(ALTIVECCORE_ROOT)/include
DAEMON_LINK_FLAGS := -framework Foundation -framework CoreFoundation \
		-framework SystemConfiguration -framework Security -lxml2 \
		-framework SyncServices \
		-lobjc -lgcc_s.10.4

daemon-config: validate-build shared-config $(DAEMON_OUTPUT)

$(DAEMON_OUTPUT): $(DAEMON_INTERMEDIATES)/ppc.bin \
		$(DAEMON_INTERMEDIATES)/i386.bin
	@echo " [3/3] Merging daemon universal binary (ppc, i386)..."
	@mkdir -p "$(dir $@)"
	@$(LIPO) -create $^ -output "$@"

$(DAEMON_INTERMEDIATES)/ppc.bin: $(DAEMON_PPC_OBJECTS) \
		$(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE)
	@echo "  > linking daemon ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(DAEMON_LINK_FLAGS) -o "$@"

$(DAEMON_INTERMEDIATES)/i386.bin: $(DAEMON_I386_OBJECTS) \
		$(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE)
	@echo "  > linking daemon i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(DAEMON_LINK_FLAGS) -o "$@"

$(DAEMON_INTERMEDIATES)/ppc/%.o: $(DAEMON_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling daemon ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(DAEMON_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(DAEMON_INTERMEDIATES)/i386/%.o: $(DAEMON_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling daemon i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(DAEMON_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(DAEMON_INTERMEDIATES)/ppc/%.o: $(DAEMON_SOURCE_ROOT)/%.c
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling daemon ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(DAEMON_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(DAEMON_INTERMEDIATES)/i386/%.o: $(DAEMON_SOURCE_ROOT)/%.c
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling daemon i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(DAEMON_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(DAEMON_PPC_ALTIVECCORE): $(ALTIVECCORE_STATIC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > thinning AltivecCore static library to ppc"
	@$(LIPO) "$<" -thin ppc -output "$@"

$(DAEMON_I386_ALTIVECCORE): $(ALTIVECCORE_STATIC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > thinning AltivecCore static library to i386"
	@$(LIPO) "$<" -thin i386 -output "$@"

.PHONY: daemon-config
