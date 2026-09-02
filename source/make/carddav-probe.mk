# Non-shipped read-only CardDAV diagnostic tool.

CARDDAV_PROBE_NAME := RetroCloudCardDAVProbe
CARDDAV_PROBE_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-carddav-probe
CARDDAV_PROBE_BUILD_ROOT := $(BUILD_ROOT)/macOS-carddav-probe/$(CONFIG)
CARDDAV_PROBE_SOURCE := $(CARDDAV_PROBE_SOURCE_ROOT)/main.c
CARDDAV_PROBE_INTERMEDIATES := $(CARDDAV_PROBE_BUILD_ROOT)/Intermediates
CARDDAV_PROBE_OUTPUT := $(CARDDAV_PROBE_BUILD_ROOT)/$(CARDDAV_PROBE_NAME)
CARDDAV_PROBE_PPC_OBJECT := $(CARDDAV_PROBE_INTERMEDIATES)/ppc/main.o
CARDDAV_PROBE_I386_OBJECT := $(CARDDAV_PROBE_INTERMEDIATES)/i386/main.o
CARDDAV_PROBE_COMPILE_FLAGS := -I$(SHARED_SOURCE_ROOT) \
	-I$(ALTIVECCORE_ROOT)/include
CARDDAV_PROBE_LINK_FLAGS := -framework CoreFoundation \
	-framework SystemConfiguration -lxml2 -lobjc -lgcc_s.10.4

carddav-probe-config: validate-build shared-config $(CARDDAV_PROBE_OUTPUT)

$(CARDDAV_PROBE_OUTPUT): $(CARDDAV_PROBE_INTERMEDIATES)/ppc.bin \
		$(CARDDAV_PROBE_INTERMEDIATES)/i386.bin
	@echo " [3/3] Merging CardDAV probe universal binary (ppc, i386)..."
	@mkdir -p "$(dir $@)"
	@$(LIPO) -create $^ -output "$@"

$(CARDDAV_PROBE_INTERMEDIATES)/ppc.bin: $(CARDDAV_PROBE_PPC_OBJECT) \
		$(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE)
	@echo "  > linking CardDAV probe ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(CARDDAV_PROBE_LINK_FLAGS) -o "$@"

$(CARDDAV_PROBE_INTERMEDIATES)/i386.bin: $(CARDDAV_PROBE_I386_OBJECT) \
		$(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE)
	@echo "  > linking CardDAV probe i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(CARDDAV_PROBE_LINK_FLAGS) -o "$@"

$(CARDDAV_PROBE_PPC_OBJECT): $(CARDDAV_PROBE_SOURCE)
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling CardDAV probe ppc..."
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(CARDDAV_PROBE_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch ppc -isysroot "$(SDK)" -c "$<" -o "$@"

$(CARDDAV_PROBE_I386_OBJECT): $(CARDDAV_PROBE_SOURCE)
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling CardDAV probe i386..."
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(CARDDAV_PROBE_COMPILE_FLAGS) $(OPT_FLAGS) \
		-arch i386 -isysroot "$(SDK)" -c "$<" -o "$@"

.PHONY: carddav-probe-config
