package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAnthropicMessagesConvertsTextDocumentForOpenAI(t *testing.T) {
	var upstreamPayload map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&upstreamPayload); err != nil {
			t.Errorf("decode upstream request: %v", err)
		}
		w.Header().Set("content-type", "application/json")
		_, _ = io.WriteString(w, `{"id":"chatcmpl_document","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}`)
	}))
	defer upstream.Close()

	handler, _, secret := newAnthropicGateway(t, upstream.URL, ProviderOpenAICompatible)
	resp := doAnthropicRequest(t, handler, "/v1/messages", map[string]any{
		"model": "claude-tokenhub-test", "max_tokens": 128,
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "text", "text": "Read the attachment."},
			map[string]any{"type": "document", "source": map[string]any{"type": "text", "media_type": "text/plain", "data": "TEXT_DOCUMENT_MARKER_42D9"}},
		}}},
	}, "Bearer "+secret, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", resp.Code, resp.Body.String())
	}
	content := firstOpenAIUserContent(t, upstreamPayload)
	if !strings.Contains(content, "Read the attachment.") || !strings.Contains(content, "TEXT_DOCUMENT_MARKER_42D9") {
		t.Fatalf("expected text and document content upstream, got %q", content)
	}
	if strings.Contains(content, "attachment notice") {
		t.Fatalf("valid text document must not be degraded: %q", content)
	}
}

func TestAnthropicMessagesDegradesUnavailableDocumentForOpenAI(t *testing.T) {
	tests := []struct {
		name   string
		source any
		mime   string
	}{
		{name: "pdf", source: map[string]any{"type": "base64", "media_type": "application/pdf", "data": "%%%invalid%%%"}, mime: "application/pdf"},
		{name: "empty text", source: map[string]any{"type": "text", "media_type": "text/plain", "data": ""}, mime: "text/plain"},
		{name: "missing source", source: nil, mime: "unknown type"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var upstreamPayload map[string]any
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_ = json.NewDecoder(r.Body).Decode(&upstreamPayload)
				w.Header().Set("content-type", "application/json")
				_, _ = io.WriteString(w, `{"id":"chatcmpl_document","choices":[{"index":0,"message":{"role":"assistant","content":"continued"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}`)
			}))
			defer upstream.Close()

			handler, _, secret := newAnthropicGateway(t, upstream.URL, ProviderOpenAICompatible)
			document := map[string]any{"type": "document"}
			if test.source != nil {
				document["source"] = test.source
			}
			resp := doAnthropicRequest(t, handler, "/v1/messages", map[string]any{
				"model": "claude-tokenhub-test", "max_tokens": 128,
				"messages": []any{map[string]any{"role": "user", "content": []any{
					map[string]any{"type": "text", "text": "SURVIVING_TEXT_MARKER_91BC"}, document,
				}}},
			}, "Bearer "+secret, "")
			if resp.Code != http.StatusOK {
				t.Fatalf("expected degraded request to continue, got %d: %s", resp.Code, resp.Body.String())
			}
			content := firstOpenAIUserContent(t, upstreamPayload)
			for _, expected := range []string{"SURVIVING_TEXT_MARKER_91BC", "attachment notice", test.mime, "Do not assume", "Do not retry"} {
				if !strings.Contains(content, expected) {
					t.Fatalf("expected %q in degraded content, got %q", expected, content)
				}
			}
			if strings.Contains(content, "%%%invalid%%%") {
				t.Fatalf("document payload must not be forwarded: %q", content)
			}
		})
	}
}

func TestAnthropicMessagesPreservesDocumentForNativeRoute(t *testing.T) {
	var upstreamPayload map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&upstreamPayload)
		w.Header().Set("content-type", "application/json")
		_, _ = io.WriteString(w, `{"id":"msg_document","type":"message","role":"assistant","model":"upstream-model","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":1}}`)
	}))
	defer upstream.Close()

	handler, _, secret := newAnthropicGateway(t, upstream.URL, ProviderAnthropic)
	resp := doAnthropicRequest(t, handler, "/v1/messages", map[string]any{
		"model": "claude-tokenhub-test", "max_tokens": 128,
		"messages": []any{map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "document", "source": map[string]any{"type": "base64", "media_type": "application/pdf", "data": "PDF_BASE64_MARKER"}},
		}}},
	}, "Bearer "+secret, "")
	if resp.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", resp.Code, resp.Body.String())
	}
	encoded, _ := json.Marshal(upstreamPayload)
	if !strings.Contains(string(encoded), "PDF_BASE64_MARKER") || !strings.Contains(string(encoded), `"type":"document"`) {
		t.Fatalf("native route must preserve original document: %s", encoded)
	}
}

func firstOpenAIUserContent(t *testing.T, payload map[string]any) string {
	t.Helper()
	messages, _ := payload["messages"].([]any)
	for _, item := range messages {
		message, _ := item.(map[string]any)
		if message["role"] != "user" {
			continue
		}
		if text, ok := message["content"].(string); ok {
			return text
		}
		encoded, _ := json.Marshal(message["content"])
		return string(encoded)
	}
	t.Fatalf("missing upstream user message: %#v", payload)
	return ""
}
