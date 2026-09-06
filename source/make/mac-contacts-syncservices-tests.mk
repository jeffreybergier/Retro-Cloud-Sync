# Offline Tiger Sync Services integration test tools and fixtures.

SYNC_TEST_SOURCE_ROOT := $(SOURCE_ROOT)/tests/macOS/contacts-syncservices
SYNC_TEST_BUILD_ROOT := $(BUILD_ROOT)/tests/macOS/contacts-syncservices
SYNC_TEST_VERIFIER_SOURCE := $(SYNC_TEST_SOURCE_ROOT)/ContactsSyncServicesVerifier.m
SYNC_TEST_VERIFIER := $(SYNC_TEST_BUILD_ROOT)/RetroCloudContactsSyncServicesVerifier
SYNC_TEST_FIXTURE_SOURCE := $(SOURCE_ROOT)/tests/fixtures/contacts/ContactsFixtureGenerator.c
SYNC_TEST_FIXTURE_GENERATOR := $(SYNC_TEST_BUILD_ROOT)/RetroCloudContactsFixtureGenerator
SYNC_TEST_INITIAL_DATABASE := $(SYNC_TEST_BUILD_ROOT)/Contacts-initial.sqlite
SYNC_TEST_UPDATED_DATABASE := $(SYNC_TEST_BUILD_ROOT)/Contacts-updated.sqlite
SYNC_TEST_EMPTY_DATABASE := $(SYNC_TEST_BUILD_ROOT)/Contacts-empty.sqlite
SYNC_TEST_PPC_OBJECT := $(SYNC_TEST_BUILD_ROOT)/Intermediates/ppc/ContactsSyncServicesVerifier.o
SYNC_TEST_I386_OBJECT := $(SYNC_TEST_BUILD_ROOT)/Intermediates/i386/ContactsSyncServicesVerifier.o

syncservices-test-config: validate-build $(SYNC_TEST_VERIFIER) \
		$(SYNC_TEST_INITIAL_DATABASE) $(SYNC_TEST_UPDATED_DATABASE) \
		$(SYNC_TEST_EMPTY_DATABASE)

$(SYNC_TEST_VERIFIER): $(SYNC_TEST_BUILD_ROOT)/Intermediates/ppc.bin \
		$(SYNC_TEST_BUILD_ROOT)/Intermediates/i386.bin
	@echo "  > merging Sync Services verifier (ppc, i386)"
	@$(LIPO) -create $^ -output "$@"

$(SYNC_TEST_BUILD_ROOT)/Intermediates/ppc.bin: $(SYNC_TEST_PPC_OBJECT)
	@echo "  > linking Sync Services verifier ppc binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		-arch ppc -isysroot "$(SDK)" $^ \
		-framework Foundation -framework SyncServices -framework AddressBook -lobjc -lgcc_s.10.4 \
		-o "$@"

$(SYNC_TEST_BUILD_ROOT)/Intermediates/i386.bin: $(SYNC_TEST_I386_OBJECT)
	@echo "  > linking Sync Services verifier i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ \
		-framework Foundation -framework SyncServices -framework AddressBook -lobjc -lgcc_s.10.4 \
		-o "$@"

$(SYNC_TEST_PPC_OBJECT): $(SYNC_TEST_VERIFIER_SOURCE)
	@mkdir -p "$(dir $@)"
	@echo "  > compiling Sync Services verifier ppc"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(PPC_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch ppc -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(SYNC_TEST_I386_OBJECT): $(SYNC_TEST_VERIFIER_SOURCE)
	@mkdir -p "$(dir $@)"
	@echo "  > compiling Sync Services verifier i386"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		$(COMMON_FLAGS) $(OPT_FLAGS) -arch i386 -isysroot "$(SDK)" \
		-c "$<" -o "$@"

$(SYNC_TEST_FIXTURE_GENERATOR): $(SYNC_TEST_FIXTURE_SOURCE) \
		$(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCVCard.c \
		$(SHARED_SOURCE_ROOT)/RCContactStore.c $(SHARED_SOURCE_ROOT)/RCWriteJournal.c $(LIBVC_HOST_LIBRARY)
	@mkdir -p "$(dir $@)"
	@echo "  > building Sync Services fixture generator"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		$(LIBVC_FLAGS) -I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include \
		$^ -lpthread -lsqlite3 -o "$@"

$(SYNC_TEST_INITIAL_DATABASE): $(SYNC_TEST_FIXTURE_GENERATOR)
	@rm -f "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" initial "$@"

$(SYNC_TEST_UPDATED_DATABASE): $(SYNC_TEST_INITIAL_DATABASE) \
		$(SYNC_TEST_FIXTURE_GENERATOR)
	@cp "$(SYNC_TEST_INITIAL_DATABASE)" "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" updated "$@"

$(SYNC_TEST_EMPTY_DATABASE): $(SYNC_TEST_UPDATED_DATABASE) \
		$(SYNC_TEST_FIXTURE_GENERATOR)
	@cp "$(SYNC_TEST_UPDATED_DATABASE)" "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" empty "$@"

.PHONY: syncservices-test-config

# Derive every phase from a predecessor to retain production SQLite identities.
SYNC_TEST_EXTRA_PHASES := reordered stripped malformed missing-identity retained interrupted fresh
syncservices-test-config: $(addprefix $(SYNC_TEST_BUILD_ROOT)/Contacts-,$(addsuffix .sqlite,$(SYNC_TEST_EXTRA_PHASES)))
$(SYNC_TEST_BUILD_ROOT)/Contacts-reordered.sqlite: $(SYNC_TEST_INITIAL_DATABASE) $(SYNC_TEST_FIXTURE_GENERATOR)
	@cp "$<" "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" reordered "$@"
$(SYNC_TEST_BUILD_ROOT)/Contacts-stripped.sqlite: $(SYNC_TEST_UPDATED_DATABASE) $(SYNC_TEST_FIXTURE_GENERATOR)
	@cp "$<" "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" stripped "$@"
$(SYNC_TEST_BUILD_ROOT)/Contacts-malformed.sqlite $(SYNC_TEST_BUILD_ROOT)/Contacts-missing-identity.sqlite: $(SYNC_TEST_INITIAL_DATABASE) $(SYNC_TEST_FIXTURE_GENERATOR)
	@cp "$<" "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" "$(patsubst Contacts-%,%,$(basename $(notdir $@)))" "$@"

$(SYNC_TEST_BUILD_ROOT)/Contacts-retained.sqlite $(SYNC_TEST_BUILD_ROOT)/Contacts-interrupted.sqlite: $(SYNC_TEST_INITIAL_DATABASE) $(SYNC_TEST_FIXTURE_GENERATOR)
	@cp "$<" "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" "$(patsubst Contacts-%,%,$(basename $(notdir $@)))" "$@"

$(SYNC_TEST_BUILD_ROOT)/Contacts-fresh.sqlite: $(SYNC_TEST_FIXTURE_GENERATOR)
	@rm -f "$@"
	@"$(SYNC_TEST_FIXTURE_GENERATOR)" fresh "$@"

$(SYNC_TEST_PPC_OBJECT) $(SYNC_TEST_I386_OBJECT): $(DAEMON_SOURCE_ROOT)/RCContactSyncClient.h
