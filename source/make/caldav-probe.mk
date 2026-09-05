# Non-shipped read-only CalDAV diagnostic tool.

CALDAV_PROBE_NAME := RetroCloudCalDAVProbe
CALDAV_PROBE_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-caldav-probe
CALDAV_PROBE_BUILD_ROOT := $(BUILD_ROOT)/macOS-caldav-probe/$(CONFIG)
CALDAV_PROBE_SOURCE := $(CALDAV_PROBE_SOURCE_ROOT)/main.c
CALDAV_PROBE_INTERMEDIATES := $(CALDAV_PROBE_BUILD_ROOT)/Intermediates
CALDAV_PROBE_OUTPUT := $(CALDAV_PROBE_BUILD_ROOT)/$(CALDAV_PROBE_NAME)
CALDAV_PROBE_PPC_OBJECT := $(CALDAV_PROBE_INTERMEDIATES)/ppc/main.o
CALDAV_PROBE_I386_OBJECT := $(CALDAV_PROBE_INTERMEDIATES)/i386/main.o
CALDAV_PROBE_COMPILE_FLAGS = $(ICAL_FLAGS) -I$(SHARED_SOURCE_ROOT) \
	-I$(ALTIVECCORE_ROOT)/include
CALDAV_PROBE_LINK_FLAGS := -framework CoreFoundation \
	-framework SystemConfiguration -lxml2 -lobjc -lgcc_s.10.4

caldav-probe-config: validate-build shared-config $(CALDAV_PROBE_OUTPUT)

$(CALDAV_PROBE_OUTPUT): $(CALDAV_PROBE_INTERMEDIATES)/ppc.bin \
		$(CALDAV_PROBE_INTERMEDIATES)/i386.bin
	@echo " [3/3] Merging CalDAV probe universal binary (ppc, i386)..."
	@mkdir -p "$(dir $@)"
	@$(LIPO) -create $^ -output "$@"

$(CALDAV_PROBE_INTERMEDIATES)/ppc.bin: $(CALDAV_PROBE_PPC_OBJECT) \
		$(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) $(ICAL_PPC_LIBRARY)
	@echo "  > linking CalDAV probe ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(CALDAV_PROBE_LINK_FLAGS) -o "$@"

$(CALDAV_PROBE_INTERMEDIATES)/i386.bin: $(CALDAV_PROBE_I386_OBJECT) \
		$(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE) $(ICAL_I386_LIBRARY)
	@echo "  > linking CalDAV probe i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(CALDAV_PROBE_LINK_FLAGS) -o "$@"

$(CALDAV_PROBE_PPC_OBJECT): $(CALDAV_PROBE_SOURCE) $(ICAL_PPC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling CalDAV probe ppc..."
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(CALDAV_PROBE_COMPILE_FLAGS) $(OPT_FLAGS) \
		-I$(ICAL_ROOT)/libical-ppc/src -arch ppc -isysroot "$(SDK)" -c "$<" -o "$@"

$(CALDAV_PROBE_I386_OBJECT): $(CALDAV_PROBE_SOURCE) $(ICAL_I386_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling CalDAV probe i386..."
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(CALDAV_PROBE_COMPILE_FLAGS) $(OPT_FLAGS) \
		-I$(ICAL_ROOT)/libical-i386/src -arch i386 -isysroot "$(SDK)" -c "$<" -o "$@"

.PHONY: caldav-probe-config

caldav-probe:
	@$(MAKE) --no-print-directory CONFIG=release BUILD_ROOT="$(BUILD_ROOT)" caldav-probe-config
.PHONY: caldav-probe
