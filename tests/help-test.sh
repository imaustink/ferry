#!/usr/bin/env bash
# Asking for help changes nothing.
#
# 'ferry up --help' used to start the cluster: cmd_up's flag loop ended in a
# catch-all that dropped what it did not know, so --help and every misspelt
# flag were ignored and up went ahead with the defaults. 'ferry upgrade nodes'
# had the same loop. This runs every command with --help and -h, in a sandbox
# with no cluster and with stubs in front of the tools a command would act
# through, and fails if any of them was called or the command did not print
# its usage and exit 0.
#
# The commands are read from ferry's own dispatcher, so a new one is covered
# without anyone remembering to add it here.
#
#   ./tests/help-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/stubs" "$sandbox/home" "$sandbox/run"

# Anything a command does to a cluster or this Mac goes through one of these.
calls="$sandbox/calls"
: > "$calls"
for tool in kubectl launchctl pkill pgrep curl buildctl swiftc go make codesign; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$calls" > "$sandbox/stubs/$tool"
  chmod +x "$sandbox/stubs/$tool"
done

ferry() {
  PATH="$sandbox/stubs:$PATH" \
  KUBECONFIG="" \
  FERRY_NO_UPDATE_CHECK=1 \
  FERRY_PROFILE=help-test \
  FERRY_PROFILES="$sandbox/profiles" \
  FERRY_HOME="$sandbox/home" \
  FERRY_RUN="$sandbox/run" \
    perl -e 'alarm shift; exec @ARGV' 20 bash "$repo/ferry" "$@" 2>&1 </dev/null
}
# The alarm because a command that went ahead may wait on something that never
# comes: 'ferry up --durability' with no value used to loop forever. It shows
# here as exit 142 (SIGALRM) instead of a test run that never ends.

# Every top-level command the dispatcher at the bottom of ferry knows.
commands="$(awk '/^case "\$\{1:-\}" in/ { on = 1; next }
                 on && /^esac/ { exit }
                 on && match($0, /^  [a-z][a-z-]*[|)]/) { s = substr($0, 3, RLENGTH - 3); print s }' "$repo/ferry")"
# And the ones under them that act.
subcommands="image build|image load|node add|node rm|node ls|upgrade plan|upgrade apply|upgrade node|upgrade nodes|upgrade rollback|upgrade prune|upgrade status|mac-image bake|mac-image status|machines enable|machines disable|service install|service uninstall|profile rm|config set|addons enable|addons disable|token create"

printf '\033[1m%s\033[0m\n' "every command answers --help with its usage, and does nothing else"
count="$(echo "$commands" | wc -l | tr -d ' ')"
if [ "$count" -gt 20 ]; then ok "found $count commands in the dispatcher"
else bad "found only '$commands' in the dispatcher"; fi

check() { # flag words...
  local flag="$1"; shift
  : > "$calls"
  local out code
  out="$(ferry "$@" "$flag")"; code=$?
  local name="ferry $* $flag"
  if [ "$code" != 0 ]; then bad "$name exits 0"; echo "      exited $code:"; echo "$out" | sed 's/^/        /' | head -5; return; fi
  case "$out" in
    *"ferry $1"*) : ;;
    *) bad "$name prints its usage"; echo "$out" | sed 's/^/        /' | head -5; return ;;
  esac
  if [ -s "$calls" ]; then bad "$name touches nothing"; sed 's/^/        called: /' "$calls"; return; fi
  if [ -n "$(ls -A "$sandbox/run")" ]; then bad "$name starts nothing"; ls -A "$sandbox/run" | sed 's/^/        /'; return; fi
  ok "$name"
}

while read -r c; do
  [ -n "$c" ] || continue
  check --help "$c"
  check -h "$c"
done <<< "$commands"
IFS='|' read -ra subs <<< "$subcommands"
for s in "${subs[@]}"; do
  # shellcheck disable=SC2086 # word-split on purpose: 'upgrade nodes' is two words
  check --help $s
done
# After other flags too: --help anywhere means help.
check --help up --disposable
check --help upgrade nodes --to v1.36.0
echo

printf '\033[1m%s\033[0m\n' "a flag up or upgrade nodes does not know is refused, not dropped"
refuses() { # description words...
  local description="$1"; shift
  : > "$calls"
  local out code
  out="$(ferry "$@")"; code=$?
  if [ "$code" = 2 ] && [ ! -s "$calls" ]; then ok "$description"
  else bad "$description"; echo "      exited $code:"; echo "$out" | sed 's/^/        /' | head -5; fi
}
refuses "ferry up --kubernetes-verison v1.36 (misspelt)" up --kubernetes-verison v1.36
refuses "ferry up --durabilty process-crash (misspelt)" up --durabilty process-crash
refuses "ferry up stray" up stray
refuses "ferry up --durability with no value, rather than looping" up --durability
refuses "ferry upgrade nodes --too v1.36.0 (misspelt)" upgrade nodes --too v1.36.0
refuses "ferry upgrade nodes somenode (that is 'upgrade node')" upgrade nodes somenode
refuses "ferry upgrade nodes --to with no version" upgrade nodes --to
refuses "ferry upgrade nodes --to 1.36 (not a version)" upgrade nodes --to 1.36
echo

if [ "$fail" -eq 0 ]; then
  printf '\033[1m%s\033[0m\n' "$pass passed"
else
  printf '\033[1m%s\033[0m\n' "$pass passed, $fail failed"
  exit 1
fi
