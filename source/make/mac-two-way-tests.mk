TWO_WAY_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/two-way
TWO_WAY_TEST_SOURCES := $(SOURCE_ROOT)/tests/macOS/two-way/TwoWaySyncTests.m \
  $(addprefix $(DAEMON_SOURCE_ROOT)/,RCTwoWaySync.m RCTwoWayFields.m RCContactTwoWay.m RCContactPhotoCache.m RCCalendarTwoWay.m \
  RCSyncServicesBridge.m RCCalendarSyncServicesBridge.m RCSyncConflictSession.m RCLogger.m)
TWO_WAY_TEST_HEADERS := $(wildcard $(DAEMON_SOURCE_ROOT)/*.h) $(wildcard $(SHARED_SOURCE_ROOT)/*.h)
$(TWO_WAY_TEST_ROOT)/ppc: $(TWO_WAY_TEST_SOURCES) $(TWO_WAY_TEST_HEADERS) \
  $(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) $(ICAL_PPC_LIBRARY) $(LIBVC_PPC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) $(ICAL_FLAGS) $(OPT_FLAGS) \
	  -I$(ICAL_ROOT)/libical-ppc/src -I$(ALTIVECCORE_ROOT)/include -arch ppc -isysroot "$(SDK)" \
	  $(TWO_WAY_TEST_SOURCES) $(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) $(ICAL_PPC_LIBRARY) \
	  $(LIBVC_PPC_LIBRARY) $(DAEMON_LINK_FLAGS) -o "$@"
$(TWO_WAY_TEST_ROOT)/i386: $(TWO_WAY_TEST_SOURCES) $(TWO_WAY_TEST_HEADERS) \
  $(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE) $(ICAL_I386_LIBRARY) $(LIBVC_I386_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) $(ICAL_FLAGS) $(OPT_FLAGS) \
	  -I$(ICAL_ROOT)/libical-i386/src -I$(ALTIVECCORE_ROOT)/include -arch i386 -isysroot "$(SDK)" \
	  $(TWO_WAY_TEST_SOURCES) $(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE) $(ICAL_I386_LIBRARY) \
	  $(LIBVC_I386_LIBRARY) $(DAEMON_LINK_FLAGS) -o "$@"
$(TWO_WAY_TEST_ROOT)/TwoWaySyncTests: $(TWO_WAY_TEST_ROOT)/ppc $(TWO_WAY_TEST_ROOT)/i386
	@$(LIPO) -create $^ -output "$@"
build-mac-two-way-tests: $(TWO_WAY_TEST_ROOT)/TwoWaySyncTests $(SYNC_TEST_VERIFIER)
test-mac-two-way: build-mac-two-way-tests
	@TEST_HOST="$(TEST_HOST)" TWO_WAY_TEST_MODE="$(TWO_WAY_TEST_MODE)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" \
	  /bin/bash "$(SOURCE_ROOT)/tests/macOS/two-way/run-remote.sh"
.PHONY: build-mac-two-way-tests test-mac-two-way
