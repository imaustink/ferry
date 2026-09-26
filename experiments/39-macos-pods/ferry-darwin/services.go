package main

// Services for pods on a macOS node, without kube-proxy.
//
// kube-proxy programs the kernel to rewrite a ClusterIP to one of its
// endpoints; on a Linux node that is iptables or nftables, and ferry's pod VMs
// apply its rules in their own kernels. A macOS node has neither, and pf's rdr
// does not see traffic a local process originates. But every container here
// already runs podnet.dylib, which already sits in connect(). So the rewrite
// happens there, per socket, the way Cilium's socket-level load balancer does
// it: this writes the table -- one line per service port --
//
//	tcp 10.96.14.2:80 10.190.4.2:8080,10.190.4.3:8080
//
// into /lib/ferry-services in every container root, and the shim picks an
// endpoint when a pod connects to a ClusterIP.
//
// Cluster DNS rides on the same table. macOS resolves names in mDNSResponder,
// one process for the whole node, which a chroot does not change, so the pod's
// resolv.conf means nothing. What does is /etc/resolver/<cluster domain>: every
// name under it goes to the servers it lists. Those are the endpoints of the
// cluster DNS Service -- not its ClusterIP, which mDNSResponder would send to
// without the shim -- or, when it has none, the address ferry reserves for
// CoreDNS, .0.2 of the cluster CIDR.
//
// Read with the kubelet's own client certificate: system:node may list
// Services and EndpointSlices, and a second credential would be a second thing
// to rotate. A poll, not a watch -- a handful of services on one node.

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const servicesInRoot = "lib/ferry-services"

type serviceTable struct {
	api, ca, cert string
	dnsIP, domain string
	reservedDNS   string
	rt            *runtimeSvc
	client        *http.Client
	current       string
	resolver      string
	nodeName      string
	peerRoutes    map[string]string
}

func (t *serviceTable) run() {
	for {
		if err := t.refresh(); err != nil {
			log.Printf("services: %v", err)
		}
		time.Sleep(2 * time.Second)
	}
}

func (t *serviceTable) connect() error {
	if t.client != nil {
		return nil
	}
	pair, err := tls.LoadX509KeyPair(t.cert, t.cert)
	if err != nil {
		return fmt.Errorf("the kubelet's certificate is not there yet: %w", err)
	}
	pem, err := os.ReadFile(t.ca)
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	t.client = &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{pair}},
	}}
	return nil
}

func (t *serviceTable) get(path string, into any) error {
	resp, err := t.client.Get(t.api + path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.client = nil // a rotated certificate is picked up on the next pass
		return fmt.Errorf("GET %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(into)
}

type k8sPort struct {
	Name       string `json:"name"`
	Protocol   string `json:"protocol"`
	Port       int    `json:"port"`
	TargetPort any    `json:"targetPort"`
}

func (t *serviceTable) refresh() error {
	if err := t.connect(); err != nil {
		return err
	}
	var svcs struct {
		Items []struct {
			Metadata struct{ Name, Namespace string } `json:"metadata"`
			Spec     struct {
				ClusterIP string    `json:"clusterIP"`
				Ports     []k8sPort `json:"ports"`
			} `json:"spec"`
		} `json:"items"`
	}
	var slices struct {
		Items []struct {
			Metadata struct {
				Namespace string            `json:"namespace"`
				Labels    map[string]string `json:"labels"`
			} `json:"metadata"`
			Endpoints []struct {
				Addresses  []string `json:"addresses"`
				Conditions struct {
					Ready *bool `json:"ready"`
				} `json:"conditions"`
			} `json:"endpoints"`
			Ports []struct {
				Name     *string `json:"name"`
				Protocol *string `json:"protocol"`
				Port     *int    `json:"port"`
			} `json:"ports"`
		} `json:"items"`
	}
	if err := t.refreshNodes(); err != nil {
		log.Printf("services: %v", err)
	}
	if err := t.get("/api/v1/services", &svcs); err != nil {
		return err
	}
	if err := t.get("/apis/discovery.k8s.io/v1/endpointslices", &slices); err != nil {
		return err
	}

	var lines []string
	var dns []string
	for _, s := range svcs.Items {
		ip := s.Spec.ClusterIP
		if ip == "" || ip == "None" {
			continue
		}
		key := s.Metadata.Namespace + "/" + s.Metadata.Name
		for _, p := range s.Spec.Ports {
			proto := strings.ToLower(p.Protocol)
			if proto == "" {
				proto = "tcp"
			}
			var eps []string
			for _, sl := range slices.Items {
				if sl.Metadata.Namespace+"/"+sl.Metadata.Labels["kubernetes.io/service-name"] != key {
					continue
				}
				port := 0
				for _, sp := range sl.Ports {
					name := ""
					if sp.Name != nil {
						name = *sp.Name
					}
					if name == p.Name && sp.Port != nil {
						port = *sp.Port
					}
				}
				if port == 0 {
					continue
				}
				for _, e := range sl.Endpoints {
					if e.Conditions.Ready != nil && !*e.Conditions.Ready {
						continue
					}
					for _, a := range e.Addresses {
						eps = append(eps, fmt.Sprintf("%s:%d", a, port))
						if ip == t.dnsIP && port == 53 && proto == "udp" {
							dns = append(dns, a)
						}
					}
				}
			}
			if len(eps) == 0 {
				continue
			}
			sort.Strings(eps)
			lines = append(lines, fmt.Sprintf("%s %s:%d %s", proto, ip, p.Port, strings.Join(eps, ",")))
		}
	}
	sort.Strings(lines)
	table := strings.Join(lines, "\n") + "\n"
	if table != t.current {
		t.current = table
		log.Printf("services: %d service ports with endpoints", len(lines))
		for _, root := range t.rt.roots() {
			t.install(root)
		}
	}
	if len(dns) == 0 && t.reservedDNS != "" {
		dns = []string{t.reservedDNS}
	}
	t.writeResolver(dns)
	return nil
}

// install puts the current table into one container root, atomically: the
// shim reads it on every connect to a ClusterIP.
func (t *serviceTable) install(root string) {
	dst := filepath.Join(root, servicesInRoot)
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, []byte(t.current), 0o644); err == nil {
		_ = os.Rename(tmp, dst)
	}
}

func (t *serviceTable) writeResolver(servers []string) {
	if t.domain == "" || len(servers) == 0 {
		return
	}
	sort.Strings(servers)
	var b strings.Builder
	fmt.Fprintf(&b, "# written by ferry-darwin: names under %s go to cluster DNS\n", t.domain)
	for _, s := range servers {
		fmt.Fprintf(&b, "nameserver %s\n", s)
	}
	body := b.String()
	if body == t.resolver {
		return
	}
	_ = os.MkdirAll("/etc/resolver", 0o755)
	if err := os.WriteFile(filepath.Join("/etc/resolver", t.domain), []byte(body), 0o644); err != nil {
		log.Printf("services: resolver: %v", err)
		return
	}
	t.resolver = body
	log.Printf("services: %s resolves through %s", t.domain, strings.Join(servers, ", "))
	go t.checkResolver()
}

// checkResolver says, in the log, whether mDNSResponder took the file and
// whether a name resolves from the node itself -- which is the difference
// between cluster DNS not working and it not working inside a chroot.
func (t *serviceTable) checkResolver() {
	time.Sleep(2 * time.Second)
	out, _ := exec.Command("scutil", "--dns").Output()
	seen := false
	for _, block := range strings.Split(string(out), "\n\n") {
		if strings.Contains(block, "domain   : "+t.domain) {
			seen = true
			log.Printf("services: scutil --dns has %s:\n%s", t.domain, strings.TrimSpace(block))
			break
		}
	}
	if !seen {
		log.Printf("services: scutil --dns does not list %s", t.domain)
	}
	name := "kubernetes.default.svc." + t.domain
	res, err := exec.Command("dscacheutil", "-q", "host", "-a", "name", name).CombinedOutput()
	log.Printf("services: from the node, %s -> %q (err %v)", name, strings.TrimSpace(string(res)), err)
}

// reservedDNSFor is .0.2 of the cluster CIDR, where ferry puts the Mac's
// CoreDNS before any pod can take the address.
func reservedDNSFor(clusterCIDR *net.IPNet) string {
	if clusterCIDR == nil {
		return ""
	}
	b := clusterCIDR.IP.To4()
	return fmt.Sprintf("%d.%d.0.2", b[0], b[1])
}
