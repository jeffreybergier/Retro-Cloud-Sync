# Shared sync-token protocol and real contact/calendar mirror recovery regressions.
SYNC_TEST_OUTPUT := $(BUILD_ROOT)/tests/host/sync/RetroCloudDAVSyncTests
SYNC_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/DAVSyncTests.c \
	$(SHARED_SOURCE_ROOT)/RCDAVClient.c $(SHARED_SOURCE_ROOT)/RCDAVSyncState.c $(SHARED_SOURCE_ROOT)/RCDAVStaging.c \
	$(SHARED_SOURCE_ROOT)/RCCardDAVMirror.c $(SHARED_SOURCE_ROOT)/RCCalDAVMirror.c \
	$(SHARED_SOURCE_ROOT)/RCContactStore.c $(SHARED_SOURCE_ROOT)/RCCalendarStore.c \
	$(SHARED_SOURCE_ROOT)/RCVCard.c $(SHARED_SOURCE_ROOT)/RCICalendar.c \
	$(SHARED_SOURCE_ROOT)/RCWriteJournal.c $(SHARED_SOURCE_ROOT)/RCError.c
$(SYNC_TEST_OUTPUT): $(SYNC_TEST_SOURCES) $(wildcard $(SHARED_SOURCE_ROOT)/*.h) $(ICAL_HOST_LIBRARY) $(LIBVC_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror $(ICAL_HOST_FLAGS) $(LIBVC_FLAGS) \
		-I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include -I/usr/include/libxml2 \
		$(SYNC_TEST_SOURCES) $(ICAL_HOST_LIBRARY) $(LIBVC_HOST_LIBRARY) -lsqlite3 -lxml2 -lpthread -o "$@"
test-host-sync: $(SYNC_TEST_OUTPUT)
	@"$(SYNC_TEST_OUTPUT)"
.PHONY: test-host-sync
