package main

import (
	"strings"
	"testing"
)

func TestPreviewRedactsNDJSONAndPlainTextJSON(t *testing.T) {
	sample := []byte(`{"event":"start","accessToken":"top-secret","user_id":"user-123"}` +
		"\n" + `{"event":"end","sessionId":"session-789","nested":{"password":"hide-me"}}`)
	for _, ct := range []string{"application/json", "text/plain"} {
		result := redactedPreview(sample, ct)
		for _, secret := range []string{"top-secret", "user-123", "session-789", "hide-me"} {
			if strings.Contains(result, secret) {
				t.Fatalf("%s leaked %q: %s", ct, secret, result)
			}
		}
		if !strings.Contains(result, "\"event\":\"start\"") ||
			!strings.Contains(result, "\"event\":\"end\"") {
			t.Fatalf("%s failed to preserve safe JSON fields: %s", ct, result)
		}
	}
}

func TestTruncatedJSONDoesNotRevealSecret(t *testing.T) {
	input := []byte(`{"status":"ok"}{"password":"partial-secret`)
	result := redactedPreview(input, "text/plain")
	if strings.Contains(result, "partial-secret") || !strings.Contains(result, "truncated JSON omitted") {
		t.Fatalf("unsafe incomplete JSON exposed: %s", result)
	}
	result = redactedPreview([]byte(`{"password":"partial-secret`), "application/json")
	if strings.Contains(result, "partial-secret") {
		t.Fatalf("unsafe initial incomplete JSON exposed: %s", result)
	}
}
