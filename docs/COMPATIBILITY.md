# What 1.0 promises

From v1.0.0, ferry follows [semantic versioning](https://semver.org) for the
surfaces below. A minor release may add to them. Only a major release removes
or changes one, and the release notes say so first. Anything not listed here
can change in any release.

## Stable

| surface | what is promised |
|---|---|
| **Commands** | every command and flag in `ferry help` keeps its name and meaning. An output meant for people (`status`, `doctor`, `profile`) may change wording. `ferry kubeconfig` printing a path and `ferry config get` printing a value are for scripts, and stay that way. |
| **Installer** | `curl -sfL https://get.ferry.kurpuis.com \| sh -` and every `FERRY_*` variable in [INSTALL.md](INSTALL.md#installing). |
| **Environment** | every variable documented in [INSTALL.md](INSTALL.md) keeps its name, default and meaning. |
| **Config file** | `config.yaml` at `apiVersion: ferry.dev/v1alpha1` and its keys (`ferry config` lists them). A later apiVersion will read this one. |
| **State on disk** | a cluster's data in `~/.ferry` (and `~/.ferry-<profile>`) is carried forward by every later 1.x. Upgrading is running the installer again, or `brew upgrade ferry`. You never have to delete a cluster to upgrade. |
| **Profiles** | `-p <name>` / `FERRY_PROFILE` select the same cluster, ports and state directory across upgrades. |
| **kubeconfig** | the context is called `ferry` for the default cluster and `ferry-<profile>` otherwise. |
| **Kubernetes** | the control plane and kubelet are upstream Kubernetes, with the platform glue in `patches/`. Each ferry release carries one Kubernetes version, said in its release notes and by `ferry version`. A minor ferry release may move to a newer Kubernetes minor, within upstream's supported skew, and the release notes say so. |
| **Labels and RuntimeClasses** | `ferry.dev/mode`, `ferry.dev/gpu`, and the RuntimeClasses `ferry-vm`, `ferry-shared` and `ferry-macos-vm`. |

## Supported upgrade paths

- From **v0.16.0** or any later release to any 1.x: run the installer again.
  This is the path each 1.x release is tested on before it is published.
- From a release before v0.16.0: not tested. Installing v0.16.0 first
  (`FERRY_VERSION=v0.16.0`) and then the latest is the safe route.

## Not covered

These are useful, and can still change in a minor release:

- **Mode 2 machines**: the `Machine` CRD is `v1alpha1`, and its fields may
  change before it is `v1`. See [MACHINES.md](MACHINES.md).
- **macOS pods** (`ferry-macos-vm`) and `ferry mac-image`.
- **Annotations for tuning or debugging**: `ferry.dev/read-ahead-kb`,
  `ferry.dev/debug-*` and the like.
- **The flags and sockets of ferry's own binaries** (`ferry-cri`,
  `ferry-proxy` and the rest). They are driven by the `ferry` CLI, and that is
  the interface.
- **Building from source**: `ferry build`, `ferry kernel`, `ferry node-image`,
  `ferry upgrade apply` and the toolchain they need.
- Everything under `experiments/`.
