#!/usr/bin/env bash
# Prints one line of key=value pairs: everything on the Mac that this
# profile's ferry owns and that a pod coming and going could leave behind.
#   snapshot.sh            the line
#   snapshot.sh --keys     the keys only, one per line
#
# Counted from the host, not asked of ferry: the point is to catch what ferry
# has forgotten it holds. Every count is scoped to this profile -- by pid file,
# by runtime directory, or by the pod VM having a file there open -- because
# other checkouts' clusters run on the same Mac and are none of this run's
# business.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
FERRY="${FERRY:-$here/../../ferry}"
profile="$("$FERRY" profile 2>/dev/null)"
RUN="${FERRY_RUN:-$(awk '$1 == "runtime" { print $2 }' <<<"$profile")}"
HOME_DIR="${FERRY_HOME:-$(awk '$1 == "state" { print $2 }' <<<"$profile")}"
NS="${SOAK_NS:-soak}"
export KUBECONFIG="$HOME_DIR/admin.conf"

out=()
put() { out+=("$1=$2"); }

pid_of() {
  local f
  for f in "$RUN/$1.pid" "$HOME_DIR/$1.pid"; do
    [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && { cat "$f"; return; }
  done
}

# Per component: open files, resident memory, threads. A leak in a Swift or Go
# daemon shows up in at least one of these long before it shows up anywhere else.
for c in ferry-cri ferry-streamer ferry-proxyd ferry-proxy ferry-netpol ferry-storage \
         kubelet etcd kube-apiserver kube-controller-manager kube-scheduler; do
  pid="$(pid_of "$c")"
  key="${c//-/_}"
  if [ -z "$pid" ]; then
    put "${key}_up" 0; continue
  fi
  put "${key}_up" 1
  put "${key}_fds" "$(lsof -n -P -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  put "${key}_rss_mib" "$(ps -o rss= -p "$pid" | awk '{ printf "%.0f", $1 / 1024 }')"
  put "${key}_threads" "$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
done

# Pod VMs: a VM process holding a file under this profile's runtime or state
# directory. Anything left here with no pods scheduled is a VM nobody stopped.
vms=0
for pid in $(pgrep -f Virtualization.VirtualMachine); do
  lsof -n -p "$pid" -Fn 2>/dev/null | grep -qF -e "$RUN/" -e "$HOME_DIR/" && vms=$((vms + 1))
done
put vms "$vms"

# Files the runtime keeps per pod: disks, sockets, console logs.
put run_files "$(find "$RUN" -type f 2>/dev/null | wc -l | tr -d ' ')"
put run_sockets "$(find "$RUN" -type s 2>/dev/null | wc -l | tr -d ' ')"
put run_dirs "$(find "$RUN" -type d 2>/dev/null | wc -l | tr -d ' ')"
# du reports blocks actually allocated, which is what sparse disks cost.
put run_mib "$(du -sk "$RUN" 2>/dev/null | awk '{ printf "%.0f", $1 / 1024 }')"
put run_logs_mib "$(du -sk "$RUN/logs" 2>/dev/null | awk '{ printf "%.0f", $1 / 1024 }')"
put state_mib "$(du -sk "$HOME_DIR" 2>/dev/null | awk '{ printf "%.0f", $1 / 1024 }')"
put etcd_db_mib "$(find "$HOME_DIR/etcd" -name db -exec du -sk {} + 2>/dev/null | awk '{ s += $1 } END { printf "%.0f", s / 1024 }')"

# Network interfaces on the Mac. vmnet's bridges and per-VM vmenet interfaces
# are Mac-wide, not per profile, so these count everyone's -- read them as
# a delta, and only while nothing else on the Mac is starting pods.
put if_bridge "$(ifconfig -l | tr ' ' '\n' | grep -c '^bridge')"
put if_vmenet "$(ifconfig -l | tr ' ' '\n' | grep -c '^vmenet')"
put if_total "$(ifconfig -l | wc -w | tr -d ' ')"

# Sockets this profile's processes hold, by kind. Connections that pile up in
# CLOSE_WAIT are a relay that never closed its side.
pids="$(for c in ferry-cri ferry-streamer ferry-proxyd ferry-proxy ferry-netpol ferry-storage kubelet; do pid_of "$c"; done | paste -sd, -)"
if [ -n "$pids" ]; then
  socks="$(lsof -n -P -a -p "$pids" -i 2>/dev/null | tail -n +2)"
  put tcp_listen "$(grep -c '(LISTEN)' <<<"$socks")"
  put tcp_established "$(grep -c '(ESTABLISHED)' <<<"$socks")"
  put tcp_close_wait "$(grep -c '(CLOSE_WAIT)' <<<"$socks")"
  put udp "$(grep -c ' UDP ' <<<"$socks")"
  put unix_socks "$(lsof -n -P -a -p "$pids" -U 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
fi

# What the cluster thinks is left over in the soak namespace. Once a cycle has
# drained, all of these but the Service's own should be zero.
if kubectl version --request-timeout=5s >/dev/null 2>&1; then
  put api_up 1
  put k8s_pods "$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  put k8s_pods_all "$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  put k8s_endpoints "$(kubectl get endpointslices -n "$NS" -o jsonpath='{range .items[*]}{range .endpoints[*]}x{"\n"}{end}{end}' 2>/dev/null | grep -c x)"
  put k8s_events "$(kubectl get events -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
else
  put api_up 0
fi

# Host-wide memory in use, the number that is actually gone from the Mac.
put host_used_mib "$(vm_stat | awk -F: '
  /Pages active/ {a=$2} /Pages wired down/ {w=$2} /occupied by compressor/ {c=$2}
  END { gsub(/[ .]/,"",a); gsub(/[ .]/,"",w); gsub(/[ .]/,"",c);
        printf "%.0f", (a+w+c)*16384/1048576 }')"

if [ "${1:-}" = "--keys" ]; then
  printf '%s\n' "${out[@]%%=*}"
else
  printf '%s ' "${out[@]}"; echo
fi
