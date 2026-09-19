#!/bin/sh
# ferry installer.
#
#   curl -sfL https://get.ferry.kurpuis.com | sh -
#
# and to add this Mac to a cluster already running on another:
#
#   curl -sfL https://get.ferry.kurpuis.com | FERRY_URL=mac1.local:6443 FERRY_TOKEN=F10... sh -
#
# This downloads a release rather than building one. Building ferry needs Swift
# 6.4, Go, a Kubernetes source tree and, for the guest kernel, Docker -- which
# is a reasonable thing to ask of someone changing ferry and an unreasonable
# thing to ask of someone trying it. The release carries the kubelet, the
# control plane, etcd, the runtime and the guest kernel already built.
#
# Written for /bin/sh, not bash: this is the one file that runs before ferry is
# on the machine, so it assumes nothing beyond what macOS ships.
#
# Environment:
#   FERRY_VERSION       the release to install, default the latest published
#   FERRY_URL           an existing cluster's API server; makes this a join
#   FERRY_TOKEN         the token from 'ferry token create' on that cluster
#   FERRY_NODE_NAME     what to call this node, default the Mac's short hostname
#   FERRY_INSTALL_DIR   where releases are unpacked, default ~/.ferry-dist
#   FERRY_BIN_DIR       where 'ferry' is linked, default the first writable of
#                       /usr/local/bin then ~/.local/bin
#   FERRY_SKIP_START    1 to install without starting a cluster
#   FERRY_SKIP_SERVICE  1 to not register the LaunchAgent that starts at login
#   FERRY_SKIP_KUBECTL  1 to not install kubectl even if it is missing
#   FERRY_DOWNLOAD_BASE where to fetch the tarball and its checksum from,
#                       instead of this release's GitHub URL. For a mirror, an
#                       air-gapped copy, or a release being tested before it is
#                       published: a file:// URL works. Needs FERRY_VERSION,
#                       since there is no releases API behind it to ask.
set -eu

REPO="${FERRY_REPO:-imaustink/ferry}"
INSTALL_DIR="${FERRY_INSTALL_DIR:-$HOME/.ferry-dist}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# --- can this Mac run ferry at all ---------------------------------------
#
# Checked before anything is downloaded. A 300MB download that ends in "this
# needs Apple silicon" is a worse way to learn it than a line of output.
preflight() {
  [ "$(uname -s)" = Darwin ] || die "ferry runs on macOS; this is $(uname -s)"
  [ "$(uname -m)" = arm64 ] \
    || die "ferry needs Apple silicon -- a pod is a Virtualization.framework VM (this is $(uname -m))"

  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "$major" -lt 26 ] 2>/dev/null; then
    die "ferry needs macOS 26 or newer (this is $(sw_vers -productVersion)). Routable per-pod addressing uses VZVmnetNetworkDeviceAttachment, which is 26+."
  fi
  ok "macOS $(sw_vers -productVersion) on Apple silicon"

  command -v curl >/dev/null || die "curl is required"
  command -v tar  >/dev/null || die "tar is required"

  # A pod is a VM and the hypervisor stops at 128 of them, shared with every
  # other app on the Mac. Worth saying now rather than at the 129th pod.
  if pgrep -f "com.docker.virtualization" >/dev/null 2>&1; then
    warn "Docker Desktop is running and holds one of the Mac's 128 VM slots"
  fi

  free="$(df -g "$HOME" | tail -1 | awk '{print $4}')"
  [ "$free" -ge 20 ] 2>/dev/null \
    || warn "${free}G free disk; images and pod root filesystems will want more"
}

# --- which release ---------------------------------------------------------
resolve_version() {
  if [ -n "${FERRY_VERSION:-}" ]; then echo "$FERRY_VERSION"; return; fi
  [ -z "${FERRY_DOWNLOAD_BASE:-}" ] \
    || die "FERRY_DOWNLOAD_BASE needs FERRY_VERSION too -- there is no releases API behind it to ask which version to take"
  # The API rather than the /latest redirect: the redirect follows the newest
  # release including a draft the maintainer has not finished, and installing
  # something that is still being written is not a thing an installer should do.
  v="$(curl -sfL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$v" ] || die "could not find a published release of $REPO. Name one: FERRY_VERSION=vX.Y.Z"
  echo "$v"
}

# --- download and verify ---------------------------------------------------
#
# ROOT and BINDIR are set rather than printed. These functions report progress
# as they go, and a function that both narrates and returns a value through
# stdout returns the narration too.
ROOT=""
BINDIR=""

fetch() {
  version="$1"
  tarball="ferry-$version-darwin-arm64.tar.gz"
  base="${FERRY_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$version}"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # $tmp is wanted now, not at trap time
  trap "rm -rf '$tmp'" EXIT INT TERM

  bold "downloading ferry $version"
  curl -fL# -o "$tmp/$tarball" "$base/$tarball" \
    || die "could not download $base/$tarball"
  curl -sfL -o "$tmp/$tarball.sha256" "$base/$tarball.sha256" \
    || die "could not download the checksum for $tarball"

  # The checksum comes from the same place as the tarball, so it proves the
  # download completed rather than proving the release is trustworthy. TLS to
  # github.com is what does the second part. Both matter: a truncated 300MB
  # download is far more likely here than a compromised one, and its symptom
  # without this is a kubelet that will not launch.
  ( cd "$tmp" && shasum -a 256 -c "$tarball.sha256" >/dev/null 2>&1 ) \
    || die "$tarball does not match its checksum -- the download was corrupted; try again"
  ok "checksum verified"

  mkdir -p "$INSTALL_DIR/versions"
  target="$INSTALL_DIR/versions/ferry-$version"
  # A partial unpack left behind by an interrupted install reads as an installed
  # release, so unpack beside it and rename. A rename is atomic; a tar is not.
  rm -rf "$target.incoming" "$target"
  mkdir -p "$target.incoming"
  tar -xzf "$tmp/$tarball" -C "$target.incoming" --strip-components=1 \
    || die "could not unpack $tarball"
  mv "$target.incoming" "$target"

  # curl does not set com.apple.quarantine, but a browser does, and someone who
  # downloaded the tarball by hand and ran this script against it would get
  # binaries macOS kills on launch with no useful message. Clearing it costs
  # nothing when there is nothing to clear.
  xattr -d -r com.apple.quarantine "$target" 2>/dev/null || true

  ln -sfn "versions/ferry-$version" "$INSTALL_DIR/current"
  ok "unpacked to $target"

  # Everything from here on goes through 'current', never through the version
  # directory, and that is load-bearing rather than tidy. ferry takes its root
  # from the path it was invoked by, and the LaunchAgent plist records that
  # path once and reads it at every login. Registering the agent by way of
  # .../versions/ferry-v0.1.0/ferry pins the cluster to v0.1.0 forever: the next
  # install would move 'current', move the launcher, and leave the agent still
  # starting the old release at every login -- with nothing saying so, because
  # both are a working ferry.
  ROOT="$INSTALL_DIR/current"
}

# --- put ferry on PATH -----------------------------------------------------
#
# No sudo. Nothing in ferry needs root except the fallback Service proxy, and an
# installer that asks for a password teaches the wrong thing about what this is.
link_cli() {
  if [ -n "${FERRY_BIN_DIR:-}" ]; then
    bindir="$FERRY_BIN_DIR"
    mkdir -p "$bindir" || die "cannot write to $FERRY_BIN_DIR"
  elif [ -w /usr/local/bin ] || { [ ! -e /usr/local/bin ] && [ -w /usr/local ]; }; then
    mkdir -p /usr/local/bin; bindir=/usr/local/bin
  else
    mkdir -p "$HOME/.local/bin"; bindir="$HOME/.local/bin"
  fi

  # Into 'current', not into this version: upgrading ferry then moves every
  # link at once by moving one symlink.
  ln -sfn "$INSTALL_DIR/current/ferry" "$bindir/ferry"
  ok "ferry linked into $bindir"

  case ":$PATH:" in
    *":$bindir:"*) ;;
    *)
      warn "$bindir is not on your PATH"
      echo "      echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zshrc && exec zsh"
      ;;
  esac
  BINDIR="$bindir"
}

# kubectl is how anyone talks to the cluster, and a Kubernetes distribution that
# leaves you to find one has not finished installing. Matched to the cluster's
# own version rather than whatever is newest.
install_kubectl() {
  root="$ROOT"; bindir="$BINDIR"
  [ "${FERRY_SKIP_KUBECTL:-}" = 1 ] && return 0
  if command -v kubectl >/dev/null; then ok "kubectl already installed"; return 0; fi

  k8s="$(sed -n 's/^kubernetes=//p' "$root/VERSION" | head -1)"
  [ -n "$k8s" ] || { warn "could not tell which kubectl to install; install one yourself"; return 0; }
  url="https://dl.k8s.io/release/$k8s/bin/darwin/arm64/kubectl"
  tmpk="$(mktemp -d)"
  if curl -sfL -o "$tmpk/kubectl" "$url" \
     && curl -sfL -o "$tmpk/kubectl.sha256" "$url.sha256" \
     && [ "$(shasum -a 256 "$tmpk/kubectl" | awk '{print $1}')" = "$(cat "$tmpk/kubectl.sha256")" ]; then
    chmod +x "$tmpk/kubectl"
    mv "$tmpk/kubectl" "$bindir/kubectl"
    ok "kubectl $k8s installed into $bindir"
  else
    warn "could not install kubectl; get one from https://kubernetes.io/docs/tasks/tools/"
  fi
  rm -rf "$tmpk"
}

# --- start ------------------------------------------------------------------
start() {
  root="$ROOT"
  if [ "${FERRY_SKIP_START:-}" = 1 ]; then
    echo
    bold "installed"
    echo "  ferry up          start a cluster"
    echo "  ferry doctor      check this Mac first"
    return 0
  fi

  echo
  if [ -n "${FERRY_URL:-}" ]; then
    [ -n "${FERRY_TOKEN:-}" ] \
      || die "FERRY_URL was set without FERRY_TOKEN. Get one with 'ferry token create' on the other Mac."
    # 'ferry join' refuses to run over SSH on its own account, and explains why
    # far better than this script could, so it is left to do that.
    set -- join --server "$FERRY_URL" --token "$FERRY_TOKEN"
    [ -n "${FERRY_NODE_NAME:-}" ] && set -- "$@" --node-name "$FERRY_NODE_NAME"
  else
    set -- up
  fi

  # The cluster first, the agent second.
  #
  # Registering the agent starts a cluster -- launchd's RunAtLoad does, whatever
  # the intent -- so doing it first and then running 'ferry up' here puts two
  # cmd_up runs against one etcd, one set of certificates and one vmnet subnet.
  # Started first, the agent finds a healthy cluster and holds it.
  "$root/ferry" "$@" || return 1

  if [ "${FERRY_SKIP_SERVICE:-}" != 1 ]; then
    "$root/ferry" service install --quiet \
      || warn "could not register the login agent; ferry still runs by hand"
  fi
}

main() {
  bold "ferry -- Kubernetes on a Mac, one virtual machine per pod"
  preflight
  version="$(resolve_version)"
  fetch "$version"
  link_cli
  install_kubectl
  start
}

main "$@"
