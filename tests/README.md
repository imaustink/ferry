# Tests

Three kinds, from cheapest to most real.

```sh
./tests/run.sh               # everything that runs without starting a cluster
./tests/e2e/runtime.sh       # starts a throwaway cluster and tests against it
```

## Without a cluster: `tests/run.sh`

It runs, in order:

1. **The shell suites**, every `tests/*-test.sh`. Some check behaviour — they
   run a piece of `ferry` for real against a scratch directory, a fake release,
   or a `kubectl` that records its calls. Some check that a line exists where it
   has to, because the thing it prevents was found once and cost someone a day.
   Each file's header says what it covers. A few do more when a cluster is up
   (`image-identity`, `builder-access`, `share-process-namespace`) and say so
   when one is not.
2. **`go vet` and `go test` in every Go module** outside `experiments/`.
3. **`swift test` in ferry-cri and ferry-node**, through `tests/swift.sh`. The
   first run builds both packages in debug, which takes minutes; after that it
   is seconds. `FERRY_TEST_SWIFT=0` leaves it out.

It needs Go and Swift to run all of it, and skips a kind whose toolchain is
missing rather than failing. `expect`, which macOS ships, drives `ferry init`
through a terminal in `cli-test.sh`; without it those checks are skipped.

**`tests/swift.sh <package>`** runs one package's Swift tests. It is there
because the tests use swift-testing, and with only the Command Line Tools
installed SwiftPM does not find swift-testing's macro plugin — the build fails
with `plugin for module 'TestingMacros' not found`. The script names the plugin
and framework paths when that is the toolchain.

## Against a cluster: `tests/e2e/`

**`tests/e2e/runtime.sh`** covers the RuntimeClasses, ferry's config file,
the default runtime and a Machine's durability ([docs/RUNTIMES.md](../docs/RUNTIMES.md)).
It brings up a profile called `e2e-runtime` — its own ports, state directory
and pod network, beside any cluster you already run — and goes through:

| | |
|---|---|
| A | a cluster from before the config file: its marker files are migrated on `ferry up` |
| B | `ferry init` answered at a terminal |
| C | `defaultRuntime: ferry-vm` — placement, pod overhead, a machine provisioned for `ferry-shared`, a `nodeSelector`-only pod held Pending, a wrong handler refused |
| D | a Machine's `durability` reaching its disk, and the full barrier's cost measured |
| E | the builder and the registry addon, which name `ferry-vm` |
| F | the default switched to `ferry-shared` on the running cluster |
| G | `ferry-shared` with machines turned off and on again, and `none` |
| H | `--purge` keeping the config; `--disposable` and `--fast` |

It needs a checkout built with mode 2 (`ferry build`, `ferry node-image`) and
pulls busybox, registry and buildkit images. About twelve minutes. It skips if
mode 2 is not built, refuses to touch a state directory it did not create, and
takes the cluster down on exit, pass or fail. `FERRY_E2E_KEEP=1` leaves it up
to look at; `FERRY_E2E_PROFILE` names a different profile.

It is not part of `run.sh`, which never starts a cluster.
