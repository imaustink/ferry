// A probe loop against a ferry API server, for measuring what a control plane
// switch costs the people using it.
//
// Every -interval it sends three requests, each on its own schedule so a slow
// one does not hold up the others:
//
//	readyz   GET /readyz on a fresh TCP+TLS connection -- what a new client sees
//	get      GET /api/v1/namespaces/default on a pooled HTTP/2 connection --
//	         what a long-lived client such as the kubelet sees
//	ep       the kubernetes Service's EndpointSlice, counting the moments it has
//	         no ready address -- what every in-cluster client of 10.96.0.1 sees
//
// and keeps one watch open on namespaces, counting how often it has to be
// re-established. It runs until SIGINT or -for, then prints the failures and
// the longest unbroken run of them, which is the outage.
//
//	go run . -home ~/.ferry-<profile> -port 24443 -for 60s
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type sample struct {
	at   time.Time
	ok   bool
	why  string
	took time.Duration
}

type series struct {
	name string
	mu   sync.Mutex
	s    []sample
}

func (r *series) add(ok bool, why string, took ...time.Duration) {
	r.mu.Lock()
	x := sample{at: time.Now(), ok: ok, why: why}
	if len(took) > 0 {
		x.took = took[0]
	}
	r.s = append(r.s, x)
	r.mu.Unlock()
}

// The failures, and the longest stretch from the first failure of a run to the
// first success after it.
func (r *series) report(start time.Time) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	fails := 0
	whys := map[string]int{}
	var longest, cur time.Duration
	var runStart time.Time
	var firstFail, lastFail time.Time
	var slowest time.Duration
	for _, x := range r.s {
		if x.took > slowest {
			slowest = x.took
		}
		if !x.ok {
			fails++
			whys[x.why]++
			if runStart.IsZero() {
				runStart = x.at
			}
			if firstFail.IsZero() {
				firstFail = x.at
			}
			lastFail = x.at
			continue
		}
		if !runStart.IsZero() {
			cur = x.at.Sub(runStart)
			if cur > longest {
				longest = cur
			}
			runStart = time.Time{}
		}
	}
	if !runStart.IsZero() && len(r.s) > 0 {
		if cur = r.s[len(r.s)-1].at.Sub(runStart); cur > longest {
			longest = cur // still failing when the probe stopped
		}
	}
	out := fmt.Sprintf("%-7s %5d requests  %4d failed  longest outage %v  slowest %dms", r.name, len(r.s), fails,
		longest.Round(time.Millisecond), slowest.Milliseconds())
	if fails > 0 {
		out += fmt.Sprintf("  (first at +%v, last at +%v)", firstFail.Sub(start).Round(time.Millisecond), lastFail.Sub(start).Round(time.Millisecond))
		keys := make([]string, 0, len(whys))
		for k := range whys {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			out += fmt.Sprintf("\n          %4d  %s", whys[k], k)
		}
	}
	return out
}

func short(err error) string {
	s := err.Error()
	if i := strings.LastIndex(s, ": "); i >= 0 && len(s) > 120 {
		s = s[i+2:]
	}
	return s
}

func main() {
	home := flag.String("home", "", "the profile's FERRY_HOME")
	port := flag.Int("port", 6443, "API server port")
	interval := flag.Duration("interval", 50*time.Millisecond, "time between probes")
	dur := flag.Duration("for", 0, "stop after this long (default: until SIGINT)")
	flag.Parse()
	if *home == "" {
		fmt.Fprintln(os.Stderr, "-home is required")
		os.Exit(2)
	}
	pki := filepath.Join(*home, "pki")
	cert, err := tls.LoadX509KeyPair(filepath.Join(pki, "admin.crt"), filepath.Join(pki, "admin.key"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	caPEM, err := os.ReadFile(filepath.Join(pki, "ca.crt"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	tlsc := &tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: pool}
	base := fmt.Sprintf("https://127.0.0.1:%d", *port)

	// Ten seconds, not two: a request the handover holds for a moment is slow,
	// not failed, and client-go and kubectl wait longer than either. How slow is
	// reported separately, as "slowest".
	fresh := &http.Client{Timeout: 10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: tlsc, DisableKeepAlives: true}}
	pooled := &http.Client{Timeout: 10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: tlsc.Clone(), ForceAttemptHTTP2: true}}
	watcher := &http.Client{Transport: &http.Transport{TLSClientConfig: tlsc.Clone(), ForceAttemptHTTP2: true}}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	if *dur > 0 {
		ctx, cancel = context.WithTimeout(ctx, *dur)
		defer cancel()
	}

	get := func(c *http.Client, path string) (int, []byte, error) {
		req, _ := http.NewRequestWithContext(ctx, "GET", base+path, nil)
		resp, err := c.Do(req)
		if err != nil {
			return 0, nil, err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, b, nil
	}

	readyz := &series{name: "readyz"}
	getS := &series{name: "get"}
	ep := &series{name: "ep"}
	watchS := &series{name: "watch"}
	start := time.Now()

	loop := func(fn func()) {
		t := time.NewTicker(*interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				fn()
			}
		}
	}
	var wg sync.WaitGroup
	run := func(fn func()) { wg.Add(1); go func() { defer wg.Done(); loop(fn) }() }

	record := func(s *series, c *http.Client, path string) {
		t0 := time.Now()
		code, _, err := get(c, path)
		took := time.Since(t0)
		switch {
		case ctx.Err() != nil:
		case err != nil:
			s.add(false, short(err), took)
		case code != 200:
			s.add(false, fmt.Sprintf("HTTP %d", code), took)
		default:
			s.add(true, "", took)
		}
	}
	run(func() { record(readyz, fresh, "/readyz") })
	run(func() { record(getS, pooled, "/api/v1/namespaces/default") })
	run(func() {
		code, b, err := get(pooled, "/apis/discovery.k8s.io/v1/namespaces/default/endpointslices/kubernetes")
		if ctx.Err() != nil {
			return
		}
		if err != nil || code != 200 {
			return // the API being down is counted by the others
		}
		var slice struct {
			Endpoints []struct {
				Addresses  []string `json:"addresses"`
				Conditions struct {
					Ready *bool `json:"ready"`
				} `json:"conditions"`
			} `json:"endpoints"`
		}
		if json.Unmarshal(b, &slice) != nil {
			ep.add(false, "undecodable")
			return
		}
		for _, e := range slice.Endpoints {
			if len(e.Addresses) > 0 && (e.Conditions.Ready == nil || *e.Conditions.Ready) {
				ep.add(true, "")
				return
			}
		}
		ep.add(false, "no ready address")
	})

	// One watch, re-established whenever it ends. Every re-establishment is
	// recorded as a failure sample, so "watch" counts reconnects.
	wg.Add(1)
	go func() {
		defer wg.Done()
		rv := ""
		for ctx.Err() == nil {
			path := "/api/v1/namespaces?watch=true&allowWatchBookmarks=true&timeoutSeconds=3600"
			if rv != "" {
				path += "&resourceVersion=" + rv
			}
			req, _ := http.NewRequestWithContext(ctx, "GET", base+path, nil)
			resp, err := watcher.Do(req)
			if err != nil {
				if ctx.Err() == nil {
					watchS.add(false, "open: "+short(err))
				}
				time.Sleep(*interval)
				continue
			}
			if resp.StatusCode != 200 {
				watchS.add(false, fmt.Sprintf("open: HTTP %d", resp.StatusCode))
				resp.Body.Close()
				rv = ""
				time.Sleep(*interval)
				continue
			}
			watchS.add(true, "")
			sc := bufio.NewScanner(resp.Body)
			sc.Buffer(make([]byte, 1<<20), 1<<24)
			for sc.Scan() {
				var ev struct {
					Type   string `json:"type"`
					Object struct {
						Metadata struct {
							ResourceVersion string `json:"resourceVersion"`
						} `json:"metadata"`
					} `json:"object"`
				}
				if json.Unmarshal(sc.Bytes(), &ev) == nil {
					if ev.Type == "ERROR" {
						rv = "" // too old: start again from now
					} else if v := ev.Object.Metadata.ResourceVersion; v != "" {
						rv = v
					}
				}
			}
			resp.Body.Close()
			if ctx.Err() == nil {
				watchS.add(false, "watch closed by server")
			}
		}
	}()

	<-ctx.Done()
	wg.Wait()
	fmt.Printf("probed every %v for %v\n", *interval, time.Since(start).Round(time.Second))
	for _, s := range []*series{readyz, getS, ep, watchS} {
		fmt.Println(s.report(start))
	}
}
