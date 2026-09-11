# Native tests for the NSLog boundary and mail connection diagnostics.
LOGGING_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/logging
LOGGING_TEST_SOURCES := $(SOURCE_ROOT)/tests/macOS/logging/LoggerTests.m \
  $(SOURCE_ROOT)/tests/macOS/logging/MailLoggingTests.c $(DAEMON_SOURCE_ROOT)/RCLogger.m $(DAEMON_SOURCE_ROOT)/RCStatus.m \
  $(SOURCE_ROOT)/tests/macOS/logging/StatusTests.m
LOGGING_TEST_INPUTS := $(LOGGING_TEST_SOURCES) $(DAEMON_SOURCE_ROOT)/RCMailProxy.c \
  $(DAEMON_SOURCE_ROOT)/RCLogger.h $(SHARED_SOURCE_ROOT)/RCLogLevel.h
$(LOGGING_TEST_ROOT)/ppc: $(LOGGING_TEST_INPUTS) $(DAEMON_PPC_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) $(OPT_FLAGS) \
	  -I$(DAEMON_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include -arch ppc -isysroot "$(SDK)" \
	  $(LOGGING_TEST_SOURCES) $(DAEMON_PPC_ALTIVECCORE) $(DAEMON_LINK_FLAGS) -o "$@"
$(LOGGING_TEST_ROOT)/i386: $(LOGGING_TEST_INPUTS) $(DAEMON_I386_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) $(OPT_FLAGS) \
	  -I$(DAEMON_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include -arch i386 -isysroot "$(SDK)" \
	  $(LOGGING_TEST_SOURCES) $(DAEMON_I386_ALTIVECCORE) $(DAEMON_LINK_FLAGS) -o "$@"
$(LOGGING_TEST_ROOT)/LoggerTests: $(LOGGING_TEST_ROOT)/ppc $(LOGGING_TEST_ROOT)/i386
	@$(LIPO) -create $^ -output "$@"
build-mac-logging-tests: $(LOGGING_TEST_ROOT)/LoggerTests
.PHONY: build-mac-logging-tests
test-mac-logging: build-mac-logging-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" \
	  python3 "$(SOURCE_ROOT)/tests/macOS/logging/run-remote.py"
.PHONY: test-mac-logging
