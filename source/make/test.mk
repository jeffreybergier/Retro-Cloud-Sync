# Native Accessibility-based GUI test harness.

TEST_NAME := RetroCloudSyncTests
TEST_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-test
TEST_BUILD_ROOT := $(BUILD_ROOT)/macOS-test/$(CONFIG)
TEST_SOURCES := main.m AXTestRunner.m
TEST_SOURCE_PATHS := $(addprefix $(TEST_SOURCE_ROOT)/,$(TEST_SOURCES))
TEST_INTERMEDIATES := $(TEST_BUILD_ROOT)/Intermediates
TEST_OUTPUT := $(TEST_BUILD_ROOT)/$(TEST_NAME)
TEST_PPC_OBJECTS := $(addprefix $(TEST_INTERMEDIATES)/ppc/,$(TEST_SOURCES:.m=.o))
TEST_I386_OBJECTS := $(addprefix $(TEST_INTERMEDIATES)/i386/,$(TEST_SOURCES:.m=.o))
TEST_LINK_FLAGS := -framework AppKit -framework ApplicationServices \
	-lobjc -lgcc_s.10.4

test-config: validate-build $(TEST_OUTPUT)

$(TEST_OUTPUT): $(TEST_INTERMEDIATES)/ppc.bin \
		$(TEST_INTERMEDIATES)/i386.bin
	@echo " [3/3] Merging test harness universal binary (ppc, i386)..."
	@mkdir -p "$(dir $@)"
	@$(LIPO) -create $^ -output "$@"

$(TEST_INTERMEDIATES)/ppc.bin: $(TEST_PPC_OBJECTS)
	@echo "  > linking test harness ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ $(TEST_LINK_FLAGS) -o "$@"

$(TEST_INTERMEDIATES)/i386.bin: $(TEST_I386_OBJECTS)
	@echo "  > linking test harness i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ $(TEST_LINK_FLAGS) -o "$@"

$(TEST_INTERMEDIATES)/ppc/%.o: $(TEST_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [1/3] Compiling test harness ppc: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(TEST_INTERMEDIATES)/i386/%.o: $(TEST_SOURCE_ROOT)/%.m
	@mkdir -p "$(dir $@)"
	@echo " [2/3] Compiling test harness i386: $(notdir $<)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

.PHONY: test-config
