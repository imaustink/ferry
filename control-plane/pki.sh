#!/usr/bin/env bash
# Generates the cluster PKI. Everything lives under $PKI_DIR; re-running is a
# no-op unless the CA is missing, so restarting the control plane does not
# invalidate certificates already handed out.
set -euo pipefail

PKI_DIR="${PKI_DIR:-/tmp/ferry/pki}"
NODE_NAME="${NODE_NAME:-ferry-mac}"

# The kubelet and every pod reach the API server over the pod network gateway,
# so that address is baked in from the start -- a certificate valid only on
# today's Wi-Fi network is not worth generating.
#
# Which gateway we get is not fixed: vmnet networks can stay claimed by an
# earlier run, so the runtime falls back through a list of subnets. The
# certificate therefore covers every candidate gateway, rather than being
# regenerated whenever the subnet moves. These must stay in step with
# PodRuntime.subnetCandidates.
VMNET_GW="${VMNET_GW:-192.168.66.1}"
GATEWAY_CANDIDATES="${GATEWAY_CANDIDATES:-192.168.66.1 192.168.77.1 192.168.88.1 192.168.99.1 192.168.111.1 192.168.122.1 192.168.133.1 192.168.144.1 192.168.155.1 192.168.166.1 192.168.177.1 192.168.188.1 192.168.199.1 192.168.211.1 192.168.222.1}"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"

mkdir -p "$PKI_DIR"
cd "$PKI_DIR"

client() { # name CN O [ca]
  local ext=$1.ext
  printf 'extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n' > "$ext"
  openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=$2${3:+/O=$3}" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA "${4:-ca}.crt" -CAkey "${4:-ca}.key" \
    -CAcreateserial -out "$1.crt" -days 3650 -extfile "$ext" 2>/dev/null
  rm -f "$1.csr" "$ext"
}

if [ -f ca.crt ]; then
  echo "==> reusing PKI in $PKI_DIR"
  # The kubelet's certificate names the node, and the Node authorizer grants a
  # kubelet nothing for any other name. A cluster whose node was renamed since
  # the PKI was made gets a certificate for the name it runs as now.
  if [ -f ca.key ] && [ "$(openssl x509 -in kubelet.crt -noout -subject -nameopt RFC2253 2>/dev/null)" \
       != "subject=O=system:nodes,CN=system:node:$NODE_NAME" ]; then
    client kubelet "system:node:$NODE_NAME" "system:nodes"
    echo "==> signed a kubelet certificate for $NODE_NAME"
  fi
  exit 0
fi
echo "==> generating PKI in $PKI_DIR (node=$NODE_NAME, vmnet=$VMNET_GW, lan=$LAN_IP)"

newca() { # name CN
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.crt" \
    -days 3650 -subj "/CN=$2" 2>/dev/null
}

newca ca "ferry-ca"
newca front-proxy-ca "ferry-front-proxy-ca"

# API server serving certificate.
gateway_sans=""
for candidate in $VMNET_GW $GATEWAY_CANDIDATES; do
  case ",$gateway_sans," in *",IP:$candidate,"*) continue;; esac
  gateway_sans="$gateway_sans,IP:$candidate"
done
cat > apiserver.ext <<EXT
subjectAltName=DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:localhost,DNS:$(hostname),IP:127.0.0.1,IP:$LAN_IP,IP:10.96.0.1$gateway_sans
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
