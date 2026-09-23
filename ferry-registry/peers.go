package main

// Images another Mac in the cluster has, fetched when asked for.
//
// `ferry image load` puts an image on one Mac. A pod scheduled onto a node on
// another Mac -- or onto a machine that Mac runs -- asked its own registry,
// which had never heard of it, and failed. So each Mac's registry also serves
// the others, and one that is asked for a name it does not hold asks them
// before answering 404: the manifest is fetched and recorded under the name at
// once, and each blob is fetched the first time something asks for it and
// kept. The next node on the same Mac finds everything local.
//
// Only a name is looked for on the peers. What a name resolves to is then
// fetched by digest and checked against it, so a peer can answer with the
// wrong image for a name but not with bytes that differ from what it said.
//
// Peers talk over TLS, on a port of their own, and both ends present the
// kubelet's client certificate for the node on that Mac: signed by the
// cluster CA, in group system:nodes. Nothing else is accepted, so the peer
// port answers exactly the nodes of this cluster -- not the LAN, and not a
// pod, which has no such certificate. It is read-only like the rest, and a
// peer is never asked on another's behalf: what the peer port serves is what
// that Mac holds, so two Macs missing the same name cannot ask each other in
// a circle.

import (
	"bufio"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Accepted for a manifest by tag, in the order a registry would prefer them.
var manifestAccept = strings.Join([]string{
	mediaOCIIndex, mediaOCIManifest, mediaDockerList, mediaDockerManifest,
}, ", ")

// peers is the other Macs' registries.
type peers struct {
	// list returns the base URLs to ask, e.g. https://192.168.1.40:5051.
	list   func() []string
	client *http.Client

	mu sync.Mutex
	// Where each name's blobs are, learned when the name was resolved, so a
	// blob is asked of the peer that has it rather than of every peer.
	origin map[string]string
	// Peers that did not answer, and until when they are left alone. A Mac
	// that is asleep must not add a timeout to every pull on this one.
	down map[string]time.Time
	// Blobs being fetched, so two layers requests for one digest share a
	// download.
	fetching map[string]chan struct{}
}

// How long a peer that failed to answer is skipped for.
const peerBackoff = 30 * time.Second

func newPeers(list func() []string, client *http.Client) *peers {
	return &peers{list: list, client: client, origin: map[string]string{},
		down: map[string]time.Time{}, fetching: map[string]chan struct{}{}}
}

func (p *peers) live() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	var out []string
	for _, base := range p.list() {
		if until, ok := p.down[base]; ok && time.Now().Before(until) {
			continue
		}
		out = append(out, base)
	}
	return out
}

func (p *peers) failed(base string, err error) {
	p.mu.Lock()
	p.down[base] = time.Now().Add(peerBackoff)
	p.mu.Unlock()
	log.Printf("peer %s: %v; skipped for %s", base, err, peerBackoff)
}

// splitName turns docker.io/library/app:dev into its repository and reference.
func splitName(name string) (repo, ref string) {
	if at := strings.LastIndex(name, "@"); at > 0 {
		return name[:at], name[at+1:]
	}
	colon := strings.LastIndex(name, ":")
	if colon > strings.LastIndex(name, "/") {
		return name[:colon], name[colon+1:]
	}
	return name, "latest"
}

// resolve asks the peers for a name, and records the first answer in the store.
// The manifest -- and, for an index, each child manifest the peer has -- is
// fetched now; layers wait until they are asked for.
func (p *peers) resolve(store, name string) (descriptor, bool) {
	repo, ref := splitName(name)
	for _, base := range p.live() {
		started := time.Now()
		data, mediaType, err := p.manifest(base, repo, ref)
		if errors.Is(err, errNotHere) {
			continue
		}
		if err != nil {
			p.failed(base, err)
			continue
		}
		d := descriptor{MediaType: mediaType, Digest: digestOf(data), Size: int64(len(data))}
		if strings.HasPrefix(ref, "sha256:") && ref != d.Digest {
			log.Printf("peer %s: %s answered with %s", base, name, d.Digest)
			continue
		}
		if err := putBlob(store, d.Digest, data); err != nil {
			log.Printf("store %s: %v", d.Digest, err)
			return descriptor{}, false
		}
		if isIndex(mediaType) {
			var c children
			json.Unmarshal(data, &c)
			for _, child := range c.Manifests {
				if body, _, err := p.manifest(base, repo, child.Digest); err == nil && digestOf(body) == child.Digest {
					putBlob(store, child.Digest, body)
				}
			}
		}
		if err := record(store, name, d); err != nil {
			log.Printf("record %s: %v", name, err)
			return descriptor{}, false
		}
		p.mu.Lock()
		p.origin[name] = base
		p.mu.Unlock()
		log.Printf("peer %s: resolved %s to %s in %dms", base, name, d.Digest,
			time.Since(started).Milliseconds())
		return d, true
	}
	return descriptor{}, false
}

var errNotHere = errors.New("not stored there")

func (p *peers) manifest(base, repo, ref string) ([]byte, string, error) {
	req, err := http.NewRequest(http.MethodGet, base+"/v2/"+repo+"/manifests/"+ref, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("Accept", manifestAccept)
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return nil, "", errNotHere
	case resp.StatusCode != http.StatusOK:
		return nil, "", fmt.Errorf("manifest %s: %s", ref, resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, "", err
	}
	mediaType := resp.Header.Get("Content-Type")
	if !isIndex(mediaType) && !isManifest(mediaType) {
		mediaType = sniff(data)
	}
	return data, mediaType, nil
}

// blob serves a blob this store does not have by fetching it from a peer,
// writing it to the client and to the store at once. It reports whether any
// peer had it. The digest is checked before the blob is kept, so a bad
// transfer is never served twice.
func (p *peers) blob(w http.ResponseWriter, r *http.Request, store, digest string) bool {
	p.mu.Lock()
	if wait, ok := p.fetching[digest]; ok {
		// Someone else is fetching it; serve their copy when it lands.
		p.mu.Unlock()
		<-wait
		_, err := os.Stat(blobPath(store, digest))
		return err == nil && serveStored(w, r, store, digest)
	}
	done := make(chan struct{})
	p.fetching[digest] = done
	var bases []string
	for _, base := range p.origin {
		bases = append(bases, base)
	}
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		delete(p.fetching, digest)
		p.mu.Unlock()
		close(done)
	}()

	// The peers that resolved a name first, then the rest.
	seen := map[string]bool{}
	var order []string
	for _, base := range append(bases, p.live()...) {
		if !seen[base] {
			seen[base] = true
			order = append(order, base)
		}
	}
	for _, base := range order {
		resp, err := p.client.Get(base + "/v2/_/blobs/" + digest)
		if err != nil {
			p.failed(base, err)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			continue
		}
		started := time.Now()
		n, err := p.tee(w, r, resp, store, digest)
		resp.Body.Close()
		if err != nil {
			log.Printf("peer %s: blob %s: %v", base, digest, err)
			return true // the client has had headers; it will retry
		}
		log.Printf("peer %s: fetched %s, %d bytes in %dms", base, digest, n,
			time.Since(started).Milliseconds())
		return true
	}
	return false
}

// tee copies a peer's response to the client and into the store. A client that
// goes away does not stop the download: the next one will want the same blob.
func (p *peers) tee(w http.ResponseWriter, r *http.Request, resp *http.Response, store, digest string) (int64, error) {
	dir := filepath.Join(store, "ingest")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(dir, "blob-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Docker-Content-Digest", digest)
	if resp.ContentLength >= 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(resp.ContentLength, 10))
	}
	w.WriteHeader(http.StatusOK)
	client := &lenient{w: w}
	if r.Method == http.MethodHead {
		client.gone = true
	}
	sum := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, sum, client), resp.Body)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return n, err
	}
	if got := "sha256:" + hex.EncodeToString(sum.Sum(nil)); got != digest {
		return n, fmt.Errorf("content is %s", got)
	}
	return n, os.Rename(tmp.Name(), blobPath(store, digest))
}

// lenient passes writes to a client until the first one fails, and then
// swallows the rest, so io.Copy keeps filling the store.
type lenient struct {
	w    io.Writer
	gone bool
}

func (l *lenient) Write(b []byte) (int, error) {
	if !l.gone {
		if _, err := l.w.Write(b); err != nil {
			l.gone = true
		}
	}
	return len(b), nil
}

func serveStored(w http.ResponseWriter, r *http.Request, store, digest string) bool {
	f, err := os.Open(blobPath(store, digest))
	if err != nil {
		return false
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Docker-Content-Digest", digest)
	http.ServeContent(w, r, "", time.Time{}, f)
	return true
}

func digestOf(data []byte) string {
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// putBlob writes a small blob whose digest has already been checked.
func putBlob(store, digest string, data []byte) error {
	path := blobPath(store, digest)
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return writeFile(path, data)
}

// record stores a name for a descriptor, as add does for a loaded image.
func record(store, name string, d descriptor) error {
	unlock, err := lock(store)
	if err != nil {
		return err
	}
	defer unlock()
	current, err := readIndex(store)
	if err != nil {
		return err
	}
	kept := current.Manifests[:0]
	for _, existing := range current.Manifests {
		if existing.Annotations[annotationImageName] != name {
			kept = append(kept, existing)
		}
	}
	d.Annotations = map[string]string{annotationImageName: name}
	current.Manifests = append(kept, d)
	data, err := json.MarshalIndent(current, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFile(filepath.Join(store, "oci-layout"), []byte(`{"imageLayoutVersion":"1.0.0"}`)); err != nil {
		return err
	}
	return writeFile(filepath.Join(store, "index.json"), data)
}

// peersFromFile reads ferry's peers file -- one host:relay-port a line, for
// every node in the cluster -- and returns each other Mac's registry. A Mac is
// a host, so the nodes it runs appear once; this Mac's own address is left
// out, and so is anything that is not an address.
func peersFromFile(path string, port int, self []string) func() []string {
	skip := map[string]bool{}
	for _, s := range self {
		skip[s] = true
	}
	return func() []string {
		f, err := os.Open(path)
		if err != nil {
			return nil
		}
		defer f.Close()
		seen := map[string]bool{}
		var out []string
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			host, _, err := net.SplitHostPort(strings.TrimSpace(scanner.Text()))
			if err != nil || net.ParseIP(host) == nil || skip[host] || seen[host] {
				continue
			}
			ip := net.ParseIP(host)
			if ip.IsLoopback() {
				continue
			}
			seen[host] = true
			out = append(out, "https://"+net.JoinHostPort(host, strconv.Itoa(port)))
		}
		return out
	}
}

// --- who may talk to whom ---------------------------------------------------

// credentials are a node's: the kubelet's client certificate and key, and the
// cluster CA, found through the kubelet's kubeconfig. Read again for every
// handshake, because the kubelet rotates its certificate in place.
type credentials struct {
	kubeconfig string
}

// kubeconfigPaths pulls the three fields ferry's kubeconfigs use out of one.
// Every kubeconfig ferry writes, and every one the kubelet writes after
// bootstrap, names files rather than embedding them; -data is read too.
func (c credentials) load() (tls.Certificate, *x509.CertPool, error) {
	data, err := os.ReadFile(c.kubeconfig)
	if err != nil {
		return tls.Certificate{}, nil, err
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
				v = filepath.Join(filepath.Dir(c.kubeconfig), v)
			}
			return os.ReadFile(v)
		}
		return nil, fmt.Errorf("%s has no %s", c.kubeconfig, name)
	}
	caPEM, err := read("certificate-authority")
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	certPEM, err := read("client-certificate")
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	keyPEM, err := read("client-key")
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return tls.Certificate{}, nil, fmt.Errorf("no CA certificate in %s", c.kubeconfig)
	}
	return cert, pool, nil
}

// verifyNode accepts a certificate chain only if it is a node of this cluster.
// Key usage is not checked: both ends present a kubelet *client* certificate,
// including the server, which has no serving certificate of its own that
// every peer could check.
func (c credentials) verifyNode(raw [][]byte, _ [][]*x509.Certificate) error {
	if len(raw) == 0 {
		return errors.New("no certificate")
	}
	_, pool, err := c.load()
	if err != nil {
		return err
	}
	leaf, err := x509.ParseCertificate(raw[0])
	if err != nil {
		return err
	}
	intermediates := x509.NewCertPool()
	for _, der := range raw[1:] {
		if cert, err := x509.ParseCertificate(der); err == nil {
			intermediates.AddCert(cert)
		}
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, Intermediates: intermediates,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return err
	}
	for _, org := range leaf.Subject.Organization {
		if org == "system:nodes" {
			return nil
		}
	}
	return fmt.Errorf("%s is not a node", leaf.Subject.CommonName)
}

func (c credentials) certificate() (*tls.Certificate, error) {
	cert, _, err := c.load()
	return &cert, err
}

func (c credentials) serverTLS() *tls.Config {
	return &tls.Config{
		MinVersion:            tls.VersionTLS12,
		ClientAuth:            tls.RequireAnyClientCert,
		GetCertificate:        func(*tls.ClientHelloInfo) (*tls.Certificate, error) { return c.certificate() },
		VerifyPeerCertificate: c.verifyNode,
	}
}

func (c credentials) client() *http.Client {
	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
		// The chain is checked by verifyNode instead, which knows a peer's
		// certificate is a client certificate and names no address.
		InsecureSkipVerify:    true,
		GetClientCertificate:  func(*tls.CertificateRequestInfo) (*tls.Certificate, error) { return c.certificate() },
		VerifyPeerCertificate: c.verifyNode,
	}
	return &http.Client{Transport: &http.Transport{
		TLSClientConfig:       config,
		DialContext:           (&net.Dialer{Timeout: 750 * time.Millisecond}).DialContext,
		TLSHandshakeTimeout:   2 * time.Second,
		ResponseHeaderTimeout: 5 * time.Second,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       90 * time.Second,
	}}
}
