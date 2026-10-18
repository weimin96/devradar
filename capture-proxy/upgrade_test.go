package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// Verify that a genuine 101 upgrade can carry bidirectional bytes through
// the intercepting proxy. A 200 response alone would not catch broken
// Connection/Upgrade header handling.
func TestWebSocketUpgradeRoundTrip(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !headerHasToken(r.Header.Get("Connection"), "upgrade") ||
			!strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			t.Errorf("upgrade headers lost: %v", r.Header)
			http.Error(w, "bad upgrade", http.StatusBadRequest)
			return
		}
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Error("no hijacker")
			return
		}
		c, _, err := hj.Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		_, _ = io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
		data := make([]byte, 4)
		if _, err := io.ReadFull(c, data); err != nil {
			t.Error(err)
			return
		}
		if string(data) != "ping" {
			t.Errorf("received %q", data)
		}
		_, _ = io.WriteString(c, "pong")
	}))
	defer upstream.Close()
	var events bytes.Buffer
	destination, _ := url.Parse(upstream.URL)
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	p := &proxy{transport: transport, report: &reporter{enc: json.NewEncoder(&events)}}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p.localAddress = ln.Addr().String()
	srv := &http.Server{Handler: p}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	conn, err := net.DialTimeout("tcp", ln.Addr().String(), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprintf(conn, "GET %s/ws HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n", upstream.URL, destination.Host)
	reader := bufio.NewReader(conn)
	req := &http.Request{Method: "GET"}
	response, err := http.ReadResponse(reader, req)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade status %d", response.StatusCode)
	}
	_, _ = conn.Write([]byte("ping"))
	reply := make([]byte, 4)
	if _, err := io.ReadFull(reader, reply); err != nil {
		t.Fatal(err)
	}
	if string(reply) != "pong" {
		t.Fatalf("bidirectional tunnel returned %q", reply)
	}
	if !strings.Contains(events.String(), "\"type\":\"upgrade\"") {
		t.Fatalf("missing upgrade event: %s", events.String())
	}
}

func TestUpgradeHeaderToken(t *testing.T) {
	if !headerHasToken("keep-alive, Upgrade", "upgrade") ||
		headerHasToken("X-Upgraded", "upgrade") {
		t.Fatal("upgrade token parsing regression")
	}
}
