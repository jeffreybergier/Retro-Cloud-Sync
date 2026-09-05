CALENDAR_TEST_OUTPUT := $(BUILD_ROOT)/calendar-test/RetroCloudCalendarTests
CALENDAR_TEST_SOURCES := $(SOURCE_ROOT)/shared-test/CalendarTests.c $(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCICalendar.c $(SHARED_SOURCE_ROOT)/RCCalendarStore.c
$(CALENDAR_TEST_OUTPUT): $(CALENDAR_TEST_SOURCES) $(ICAL_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror $(ICAL_HOST_FLAGS) -I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include $(CALENDAR_TEST_SOURCES) $(ICAL_HOST_LIBRARY) -lsqlite3 -lpthread -o "$@"
test-calendar: $(CALENDAR_TEST_OUTPUT)
	@"$(CALENDAR_TEST_OUTPUT)"
.PHONY: test-calendar
CALENDAR_DAV_TEST := $(BUILD_ROOT)/calendar-test/RetroCloudCalendarDAVTests
CALENDAR_DAV_SOURCES := $(SOURCE_ROOT)/shared-test/CalendarDAVTests.c $(SHARED_SOURCE_ROOT)/RCCalDAVMirror.c $(SHARED_SOURCE_ROOT)/RCDAVClient.c $(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCICalendar.c $(SHARED_SOURCE_ROOT)/RCCalendarStore.c
$(CALENDAR_DAV_TEST): $(CALENDAR_DAV_SOURCES) $(ICAL_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror $(ICAL_HOST_FLAGS) -I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include -I/usr/include/libxml2 $(CALENDAR_DAV_SOURCES) $(ICAL_HOST_LIBRARY) -lsqlite3 -lxml2 -lpthread -o "$@"
test-calendar: calendar-dav-test
calendar-dav-test: $(CALENDAR_DAV_TEST)
	@"$(CALENDAR_DAV_TEST)"
.PHONY: calendar-dav-test
CALENDAR_VERIFIER := $(BUILD_ROOT)/calendar-test/RetroCloudCalendarVerifier
CALENDAR_MAC_FIXTURES := $(BUILD_ROOT)/calendar-test/RetroCloudCalendarFixtures
CALENDAR_VERIFIER_SOURCE := $(SOURCE_ROOT)/macOS-test/CalendarVerifier.m
$(BUILD_ROOT)/calendar-test/verifier-ppc: $(CALENDAR_VERIFIER_SOURCE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) -arch ppc -isysroot "$(SDK)" "$<" -framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(BUILD_ROOT)/calendar-test/verifier-i386: $(CALENDAR_VERIFIER_SOURCE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) -arch i386 -isysroot "$(SDK)" "$<" -framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(CALENDAR_VERIFIER): $(BUILD_ROOT)/calendar-test/verifier-ppc $(BUILD_ROOT)/calendar-test/verifier-i386
	@$(LIPO) -create $^ -output "$@"
$(BUILD_ROOT)/calendar-test/fixtures-ppc: $(CALENDAR_TEST_SOURCES) $(ICAL_PPC_LIBRARY) $(DAEMON_PPC_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) $(ICAL_FLAGS) -I$(ICAL_ROOT)/libical-ppc/src -I$(ALTIVECCORE_ROOT)/include -arch ppc -isysroot "$(SDK)" $(CALENDAR_TEST_SOURCES) $(ICAL_PPC_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) -framework CoreFoundation -framework SystemConfiguration -framework Security -lxml2 -lgcc_s.10.4 -o "$@"
$(BUILD_ROOT)/calendar-test/fixtures-i386: $(CALENDAR_TEST_SOURCES) $(ICAL_I386_LIBRARY) $(DAEMON_I386_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) $(ICAL_FLAGS) -I$(ICAL_ROOT)/libical-i386/src -I$(ALTIVECCORE_ROOT)/include -arch i386 -isysroot "$(SDK)" $(CALENDAR_TEST_SOURCES) $(ICAL_I386_LIBRARY) $(DAEMON_I386_ALTIVECCORE) -framework CoreFoundation -framework SystemConfiguration -framework Security -lxml2 -lgcc_s.10.4 -o "$@"
$(CALENDAR_MAC_FIXTURES): $(BUILD_ROOT)/calendar-test/fixtures-ppc $(BUILD_ROOT)/calendar-test/fixtures-i386
	@$(LIPO) -create $^ -output "$@"
test-calendar-build: $(CALENDAR_VERIFIER) $(CALENDAR_MAC_FIXTURES)
.PHONY: test-calendar-build
CALENDAR_CLIENT_TEST := $(BUILD_ROOT)/calendar-test/RetroCloudCalendarClientTests
CALENDAR_CLIENT_TEST_SOURCE := $(SOURCE_ROOT)/macOS-test/CalendarClientTests.m
$(BUILD_ROOT)/calendar-test/client-ppc: $(CALENDAR_CLIENT_TEST_SOURCE) $(DAEMON_SOURCE_ROOT)/RCCalendarSyncClient.h
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) -arch ppc -isysroot "$(SDK)" "$<" -framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(BUILD_ROOT)/calendar-test/client-i386: $(CALENDAR_CLIENT_TEST_SOURCE) $(DAEMON_SOURCE_ROOT)/RCCalendarSyncClient.h
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) -arch i386 -isysroot "$(SDK)" "$<" -framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(CALENDAR_CLIENT_TEST): $(BUILD_ROOT)/calendar-test/client-ppc $(BUILD_ROOT)/calendar-test/client-i386
	@$(LIPO) -create $^ -output "$@"
test-calendar-client-build: validate-build $(CALENDAR_CLIENT_TEST)
test-calendar-build: test-calendar-client-build
.PHONY: test-calendar-client-build
test-calendar-syncservices: release test-calendar-build
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" bash "$(SOURCE_ROOT)/macOS-test/run-calendar-remote.sh"
.PHONY: test-calendar-syncservices
