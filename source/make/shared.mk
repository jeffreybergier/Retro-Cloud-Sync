# Plain C code shared by the app and daemon.

SHARED_SOURCE_ROOT := $(SOURCE_ROOT)/shared
SHARED_BUILD_ROOT := $(BUILD_ROOT)/shared/$(CONFIG)
SHARED_SOURCE_NAMES := $(notdir $(wildcard $(SHARED_SOURCE_ROOT)/*.c))
SHARED_SOURCE_PATHS := $(addprefix $(SHARED_SOURCE_ROOT)/,$(SHARED_SOURCE_NAMES))
SHARED_COMPILE_FLAGS = $(ICAL_FLAGS) -I$(ALTIVECCORE_ROOT)/include \
	-I$(SDK)/usr/include/libxml2

ifneq ($(strip $(SHARED_SOURCE_NAMES)),)
  PPC_SHARED_OBJECTS := $(addprefix $(SHARED_BUILD_ROOT)/ppc/,$(SHARED_SOURCE_NAMES:.c=.o))
  I386_SHARED_OBJECTS := $(addprefix $(SHARED_BUILD_ROOT)/i386/,$(SHARED_SOURCE_NAMES:.c=.o))
  PPC_SHARED_LIBRARY := $(SHARED_BUILD_ROOT)/ppc/libRetroCloudShared.a
  I386_SHARED_LIBRARY := $(SHARED_BUILD_ROOT)/i386/libRetroCloudShared.a

shared-config: validate-build $(PPC_SHARED_LIBRARY) $(I386_SHARED_LIBRARY)

$(PPC_SHARED_LIBRARY): $(PPC_SHARED_OBJECTS)
	@echo "  > archiving shared ppc library"
	@$(LEGACY_AR) rcs "$@" $^
	@$(LEGACY_RANLIB) "$@"

$(I386_SHARED_LIBRARY): $(I386_SHARED_OBJECTS)
	@echo "  > archiving shared i386 library"
	@$(LEGACY_AR) rcs "$@" $^
	@$(LEGACY_RANLIB) "$@"

$(SHARED_BUILD_ROOT)/ppc/%.o: $(SHARED_SOURCE_ROOT)/%.c $(ICAL_PPC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > shared ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(SHARED_COMPILE_FLAGS) $(OPT_FLAGS) \
		-I$(ICAL_ROOT)/libical-ppc/src -arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(SHARED_BUILD_ROOT)/i386/%.o: $(SHARED_SOURCE_ROOT)/%.c $(ICAL_I386_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > shared i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(SHARED_COMPILE_FLAGS) $(OPT_FLAGS) \
		-I$(ICAL_ROOT)/libical-i386/src -arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"
else
  PPC_SHARED_LIBRARY :=
  I386_SHARED_LIBRARY :=

shared-config: validate-build
	@echo "  > no shared C sources yet"
endif

.PHONY: shared-config
