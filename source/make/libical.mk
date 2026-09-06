# C-only libical, with a native build for tests and a build per legacy CPU.
ICAL_ROOT := $(BUILD_ROOT)/dependencies
ICAL_CHECKOUT := $(SOURCE_ROOT)/deps/libical
ICAL_CHECKOUT_FILES := $(shell find "$(ICAL_CHECKOUT)" -type f ! -name .git 2>/dev/null)
ICAL_REVISION := $(ICAL_ROOT)/libical-revision
ICAL_SOURCE := $(ICAL_ROOT)/libical-3.0.20
ICAL_PREPARE := $(ICAL_ROOT)/libical-source.stamp
ICAL_SCRIPT := $(SOURCE_ROOT)/dependencies/build-libical.sh
ICAL_PPC_LIBRARY := $(ICAL_ROOT)/libical-ppc/lib/libical.a
ICAL_I386_LIBRARY := $(ICAL_ROOT)/libical-i386/lib/libical.a
ICAL_HOST_LIBRARY := $(ICAL_ROOT)/libical-host/lib/libical.a
ICAL_FLAGS = -I$(ICAL_SOURCE)/src/libical
ICAL_HOST_FLAGS = $(ICAL_FLAGS) -I$(ICAL_ROOT)/libical-host/src

# Upstream ships generated C files beside lex/yacc inputs. Never let Make's
# implicit rules regenerate them inside the submodule.
$(ICAL_CHECKOUT_FILES): ;

# Track the commit itself: Git can refresh its index during read-only status
# checks, which should not invalidate every library and application object.
$(ICAL_REVISION): libical-revision-check | libical-checkout-check
	@mkdir -p "$(ICAL_ROOT)"
	@git -C "$(ICAL_CHECKOUT)" rev-parse HEAD > "$@.tmp"
	@cmp -s "$@.tmp" "$@" || mv "$@.tmp" "$@"
	@rm -f "$@.tmp"
libical-revision-check:
.PHONY: libical-revision-check

$(ICAL_PREPARE): $(ICAL_SCRIPT) $(SOURCE_ROOT)/make/libical.mk \
		$(ICAL_CHECKOUT_FILES) $(ICAL_REVISION) \
		| libical-checkout-check
	@bash "$(ICAL_SCRIPT)" prepare "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)"

libical-checkout-check:
	@test -f "$(ICAL_CHECKOUT)/CMakeLists.txt" || { \
		echo 'libical is missing. Run: git submodule update --init --recursive' >&2; \
		exit 1; }
.PHONY: libical-checkout-check

$(ICAL_PPC_LIBRARY): $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@echo "  > building libical ppc"
	@bash "$(ICAL_SCRIPT)" ppc "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)"

$(ICAL_I386_LIBRARY): $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@echo "  > building libical i386"
	@bash "$(ICAL_SCRIPT)" i386 "$(ICAL_ROOT)" "$(LEGACY_TOOLCHAIN)"

$(ICAL_HOST_LIBRARY): $(ICAL_PREPARE) $(ICAL_SCRIPT)
	@echo "  > building libical native"
	@bash "$(ICAL_SCRIPT)" host "$(ICAL_ROOT)"
