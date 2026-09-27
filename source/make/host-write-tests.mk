WRITE_TEST_ROOT := $(BUILD_ROOT)/tests/host/writes
WRITE_TEST_OUTPUT := $(WRITE_TEST_ROOT)/RetroCloudWriteSafetyTests
WRITE_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/WriteSafetyTests.c \
	$(SHARED_SOURCE_ROOT)/RCWriteJournal.c $(SHARED_SOURCE_ROOT)/RCDAVWriter.c \
	$(SHARED_SOURCE_ROOT)/RCConflictRecovery.c \
	$(SHARED_SOURCE_ROOT)/RCResourcePatch.c $(SHARED_SOURCE_ROOT)/RCVCard.c \
	$(SHARED_SOURCE_ROOT)/RCICalendar.c $(SHARED_SOURCE_ROOT)/RCError.c \
	$(SHARED_SOURCE_ROOT)/RCContactStore.c $(SHARED_SOURCE_ROOT)/RCCalendarStore.c
$(WRITE_TEST_OUTPUT): $(WRITE_TEST_SOURCES) $(ICAL_HOST_LIBRARY) $(LIBVC_HOST_LIBRARY) \
	$(SHARED_SOURCE_ROOT)/RCWriteJournal.h $(SHARED_SOURCE_ROOT)/RCDAVWriter.h \
	$(SHARED_SOURCE_ROOT)/RCResourcePatch.h $(SHARED_SOURCE_ROOT)/RCConflictRecovery.h
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror $(ICAL_HOST_FLAGS) $(LIBVC_FLAGS) \
		-I$(SHARED_SOURCE_ROOT) $(WRITE_TEST_SOURCES) \
		$(ICAL_HOST_LIBRARY) $(LIBVC_HOST_LIBRARY) -lsqlite3 -lpthread -o "$@"
test-host-writes: $(WRITE_TEST_OUTPUT)
	@"$(WRITE_TEST_OUTPUT)"
.PHONY: test-host-writes

WRITE_HTTP_OUTPUT := $(WRITE_TEST_ROOT)/RetroCloudWriteHTTPTests
WRITE_HTTP_SOURCES := $(SOURCE_ROOT)/tests/portable/WriteHTTPTests.c \
	$(SHARED_SOURCE_ROOT)/RCHTTPClient.c $(SHARED_SOURCE_ROOT)/RCWriteJournal.c \
	$(SHARED_SOURCE_ROOT)/RCError.c
$(WRITE_HTTP_OUTPUT): $(WRITE_HTTP_SOURCES) $(SHARED_SOURCE_ROOT)/RCHTTPClient.h
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror -Wno-deprecated-declarations \
		-I$(SHARED_SOURCE_ROOT) $(WRITE_HTTP_SOURCES) \
		-lcurl -lsqlite3 -o "$@"
test-host-writes: test-host-write-http
test-host-write-http: $(WRITE_HTTP_OUTPUT)
	@python3 "$(SOURCE_ROOT)/tests/portable/run-write-http-tests.py" "$(WRITE_HTTP_OUTPUT)"
.PHONY: test-host-write-http
