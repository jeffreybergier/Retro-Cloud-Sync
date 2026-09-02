# Retro Cloud Sync background process.

DAEMON_NAME := RetroCloudSyncDaemon
DAEMON_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-daemon
DAEMON_BUILD_ROOT := $(BUILD_ROOT)/macOS-daemon/$(CONFIG)
DAEMON_SOURCES := main.m
DAEMON_SOURCE_PATHS := $(addprefix $(DAEMON_SOURCE_ROOT)/,$(DAEMON_SOURCES))
DAEMON_INTERMEDIATES := $(DAEMON_BUILD_ROOT)/Intermediates
DAEMON_OUTPUT := $(DAEMON_BUILD_ROOT)/$(DAEMON_NAME)
DAEMON_PPC_OBJECTS := $(addprefix $(DAEMON_INTERMEDIATES)/ppc/,$(DAEMON_SOURCES:.m=.o))
DAEMON_I386_OBJECTS := $(addprefix $(DAEMON_INTERMEDIATES)/i386/,$(DAEMON_SOURCES:.m=.o))
DAEMON_LINK_FLAGS := -framework Foundation -lobjc -lgcc_s.10.4

daemon-config: validate-build shared-config $(DAEMON_OUTPUT)

$(DAEMON_OUTPUT): $(DAEMON_INTERMEDIATES)/ppc.bin \
		$(DAEMON_INTERMEDIATES)/i386.bin
	@echo " [3/3] Merging daemon universal binary (ppc, i386)..."
	@mkdir -p "$(dir $@)"
	@$(LIPO) -create $^ -output "$@"

$(DAEMON_INTERMEDIATES)/ppc.bin: $(DAEMON_PPC_OBJECTS) \
		$(PPC_SHARED_LIBRARY)
	@echo "  > linking daemon ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(DAEMON_LINK_FLAGS) -o "$@"

$(DAEMON_INTERMEDIATES)/i386.bin: $(DAEMON_I386_OBJECTS) \
		$(I386_SHARED_LIBRARY)
	@echo "  > linking daemon i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(DAEMON_LINK_FLAGS) -o "$@"

$(DAEMON_INTERMEDIATES)/ppc/%.o: $(DAEMON_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling daemon ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(DAEMON_INTERMEDIATES)/i386/%.o: $(DAEMON_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling daemon i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

.PHONY: daemon-config
