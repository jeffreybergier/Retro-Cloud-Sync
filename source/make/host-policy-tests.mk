POLICY_TEST_ROOT := $(BUILD_ROOT)/tests/host/policies
POLICY_TEST_SOURCES := $(SOURCE_ROOT)/tests/portable/PolicyTests.c \
  $(SHARED_SOURCE_ROOT)/RCPhotoCodec.c $(SHARED_SOURCE_ROOT)/RCStatusPolicy.c
$(POLICY_TEST_ROOT)/PolicyTests: $(POLICY_TEST_SOURCES) $(wildcard $(SHARED_SOURCE_ROOT)/*.h)
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
	  -I$(SHARED_SOURCE_ROOT) $(POLICY_TEST_SOURCES) -lsqlite3 -o "$@"
$(POLICY_TEST_ROOT)/ConnectionTests: $(SOURCE_ROOT)/tests/portable/ConnectionTests.c \
  $(SHARED_SOURCE_ROOT)/RCConnection.c $(SHARED_SOURCE_ROOT)/RCConnection.h
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -DRC_CONNECTION_TEST_MAIN -Wall -Wextra -Werror \
	  -I$(SHARED_SOURCE_ROOT) "$<" -o "$@"
test-host-policies: $(POLICY_TEST_ROOT)/PolicyTests $(POLICY_TEST_ROOT)/ConnectionTests
	@"$(POLICY_TEST_ROOT)/PolicyTests"
	@"$(POLICY_TEST_ROOT)/ConnectionTests"
test-host: test-host-policies
.PHONY: test-host-policies

SYNC_POLICY_SOURCES := $(SOURCE_ROOT)/tests/portable/SyncPolicyTests.c $(SHARED_SOURCE_ROOT)/RCSyncPolicy.c
$(POLICY_TEST_ROOT)/SyncPolicyTests: $(SYNC_POLICY_SOURCES) $(SHARED_SOURCE_ROOT)/RCSyncPolicy.h
	@mkdir -p "$(dir $@)"
	@$(HOST_CC) -std=c99 -Wall -Wextra -Werror -I$(SHARED_SOURCE_ROOT) $(SYNC_POLICY_SOURCES) -o "$@"
test-host-sync-policy: $(POLICY_TEST_ROOT)/SyncPolicyTests
	@"$(POLICY_TEST_ROOT)/SyncPolicyTests"
test-host-policies: test-host-sync-policy
.PHONY: test-host-sync-policy
