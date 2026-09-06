# Standalone Mac HTTPS diagnostic, excluded from offline host tests.
NETWORK_TEST_ROOT := $(BUILD_ROOT)/tests/macOS/network
NETWORK_TEST_SOURCE := $(SOURCE_ROOT)/tests/macOS/network/HTTPSDownloadTest.m
NETWORK_TEST_OUTPUT := $(NETWORK_TEST_ROOT)/RetroCloudHTTPSDownloadTest
NETWORK_TEST_LINK_FLAGS := -framework Foundation -framework CoreFoundation \
	-framework SystemConfiguration -framework Security -lxml2 -lobjc -lgcc_s.10.4

$(NETWORK_TEST_ROOT)/ppc: $(NETWORK_TEST_SOURCE) $(DAEMON_PPC_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(PPC_CC) $(COMMON_FLAGS) $(OPT_FLAGS) \
		-I$(ALTIVECCORE_ROOT)/include -arch ppc -isysroot "$(SDK)" \
		$^ $(NETWORK_TEST_LINK_FLAGS) -o "$@"
$(NETWORK_TEST_ROOT)/i386: $(NETWORK_TEST_SOURCE) $(DAEMON_I386_ALTIVECCORE)
	@mkdir -p "$(dir $@)"
	@MACOSX_DEPLOYMENT_TARGET=10.4 $(I386_CC) $(COMMON_FLAGS) $(OPT_FLAGS) \
		-I$(ALTIVECCORE_ROOT)/include -arch i386 -isysroot "$(SDK)" \
		$^ $(NETWORK_TEST_LINK_FLAGS) -o "$@"
$(NETWORK_TEST_OUTPUT): $(NETWORK_TEST_ROOT)/ppc $(NETWORK_TEST_ROOT)/i386
	@$(LIPO) -create $^ -output "$@"

build-mac-network-tests: validate-build $(NETWORK_TEST_OUTPUT)
test-mac-network: build-mac-network-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" \
		CA_CERTIFICATES="$(ALTIVECCORE_CA_CERTS)" \
		bash "$(SOURCE_ROOT)/tests/macOS/network/run-remote.sh"
.PHONY: build-mac-network-tests test-mac-network
