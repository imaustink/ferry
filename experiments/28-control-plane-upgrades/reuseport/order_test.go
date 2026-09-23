package main

// Which of several SO_REUSEPORT listeners a new connection reaches, as a test
// so it runs without disturbing the handover measurement in main.go:
//
//	go test -run Order -v .
import (
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"
)

func count(t *testing.T, url string, n int) map[string]int {
	c := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}, Timeout: 2 * time.Second}
	got := map[string]int{}
	for i := 0; i < n; i++ {
		resp, err := c.Get(url)
		if err != nil {
			got["error"]++
			continue
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		got[string(b)]++
	}
	return got
}

func TestOrder(t *testing.T) {
	port := 23444
	var servers []*server
	for _, id := range []string{"A", "B", "C"} {
		l, err := listen(port, true)
		if err != nil {
			t.Fatal(err)
		}
		servers = append(servers, serve(id, l, 0))
		for _, host := range []string{"127.0.0.1", "[::1]"} {
			fmt.Printf("bound through %s, dialling %-9s -> %v\n", id, host,
				count(t, fmt.Sprintf("http://%s:%d/", host, port), 200))
		}
	}
	for i, id := range []string{"A", "B"} {
		servers[i].ln.Close()
		fmt.Printf("closed %s -> %v\n", id, count(t, fmt.Sprintf("http://127.0.0.1:%d/", port), 200))
	}
	servers[2].ln.Close()
}
