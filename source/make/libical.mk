# C-only libical, with a native build for tests and a build per legacy CPU.
ICAL_ROOT := $(BUILD_ROOT)/dependencies
ICAL_SOURCE := $(ICAL_ROOT)/libical-3.0.20
ICAL_PREPARE := $(ICAL_ROOT)/libical-source.stamp
ICAL_SCRIPT := $(SOURCE_ROOT)/dependencies/build-libical.sh
ICAL_PPC_LIBRARY := $(ICAL_ROOT)/libical-ppc/lib/libical.a
ICAL_I386_LIBRARY := $(ICAL_ROOT)/libical-i386/lib/libical.a
ICAL_HOST_LIBRARY := $(ICAL_ROOT)/libical-host/lib/libical.a
ICAL_FLAGS = -I$(ICAL_SOURCE)/src/libical
ICAL_HOST_FLAGS = $(ICAL_FLAGS) -I$(ICAL_ROOT)/libical-host/src

$(ICAL_PREPARE): $(ICAL_SCRIPT)
	@bash "$(ICAL_SCRIPT)" prepare "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)"

$(ICAL_PPC_LIBRARY): $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@echo "  > building libical ppc"
	@bash "$(ICAL_SCRIPT)" ppc "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)"

$(ICAL_I386_LIBRARY): $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@echo "  > building libical i386"
	@bash "$(ICAL_SCRIPT)" i386 "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)"

$(ICAL_HOST_LIBRARY): $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@echo "  > building libical native"
	@bash "$(ICAL_SCRIPT)" host "$(ICAL_ROOT)"
