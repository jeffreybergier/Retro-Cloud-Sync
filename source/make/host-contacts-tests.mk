# Native tests for the portable vCard and SQLite layers.

HOST_CC ?= /usr/bin/cc
SHARED_TEST_BUILD_ROOT := $(BUILD_ROOT)/tests/host/contacts
SHARED_TEST_OUTPUT := $(SHARED_TEST_BUILD_ROOT)/RetroCloudContactStoreTests
SHARED_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/ContactStoreTests.c \
	$(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCVCard.c \
	$(SHARED_SOURCE_ROOT)/RCContactStore.c $(SHARED_SOURCE_ROOT)/RCWriteJournal.c

shared-test-run: $(SHARED_TEST_OUTPUT)
	@"$(SHARED_TEST_OUTPUT)"

$(SHARED_TEST_OUTPUT): $(SHARED_TEST_SOURCES) $(LIBVC_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > building native shared-layer tests"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		$(LIBVC_FLAGS) -I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include \
		$(SHARED_TEST_SOURCES) $(LIBVC_HOST_LIBRARY) -lpthread -lsqlite3 -o "$@"

.PHONY: shared-test-run

CONTACT_DAV_TEST_OUTPUT := $(SHARED_TEST_BUILD_ROOT)/RetroCloudCardDAVMirrorTests
CONTACT_DAV_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/CardDAVMirrorTests.c \
	$(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCVCard.c \
	$(SHARED_SOURCE_ROOT)/RCContactStore.c $(SHARED_SOURCE_ROOT)/RCWriteJournal.c $(SHARED_SOURCE_ROOT)/RCCardDAVMirror.c \
	$(SHARED_SOURCE_ROOT)/RCDAVClient.c $(SHARED_SOURCE_ROOT)/RCDAVSyncState.c

$(CONTACT_DAV_TEST_OUTPUT): $(CONTACT_DAV_TEST_SOURCES) $(LIBVC_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		$(LIBVC_FLAGS) -I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include -I/usr/include/libxml2 \
		$(CONTACT_DAV_TEST_SOURCES) $(LIBVC_HOST_LIBRARY) -lpthread -lsqlite3 -lxml2 -o "$@"

shared-test-run: contact-dav-test
contact-dav-test: $(CONTACT_DAV_TEST_OUTPUT)
	@"$(CONTACT_DAV_TEST_OUTPUT)"
.PHONY: contact-dav-test

VCARD_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/VCardParserTests.c \
	$(SHARED_SOURCE_ROOT)/RCVCard.c $(SHARED_SOURCE_ROOT)/RCError.c
VCARD_TEST_OUTPUT := $(SHARED_TEST_BUILD_ROOT)/RetroCloudVCardParserTests
$(VCARD_TEST_OUTPUT): $(VCARD_TEST_SOURCES) $(LIBVC_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		$(LIBVC_FLAGS) -I$(SHARED_SOURCE_ROOT) $(VCARD_TEST_SOURCES) \
		$(LIBVC_HOST_LIBRARY) -lpthread -o "$@"

vcard-test: $(VCARD_TEST_OUTPUT)
	@"$(VCARD_TEST_OUTPUT)"
shared-test-run: vcard-test

$(BUILD_ROOT)/tests/macOS/vcard/vcard-ppc: $(VCARD_TEST_SOURCES) $(LIBVC_PPC_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(PPC_CC) $(COMMON_FLAGS) $(LIBVC_FLAGS) -arch ppc \
		-isysroot "$(SDK)" -mmacosx-version-min=10.4 $(VCARD_TEST_SOURCES) \
		$(LIBVC_PPC_LIBRARY) -lgcc_s.10.4 -o "$@"
$(BUILD_ROOT)/tests/macOS/vcard/vcard-i386: $(VCARD_TEST_SOURCES) $(LIBVC_I386_LIBRARY)
	@mkdir -p "$(dir $@)"
	@$(I386_CC) $(COMMON_FLAGS) $(LIBVC_FLAGS) -arch i386 \
		-isysroot "$(SDK)" -mmacosx-version-min=10.4 $(VCARD_TEST_SOURCES) \
		$(LIBVC_I386_LIBRARY) -lgcc_s.10.4 -o "$@"
build-mac-vcard-tests: validate-build $(BUILD_ROOT)/tests/macOS/vcard/vcard-ppc \
		$(BUILD_ROOT)/tests/macOS/vcard/vcard-i386
.PHONY: vcard-test build-mac-vcard-tests
