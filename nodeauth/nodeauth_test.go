package nodeauth

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type ca struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pem  []byte
}

func newCA(t *testing.T) ca {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ferry-ca"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, _ := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	cert, _ := x509.ParseCertificate(der)
	return ca{cert, key, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}
}

func (c ca) sign(t *testing.T, cn string, orgs []string, usage x509.ExtKeyUsage) (der []byte, keyPEM []byte) {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: cn, Organization: orgs},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage},
	}
	der, _ = x509.CreateCertificate(rand.Reader, template, c.cert, &key.PublicKey, c.key)
	k, _ := x509.MarshalECPrivateKey(key)
	return der, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: k})
}

func TestNode(t *testing.T) {
	cluster, other := newCA(t), newCA(t)
	roots, err := Pool(cluster.pem)
	if err != nil {
		t.Fatal(err)
	}
	client := x509.ExtKeyUsageClientAuth
	cases := []struct {
		what  string
		chain func() [][]byte
		name  string // "" is refused
	}{
		{"a kubelet", func() [][]byte {
			der, _ := cluster.sign(t, "system:node:mac-b", []string{"system:nodes"}, client)
			return [][]byte{der}
		}, "mac-b"},
		{"no certificate", func() [][]byte { return nil }, ""},
		{"another cluster's kubelet", func() [][]byte {
			der, _ := other.sign(t, "system:node:mac-b", []string{"system:nodes"}, client)
			return [][]byte{der}
		}, ""},
		{"an admin", func() [][]byte {
			der, _ := cluster.sign(t, "ferry-admin", []string{"system:masters"}, client)
			return [][]byte{der}
		}, ""},
		// The group without the name is not a node: the Node authorizer
		// would have nothing to scope it to, and neither would anything here.
		{"the group, not the name", func() [][]byte {
			der, _ := cluster.sign(t, "mac-b", []string{"system:nodes"}, client)
			return [][]byte{der}
		}, ""},
		{"the name, not the group", func() [][]byte {
			der, _ := cluster.sign(t, "system:node:mac-b", []string{"system:masters"}, client)
			return [][]byte{der}
		}, ""},
		{"an empty name", func() [][]byte {
			der, _ := cluster.sign(t, "system:node:", []string{"system:nodes"}, client)
			return [][]byte{der}
		}, ""},
		{"a serving certificate where a client one is asked for", func() [][]byte {
			der, _ := cluster.sign(t, "system:node:mac-b", []string{"system:nodes"}, x509.ExtKeyUsageServerAuth)
			return [][]byte{der}
		}, ""},
		{"a certificate that is not one", func() [][]byte { return [][]byte{[]byte("nonsense")} }, ""},
	}
	for _, c := range cases {
		got, err := Node(c.chain(), roots, client)
		if c.name == "" && err == nil {
			t.Errorf("%s: accepted as %q", c.what, got)
		}
		if c.name != "" && (err != nil || got != c.name) {
			t.Errorf("%s: got %q, %v; want %q", c.what, got, err, c.name)
		}
	}
}

func TestRead(t *testing.T) {
	cluster := newCA(t)
	dir := t.TempDir()
	der, key := cluster.sign(t, "system:node:mac-a", []string{"system:nodes"}, x509.ExtKeyUsageClientAuth)
	os.WriteFile(filepath.Join(dir, "ca.crt"), cluster.pem, 0o644)
	os.WriteFile(filepath.Join(dir, "client.pem"),
		append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), key...), 0o600)
	// The shape the kubelet writes after bootstrap: a relative CA path, and
	// the certificate and key in one rotated file.
	path := filepath.Join(dir, "kubelet.conf")
	os.WriteFile(path, []byte(`apiVersion: v1
clusters:
- cluster:
    certificate-authority: ca.crt
    server: https://192.168.1.29:6443
  name: default-cluster
users:
- name: default-auth
  user:
    client-certificate: `+dir+`/client.pem
    client-key: `+dir+`/client.pem
`), 0o600)
	k, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if k.Server != "https://192.168.1.29:6443" {
		t.Errorf("server = %q", k.Server)
	}
	cert, roots, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if name, err := Node(cert.Certificate, roots, x509.ExtKeyUsageClientAuth); err != nil || name != "mac-a" {
		t.Errorf("own certificate = %q, %v", name, err)
	}
}
