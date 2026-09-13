#!/usr/bin/env bash
# Builds a real OCI image without Docker.
#
# 'ferry image load' exists for running something you just built, so the test for
# it should be something just built -- not something pulled and re-saved. A Go
# binary with CGO off is a whole container image's worth of content in one file,
# so the image is one layer holding one executable.
#
#   ./build-image.sh [output-directory]
set -euo pipefail
out="${1:-/tmp/ferry-demo-image}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/main.go" <<'GO'
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	host, _ := os.Hostname()
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "built-on-this-mac from %s\n", host)
	})
	fmt.Println("listening on :8080")
	http.ListenAndServe(":8080", nil)
}
GO
( cd "$work" && go mod init demo >/dev/null 2>&1 && \
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-s -w" -o app . )

# One layer: the binary at /app.
mkdir -p "$work/root"
cp "$work/app" "$work/root/app"
chmod 0755 "$work/root/app"
tar --format=ustar -C "$work/root" -cf "$work/layer.tar" app
diffid="$(shasum -a 256 "$work/layer.tar" | awk '{print $1}')"
gzip -n -c "$work/layer.tar" > "$work/layer.tar.gz"
layerdigest="$(shasum -a 256 "$work/layer.tar.gz" | awk '{print $1}')"
layersize="$(wc -c < "$work/layer.tar.gz" | tr -d ' ')"

rm -rf "$out"; mkdir -p "$out/blobs/sha256"
cp "$work/layer.tar.gz" "$out/blobs/sha256/$layerdigest"

cat > "$work/config.json" <<JSON
{
  "architecture": "arm64",
  "os": "linux",
  "config": {
    "Entrypoint": ["/app"],
    "ExposedPorts": {"8080/tcp": {}}
  },
  "rootfs": {"type": "layers", "diff_ids": ["sha256:$diffid"]}
}
JSON
configdigest="$(shasum -a 256 "$work/config.json" | awk '{print $1}')"
configsize="$(wc -c < "$work/config.json" | tr -d ' ')"
cp "$work/config.json" "$out/blobs/sha256/$configdigest"

cat > "$work/manifest.json" <<JSON
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:$configdigest",
    "size": $configsize
  },
  "layers": [{
    "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
    "digest": "sha256:$layerdigest",
    "size": $layersize
  }]
}
JSON
manifestdigest="$(shasum -a 256 "$work/manifest.json" | awk '{print $1}')"
manifestsize="$(wc -c < "$work/manifest.json" | tr -d ' ')"
cp "$work/manifest.json" "$out/blobs/sha256/$manifestdigest"

# The name the image will carry into the cluster.
reference="${FERRY_IMAGE_NAME:-docker.io/library/ferry-demo:built-here}"
cat > "$out/index.json" <<JSON
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [{
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "digest": "sha256:$manifestdigest",
    "size": $manifestsize,
    "platform": {"architecture": "arm64", "os": "linux"},
    "annotations": {"org.opencontainers.image.ref.name": "$reference"}
  }]
}
JSON
echo '{"imageLayoutVersion": "1.0.0"}' > "$out/oci-layout"

echo "built $reference"
echo "  layout $out"
echo "  layer  $(echo "$layersize" | awk '{printf "%.1f MiB", $1/1048576}')"
