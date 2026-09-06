# Offline Mac integration tools; shared fixture definitions come from host-calendars-tests.mk.
CALENDAR_MAC_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/calendars-syncservices
CALENDAR_VERIFIER := $(CALENDAR_MAC_TEST_ROOT)/RetroCloudCalendarSyncServicesVerifier
CALENDAR_MAC_FIXTURES := $(CALENDAR_MAC_TEST_ROOT)/RetroCloudCalendarFixtureGenerator
CALENDAR_VERIFIER_SOURCE := $(SOURCE_ROOT)/tests/macOS/calendars-syncservices/CalendarSyncServicesVerifier.m
$(CALENDAR_MAC_TEST_ROOT)/verifier-ppc: $(CALENDAR_VERIFIER_SOURCE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) -arch ppc -isysroot "$(SDK)" "$<" \
		-framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(CALENDAR_MAC_TEST_ROOT)/verifier-i386: $(CALENDAR_VERIFIER_SOURCE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) -arch i386 -isysroot "$(SDK)" "$<" \
		-framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(CALENDAR_VERIFIER): $(CALENDAR_MAC_TEST_ROOT)/verifier-ppc $(CALENDAR_MAC_TEST_ROOT)/verifier-i386
	@$(LIPO) -create $^ -output "$@"
$(CALENDAR_MAC_TEST_ROOT)/fixtures-ppc: $(CALENDAR_FIXTURE_SOURCES) $(ICAL_PPC_LIBRARY) \
	$(DAEMON_PPC_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) $(ICAL_FLAGS) \
		-I$(ICAL_ROOT)/libical-ppc/src -I$(ALTIVECCORE_ROOT)/include -arch ppc -isysroot "$(SDK)" \
		$(CALENDAR_FIXTURE_SOURCES) $(ICAL_PPC_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) -framework CoreFoundation \
		-framework SystemConfiguration -framework Security -lxml2 -lgcc_s.10.4 -o "$@"
$(CALENDAR_MAC_TEST_ROOT)/fixtures-i386: $(CALENDAR_FIXTURE_SOURCES) $(ICAL_I386_LIBRARY) \
	$(DAEMON_I386_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) $(ICAL_FLAGS) \
		-I$(ICAL_ROOT)/libical-i386/src -I$(ALTIVECCORE_ROOT)/include -arch i386 -isysroot "$(SDK)" \
		$(CALENDAR_FIXTURE_SOURCES) $(ICAL_I386_LIBRARY) $(DAEMON_I386_ALTIVECCORE) -framework \
		CoreFoundation -framework SystemConfiguration -framework Security -lxml2 -lgcc_s.10.4 -o "$@"
$(CALENDAR_MAC_FIXTURES): $(CALENDAR_MAC_TEST_ROOT)/fixtures-ppc $(CALENDAR_MAC_TEST_ROOT)/fixtures-i386
	@$(LIPO) -create $^ -output "$@"
build-mac-calendars-syncservices-tests: $(CALENDAR_VERIFIER) $(CALENDAR_MAC_FIXTURES)
.PHONY: build-mac-calendars-syncservices-tests
CALENDAR_CLIENT_TEST := $(CALENDAR_MAC_TEST_ROOT)/RetroCloudCalendarClientRegistrationTests
CALENDAR_CLIENT_TEST_SOURCE := \
	$(SOURCE_ROOT)/tests/macOS/calendars-syncservices/CalendarClientRegistrationTests.m
$(CALENDAR_MAC_TEST_ROOT)/client-ppc: $(CALENDAR_CLIENT_TEST_SOURCE) \
	$(DAEMON_SOURCE_ROOT)/RCCalendarSyncClient.h
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) -arch ppc -isysroot "$(SDK)" "$<" \
		-framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(CALENDAR_MAC_TEST_ROOT)/client-i386: $(CALENDAR_CLIENT_TEST_SOURCE) \
	$(DAEMON_SOURCE_ROOT)/RCCalendarSyncClient.h
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) -arch i386 -isysroot "$(SDK)" "$<" \
		-framework Foundation -framework SyncServices -lobjc -lgcc_s.10.4 -o "$@"
$(CALENDAR_CLIENT_TEST): $(CALENDAR_MAC_TEST_ROOT)/client-ppc $(CALENDAR_MAC_TEST_ROOT)/client-i386
	@$(LIPO) -create $^ -output "$@"
build-mac-calendar-client-tests: validate-build $(CALENDAR_CLIENT_TEST)
build-mac-calendars-syncservices-tests: build-mac-calendar-client-tests
.PHONY: build-mac-calendar-client-tests
test-mac-calendars-syncservices: release build-mac-calendars-syncservices-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" bash \
		"$(SOURCE_ROOT)/tests/macOS/calendars-syncservices/run-remote.sh"
.PHONY: test-mac-calendars-syncservices

$(CALENDAR_MAC_TEST_ROOT)/fixtures-ppc $(CALENDAR_MAC_TEST_ROOT)/fixtures-i386: \
	$(CALENDAR_FIXTURE_ROOT)/CalendarFixtures.h
