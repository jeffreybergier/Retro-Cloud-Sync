# Opt-in evaluation of the legacy VObject parser. It is not used by the app.
VCAL_COMPAT_ROOT := $(BUILD_ROOT)/vcal-compat
VCAL_COMPAT_SOURCE := $(SOURCE_ROOT)/shared-test/VCalCompatibility.c
VCAL_COMPAT_SOURCES := $(VCAL_COMPAT_SOURCE) $(SHARED_SOURCE_ROOT)/RCVCard.c \
	$(SHARED_SOURCE_ROOT)/RCError.c
VCAL_COMPAT_FLAGS = $(LIBVC_FLAGS) -I$(ICAL_SOURCE)/src/libicalvcal -I$(SHARED_SOURCE_ROOT)
VCAL_HOST_LIBRARY := $(ICAL_ROOT)/libical-host/lib/libicalvcal.a
VCAL_PPC_LIBRARY := $(ICAL_ROOT)/libical-ppc/lib/libicalvcal.a
VCAL_I386_LIBRARY := $(ICAL_ROOT)/libical-i386/lib/libicalvcal.a

$(VCAL_HOST_LIBRARY): $(ICAL_HOST_LIBRARY)
	@bash "$(ICAL_SCRIPT)" host "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)" icalvcal
$(VCAL_PPC_LIBRARY): $(ICAL_PPC_LIBRARY)
	@bash "$(ICAL_SCRIPT)" ppc "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)" icalvcal
$(VCAL_I386_LIBRARY): $(ICAL_I386_LIBRARY)
	@bash "$(ICAL_SCRIPT)" i386 "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)" icalvcal

$(VCAL_COMPAT_ROOT)/host: $(VCAL_COMPAT_SOURCES) $(VCAL_HOST_LIBRARY) $(LIBVC_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		$(VCAL_COMPAT_FLAGS) $(VCAL_COMPAT_SOURCES) \
		$(VCAL_HOST_LIBRARY) $(ICAL_HOST_LIBRARY) $(LIBVC_HOST_LIBRARY) -lpthread -o "$@"

$(VCAL_COMPAT_ROOT)/ppc: $(VCAL_COMPAT_SOURCES) $(VCAL_PPC_LIBRARY) $(LIBVC_PPC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) $(VCAL_COMPAT_FLAGS) \
		-arch ppc -isysroot "$(SDK)" $(VCAL_COMPAT_SOURCES) \
		$(VCAL_PPC_LIBRARY) $(ICAL_PPC_LIBRARY) $(LIBVC_PPC_LIBRARY) -lgcc_s.10.4 -o "$@"

$(VCAL_COMPAT_ROOT)/i386: $(VCAL_COMPAT_SOURCES) $(VCAL_I386_LIBRARY) $(LIBVC_I386_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) $(VCAL_COMPAT_FLAGS) \
		-arch i386 -isysroot "$(SDK)" $(VCAL_COMPAT_SOURCES) \
		$(VCAL_I386_LIBRARY) $(ICAL_I386_LIBRARY) $(LIBVC_I386_LIBRARY) -lgcc_s.10.4 -o "$@"

# A compatibility gate: exits nonzero while upstream changes valid card data.
test-vcal-compat: $(VCAL_COMPAT_ROOT)/host
	@"$(VCAL_COMPAT_ROOT)/host"

test-vcal-compat-build: validate-build $(VCAL_COMPAT_ROOT)/host \
		$(VCAL_COMPAT_ROOT)/ppc $(VCAL_COMPAT_ROOT)/i386

.PHONY: test-vcal-compat test-vcal-compat-build
