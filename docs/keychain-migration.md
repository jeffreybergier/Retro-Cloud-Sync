# Shared Keychain migration

The native credential facade now uses AltivecCocoa's `AIKeychainStore`.
Build against an Altivec engine containing this class and its public header;
the earlier published image alone does not contain this new implementation.
Existing public app APIs and credential names remain unchanged. No saved
credentials are renamed or rewritten just by launching the app.

The C-facing credential API remains in `RCICloudCredentials.h`. Implementations
are MRC Objective-C adapters (`RCICloudCredentials.m` / `RCIOSCredentials.m`).
Mac trusted-application ACL construction stays here; creation labels and the
explicit ACL refresh on Save are forwarded to the shared store. iOS retains
the app access group, service, 4096-byte limit and after-first-unlock/device-only
policy, including updates. Account display checks metadata without reading
passwords. C callers still own and clear the returned password buffer.

Validation on 2026-10-15: clean Mac/iOS debug and release builds, the app's
complete offline suite, and isolated consumer-facade tests on the host Mac
and `x4-vm` (Tiger 10.4.11/PPC) passed. Shared tests are in the sibling engine's
`libs/cocoa/tests/test_keychain_consumers{,_cross}.sh`; they exercise production
facades using disposable Keychains. rCloud's existing-item ACL-edit call is
recorded to avoid an interactive native authorization prompt. Its actual ACL
edit authorization is still unverified; its storage operations are native.
`koolphone5` was unreachable, so phone runtime tests were skipped with user
approval. Cross-build success is not proof of iPhone runtime behavior.

No installed app or existing user credentials were changed by validation.
The engine's `docs/keychain.md` records API choice, source reduction and full
coverage limits. No image was rebuilt or published for this migration.
