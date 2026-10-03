# Retro-Cloud-Sync

Legacy Mac OS X mail proxy and contacts/calendar synchronization.

Contacts and Calendars currently publish through Apple's Sync Services. On
the tested OS X 10.9.5 host (`x9-local`), Sync Services rejects this client
before registration (disabled reason 1002), so these modes cannot apply their
mirrors to the local apps. The mail proxy runs independently. Mavericks support
for Contacts and Calendar will require a separate native integration; resetting
the Sync Services database does not restore this bridge.

Run tests from the Linux build container:

```sh
make test-business-linux
make test-business-mac TEST_HOST=x4-vm
make test-ui-mac TEST_HOST=x4-vm
```

`make test` runs the Linux suite. See [test documentation](source/tests/README.md)
for dependencies, suite membership, narrower targets and Mac desktop requirements.

GitHub Actions runs `make test-business-linux` once per branch push. A `vMAJOR.MINOR.PATCH`
tag builds the macOS app ZIP and attaches `Retro-Cloud-Sync-VERSION-macOS.zip`
to its GitHub Release after checking that the tag and app version match. The
release workflow needs three repository secrets containing HTTPS URLs for the
checksum-verified SDK archives: `ALTIVEC_SDK_MACOS_105_URL`,
`ALTIVEC_SDK_MACOS_113_URL`, and `ALTIVEC_SDK_IPHONEOS_84_URL`.
