package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCertificateAndHTTPSUpload(t *testing.T) {
	directory := t.TempDir()
	ca, err := createOrLoadCA(directory)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := createOrLoadCA(directory); err != nil {
		t.Fatal("CA should be reusable", err)
	}
	keyInfo, err := os.Stat(filepath.Join(directory, "DevRadar-Local-CA.key"))
	if err != nil {
		t.Fatal(err)
	}
	if keyInfo.Mode().Perm() != 0600 {
		t.Fatalf("CA key permissions: %v", keyInfo.Mode())
	}
	der, err := os.ReadFile(filepath.Join(directory, "DevRadar-Local-CA.cer"))
	if err != nil {
		t.Fatal(err)
	}
	derCert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(derCert.Raw, ca.cert.Raw) {
		t.Fatal("DER certificate differs from PEM root CA")
	}
	rootPool := x509.NewCertPool()
	if !rootPool.AppendCertsFromPEM(ca.rootPEM) {
		t.Fatal("root CA is invalid")
	}

	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("method: %s", r.Method)
		}
		_, _ = io.Copy(io.Discard, r.Body)
		_, _ = w.Write([]byte("received"))
	}))
	defer origin.Close()
	var events bytes.Buffer
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.TLSClientConfig = &tls.Config{RootCAs: origin.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs, InsecureSkipVerify: true} // test-only self-signed upstream
	p := &proxy{ca: ca, intercept: true, preview: true, transport: transport, report: &reporter{enc: json.NewEncoder(&events)}}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p.localAddress = ln.Addr().String()
	server := &http.Server{Handler: p}
	go server.Serve(ln)
	defer server.Close()
	proxyURL, _ := url.Parse("http://" + p.localAddress)
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: rootPool}}}
	req, err := http.NewRequest("POST", origin.URL+"/upload?secret=query-not-saved", strings.NewReader(`{"name":"report","token":"do-not-store"}`))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatalf("HTTP status %d", response.StatusCode)
	}
	time.Sleep(30 * time.Millisecond)
	got := events.String()
	if !strings.Contains(got, "\"type\":\"request\"") {
		t.Fatalf("request not captured: %s", got)
	}
	if !strings.Contains(got, "\"preview\"") {
		t.Fatalf("missing body preview: %s", got)
	}
	if strings.Contains(got, "do-not-store") || strings.Contains(got, "query-not-saved") {
		t.Fatalf("secret leaked in event: %s", got)
	}
	if !strings.Contains(got, "[redacted]") {
		t.Fatalf("redaction missing: %s", got)
	}
}

func TestRefuseSelfProxy(t *testing.T) {
	var output bytes.Buffer
	p := &proxy{report: &reporter{enc: json.NewEncoder(&output)}, localAddress: "127.0.0.1:8876"}
	r := httptest.NewRequest("GET", "http://127.0.0.1:8876/", nil)
	w := httptest.NewRecorder()
	p.ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", w.Code)
	}
}
