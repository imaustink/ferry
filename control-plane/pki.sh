#!/usr/bin/env bash
# Generates the cluster PKI. Everything lives under $PKI_DIR; re-running is a
# no-op unless the CA is missing, so restarting the control plane does not
# invalidate certificates already handed out.
set -euo pipefail

PKI_DIR="${PKI_DIR:-/tmp/ferry/pki}"
NODE_NAME="${NODE_NAME:-ferry-mac}"

# The kubelet reaches the API server over vmnet once pods are VMs, so the
# gateway address is baked in from the start -- an API server certificate that
# is only valid on today's Wi-Fi network is not worth generating.
VMNET_GW="${VMNET_GW:-192.168.66.1}"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"

if [ -f ca.crt ]; then
  echo "==> reusing PKI in $PKI_DIR"
  exit 0
fi
echo "==> generating PKI in $PKI_DIR (node=$NODE_NAME, vmnet=$VMNET_GW, lan=$LAN_IP)"

newca() { # name CN
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.crt" \
    -days 3650 -subj "/CN=$2" 2>/dev/null
}

client() { # name CN O
  local ext=$1.ext
  printf 'extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n' > "$ext"
  openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=$2${3:+/O=$3}" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA "${4:-ca}.crt" -CAkey "${4:-ca}.key" \
    -CAcreateserial -out "$1.crt" -days 3650 -extfile "$ext" 2>/dev/null
  rm -f "$1.csr" "$ext"
}

newca ca "ferry-ca"
newca front-proxy-ca "ferry-front-proxy-ca"

# API server serving certificate.
cat > apiserver.ext <<EXT
subjectAltName=DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:localhost,DNS:$(hostname),IP:127.0.0.1,IP:$VMNET_GW,IP:$LAN_IP,IP:10.96.0.1
extendedKeyUsage=serverAuth
basicConstraints=CA:FALSE
EXT
openssl req -newkey rsa:2048 -nodes -keyout apiserver.key -out apiserver.csr \
  -subj "/CN=kube-apiserver" 2>/dev/null
openssl x509 -req -in apiserver.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out apiserver.crt -days 3650 -extfile apiserver.ext 2>/dev/null
rm -f apiserver.csr apiserver.ext

# Clients. The kubelet identifies as system:node:<name> in group system:nodes,
# which is what the Node authorizer keys off.
client admin                   "ferry-admin"                  "system:masters"
client apiserver-kubelet-client "kube-apiserver-kubelet-client" "system:masters"
client kubelet                 "system:node:$NODE_NAME"     "system:nodes"
client controller-manager      "system:kube-controller-manager"
client scheduler               "system:kube-scheduler"
client front-proxy-client      "front-proxy-client"         ""  front-proxy-ca

# ServiceAccount token signing keypair.
openssl genrsa -out sa.key 2048 2>/dev/null
openssl rsa -in sa.key -pubout -out sa.pub 2>/dev/null

echo "==> PKI ready"
ls "$PKI_DIR"
