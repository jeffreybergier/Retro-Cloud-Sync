# Native tests for the portable vCard and SQLite layers.

HOST_CC ?= /usr/bin/cc
SHARED_TEST_BUILD_ROOT := $(BUILD_ROOT)/shared-test
SHARED_TEST_OUTPUT := $(SHARED_TEST_BUILD_ROOT)/RetroCloudSharedTests
SHARED_TEST_SOURCES := $(SOURCE_ROOT)/shared-test/main.c \
	$(SHARED_SOURCE_ROOT)/RCError.c $(SHARED_SOURCE_ROOT)/RCVCard.c \
	$(SHARED_SOURCE_ROOT)/RCContactStore.c

shared-test-run: $(SHARED_TEST_OUTPUT)
	@"$(SHARED_TEST_OUTPUT)"

$(SHARED_TEST_OUTPUT): $(SHARED_TEST_SOURCES)
	@mkdir -p "$(dir $@)"
	@echo "  > building native shared-layer tests"
	@$(HOST_CC) -std=c99 -D_XOPEN_SOURCE=600 -Wall -Wextra -Werror \
		-I$(SHARED_SOURCE_ROOT) -I$(ALTIVECCORE_ROOT)/include \
		$(SHARED_TEST_SOURCES) -lsqlite3 -o "$@"

.PHONY: shared-test-run
