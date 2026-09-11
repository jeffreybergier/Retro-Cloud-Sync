# Runs an isolated copy under Desktop, with a fake blocked credential helper.
test-mac-shutdown: daemon-config build-mac-conflict-tests
	@TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" DAEMON_OUTPUT="$(DAEMON_OUTPUT)" \
	  SESSION_TEST_OUTPUT="$(CONFLICT_TEST_ROOT)/ConflictSessionTests" CA_CERTIFICATE="$(ALTIVECCORE_CA_CERTS)" python3 "$(SOURCE_ROOT)/tests/macOS/shutdown/run-remote.py"
.PHONY: test-mac-shutdown
