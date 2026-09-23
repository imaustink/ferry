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
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// pki is a cluster CA and what it signs, written out as ferry lays it out.
type pki struct {
	t    *testing.T
	dir  string
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
}

func newPKI(t *testing.T) *pki {
	t.Helper()
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ferry-ca"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, _ := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	cert, _ := x509.ParseCertificate(der)
	p := &pki{t: t, dir: t.TempDir(), cert: cert, key: key}
	p.write("ca.crt", "CERTIFICATE", der)
	return p
}

func (p *pki) write(name, kind string, der []byte) string {
	path := filepath.Join(p.dir, name)
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: der}), 0o600); err != nil {
		p.t.Fatal(err)
	}
	return path
}

// sign writes a certificate and key and returns their paths.
func (p *pki) sign(name, cn string, orgs []string, usage x509.ExtKeyUsage, ips ...net.IP) (string, string) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: cn, Organization: orgs},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}, IPAddresses: ips,
	}
	der, _ := x509.CreateCertificate(rand.Reader, template, p.cert, &key.PublicKey, p.key)
	keyDER, _ := x509.MarshalECPrivateKey(key)
	return p.write(name+".crt", "CERTIFICATE", der), p.write(name+".key", "EC PRIVATE KEY", keyDER)
}

// kubelet writes the kubeconfig a node's kubelet has after bootstrap.
func (p *pki) kubelet(node string) string {
	return p.kubeconfig(node, "system:node:"+node, "system:nodes")
}

// kubeconfig writes one for any certificate the cluster CA signs.
func (p *pki) kubeconfig(file, cn string, orgs ...string) string {
	cert, key := p.sign(file, cn, orgs, x509.ExtKeyUsageClientAuth)
	path := filepath.Join(p.dir, file+".conf")
	os.WriteFile(path, []byte(fmt.Sprintf(`apiVersion: v1
clusters:
- cluster:
    certificate-authority: %s
    server: https://127.0.0.1:6443
  name: default-cluster
users:
- name: default-auth
  user:
    client-certificate: %s
    client-key: %s
`, filepath.Join(p.dir, "ca.crt"), cert, key)), 0o600)
	return path
}

// A cluster of two nodes, a and b: a web pod on each, a friend of theirs on b,
// and a policy that lets only friends in.
func twoNodes(t *testing.T, extra ...any) *compiler {
	objects := append([]any{
		pod("web-a", "default", "a", "10.244.0.5", web),
		pod("web-b", "default", "b", "10.244.1.5", web),
		pod("friend", "default", "b", "10.244.1.9", map[string]string{"role": "friend"}),
		policy("friends", networkingv1.NetworkPolicySpec{
			PodSelector: selectWeb(),
			Ingress: []networkingv1.NetworkPolicyIngressRule{{From: []networkingv1.NetworkPolicyPeer{{
				PodSelector: &metav1.LabelSelector{MatchLabels: map[string]string{"role": "friend"}}}}}},
		}),
	}, extra...)
	return newCompiler(t, objects...)
}

// peerPort is the control plane's peer port, serving views, with the API
// server's certificate for 127.0.0.1.
func peerPort(t *testing.T, p *pki, handler http.Handler) *httptest.Server {
	t.Helper()
	cert, key := p.sign("apiserver", "kube-apiserver", nil, x509.ExtKeyUsageServerAuth, net.ParseIP("127.0.0.1"))
	config, err := peerTLS(cert, key, filepath.Join(p.dir, "ca.crt"))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(handler)
	srv.TLS = config
	srv.EnableHTTP2 = true
	srv.Config.ErrorLog = nil
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv
}

func get(t *testing.T, u *upstream, path string) (string, error) {
	t.Helper()
	body, _, err := u.fetch(path, 0)
	return string(body), err
}

func TestEachNodeIsServedOnlyItsOwnPods(t *testing.T) {
	p := newPKI(t)
	views := newNodeViews()
	r, err := twoNodes(t).compile()
	if err != nil {
		t.Fatal(err)
	}
	views.publish(r)
	srv := peerPort(t, p, views.handler())
	address := srv.Listener.Addr().String()

	a, err := newUpstream(p.kubelet("a"), address)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := newUpstream(p.kubelet("b"), address)

	rulesA, err := get(t, a, "/rules")
	if err != nil {
		t.Fatal(err)
	}
	mustContain(t, rulesA, "## 10.244.0.5\n",
		"ip saddr { 10.244.1.9 } accept") // the peer its policy admits: an address, nothing more
	mustNotContain(t, rulesA, "## 10.244.1.5", "## 10.244.1.9")

	rulesB, _ := get(t, b, "/rules")
	mustContain(t, rulesB, "## 10.244.1.5\n", "## 10.244.1.9\n")
	mustNotContain(t, rulesB, "## 10.244.0.5")

	for _, c := range []struct {
		u    *upstream
		want string
	}{{a, "10.244.0.5"}, {b, "10.244.1.5"}} {
		body, err := get(t, c.u, "/edge")
		if err != nil {
			t.Fatal(err)
		}
		var document edgeDocument
		if err := json.Unmarshal([]byte(body), &document); err != nil {
			t.Fatal(err)
		}
		if _, ok := document.Pods[c.want]; !ok || len(document.Pods) != 1 {
			t.Errorf("%s's edge = %s, want %s alone", c.u.node, body, c.want)
		}
	}

	// A node the cluster has never heard of is served nothing, not everything.
	stranger, _ := newUpstream(p.kubelet("c"), address)
	if body, err := get(t, stranger, "/rules"); err != nil || body != "" {
		t.Errorf("an unknown node got %q, %v", body, err)
	}
	if body, _ := get(t, stranger, "/edge"); body != `{"pods":{}}` {
		t.Errorf("an unknown node's edge = %s", body)
	}
}

func TestPeerPortRefusesAnythingButANode(t *testing.T) {
	p := newPKI(t)
	views := newNodeViews()
	r, _ := twoNodes(t).compile()
	views.publish(r)
	srv := peerPort(t, p, views.handler())
	address := srv.Listener.Addr().String()

	refused := func(what, kubeconfig string) {
		t.Helper()
		u, err := newUpstream(kubeconfig, address)
		if err != nil {
			t.Fatal(err)
		}
		if body, err := get(t, u, "/rules"); err == nil {
			t.Errorf("%s was served %q", what, body)
		}
	}
	refused("an admin", p.kubeconfig("admin", "ferry-admin", "system:masters"))
	refused("a node's name outside the nodes' group", p.kubeconfig("a-masters", "system:node:a", "system:masters"))
	refused("the group without a node's name", p.kubeconfig("unnamed", "a", "system:nodes"))

	// Another cluster's node. It trusts this server's CA, so it is only its
	// own certificate that is refused.
	other := newPKI(t)
	otherConf := other.kubelet("a")
	conf, _ := os.ReadFile(otherConf)
	os.WriteFile(otherConf, []byte(strings.Replace(string(conf),
		filepath.Join(other.dir, "ca.crt"), filepath.Join(p.dir, "ca.crt"), 1)), 0o600)
	refused("another cluster's node", otherConf)

	// No certificate at all: a pod, or anything on the LAN.
	pool := x509.NewCertPool()
	pool.AddCert(p.cert)
	plain := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	if resp, err := plain.Get(srv.URL + "/rules"); err == nil {
		resp.Body.Close()
		t.Errorf("no certificate got %s", resp.Status)
	}

	// And the follower checks the server: a peer port presenting anything but
	// a certificate the cluster CA signed for that address is not the control
	// plane, however good the node's own certificate is.
	impostor := newPKI(t)
	fake := peerPort(t, impostor, views.handler())
	u, _ := newUpstream(p.kubelet("a"), fake.Listener.Addr().String())
	if _, err := get(t, u, "/rules"); err == nil {
		t.Error("a server the cluster CA did not sign was believed")
	}
}

// swap lets a test change what the upstream serves, or take it down.
type swap struct {
	views *nodeViews
	down  atomic.Bool
}

func (s *swap) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if s.down.Load() {
		http.Error(w, "down", http.StatusBadGateway)
		return
	}
	s.views.handler().ServeHTTP(w, r)
}

// local asks the follower's own socket as ferry-cri and ferry-proxy do.
func local(t *testing.T, s *ruleServer, after uint64) (string, uint64, int) {
	t.Helper()
	w := httptest.NewRecorder()
	s.serve(w, httptest.NewRequest("GET", "/rules?after="+strconv.FormatUint(after, 10), nil))
	generation, _ := strconv.ParseUint(w.Header().Get("X-Ferry-Generation"), 10, 64)
	body, _ := io.ReadAll(w.Body)
	return string(body), generation, w.Code
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("never: %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestFollowerServesItsNodesAndKeepsThemWhenTheControlPlaneGoes(t *testing.T) {
	defer func(h time.Duration) { hold = h }(hold)
	hold = 300 * time.Millisecond

	p := newPKI(t)
	upstreamViews := &swap{views: newNodeViews()}
	r, _ := twoNodes(t).compile()
	upstreamViews.views.publish(r)
	srv := peerPort(t, p, upstreamViews)
	address := srv.Listener.Addr().String()

	// One Mac, two nodes, each followed with its own certificate.
	a, _ := newUpstream(p.kubelet("a"), address)
	b, _ := newUpstream(p.kubelet("b"), address)
	rules, edge := newRuleServer("text/plain"), newRuleServer("application/json")
	newFollower([]*upstream{a, b}, rules, edge).start()

	eventually(t, "the follower has both nodes' rules", func() bool {
		body, _, code := local(t, rules, 0)
		return code == 200 && strings.Contains(body, "## 10.244.0.5") && strings.Contains(body, "## 10.244.1.5")
	})
	body, _, _ := local(t, edge, 0)
	var document edgeDocument
	json.Unmarshal([]byte(body), &document)
	if len(document.Pods) != 2 {
		t.Errorf("merged edge = %s, want both web pods", body)
	}

	// A change upstream reaches the local socket, and wakes a held caller.
	_, seen, _ := local(t, rules, 0)
	woken := make(chan string, 1)
	go func() { body, _, _ := local(t, rules, seen); woken <- body }()
	time.Sleep(50 * time.Millisecond)
	started := time.Now()
	r, _ = twoNodes(t, pod("friend-2", "default", "a", "10.244.0.9", map[string]string{"role": "friend"})).compile()
	upstreamViews.views.publish(r)
	select {
	case body := <-woken:
		if !strings.Contains(body, "10.244.0.9") {
			t.Errorf("woken with %q", body)
		}
		t.Logf("upstream change reached a held local caller in %s", time.Since(started))
	case <-time.After(2 * time.Second):
		t.Fatal("a held caller was not woken by an upstream change")
	}

	// The control plane goes away. Nothing is published, so the last rules
	// stay what every caller is given, and a caller that has them is held.
	_, before, _ := local(t, rules, 0)
	upstreamViews.down.Store(true)
	time.Sleep(3 * hold)
	body, after, code := local(t, rules, before)
	if code != 200 || after != before || !strings.Contains(body, "10.244.0.9") {
		t.Errorf("with the control plane down: %d, generation %d -> %d, %q", code, before, after, body)
	}
	edgeBody, _, _ := local(t, edge, 0)
	json.Unmarshal([]byte(edgeBody), &document)
	if len(document.Pods) != 2 {
		t.Errorf("edge with the control plane down = %s", edgeBody)
	}

	// And it comes back to whatever changed while it was gone.
	r, _ = twoNodes(t).compile()
	upstreamViews.views.publish(r)
	upstreamViews.down.Store(false)
	eventually(t, "the follower catches up", func() bool {
		body, _, _ := local(t, rules, 0)
		return !strings.Contains(body, "10.244.0.9")
	})
}

func TestFollowerPublishesNothingUntilEveryNodeIsHeardFrom(t *testing.T) {
	defer func(h time.Duration) { hold = h }(hold)
	hold = 200 * time.Millisecond

	p := newPKI(t)
	views := newNodeViews()
	r, _ := twoNodes(t).compile()
	views.publish(r)
	srv := peerPort(t, p, views.handler())
	address := srv.Listener.Addr().String()

	a, _ := newUpstream(p.kubelet("a"), address)
	// b's certificate is not a node's, so b is never answered.
	b, _ := newUpstream(p.kubeconfig("unnamed", "b", "system:nodes"), address)
	rules, edge := newRuleServer("text/plain"), newRuleServer("application/json")
	newFollower([]*upstream{a, b}, rules, edge).start()

	time.Sleep(4 * hold)
	// Half a merge would tell ferry-proxy that b's pods are isolated by
	// nothing. Refused is what makes it keep what it had.
	if body, _, code := local(t, edge, 0); code != http.StatusServiceUnavailable {
		t.Errorf("edge with one node unheard = %d %q, want 503", code, body)
	}
	if _, _, code := local(t, rules, 0); code != http.StatusServiceUnavailable {
		t.Errorf("rules with one node unheard = %d, want 503", code)
	}
}

func TestGenerationsSurviveARestart(t *testing.T) {
	first := newRuleServer("text/plain")
	first.publish("x")
	_, seen, _ := local(t, first, 0)
	// The process restarts with the same rules, and a caller asks for
	// something newer than what it saw from the old one.
	second := newRuleServer("text/plain")
	second.publish("x")
	_, generation, _ := local(t, second, 0)
	if generation <= seen {
		t.Errorf("a restarted server's generation %d is not newer than %d, so its callers wait out the hold", generation, seen)
	}
}
