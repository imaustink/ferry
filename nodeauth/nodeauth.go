// Package nodeauth is how one ferry process knows another is a node of this
// cluster: it holds the kubelet's client certificate, signed by the cluster CA,
// in group system:nodes, named system:node:<name>.
//
// That certificate is the one credential every node already has and nothing
// else does -- not a pod, not the LAN -- so the processes ferry runs between
// Macs (the registry's peer port, ferry-netpol's) use it as their identity
// rather than minting one of their own. The name in it is what the API
// server's Node authorizer keys off too, which is what lets a server answer a
// node with exactly what that node is allowed to know.
//
// Standard library only, because ferry-registry is.
package nodeauth

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Group and Prefix are what the Node authorizer recognises a kubelet by.
const (
	Group  = "system:nodes"
	Prefix = "system:node:"
)

// Kubeconfig is the parts of a kubeconfig a node's identity is made of.
type Kubeconfig struct {
	Server string
	CA     []byte
	Cert   []byte
	Key    []byte
}

// Read pulls the fields ferry's kubeconfigs use out of one. Every kubeconfig
// ferry writes, and every one the kubelet writes after bootstrap, names files
// rather than embedding them; -data is read too.
//
// Not a YAML parser, deliberately: these files are one shape, and the registry
// has no dependencies to parse YAML with. The first value for a key wins, which
// is the current cluster and user in every file ferry makes.
func Read(path string) (Kubeconfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Kubeconfig{}, err
	}
	fields := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "- "))
		line = strings.NewReplacer("{", ",", "}", ",").Replace(line)
		for _, piece := range strings.Split(line, ",") {
			key, value, ok := strings.Cut(strings.TrimSpace(piece), ":")
			if !ok {
				continue
			}
			key = strings.TrimSpace(key)
			value = strings.Trim(strings.TrimSpace(value), `"'`)
			if _, have := fields[key]; !have && value != "" {
				fields[key] = value
			}
		}
	}
	read := func(name string) ([]byte, error) {
		if v := fields[name+"-data"]; v != "" {
			return base64.StdEncoding.DecodeString(v)
		}
		if v := fields[name]; v != "" {
			if !filepath.IsAbs(v) {
				v = filepath.Join(filepath.Dir(path), v)
			}
			return os.ReadFile(v)
		}
		return nil, fmt.Errorf("%s has no %s", path, name)
	}
	var k Kubeconfig
	k.Server = fields["server"]
	if k.CA, err = read("certificate-authority"); err != nil {
		return Kubeconfig{}, err
	}
	if k.Cert, err = read("client-certificate"); err != nil {
		return Kubeconfig{}, err
	}
	if k.Key, err = read("client-key"); err != nil {
		return Kubeconfig{}, err
	}
	return k, nil
}

// Load is a kubeconfig's client certificate and its CA as a pool.
func Load(path string) (tls.Certificate, *x509.CertPool, error) {
	k, err := Read(path)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	cert, err := tls.X509KeyPair(k.Cert, k.Key)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	pool, err := Pool(k.CA)
	if err != nil {
		return tls.Certificate{}, nil, fmt.Errorf("%s: %w", path, err)
	}
	return cert, pool, nil
}

// Pool is a CA bundle as a pool.
func Pool(pem []byte) (*x509.CertPool, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errors.New("no CA certificate")
	}
	return pool, nil
}

// Node returns the name of the node a certificate chain belongs to, or an error
// if it is not a node of the cluster roots describes.
//
// The chain has to verify against roots for usage, the leaf has to be in group
// system:nodes, and its common name has to be system:node:<name> -- the same
// three things the API server checks before the Node authorizer will call it a
// node. ExtKeyUsageAny is for a peer that presents a kubelet client
// certificate as a server, which has no serving certificate every peer could
// check.
func Node(raw [][]byte, roots *x509.CertPool, usage x509.ExtKeyUsage) (string, error) {
	if len(raw) == 0 {
		return "", errors.New("no certificate")
	}
	leaf, err := x509.ParseCertificate(raw[0])
	if err != nil {
		return "", err
	}
	intermediates := x509.NewCertPool()
	for _, der := range raw[1:] {
		if cert, err := x509.ParseCertificate(der); err == nil {
			intermediates.AddCert(cert)
		}
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates,
		KeyUsages: []x509.ExtKeyUsage{usage}}); err != nil {
		return "", err
	}
	return NameOf(leaf)
}

// NameOf is the node a certificate that has already been verified names.
func NameOf(leaf *x509.Certificate) (string, error) {
	inGroup := false
	for _, org := range leaf.Subject.Organization {
		if org == Group {
			inGroup = true
		}
	}
	name, named := strings.CutPrefix(leaf.Subject.CommonName, Prefix)
	if !inGroup || !named || name == "" {
		return "", fmt.Errorf("%q is not a node", leaf.Subject.CommonName)
	}
	return name, nil
}
