# Canonical contacts conflict/recovery tests. Synthetic, offline, never shipped.
CONFLICT_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/conflicts
CONFLICT_TEST_SOURCES := $(SOURCE_ROOT)/tests/macOS/contacts-syncservices/ConflictSessionTests.m \
	$(DAEMON_SOURCE_ROOT)/RCSyncConflictSession.m $(DAEMON_SOURCE_ROOT)/RCContactConflictResolver.m
CONFLICT_TEST_HEADERS := $(DAEMON_SOURCE_ROOT)/RCSyncRecordEquality.h \
	$(DAEMON_SOURCE_ROOT)/RCSyncFieldScope.h \
	$(DAEMON_SOURCE_ROOT)/RCSyncConflictSession.h \
	$(DAEMON_SOURCE_ROOT)/RCContactConflictResolver.h $(wildcard $(SHARED_SOURCE_ROOT)/*.h)

$(CONFLICT_TEST_ROOT)/ppc: $(CONFLICT_TEST_SOURCES) $(CONFLICT_TEST_HEADERS) \
	$(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) $(ICAL_PPC_LIBRARY) $(LIBVC_PPC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) $(COMMON_FLAGS) $(OPT_FLAGS) \
		-I$(ALTIVECCORE_ROOT)/include -arch ppc -isysroot "$(SDK)" $(CONFLICT_TEST_SOURCES) \
		$(PPC_SHARED_LIBRARY) $(DAEMON_PPC_ALTIVECCORE) $(ICAL_PPC_LIBRARY) $(LIBVC_PPC_LIBRARY) \
		$(DAEMON_LINK_FLAGS) -o "$@"
$(CONFLICT_TEST_ROOT)/i386: $(CONFLICT_TEST_SOURCES) $(CONFLICT_TEST_HEADERS) \
	$(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE) $(ICAL_I386_LIBRARY) $(LIBVC_I386_LIBRARY)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) $(COMMON_FLAGS) $(OPT_FLAGS) \
		-I$(ALTIVECCORE_ROOT)/include -arch i386 -isysroot "$(SDK)" $(CONFLICT_TEST_SOURCES) \
		$(I386_SHARED_LIBRARY) $(DAEMON_I386_ALTIVECCORE) $(ICAL_I386_LIBRARY) $(LIBVC_I386_LIBRARY) \
		$(DAEMON_LINK_FLAGS) -o "$@"
$(CONFLICT_TEST_ROOT)/ConflictSessionTests: $(CONFLICT_TEST_ROOT)/ppc $(CONFLICT_TEST_ROOT)/i386
	@$(LIPO) -create $^ -output "$@"
build-mac-conflict-tests: $(CONFLICT_TEST_ROOT)/ConflictSessionTests $(SYNC_TEST_VERIFIER)
test-mac-conflicts: build-mac-conflict-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" \
		/bin/bash "$(SOURCE_ROOT)/tests/macOS/contacts-syncservices/run-conflicts-remote.sh"
.PHONY: build-mac-conflict-tests test-mac-conflicts
