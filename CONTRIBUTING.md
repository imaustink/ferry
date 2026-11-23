# Contributing to ferry

Thanks for looking. Bug reports, measurements, and pull requests are all
welcome.

## Reporting a bug

Run this on the Mac where it happened and attach the file it writes:

```sh
ferry logs --bundle
```

It holds every component's log, `ferry status`, `ferry doctor`, and what the
API server says is running. It does not hold your credentials, but look
through it before posting. Say what you ran, what you expected, and what
happened. [The bug template](https://github.com/imaustink/ferry/issues/new?template=bug.yml)
asks for exactly that.

Security problems go to a private advisory instead. See [SECURITY.md](SECURITY.md).

## Changing ferry

You need Apple silicon, macOS 26, Swift 6.4, Go 1.26 and `buildctl`
(`brew install buildkit`). [docs/INSTALL.md](docs/INSTALL.md#build-from-source)
covers the build. A checkout in a git worktree gets its own cluster, ports and
state, so it will not disturb one you already run
([docs/PROFILES.md](docs/PROFILES.md)).

```sh
./ferry doctor && ./ferry build && ./ferry up
```

### Tests

```sh
./tests/run.sh              # everything that runs without a cluster: what CI runs
./tests/e2e/runtime.sh      # starts a throwaway cluster; about twelve minutes
```

CI runs `tests/run.sh`, `shellcheck` and the Swift tests on every pull request.
GitHub's runners cannot start a VM, so anything that needs a pod has to be run
on a Mac. Say in the pull request what you ran.

[tests/README.md](tests/README.md) explains the suites. When you fix a bug,
add the check that would have caught it, in the suite that covers that file.

### Style

- The `ferry` CLI is bash and `install.sh` is POSIX `sh`, because the installer
  runs before anything else is on the Mac. Both must pass `shellcheck -S error`.
- Comments say *why*, especially for a choice that looks wrong until you know
  what it prevents. Most of the long ones are there because the obvious version
  was tried and failed.
- A claim about performance links to the experiment that measured it.
- A new environment variable or config key is documented in
  [docs/INSTALL.md](docs/INSTALL.md). A test fails if it is not.

## Releasing

See [Cutting a release](README.md#cutting-a-release). Before publishing:

1. `./tests/run.sh` and `./tests/e2e/runtime.sh` pass on the release commit.
2. The upgrade path [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) promises
   works: on a Mac running the previous release with a workload on it, install
   the draft with
   `FERRY_VERSION=<new> FERRY_DOWNLOAD_BASE=file://$PWD/dist sh install.sh`
   and check the workload is still there and `kubectl` still reaches it.
3. `CHANGELOG.md` has the release's section.
4. After publishing, update the tap:
   `./release/homebrew.sh <version> > ../homebrew-ferry/Formula/ferry.rb`.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
