package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequestLifecycleEvents(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte("ok"))
	}))
	defer upstream.Close()
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	var results bytes.Buffer
	p := &proxy{report: &reporter{enc: json.NewEncoder(&results)}, transport: transport}
	request := httptest.NewRequest(http.MethodPost, upstream.URL+"/upload?token=private", strings.NewReader("hello"))
	w := httptest.NewRecorder()
	p.forward(w, request, "")
	if w.Code != 202 {
		t.Fatalf("status = %d", w.Code)
	}

	var lines []event
	for _, line := range bytes.Split(bytes.TrimSpace(results.Bytes()), []byte("\n")) {
		var item event
		if err := json.Unmarshal(line, &item); err != nil {
			t.Fatal(err)
		}
		lines = append(lines, item)
	}
	if len(lines) != 2 || lines[0].Type != "started" || lines[1].Type != "request" {
		t.Fatalf("unexpected lifecycle: %+v", lines)
	}
	if lines[0].RequestID == "" || lines[0].RequestID != lines[1].RequestID {
		t.Fatal("lifecycle IDs do not match")
	}
	if lines[0].Timestamp == "" || lines[1].Timestamp == "" || lines[1].DurationMs < 0 {
		t.Fatal("timestamps or duration missing")
	}
	if strings.Contains(results.String(), "token=private") {
		t.Fatal("query parameters leaked through lifecycle event")
	}
}
