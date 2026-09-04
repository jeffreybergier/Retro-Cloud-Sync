# Offline Tiger Sync Services integration test tools and fixtures.

SYNC_TEST_SOURCE_ROOT := $(SOURCE_ROOT)/macOS-test
SYNC_TEST_BUILD_ROOT := $(BUILD_ROOT)/syncservices-test
SYNC_TEST_VERIFIER_SOURCE := $(SYNC_TEST_SOURCE_ROOT)/SyncServicesVerifier.m
SYNC_TEST_VERIFIER := $(SYNC_TEST_BUILD_ROOT)/RetroCloudSyncSyncServicesVerifier
SYNC_TEST_FIXTURE_SOURCE := $(SYNC_TEST_SOURCE_ROOT)/SyncServicesFixture.c
SYNC_TEST_FIXTURE_GENERATOR := $(SYNC_TEST_BUILD_ROOT)/RetroCloudSyncFixtureGenerator
SYNC_TEST_INITIAL_DATABASE := $(SYNC_TEST_BUILD_ROOT)/Contacts-initial.sqlite
SYNC_TEST_UPDATED_DATABASE := $(SYNC_TEST_BUILD_ROOT)/Contacts-updated.sqlite
SYNC_TEST_EMPTY_DATABASE := $(SYNC_TEST_BUILD_ROOT)/Contacts-empty.sqlite
SYNC_TEST_PPC_OBJECT := $(SYNC_TEST_BUILD_ROOT)/Intermediates/ppc/SyncServicesVerifier.o
SYNC_TEST_I386_OBJECT := $(SYNC_TEST_BUILD_ROOT)/Intermediates/i386/SyncServicesVerifier.o

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
		-framework Foundation -framework AddressBook -lobjc -lgcc_s.10.4 \
		-o "$@"

$(SYNC_TEST_BUILD_ROOT)/Intermediates/i386.bin: $(SYNC_TEST_I386_OBJECT)
	@echo "  > linking Sync Services verifier i386 binary"
	@MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) $(I386_CC) \
		-arch i386 -isysroot "$(SDK)" $^ \
		-framework Foundation -framework AddressBook -lobjc -lgcc_s.10.4 \
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
		$(SHARED_SOURCE_ROOT)/RCContactStore.c
	@mkdir -p "$(dir $@)"
	@echo "  > building Sync Services fixture generator"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		-I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include \
		$^ -lsqlite3 -o "$@"

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
