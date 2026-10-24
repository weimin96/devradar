package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func failureProxy(output *bytes.Buffer) *proxy {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	return &proxy{transport: transport, report: &reporter{enc: json.NewEncoder(output)}}
}
func TestTruncatedDownloadEmitsError(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "100")
		_, _ = w.Write([]byte("short"))
	}))
	defer origin.Close()
	var output bytes.Buffer
	p := failureProxy(&output)
	p.forward(httptest.NewRecorder(), httptest.NewRequest("GET", origin.URL, nil), "")
	var events []event
	dec := json.NewDecoder(&output)
	for {
		var e event
		if err := dec.Decode(&e); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			t.Fatal(err)
		}
		events = append(events, e)
	}
	if len(events) == 0 {
		t.Fatal("缺少请求事件")
	}
	last := events[len(events)-1]
	if last.Type != "error" || last.DownloadBytes != 5 || last.Status != 200 {
		t.Fatalf("下载中断须记录失败并保留实际字节数: %+v", last)
	}
}
func TestCancelledRequestDoesNotReachUpstream(t *testing.T) {
	var called atomic.Bool
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called.Store(true); w.WriteHeader(200) }))
	defer origin.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	request := httptest.NewRequest("GET", origin.URL, nil).WithContext(ctx)
	var output bytes.Buffer
	failureProxy(&output).forward(httptest.NewRecorder(), request, "")
	if called.Load() {
		t.Fatal("已取消的请求不得转发到上游")
	}
}
