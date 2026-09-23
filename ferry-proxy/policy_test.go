package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"syscall"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// What ferry-netpol renders for: web (10.244.0.5) open on 80 to the LAN except
// one address and to one pod, and on 8443-8445 to anyone; hostPort 8080 is its
// container port 80. db (10.244.0.6) is deny-all.
const document = `{"pods":{
  "10.244.0.5":{"rules":[
    {"from":[{"cidr":"192.168.1.0/24","except":["192.168.1.29/32"]},{"cidr":"10.244.1.9/32"}],
     "ports":[{"protocol":"tcp","port":80}]},
    {"all":true,"ports":[{"protocol":"tcp","port":8443,"endPort":8445},{"protocol":"udp"}]}
  ],"hostPorts":{"tcp/8080":80}},
  "10.244.0.6":{"rules":[]}
}}`

func loadPolicy(t *testing.T, doc string) {
	t.Helper()
	policy, err := parseEdgePolicy([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	currentEdgePolicy.Store(policy)
	t.Cleanup(func() { currentEdgePolicy.Store(nil) })
}

func TestAdmits(t *testing.T) {
	loadPolicy(t, document)
	ap := netip.MustParseAddrPort
	ip := netip.MustParseAddr
	cases := []struct {
		pod, protocol, client string
		hostPort              bool
		want                  bool
	}{
		{"10.244.0.5:80", "tcp", "192.168.1.40", false, true},
		{"10.244.0.5:80", "tcp", "::ffff:192.168.1.40", false, true}, // a dual-stack listener's view
		{"10.244.0.5:80", "tcp", "192.168.1.29", false, false},       // the exception
		{"10.244.0.5:80", "tcp", "192.168.2.1", false, false},
		{"10.244.0.5:80", "tcp", "10.244.1.9", false, true},
		{"10.244.0.5:80", "udp", "192.168.1.40", false, true}, // every UDP port, from anyone
		{"10.244.0.5:81", "tcp", "192.168.1.40", false, false},
		{"10.244.0.5:8444", "tcp", "127.0.0.1", false, true},
		{"10.244.0.5:8446", "tcp", "127.0.0.1", false, false},
		{"10.244.0.5:8080", "tcp", "192.168.1.40", true, true}, // hostPort 8080 is container port 80
		{"10.244.0.5:8081", "tcp", "192.168.1.40", true, false},
		{"10.244.0.6:5432", "tcp", "127.0.0.1", false, false},
		{"10.244.0.7:80", "tcp", "192.168.2.1", false, true}, // no policy isolates it
	}
	for _, c := range cases {
		if got := admits(ap(c.pod), c.protocol, ip(c.client), c.hostPort); got != c.want {
			t.Errorf("admits(%s %s from %s, hostPort=%v) = %v, want %v",
				c.pod, c.protocol, c.client, c.hostPort, got, c.want)
		}
	}
	// A forward to another node has no pod, and is that node's to check.
	if !admits(netip.AddrPort{}, "tcp", ip("192.168.2.1"), false) {
		t.Error("a node forward should not be checked here")
	}
}

func TestNoPolicyAdmitsEverything(t *testing.T) {
	currentEdgePolicy.Store(nil)
	if !admits(netip.MustParseAddrPort("10.244.0.6:5432"), "tcp", netip.MustParseAddr("1.2.3.4"), false) {
		t.Error("with no document every pod is open, as it is at the pod")
	}
}

// echoServer answers each connection with one line naming itself.
func echoServer(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			fmt.Fprintln(c, "backend")
			c.Close()
		}
	}()
	return l.Addr().String()
}

func dialAndRead(address string) (string, error) {
	c, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return "", err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	return strings.TrimSpace(line), err
}

func freePort(t *testing.T) int32 {
	t.Helper()
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return int32(l.Addr().(*net.TCPAddr).Port)
}

// A narrowed wildcard answers at the addresses it was given and refuses the
// rest, which is what binding those addresses alone would have done.
func TestNarrowedListener(t *testing.T) {
	backendAddress := echoServer(t)
	port := freePort(t)
	p, err := newServiceProxy("test", "", port, corev1.ProtocolTCP, localAddresses{netip.MustParseAddr("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	p.setBackends([]backend{podBackend(backendAddress)})

	if got, err := dialAndRead(fmt.Sprintf("127.0.0.1:%d", port)); err != nil || got != "backend" {
		t.Errorf("127.0.0.1: got %q, %v", got, err)
	}
	if got, err := dialAndRead(fmt.Sprintf("[::1]:%d", port)); err == nil && got != "" {
		t.Errorf("::1 is not in the set and should be refused, got %q", got)
	}
}

func TestPolicyRefusesAtTheEdge(t *testing.T) {
	backendAddress := echoServer(t)
	port := freePort(t)
	p, err := newServiceProxy("test", "127.0.0.1", port, corev1.ProtocolTCP, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	p.setBackends([]backend{podBackend(backendAddress)})
	listen := fmt.Sprintf("127.0.0.1:%d", port)

	if got, _ := dialAndRead(listen); got != "backend" {
		t.Fatalf("before any policy: got %q", got)
	}
	loadPolicy(t, `{"pods":{"127.0.0.1":{"rules":[]}}}`)
	if got, err := dialAndRead(listen); got != "" {
		t.Errorf("deny-all: got %q (%v), want a refusal", got, err)
	}
	loadPolicy(t, `{"pods":{"127.0.0.1":{"rules":[{"from":[{"cidr":"127.0.0.0/8"}]}]}}}`)
	if got, _ := dialAndRead(listen); got != "backend" {
		t.Errorf("ipBlock allowing loopback: got %q", got)
	}
	loadPolicy(t, `{"pods":{"127.0.0.1":{"rules":[{"from":[{"cidr":"127.0.0.0/8","except":["127.0.0.1/32"]}]}]}}}`)
	if got, _ := dialAndRead(listen); got != "" {
		t.Errorf("ipBlock except: got %q, want a refusal", got)
	}
}

// UDP through a narrowed wildcard: answered at the address it was sent to, and
// the reply comes from that address.
func TestNarrowedUDP(t *testing.T) {
	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buffer := make([]byte, 1500)
		for {
			n, from, err := echo.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			echo.WriteToUDP(append([]byte("echo:"), buffer[:n]...), from)
		}
	}()

	port := freePort(t)
	backends, _ := newServiceProxy("test", "", port, corev1.ProtocolUDP, nil)
	backends.setBackends([]backend{podBackend(echo.LocalAddr().String())})
	u, err := newUDPProxy("test", "", port, backends, localAddresses{netip.MustParseAddr("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer u.close()

	c, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(port)})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	c.Write([]byte("hi"))
	buffer := make([]byte, 100)
	n, err := c.Read(buffer) // a connected socket only accepts a reply from 127.0.0.1:port
	if err != nil || string(buffer[:n]) != "echo:hi" {
		t.Errorf("got %q, %v", buffer[:n], err)
	}
}

func TestListenFailureNamesTheCause(t *testing.T) {
	e := exposure{port: 80, shown: "192.168.1.29", kind: "LoadBalancer"}
	inUse := &net.OpError{Op: "listen", Err: &osSyscallError{syscall.EADDRINUSE}}
	if reason, message := listenFailure(e, inUse); reason != "PortInUse" ||
		!strings.Contains(message, "lsof -nP -iTCP:80") || !strings.Contains(message, "192.168.1.29:80") {
		t.Errorf("in use: %s %s", reason, message)
	}
	if reason, _ := listenFailure(e, &net.OpError{Op: "listen", Err: &osSyscallError{syscall.EACCES}}); reason != "PortNotPermitted" {
		t.Errorf("EACCES: %s", reason)
	}
}

// The whole of what policy adds to a connection: one lookup.
func BenchmarkAdmits(b *testing.B) {
	policy, _ := parseEdgePolicy([]byte(document))
	currentEdgePolicy.Store(policy)
	defer currentEdgePolicy.Store(nil)
	client := netip.MustParseAddr("192.168.1.40")
	for name, pod := range map[string]string{
		"pod no policy selects": "10.244.0.7:80",
		"isolated pod, allowed": "10.244.0.5:80",
		"isolated pod, refused": "10.244.0.6:5432",
	} {
		pod := netip.MustParseAddrPort(pod)
		b.Run(name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				admits(pod, "tcp", client, false)
			}
		})
	}
}

type osSyscallError struct{ errno syscall.Errno }

func (e *osSyscallError) Error() string { return e.errno.Error() }
func (e *osSyscallError) Unwrap() error { return e.errno }

// Another process holding the wildcard -- AirPlay's *:5000, say -- leaves the
// particular addresses free, and the Service is served there instead.
func TestWildcardTakenFallsBackToAddresses(t *testing.T) {
	backendAddress := echoServer(t)
	port := freePort(t)
	squatter, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer squatter.Close()

	p, err := newServiceProxy("lb", "", port, corev1.ProtocolTCP, localAddresses{netip.MustParseAddr("127.0.0.1")})
	if err != nil {
		t.Fatalf("with the wildcard taken: %v", err)
	}
	defer p.close()
	if !p.shared {
		t.Error("should say it fell back")
	}
	p.setBackends([]backend{podBackend(backendAddress)})
	if got, _ := dialAndRead(fmt.Sprintf("127.0.0.1:%d", port)); got != "backend" {
		t.Errorf("127.0.0.1 should reach the Service ahead of the wildcard's owner, got %q", got)
	}
}

// Two of this process's own Services on one port must not fall back onto each
// other: the second is refused, as it was when a listener was the arbiter.
func TestOwnPortConflict(t *testing.T) {
	c := &controller{proxies: map[string]*serviceProxy{
		"nodeport/default/a:30080/TCP":     {},
		"loadbalancer/default/b:8080/TCP":  {},
		"clusterip/default/c:8080":         {},
		"loadbalancer/default/d:8080/UDP":  {},
		"loadbalancer/default/self:81/TCP": {},
	}}
	for key, conflict := range map[string]bool{
		"loadbalancer/default/x:8080/TCP":  true,
		"loadbalancer/default/x:30080/TCP": true, // a node port is a wildcard listener too
		"loadbalancer/default/x:8081/TCP":  false,
		"loadbalancer/default/x:30080/UDP": false,
		"loadbalancer/default/self:81/TCP": false,
		"clusterip/default/x:8080":         false,
	} {
		err := c.ownPortConflict(exposure{key: key})
		if (err != nil) != conflict || (err != nil && !errors.Is(err, syscall.EADDRINUSE)) {
			t.Errorf("%s: %v", key, err)
		}
	}
}

func TestSCTPIsReportedNotServed(t *testing.T) {
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: "s", Namespace: "default"},
		Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeLoadBalancer, Ports: []corev1.ServicePort{
			{Port: 80, NodePort: 30080, Protocol: corev1.ProtocolTCP},
			{Port: 7777, NodePort: 30777, Protocol: corev1.ProtocolSCTP},
		}},
	}
	exposures, sctp := exposuresFor(service, "192.168.1.29")
	if len(exposures) != 2 {
		t.Errorf("want the TCP port's node port and load balancer, got %+v", exposures)
	}
	if strings.Join(sctp, ", ") != "node port 30777, 192.168.1.29:7777" {
		t.Errorf("sctp: %v", sctp)
	}
	for _, e := range exposures {
		if e.kind == "LoadBalancer" && (e.address != "" || !e.only.hasIP(netip.MustParseAddr("192.168.1.29"))) {
			t.Errorf("a LoadBalancer should be a narrowed wildcard: %+v", e)
		}
	}
}
