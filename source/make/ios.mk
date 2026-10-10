# Synthetic native-store/UI variants use the same production build graph.
ios-native-tests:
	+$(MAKE) -C $(SOURCE_ROOT)/iOS-daemon release BUILD_ROOT="$(BUILD_ROOT)/iOS-tests" CPPFLAGS=-DRCIOS_NATIVE_TESTS=1 RC_TEST_SOURCE="$(SOURCE_ROOT)/tests/iOS/native-stores/NativeStoreTests.m"
test-ios-native-stores: ios-native-tests
	TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" PROJECT_ROOT="$(PROJECT_ROOT)" python3 $(SOURCE_ROOT)/tests/iOS/native-stores/run-remote.py
ios-ui-tests:
	+$(MAKE) -C $(SOURCE_ROOT)/iOS-daemon release BUILD_ROOT="$(BUILD_ROOT)/iOS-ui-tests" CPPFLAGS=-DRCIOS_UI_TESTS=1 RC_UI_TESTS=1 rCloud_PACKAGES=ipa rCloud_ENTITLEMENTS="$(SOURCE_ROOT)/tests/iOS/Entitlements.plist"
test-ios-ui: ios-ui-tests
	TEST_HOST="$(TEST_HOST)" BUILD_ROOT="$(BUILD_ROOT)" python3 $(SOURCE_ROOT)/tests/iOS/run-ui.py
