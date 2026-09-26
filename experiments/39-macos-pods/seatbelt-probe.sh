#!/usr/bin/env bash
# What a Seatbelt-confined process can and cannot do: the rootless shared-kernel
# container, probed on the host.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
R="$here/build/ctr"
rm -rf "$R"; mkdir -p "$R/bin" "$R/tmp"; clang -O2 -o "$R/bin/hello" "$here/hello.c"
run() { "$here/seatbelt-run.sh" "$R" "$@"; }

echo "--- binary from the image:";   run hello "from a darwin container"
echo "--- write inside its root:";   run /bin/sh -c 'echo ok > tmp/x && cat tmp/x'
echo "--- read the user's home:";    run /bin/ls "$HOME" 2>&1 | head -2
echo "--- write outside its root:";  run /usr/bin/touch /tmp/ferry-escape 2>&1; ls /tmp/ferry-escape 2>&1
echo "--- what it can see:";          run hello probe
echo "--- network:";                 run /usr/bin/curl -s -o /dev/null -w '%{http_code}\n' https://example.com
echo "--- start latency, 20 runs:"
start=$(python3 -c 'import time; print(time.time())')
for _ in $(seq 20); do run hello >/dev/null; done
python3 -c "import time; print(f'{(time.time()-$start)/20*1000:.1f} ms per container')"
