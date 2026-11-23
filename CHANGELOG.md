# Changelog

What changed for someone using ferry, newest first. Releases before v1.0.0 are
described in their [GitHub release notes](https://github.com/imaustink/ferry/releases).
From v1.0.0, what may and may not change between releases is in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## v1.0.0 (unreleased)

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
- Output has no colour codes when it is not going to a terminal, or under
  `NO_COLOR`.

### Added

- **`ferry -p <name>`** (or `--profile`) runs any command against a named
  cluster, so an installed ferry can run several: `ferry -p demo up`.
  **`ferry profile ls`** lists every cluster on the Mac and which are running.
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
