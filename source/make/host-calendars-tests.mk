# Offline host tests for calendar parsing, storage and simulated CalDAV.
CALENDAR_TEST_OUTPUT := $(BUILD_ROOT)/tests/host/calendars/RetroCloudCalendarCodecStoreTests
CALENDAR_FIXTURE_ROOT := $(SOURCE_ROOT)/tests/fixtures/calendars
CALENDAR_COMMON_SOURCES := $(CALENDAR_FIXTURE_ROOT)/CalendarFixtures.c \
	$(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCICalendar.c \
	$(SHARED_SOURCE_ROOT)/RCCalendarStore.c $(SHARED_SOURCE_ROOT)/RCWriteJournal.c
CALENDAR_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/CalendarCodecStoreTests.c \
	$(CALENDAR_COMMON_SOURCES)
CALENDAR_FIXTURE_SOURCES := $(CALENDAR_FIXTURE_ROOT)/CalendarFixtureGenerator.c \
	$(CALENDAR_COMMON_SOURCES)
$(CALENDAR_TEST_OUTPUT): $(CALENDAR_TEST_SOURCES) $(ICAL_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror $(ICAL_HOST_FLAGS) \
		-I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include $(CALENDAR_TEST_SOURCES) $(ICAL_HOST_LIBRARY) \
		-lsqlite3 -lpthread -o "$@"
test-host-calendars: $(CALENDAR_TEST_OUTPUT)
	@"$(CALENDAR_TEST_OUTPUT)"
.PHONY: test-host-calendars
CALENDAR_DAV_TEST := $(BUILD_ROOT)/tests/host/calendars/RetroCloudCalDAVMirrorTests
CALENDAR_DAV_SOURCES := $(SOURCE_ROOT)/tests/portable/CalDAVMirrorTests.c \
	$(SHARED_SOURCE_ROOT)/RCCalDAVMirror.c $(SHARED_SOURCE_ROOT)/RCDAVClient.c $(SHARED_SOURCE_ROOT)/RCDAVSyncState.c $(SHARED_SOURCE_ROOT)/RCDAVStaging.c \
	$(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCICalendar.c \
	$(SHARED_SOURCE_ROOT)/RCCalendarStore.c $(SHARED_SOURCE_ROOT)/RCWriteJournal.c
$(CALENDAR_DAV_TEST): $(CALENDAR_DAV_SOURCES) $(ICAL_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror $(ICAL_HOST_FLAGS) \
		-I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include -I/usr/include/libxml2 \
		$(CALENDAR_DAV_SOURCES) $(ICAL_HOST_LIBRARY) -lsqlite3 -lxml2 -lpthread -o "$@"
test-host-calendars: calendar-dav-test
calendar-dav-test: $(CALENDAR_DAV_TEST)
	@"$(CALENDAR_DAV_TEST)"
.PHONY: calendar-dav-test

$(CALENDAR_TEST_OUTPUT): $(CALENDAR_FIXTURE_ROOT)/CalendarFixtures.h $(CALENDAR_FIXTURE_ROOT)/CalendarTimeFixtures.h
