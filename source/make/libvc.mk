# Pinned libvc checkout; generated sources stay outside the submodule.
LIBVC_CHECKOUT := $(SOURCE_ROOT)/deps/libvc
LIBVC_ROOT := $(BUILD_ROOT)/dependencies
LIBVC_SOURCE := $(LIBVC_ROOT)/libvc-source
LIBVC_SCRIPT := $(SOURCE_ROOT)/make/scripts/build-libvc.sh
LIBVC_SUPPORT := $(SOURCE_ROOT)/make/scripts/libvc-portability.h \
	$(SOURCE_ROOT)/make/scripts/libvc-portability.c
LIBVC_INPUTS := $(addprefix $(LIBVC_CHECKOUT)/src/,vc.c vc.h vc_parse.y vc_scan.l)
LIBVC_PREPARE := $(LIBVC_ROOT)/libvc-source.stamp
LIBVC_REVISION := $(LIBVC_ROOT)/libvc-revision
LIBVC_HOST_LIBRARY := $(LIBVC_ROOT)/libvc-host/libvc.a
LIBVC_PPC_LIBRARY := $(LIBVC_ROOT)/libvc-ppc/libvc.a
LIBVC_I386_LIBRARY := $(LIBVC_ROOT)/libvc-i386/libvc.a
LIBVC_FLAGS = -I$(LIBVC_SOURCE)/src

$(LIBVC_INPUTS): ;
libvc-checkout-check:
	@test -f "$(LIBVC_CHECKOUT)/src/vc.c" || { \
		echo 'libvc is missing. Run: git submodule update --init --recursive' >&2; \
		exit 1; }
$(LIBVC_REVISION): libvc-revision-check | libvc-checkout-check
	@mkdir -p "$(LIBVC_ROOT)"
	@git -C "$(LIBVC_CHECKOUT)" rev-parse HEAD > "$@.tmp"
	@cmp -s "$@.tmp" "$@" || mv "$@.tmp" "$@"
	@rm -f "$@.tmp"
libvc-revision-check:

$(LIBVC_PREPARE): $(LIBVC_SCRIPT) $(LIBVC_INPUTS) $(LIBVC_REVISION) \
		$(SOURCE_ROOT)/make/scripts/libvc-parser.patch $(SOURCE_ROOT)/make/libvc.mk
	@bash "$(LIBVC_SCRIPT)" prepare "$(LIBVC_ROOT)"
$(LIBVC_HOST_LIBRARY): $(LIBVC_PREPARE) $(LIBVC_SUPPORT)
	@HOST_CC="$(HOST_CC)" bash "$(LIBVC_SCRIPT)" host "$(LIBVC_ROOT)"
$(LIBVC_PPC_LIBRARY): $(LIBVC_PREPARE) $(LIBVC_SUPPORT)
	@bash "$(LIBVC_SCRIPT)" ppc "$(LIBVC_ROOT)" "$(LEGACY_TOOLCHAIN)"
$(LIBVC_I386_LIBRARY): $(LIBVC_PREPARE) $(LIBVC_SUPPORT)
	@bash "$(LIBVC_SCRIPT)" i386 "$(LIBVC_ROOT)" "$(LEGACY_TOOLCHAIN)"

.PHONY: libvc-checkout-check libvc-revision-check
