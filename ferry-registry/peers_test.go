package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// cluster makes a CA and returns a function that writes a kubeconfig for a
// client certificate it signs, in the given organization.
func cluster(t *testing.T) func(cn, org string) string {
	t.Helper()
	dir := t.TempDir()
	caKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ferry-ca"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	caDER, _ := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	caCert, _ := x509.ParseCertificate(caDER)
	caPath := filepath.Join(dir, "ca.crt")
	os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), 0o644)
	serial := int64(2)
	return func(cn, org string) string {
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		serial++
		template := &x509.Certificate{
			SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: cn, Organization: []string{org}},
			NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		}
		der, _ := x509.CreateCertificate(rand.Reader, template, caCert, &key.PublicKey, caKey)
		keyDER, _ := x509.MarshalECPrivateKey(key)
		base := filepath.Join(dir, fmt.Sprint(serial))
		os.WriteFile(base+".crt", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
		os.WriteFile(base+".key", pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600)
		// The shape up.sh and the kubelet's bootstrap both write.
		conf := fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- cluster: {certificate-authority: %s, server: "https://10.0.0.1:6443"}
  name: ferry
users:
- name: kubelet
  user:
    client-certificate: %s.crt
    client-key: %s.key
`, caPath, base, base)
		path := base + ".conf"
		os.WriteFile(path, []byte(conf), 0o644)
		return path
	}
}

// peerServer serves a store the way the peer port does: TLS, nodes only, and
// no pull-through of its own.
func peerServer(t *testing.T, store, kubeconfig string) *httptest.Server {
	t.Helper()
	// Wrapped by hand rather than StartTLS, which installs a certificate of
	// its own ahead of GetCertificate.
	srv := httptest.NewUnstartedServer(&registry{store: store})
	srv.Listener = tls.NewListener(srv.Listener, (&credentials{kubeconfig: kubeconfig}).serverTLS())
	srv.Start()
	srv.URL = strings.Replace(srv.URL, "http://", "https://", 1)
	t.Cleanup(srv.Close)
	return srv
}

func TestPullsThroughFromAnotherMac(t *testing.T) {
	sign := cluster(t)
	// Mac A has the image; Mac B does not.
	storeA := t.TempDir()
	src, digest := layout(t, "docker.io/library/app:dev", "layer-bytes")
	if _, err := add(storeA, src); err != nil {
		t.Fatal(err)
	}
	a := peerServer(t, storeA, sign("system:node:mac-a", "system:nodes"))

	storeB := t.TempDir()
	credsB := &credentials{kubeconfig: sign("system:node:mac-b", "system:nodes")}
	down := "https://127.0.0.1:1" // a Mac that is asleep
	b := httptest.NewServer(&registry{store: storeB,
		peers: newPeers(func() []string { return []string{down, a.URL} }, credsB.client())})
	defer b.Close()

	// What a machine's containerd asks, and what ferry-cri asks.
	resp, body := get(t, b.URL+"/v2/library/app/manifests/dev?ns=docker.io")
	if resp.StatusCode != 200 || resp.Header.Get("Docker-Content-Digest") != digest {
		t.Fatalf("manifest through B = %d %s", resp.StatusCode, body)
	}
	if d, ok, _ := lookup(storeB, "docker.io/library/app:dev"); !ok || d.Digest != digest {
		t.Fatalf("B did not record the name: %v %v", d, ok)
	}
	var m children
	json.Unmarshal([]byte(body), &m)
	layerDigest := m.Layers[0].Digest
	if _, err := os.Stat(blobPath(storeB, layerDigest)); err == nil {
		t.Fatal("the layer was fetched before anything asked for it")
	}
	resp, layer := get(t, b.URL+"/v2/docker.io/library/app/blobs/"+layerDigest)
	if resp.StatusCode != 200 || layer != "layer-bytes" {
		t.Fatalf("layer through B = %d %q", resp.StatusCode, layer)
	}
	if _, err := os.Stat(blobPath(storeB, layerDigest)); err != nil {
		t.Fatal("the layer was not kept")
	}
	// Kept: A going away does not matter now.
	a.Close()
	if resp, layer := get(t, b.URL+"/v2/x/blobs/"+layerDigest); resp.StatusCode != 200 || layer != "layer-bytes" {
		t.Fatalf("kept layer = %d %q", resp.StatusCode, layer)
	}
	// A name nobody has is still a 404, which is what sends containerd upstream.
	if resp, _ := get(t, b.URL+"/v2/library/busybox/manifests/1.36?ns=docker.io"); resp.StatusCode != 404 {
		t.Fatalf("unknown name = %d, want 404", resp.StatusCode)
	}
}

func TestPeerPortAnswersOnlyNodes(t *testing.T) {
	sign := cluster(t)
	store := t.TempDir()
	src, _ := layout(t, "docker.io/library/app:dev", "x")
	add(store, src)
	srv := peerServer(t, store, sign("system:node:mac-a", "system:nodes"))

	try := func(kubeconfig string) error {
		c := &credentials{kubeconfig: kubeconfig}
		resp, err := c.client().Get(srv.URL + "/v2/docker.io/library/app/manifests/dev")
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			return fmt.Errorf("%s", resp.Status)
		}
		return nil
	}
	if err := try(sign("system:node:mac-b", "system:nodes")); err != nil {
		t.Fatalf("a node was refused: %v", err)
	}
	// Signed by the cluster, but not a node: a user's certificate.
	if err := try(sign("admin", "system:masters")); err == nil {
		t.Fatal("a non-node certificate was accepted")
	}
	// No certificate at all -- a pod, or anything else on the LAN.
	plain := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	if resp, err := plain.Get(srv.URL + "/v2/"); err == nil {
		resp.Body.Close()
		t.Fatalf("no certificate got %s", resp.Status)
	}
	// Another cluster's node.
	if err := try(cluster(t)("system:node:other", "system:nodes")); err == nil {
		t.Fatal("another cluster's node was accepted")
	}
	// And still read-only for a node.
	c := &credentials{kubeconfig: sign("system:node:mac-c", "system:nodes")}
	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/v2/docker.io/library/app/manifests/dev", strings.NewReader("{}"))
	if resp, err := c.client().Do(req); err != nil || resp.StatusCode != 405 {
		t.Fatalf("PUT from a node = %v %v, want 405", resp, err)
	}
}

func TestPeersFromFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "peers")
	os.WriteFile(path, []byte("192.168.1.29:30472\n192.168.1.29:30473\n192.168.1.40:8472\n127.0.0.1:9\nnonsense\n"), 0o644)
	got := peersFromFile(path, 5051, []string{"192.168.1.29"})()
	if len(got) != 1 || got[0] != "https://192.168.1.40:5051" {
		t.Fatalf("peers = %v", got)
	}
}
