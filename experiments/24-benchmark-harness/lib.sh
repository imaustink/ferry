#!/usr/bin/env bash
# Measurement helpers shared by every stack driver.
#
# The three stacks put their memory in different places -- ferry in native
# macOS processes plus one Virtualization.framework VM per pod, kind and
# minikube inside Docker Desktop's VM -- so nothing but a host-wide number
# compares them directly. Every measurement here is taken from the host.

BENCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${RESULTS:-$BENCH_HOME/results}"
FERRY="${FERRY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ferry}"
mkdir -p "$RESULTS"

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

# Host memory in use: active + wired + compressed, the number that is actually
# gone from the machine. macOS on arm64 pages are 16 KiB.
used_mib() {
  vm_stat | awk -F: '
    /Pages active/      {a=$2}
    /Pages wired down/  {w=$2}
    /occupied by compressor/ {c=$2}
    END {gsub(/[ .]/,"",a); gsub(/[ .]/,"",w); gsub(/[ .]/,"",c);
         printf "%.0f", (a+w+c)*16384/1048576}'
}

# Every Virtualization.framework VM on the machine. Docker Desktop's VM is one
# of these and so is each ferry pod, which is what makes them comparable.
vm_pids() {
  ps -Ao pid=,comm= | awk '/Virtualization.VirtualMachine/ {print $1}'
}

# The VMs belonging to the ferry under test, identified by what they have open.
#
# "every VM that is not Docker's" was the old rule, and it is wrong on any
# machine running more than one ferry -- which is every machine with more than
# one worktree. Measured while writing this: three pod VMs from the default
# profile, one from another worktree's, and a Claude sandbox VM, all of which
# the old rule charged to the cluster under test. That is 3.5 GiB of somebody
# else's memory in ferry's column, on its way into a README.
#
# A ferry pod VM keeps its disks under FERRY_RUN/cri; a machine node's are
# under FERRY_RUN or FERRY_HOME. A VM with none of those open is not ours,
# whoever it belongs to.
ferry_vm_pids() {
  local run home pid
  run="${FERRY_RUN:-/tmp/ferry-run${FERRY_PROFILE:+-$FERRY_PROFILE}}"
  home="$(dirname "$("$FERRY" kubeconfig 2>/dev/null)")"
  [ -d "$home" ] || home="${FERRY_HOME:-$HOME/.ferry}"
  for pid in $(vm_pids); do
    if lsof -p "$pid" 2>/dev/null | grep -qF -e "$run/" -e "$home/"; then
      echo "$pid"
    fi
  done
}

# phys_footprint -- what macOS charges a process, resident minus the shared
# pages every VM process maps its own copy of. Slow (~1-3s per VM process),
# so it is taken at rest rather than sampled.
footprint_mib() {
  local total=0 pid
  for pid in "$@"; do
    [ -z "$pid" ] && continue
    total=$(vmmap --summary "$pid" 2>/dev/null | awk -v t="$total" '
      /^Physical footprint:/ {
        v=$3; u=substr(v,length(v)); n=substr(v,1,length(v)-1)
        if (u=="G") n*=1024; else if (u=="K") n/=1024; else if (u!="M") n=v
        t+=n; exit}
      END {printf "%.1f", t}')
  done
  echo "$total"
}

# Cumulative CPU seconds a pid set has consumed, from ps cputime.
#
# The honest basis for "what does this cost when nothing is happening".
# `ps %cpu` below is a decaying average over a window the kernel chooses and
# does not publish, so it cannot be compared between a stack that has just
# finished a burst and one that has been resting -- which is exactly the
# comparison the idle rows make. Two readings of this, over the wall time
# between them, is an average over a window we picked.
#
# macOS prints cputime as [[dd-]hh:]mm:ss.ss.
cpu_seconds_of() {
  local args=() pid
  for pid in "$@"; do [ -n "$pid" ] && args+=(-p "$pid"); done
  [ ${#args[@]} -eq 0 ] && { echo 0; return; }
  ps -o cputime= "${args[@]}" 2>/dev/null | awk '
    { gsub(/^ +/, ""); gsub(/-/, ":")
      n = split($1, a, ":"); s = 0
      if      (n == 4) s = a[1]*86400 + a[2]*3600 + a[3]*60 + a[4]
      else if (n == 3) s = a[1]*3600 + a[2]*60 + a[3]
      else if (n == 2) s = a[1]*60 + a[2]
      else             s = a[1]
      t += s }
    END { printf "%.2f", t+0 }'
}

# Sum of %CPU across a pid set.
cpu_of() {
  local args=() pid
  for pid in "$@"; do [ -n "$pid" ] && args+=(-p "$pid"); done
  [ ${#args[@]} -eq 0 ] && { echo 0; return; }
  ps -o %cpu= "${args[@]}" 2>/dev/null | awk '{t+=$1} END {printf "%.1f", t+0}'
}

# ferry's native control plane and runtime, for the checkout under test.
#
# Anchored on this checkout's bin directory. Matching 'bin/etcd' alone also
# matches another worktree's etcd, an installed release's, and anything else
# on the machine that keeps a binary by that name under a bin -- the same
# mistake ferry_vm_pids documents, arrived at from the process table instead
# of the VM list. FERRY is this harness's ferry, so its bin is the only one
# these numbers should include.
ferry_host_pids() {
  local bin; bin="$(cd "$(dirname "$FERRY")" && pwd)/bin"
  pgrep -f "^$bin/(etcd|kube-apiserver|kube-controller-manager|kube-scheduler|kubelet|ferry-cri|ferry-streamer|ferry-proxyd|ferry-netpol|ferry-storage|ferry-gpud|ferry-proxy|ferry-machined|ferry-node|ferry-karpenter)" 2>/dev/null
}

# Docker Desktop's own processes on the host side (its VM is found separately).
docker_host_pids() {
  pgrep -f 'Docker.app/Contents/MacOS/(com.docker.backend|com.docker.virtualization|com.docker.build)' 2>/dev/null
}

# Wait until every node is Ready and no kube-system pod is still coming up.
# Returns non-zero if it never settles.
wait_ready() { # kubeconfig context timeout_s
  local kc="$1" ctx="$2" limit="${3:-300}" start deadline
  start=$(date +%s); deadline=$((start + limit))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if k "$kc" "$ctx" get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
       | grep -qv False; then
      local nodes ready
      nodes=$(k "$kc" "$ctx" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
      ready=$(k "$kc" "$ctx" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
      if [ "$nodes" -gt 0 ] && [ "$nodes" = "$ready" ]; then
        # and the system pods the distro considers part of a working cluster
        local pending
        pending=$(k "$kc" "$ctx" get pods -n kube-system --no-headers 2>/dev/null \
          | awk '$3!="Running" && $3!="Completed"' | wc -l | tr -d ' ')
        [ "${pending:-1}" = 0 ] && return 0
      fi
    fi
    sleep 1
  done
  return 1
}

k() { # kubeconfig context args...
  local kc="$1" ctx="$2"; shift 2
  if [ -n "$ctx" ]; then KUBECONFIG="$kc" kubectl --context "$ctx" "$@"
  else KUBECONFIG="$kc" kubectl "$@"; fi
}

# Let the machine settle so a footprint reading is not chasing a boot.
quiesce() { sleep "${1:-45}"; }

record() { # tag key value
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$RESULTS/raw.tsv"
}

# Resident set, summed. Page-precise, unlike vmmap's two significant decimals
# -- which on Docker Desktop's 8 GiB VM process resolve to about 100 MiB and so
# cannot see a cluster appear inside it. RSS double-counts the shared framework
# pages that every VM process maps, which matters for ferry's twenty small VMs
# and not for Docker's one large one, so both numbers are recorded.
rss_mib() {
  local args=() pid
  for pid in "$@"; do [ -n "$pid" ] && args+=(-p "$pid"); done
  [ ${#args[@]} -eq 0 ] && { echo 0; return; }
  ps -o rss= "${args[@]}" 2>/dev/null | awk '{t+=$1} END {printf "%.1f", t/1024}'
}

# Memory used inside Docker Desktop's VM, which is where kind and minikube put
# everything. Read from a container: /proc/meminfo there is the VM's.
docker_guest_used_mib() {
  docker run --rm alpine:3.20 free -m 2>/dev/null \
    | awk '/^Mem:/ {print $3}'
}
