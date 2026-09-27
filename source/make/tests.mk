# Test dependencies and compatibility aliases. Every Mac build happens on Linux.

test-host: test-host-contacts test-host-calendars test-host-writes test-host-sync

# Header-only rules and shared record layouts are part of these executables.
# A fast incremental Linux run must not silently reuse a pre-refactor binary.
$(SHARED_TEST_OUTPUT) $(CONTACT_DAV_TEST_OUTPUT) $(VCARD_TEST_OUTPUT) \
$(CALENDAR_TEST_OUTPUT) $(CALENDAR_DAV_TEST) $(WRITE_TEST_OUTPUT) \
$(WRITE_HTTP_OUTPUT) $(SYNC_TEST_OUTPUT): $(wildcard $(SHARED_SOURCE_ROOT)/*.h)

# Compatibility alias for the portable suite.
test: test-business-linux
.PHONY: test

build-mac-tests: build-mac-logging-tests build-mac-network-tests build-mac-app-tests build-mac-contacts-syncservices-tests \
	build-mac-calendars-syncservices-tests build-mac-vcard-tests build-mac-conflict-tests build-mac-two-way-tests

# Keep old commands working during the naming transition.
test-build: build-mac-app-tests
test-debug: build-mac-app-tests-debug
test-analyze: analyze-mac-app-tests
test-gui: test-mac-app
test-shared: test-host-contacts
test-calendar: test-host-calendars
test-syncservices-build: build-mac-contacts-syncservices-tests
test-syncservices-analyze: analyze-mac-contacts-syncservices-tests
test-syncservices: test-mac-contacts-syncservices
test-calendar-build: build-mac-calendars-syncservices-tests
test-calendar-client-build: build-mac-calendar-client-tests
test-calendar-syncservices: test-mac-calendars-syncservices
test-vcard-build: build-mac-vcard-tests
test-vcal-compat: compare-host-libicalvcal
test-vcal-compat-build: build-libicalvcal-comparison
carddav-probe: build-mac-carddav-probe
carddav-probe-debug: build-mac-carddav-probe-debug
caldav-probe: build-mac-caldav-probe

.PHONY: test-host build-mac-tests test-mac-network help \
	test-build \
	test-debug \
	test-analyze \
	test-gui \
	test-shared \
	test-calendar \
	test-syncservices-build \
	test-syncservices-analyze \
	test-syncservices \
	test-calendar-build \
	test-calendar-client-build \
	test-calendar-syncservices \
	test-vcard-build \
	test-vcal-compat \
	test-vcal-compat-build \
	carddav-probe \
	carddav-probe-debug \
	caldav-probe

help:
	@cat "$(SOURCE_ROOT)/tests/help.txt"

include $(SOURCE_ROOT)/make/mac-shutdown-tests.mk
