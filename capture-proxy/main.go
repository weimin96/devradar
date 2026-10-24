// devradar-proxy is a loopback-only HTTP/HTTPS debugging proxy.
// It is built into DevRadar; it does not use mitmproxy or a Network Extension.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const maxBodySample = 2048

type event struct {
	RequestID     string `json:"requestId,omitempty"`
	Timestamp     string `json:"timestamp,omitempty"`
	DurationMs    int64  `json:"durationMs,omitempty"`
	Type          string `json:"type"`
	Method        string `json:"method,omitempty"`
	Host          string `json:"host,omitempty"`
	Path          string `json:"path,omitempty"`
	Status        int    `json:"status,omitempty"`
	UploadBytes   int64  `json:"uploadBytes,omitempty"`
	DownloadBytes int64  `json:"downloadBytes,omitempty"`
	ContentType   string `json:"contentType,omitempty"`
	Preview       string `json:"preview,omitempty"`
	Message       string `json:"message,omitempty"`
}

type reporter struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func (r *reporter) send(e event) {
	r.mu.Lock()
	defer r.mu.Unlock()
	_ = r.enc.Encode(e)
}

type certificateAuthority struct {
	cert    *x509.Certificate
	key     *ecdsa.PrivateKey
	rootPEM []byte
	mu      sync.Mutex
	cache   map[string]*tls.Certificate
}

func createOrLoadCA(folder string) (*certificateAuthority, error) {
	if err := os.MkdirAll(folder, 0700); err != nil {
		return nil, err
	}
	certPath := filepath.Join(folder, "DevRadar-Local-CA.pem")
	keyPath := filepath.Join(folder, "DevRadar-Local-CA.key")
	certBytes, certErr := os.ReadFile(certPath)
	keyBytes, keyErr := os.ReadFile(keyPath)
	if certErr != nil || keyErr != nil {
		if !errors.Is(certErr, os.ErrNotExist) || !errors.Is(keyErr, os.ErrNotExist) {
			return nil, fmt.Errorf("CA certificate/key incomplete or unreadable; refusing replacement")
		}
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, err
		}
		serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if err != nil {
			return nil, err
		}
		tmpl := &x509.Certificate{
			SerialNumber: serial, Subject: pkix.Name{CommonName: "DevRadar Local Capture CA"},
			NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().AddDate(1, 0, 0),
			IsCA: true, BasicConstraintsValid: true,
			KeyUsage:       x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
			MaxPathLenZero: true,
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
		if err != nil {
			return nil, err
		}
		certBytes = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		keyDer, err := x509.MarshalECPrivateKey(key)
		if err != nil {
			return nil, err
		}
		keyBytes = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDer})
		// Fail closed if a key or CA file already appeared concurrently.
		file, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return nil, err
		}
		if _, err = file.Write(keyBytes); err != nil {
			file.Close()
			return nil, err
		}
		if err = file.Close(); err != nil {
			return nil, err
		}
		file, err = os.OpenFile(certPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return nil, err
		}
		if _, err = file.Write(certBytes); err != nil {
			file.Close()
			return nil, err
		}
		if err = file.Close(); err != nil {
			return nil, err
		}
	}
	block, _ := pem.Decode(certBytes)
	keyBlock, _ := pem.Decode(keyBytes)
	if block == nil || keyBlock == nil {
		return nil, fmt.Errorf("invalid CA PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, err := x509.ParseECPrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, err
	}
	if !cert.IsCA || time.Now().After(cert.NotAfter) {
		return nil, fmt.Errorf("CA expired or not a CA")
	}
	// Keychain Access can import PEM, but on some macOS configurations its
	// Import Items flow is more reliable with the DER-encoded .cer format.
	// Export only the *public* certificate. Never expose the CA private key.
	derPath := filepath.Join(folder, "DevRadar-Local-CA.cer")
	if existing, err := os.ReadFile(derPath); err == nil {
		if !bytes.Equal(existing, cert.Raw) {
			return nil, fmt.Errorf("DER certificate does not match the existing CA; refusing to overwrite")
		}
	} else if errors.Is(err, os.ErrNotExist) {
		file, err := os.OpenFile(derPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return nil, err
		}
		if _, err = file.Write(cert.Raw); err != nil {
			file.Close()
			return nil, err
		}
		if err = file.Close(); err != nil {
			return nil, err
		}
	} else {
		return nil, err
	}
	return &certificateAuthority{cert: cert, key: key, rootPEM: certBytes, cache: make(map[string]*tls.Certificate)}, nil
}

func (ca *certificateAuthority) forHost(host string) (*tls.Certificate, error) {
	ca.mu.Lock()
	defer ca.mu.Unlock()
	if cached := ca.cache[host]; cached != nil {
		return cached, nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	leaf := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: host},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	if ip := net.ParseIP(host); ip != nil {
		leaf.IPAddresses = []net.IP{ip}
	} else {
		leaf.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		return nil, err
	}
	cert := &tls.Certificate{Certificate: [][]byte{der, ca.cert.Raw}, PrivateKey: key}
	ca.cache[host] = cert
	return cert, nil
}

type proxy struct {
	report        *reporter
	ca            *certificateAuthority
	intercept     bool
	preview       bool
	transport     *http.Transport
	localAddress  string
	upstreamProxy *url.URL
	sequence      atomic.Uint64
}

func (p *proxy) beginRequest(method string, target *url.URL) (string, time.Time) {
	started := time.Now()
	id := fmt.Sprintf("%d", p.sequence.Add(1))
	p.report.send(event{
		Type: "started", RequestID: id, Timestamp: started.UTC().Format(time.RFC3339Nano),
		Method: method, Host: target.Host, Path: truncate(target.EscapedPath(), 384),
	})
	return id, started
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.connect(w, r)
		return
	}
	p.forward(w, r, "")
}

type countingBody struct {
	io.ReadCloser
	n       int64
	sample  []byte
	preview bool
}

func (b *countingBody) Read(buf []byte) (int, error) {
	n, err := b.ReadCloser.Read(buf)
	b.n += int64(n)
	if b.preview && len(b.sample) < maxBodySample {
		remaining := maxBodySample - len(b.sample)
		if n < remaining {
			remaining = n
		}
		b.sample = append(b.sample, buf[:remaining]...)
	}
	return n, err
}

func (p *proxy) forward(w http.ResponseWriter, request *http.Request, forcedScheme string) {
	target := request.URL
	if !target.IsAbs() {
		copyURL := *target
		copyURL.Scheme = forcedScheme
		if copyURL.Scheme == "" {
			copyURL.Scheme = "http"
		}
		copyURL.Host = request.Host
		target = &copyURL
	}
	if target.Host == "" {
		http.Error(w, "missing host", http.StatusBadRequest)
		return
	}
	if target.Host == p.localAddress {
		http.Error(w, "proxy cannot forward to itself", http.StatusForbidden)
		return
	}
	if len(target.Hostname()) > 253 {
		http.Error(w, "host too long", http.StatusBadRequest)
		return
	}
	// Go's ReverseProxy handles 101 Switching Protocols and bidirectional
	// websocket streams. The ordinary HTTP path below strips hop-by-hop
	// headers, which would silently break Upgrade. These tunnel bytes are
	// intentionally NOT inspected or attributed to the selected application.
	if headerHasToken(request.Header.Get("Connection"), "upgrade") &&
		request.Header.Get("Upgrade") != "" {
		p.forwardUpgrade(w, request, target)
		return
	}
	requestID, started := p.beginRequest(request.Method, target)
	outgoing := request.Clone(request.Context())
	copyURL := *target
	outgoing.URL = &copyURL
	outgoing.RequestURI = ""
	removeHopHeaders(outgoing.Header)
	var body *countingBody
	if outgoing.Body != nil {
		body = &countingBody{ReadCloser: outgoing.Body, preview: p.preview}
		outgoing.Body = body
	}
	resp, err := p.transport.RoundTrip(outgoing)
	if err != nil {
		p.report.send(event{
			Type: "error", RequestID: requestID, Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
			DurationMs: time.Since(started).Milliseconds(),
			Method:     request.Method, Host: target.Host, Message: truncate(err.Error(), 140),
		})
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	removeHopHeaders(resp.Header)
	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)
	downloaded, transferErr := io.Copy(w, resp.Body)
	bytesSent := int64(0)
	previewText := ""
	if body != nil {
		bytesSent = body.n
		previewText = redactedPreview(body.sample, request.Header.Get("Content-Type"))
	}
	path := target.EscapedPath()
	if len(path) > 384 {
		path = path[:384]
	}
	kind, message := "request", ""
	if transferErr != nil {
		kind, message = "error", "响应传输失败："+truncate(transferErr.Error(), 140)
	}
	p.report.send(event{
		RequestID: requestID, Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		DurationMs: time.Since(started).Milliseconds(),
		Type:       kind, Method: request.Method, Host: target.Host, Path: path, Message: message,
		Status: resp.StatusCode, UploadBytes: bytesSent, DownloadBytes: downloaded,
		ContentType: truncate(request.Header.Get("Content-Type"), 100), Preview: previewText,
	})
}

func headerHasToken(header, token string) bool {
	for _, part := range strings.Split(header, ",") {
		if strings.EqualFold(strings.TrimSpace(part), token) {
			return true
		}
	}
	return false
}

func (p *proxy) forwardUpgrade(w http.ResponseWriter, request *http.Request, target *url.URL) {
	destination := *target
	requestID, started := p.beginRequest(request.Method, target)
	// WebSocket uses HTTP/1.1 Upgrade semantics; do not negotiate HTTP/2
	// with the upstream for this connection.
	upgradeTransport := p.transport.Clone()
	upgradeTransport.ForceAttemptHTTP2 = false
	upgradeTransport.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
	defer upgradeTransport.CloseIdleConnections()
	proxy := &httputil.ReverseProxy{
		Transport: upgradeTransport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(&destination)
			pr.Out.Host = request.Host
		},
		ModifyResponse: func(response *http.Response) error {
			p.report.send(event{
				RequestID: requestID, Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
				DurationMs: time.Since(started).Milliseconds(),
				Type:       "upgrade", Method: request.Method, Host: destination.Host,
				Path: truncate(destination.EscapedPath(), 384), Status: response.StatusCode,
				Message: "升级连接透明转发；流式内容不做解析或进程归属",
			})
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			p.report.send(event{
				RequestID: requestID, Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
				DurationMs: time.Since(started).Milliseconds(),
				Type:       "error", Method: r.Method, Host: destination.Host,
				Message: "upgrade forwarding failed: " + truncate(err.Error(), 140),
			})
			http.Error(w, "upstream upgrade failed", http.StatusBadGateway)
		},
	}
	proxy.ServeHTTP(w, request)
}

func removeHopHeaders(h http.Header) {
	for _, header := range strings.Split(h.Get("Connection"), ",") {
		h.Del(strings.TrimSpace(header))
	}
	for _, key := range []string{"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade"} {
		h.Del(key)
	}
}

func (p *proxy) connect(w http.ResponseWriter, req *http.Request) {
	hostPort := req.Host
	host, port, err := net.SplitHostPort(hostPort)
	if err != nil {
		host = hostPort
		port = "443"
		hostPort = net.JoinHostPort(host, port)
	}
	if hostPort == p.localAddress {
		http.Error(w, "proxy cannot connect to itself", http.StatusForbidden)
		return
	}
	if host == "" {
		http.Error(w, "missing host", 400)
		return
	}
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack unavailable", 500)
		return
	}
	client, buffered, err := hijacker.Hijack()
	if err != nil {
		return
	}
	if !p.intercept {
		p.tunnel(client, buffered, hostPort)
		return
	}
	_, _ = client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	serverName := host
	identity, err := p.ca.forHost(serverName)
	if err != nil {
		p.report.send(event{Type: "error", Host: host, Message: "TLS cert: " + err.Error()})
		client.Close()
		return
	}
	tlsClient := tls.Server(&preReadConn{Conn: client, reader: buffered.Reader}, &tls.Config{
		Certificates: []tls.Certificate{*identity}, MinVersion: tls.VersionTLS12,
		NextProtos: []string{"http/1.1"},
	})
	if err := tlsClient.Handshake(); err != nil {
		p.report.send(event{Type: "error", Host: host, Message: "HTTPS client rejected local certificate or handshake: " + truncate(err.Error(), 140)})
		tlsClient.Close()
		return
	}
	p.report.send(event{Type: "tls", Host: host, Message: "HTTPS decrypt connected"})
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { p.forward(w, r, "https") }), ReadHeaderTimeout: 10 * time.Second}
	_ = server.Serve(&singleConnListener{conn: tlsClient, done: make(chan struct{})})
}

func (p *proxy) tunnel(client net.Conn, br *bufio.ReadWriter, upstreamHost string) {
	var upstream net.Conn
	var err error
	if p.upstreamProxy != nil {
		upstream, err = p.dialUpstreamTunnel(upstreamHost)
	} else {
		upstream, err = net.DialTimeout("tcp", upstreamHost, 10*time.Second)
	}
	if err != nil {
		_, _ = client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
		client.Close()
		return
	}
	_, _ = client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	var outgoing, incoming int64
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		outgoing, _ = io.Copy(upstream, br)
		if c, ok := upstream.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		incoming, _ = io.Copy(client, upstream)
		if c, ok := client.(*net.TCPConn); ok {
			_ = c.CloseWrite()
		}
	}()
	wg.Wait()
	client.Close()
	upstream.Close()
	p.report.send(event{Type: "tunnel", Method: "CONNECT", Host: upstreamHost, UploadBytes: outgoing, DownloadBytes: incoming})
}

// Forward opaque CONNECT traffic through the user's existing HTTP proxy.
// Without this, temporarily routing system traffic through DevRadar would
// silently bypass the user's original proxy, which may be a VPN/Clash port.
func (p *proxy) dialUpstreamTunnel(destination string) (net.Conn, error) {
	conn, err := net.DialTimeout("tcp", p.upstreamProxy.Host, 10*time.Second)
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	request := &http.Request{
		Method: http.MethodConnect,
		URL:    &url.URL{Opaque: destination},
		Host:   destination,
		Header: make(http.Header),
	}
	if err := request.Write(conn); err != nil {
		conn.Close()
		return nil, err
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, request)
	if err != nil {
		conn.Close()
		return nil, err
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		conn.Close()
		return nil, fmt.Errorf("upstream proxy CONNECT rejected: %s", response.Status)
	}
	_ = conn.SetDeadline(time.Time{})
	return &preReadConn{Conn: conn, reader: reader}, nil
}

type preReadConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *preReadConn) Read(b []byte) (int, error) { return c.reader.Read(b) }

type singleConnListener struct {
	conn      net.Conn
	mu        sync.Mutex
	accepted  bool
	done      chan struct{}
	closeOnce sync.Once
}

func (l *singleConnListener) Accept() (net.Conn, error) {
	l.mu.Lock()
	if l.accepted {
		l.mu.Unlock()
		<-l.done
		return nil, net.ErrClosed
	}
	l.accepted = true
	l.mu.Unlock()
	return &closeAwareConn{Conn: l.conn, onClose: func() { l.closeOnce.Do(func() { close(l.done) }) }}, nil
}
func (l *singleConnListener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return l.conn.Close()
}
func (l *singleConnListener) Addr() net.Addr { return l.conn.LocalAddr() }

type closeAwareConn struct {
	net.Conn
	onClose func()
}

func (c *closeAwareConn) Close() error { c.onClose(); return c.Conn.Close() }

var sensitive = regexp.MustCompile(`(?i)(password|authorization|token|cookie|secret|api[_-]?key|access[_-]?key|credential|session[_-]?id|user[_-]?id|device[_-]?id|email)(\s*[=:]\s*)[^\s&,;"}]+`)

func sensitiveKey(key string) bool {
	k := strings.ToLower(key)
	for _, part := range []string{
		"password", "authorization", "token", "cookie", "secret",
		"apikey", "api_key", "api-key", "accesskey", "access_key",
		"credential", "sessionid", "session_id", "userid", "user_id",
		"deviceid", "device_id", "email",
	} {
		if strings.Contains(k, part) {
			return true
		}
	}
	return false
}

func redactedPreview(b []byte, contentType string) string {
	if len(b) == 0 {
		return ""
	}
	ct := strings.ToLower(contentType)
	if !strings.Contains(ct, "json") && !strings.Contains(ct, "text/") && !strings.Contains(ct, "x-www-form-urlencoded") {
		return "[non-text upload; content not retained]"
	}
	trimmed := bytes.TrimSpace(b)
	// Application logs sometimes send NDJSON or multiple concatenated JSON
	// objects using text/plain. Parse and redact EACH object before emitting.
	if strings.Contains(ct, "json") || (len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[')) {
		decoder := json.NewDecoder(bytes.NewReader(trimmed))
		var safeParts []string
		for len(safeParts) < 32 {
			var value any
			err := decoder.Decode(&value)
			if errors.Is(err, io.EOF) {
				break
			}
			if err != nil {
				// Incomplete JSON is often an artifact of the 2 KB sample cap.
				// Do not return the unparsed tail: it may contain credentials.
				if len(safeParts) == 0 {
					return "[JSON preview truncated or unsafe; content omitted]"
				}
				safeParts = append(safeParts, "[truncated JSON omitted]")
				break
			}
			safe, err := json.Marshal(scrubJSON(value, 0))
			if err != nil {
				return "[JSON preview unavailable]"
			}
			safeParts = append(safeParts, string(safe))
		}
		return truncate(strings.Join(safeParts, "\n"), maxBodySample)
	}
	return truncate(sensitive.ReplaceAllString(string(b), "$1$2[redacted]"), maxBodySample)
}
func scrubJSON(v any, depth int) any {
	if depth > 6 {
		return "[truncated]"
	}
	switch obj := v.(type) {
	case map[string]any:
		out := make(map[string]any)
		for k, val := range obj {
			if sensitiveKey(k) {
				out[k] = "[redacted]"
			} else {
				out[k] = scrubJSON(val, depth+1)
			}
		}
		return out
	case []any:
		if len(obj) > 20 {
			obj = obj[:20]
		}
		for i := range obj {
			obj[i] = scrubJSON(obj[i], depth+1)
		}
		return obj
	case string:
		return truncate(sensitive.ReplaceAllString(obj, "$1$2[redacted]"), 256)
	default:
		return v
	}
}
func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

func main() {
	listen := flag.String("listen", "127.0.0.1:8876", "loopback proxy address")
	caDir := flag.String("ca-dir", "", "private CA directory")
	intercept := flag.Bool("https", false, "decrypt HTTPS for clients trusting the local CA")
	preview := flag.Bool("preview", false, "emit redacted request body previews")
	initCA := flag.Bool("init-ca", false, "generate the local CA and exit")
	parentPID := flag.Int("parent-pid", 0, "parent DevRadar process ID, for crash cleanup")
	upstream := flag.String("upstream", "", "original HTTP proxy URL to chain through")
	flag.Parse()
	log.SetOutput(os.Stderr)
	if *caDir == "" {
		log.Fatal("--ca-dir required")
	}
	var ca *certificateAuthority
	if *initCA || *intercept {
		var err error
		ca, err = createOrLoadCA(*caDir)
		if err != nil {
			log.Fatal(err)
		}
		if *initCA {
			fmt.Println(filepath.Join(*caDir, "DevRadar-Local-CA.pem"))
			return
		}
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	if !strings.HasPrefix(ln.Addr().String(), "127.0.0.1:") && !strings.HasPrefix(ln.Addr().String(), "[::1]:") {
		log.Fatal("proxy must listen on loopback")
	}
	report := &reporter{enc: json.NewEncoder(os.Stdout)}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	var upstreamURL *url.URL
	if *upstream != "" {
		upstreamURL, err = url.Parse(*upstream)
		if err != nil || upstreamURL.Scheme != "http" || upstreamURL.User != nil || upstreamURL.Host == "" {
			log.Fatal("invalid upstream proxy URL")
		}
		if upstreamURL.Host == ln.Addr().String() {
			log.Fatal("upstream proxy loop")
		}
		transport.Proxy = http.ProxyURL(upstreamURL)
	}
	p := &proxy{report: report, ca: ca, intercept: *intercept, preview: *preview, transport: transport, localAddress: ln.Addr().String(), upstreamProxy: upstreamURL}
	srv := &http.Server{Handler: p, ReadHeaderTimeout: 10 * time.Second}
	report.send(event{Type: "ready", Host: ln.Addr().String()})
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Every proxy session has a hard lifetime even if DevRadar crashes or is
	// forcibly terminated. Do not leave a decrypting loopback service running.
	deadline := time.AfterFunc(10*time.Minute, stop)
	defer deadline.Stop()
	if *parentPID > 1 {
		go func() {
			ticker := time.NewTicker(2 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if err := syscall.Kill(*parentPID, 0); err != nil {
						stop()
						return
					}
				}
			}
		}()
	}
	go func() {
		<-ctx.Done()
		timeout, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = srv.Shutdown(timeout)
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
