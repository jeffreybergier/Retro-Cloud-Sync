# Retro-Cloud-Sync

Legacy Mac OS X mail proxy and contacts/calendar synchronization.

Run tests from the Linux build container:

```sh
make test-business-linux
make test-business-mac TEST_HOST=x4-vm
make test-ui-mac TEST_HOST=x4-vm
```

`make test` runs the Linux suite. See [test documentation](source/tests/README.md)
for dependencies, suite membership, narrower targets and Mac desktop requirements.
