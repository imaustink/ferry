# Changelog

What changed for someone using ferry, newest first. Releases before v1.0.0 are
described in their [GitHub release notes](https://github.com/imaustink/ferry/releases).
From v1.0.0, what may and may not change between releases is in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## Unreleased

### Fixed

- **`ferry up --help` prints help instead of starting the cluster.** `ferry up`
  ignored any flag it did not know, so `--help`, `-h` and a misspelt flag such
  as `--kubernetes-verison` brought the cluster up with the defaults. It now
  refuses an unknown flag with exit 2. `ferry upgrade nodes` had the same
  problem and would have run the upgrade; it is fixed the same way. Every
  command now answers `--help` or `-h` with its usage and does nothing else.
- **`ferry up --durability` with no value is refused** instead of hanging.

## v1.0.1

Kubernetes v1.37.0, control plane v1.37.0, etcd v3.6.5.

### Fixed

- **Machines keep to the Mac's clock after it sleeps.** A machine (mode 2 node)
  that was up across a sleep fell behind by however long the Mac slept and
  stayed there, so its pods disagreed with the Mac about the time: signed
  webhooks were refused as stale and expired tokens were accepted. Its init now
  asks ferry-node for the Mac's time over vsock every 5 seconds and steps the
  clock when it is 2 or more seconds out. A machine that is already running
  gets this when it is recreated.
- **`ferry down --purge` reliably removes the cluster's kubeconfig context.** It
  sometimes left the context behind.

## v1.0.0

Kubernetes v1.37.0, control plane v1.37.0, etcd v3.6.5.

### Changed

- **`kubectl` works as soon as `ferry up` returns.** `ferry up` merges its
  credentials into `~/.kube/config` (or the first file in `$KUBECONFIG`), the
  way `kind create cluster` does. It switches the current context only when
  that loses nothing: there is none, it no longer exists, or it is another
  ferry cluster's. Otherwise it prints the `use-context` line. Opt out with
  `ferry config set mergeKubeconfig false` or `FERRY_MERGE_KUBECONFIG=0`.
- **The installer no longer registers the login agent by default.** Nothing
  starts at login unless you ask: `FERRY_SERVICE=1` on the installer, or
  `ferry service install` later. A Mac that joins a cluster still gets one,
  and an upgrade keeps one that is already registered.
- **`ferry down --purge` removes the cluster's kubeconfig context**, as
  `kind delete cluster` does.
- **An upgrade says when the running cluster still needs a restart.** Running
  the installer under a cluster that is up leaves it on the old release until
  it restarts. `ferry up` and `ferry status` now name the release it is still on,
  and say to run `ferry down && ferry up`. The first upgrade from v0.16.0 or
  earlier says "an earlier ferry", because those releases kept no record.
- Output has no colour codes when it is not going to a terminal, or under
  `NO_COLOR`.

### Added

- **`ferry -p <name>`** (or `--profile`) runs any command against a named
  cluster, so an installed ferry can run several: `ferry -p demo up`.
  **`ferry profile ls`** lists every cluster on the Mac and which are running.
- **`ferry up --kubernetes-version v1.35`** creates a cluster at another
  Kubernetes, like kind's `--image` and minikube's `--kubernetes-version`. A
  release offers v1.34, v1.35, v1.36 and v1.37. It carries the default in its
  tarball and downloads the others, checksummed, the first time a cluster asks.
  `ferry version` lists them. A cluster keeps its version across restarts and
  ferry upgrades.
- **`ferry profile rm <name>`** deletes a stopped cluster and frees its number.
- **`ferry completion zsh|bash|fish`**.
- **`ferry logs --bundle`** collects every component log, ferry's own reports
  and the cluster's state into one tarball for a bug report. `ferry logs` on
  its own lists the components.
- **Homebrew**: `brew install imaustink/ferry/ferry`.
- `ferry up` and `ferry status` say when a newer release is out, at most once
  a day and only on a terminal. `FERRY_NO_UPDATE_CHECK=1` turns it off.
- MIT license.

### Fixed

- `ferry completion fish` exited 1.
