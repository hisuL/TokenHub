package server

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestOpenAICompatibleAdapterPropagatesProviderRequestID(t *testing.T) {
	const requestID = "req_unified_trace_test"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if got := request.Header.Get("x-request-id"); got != requestID {
			t.Errorf("x-request-id = %q, want %q", got, requestID)
		}
		w.Header().Set("content-type", "application/json")
		_, _ = io.WriteString(w, `{"id":"chatcmpl-test","choices":[],"usage":{"total_tokens":0}}`)
	}))
	defer upstream.Close()

	adapter := OpenAICompatibleAdapter{Client: upstream.Client()}
	provider := Provider{BaseURL: upstream.URL, Headers: map[string]string{"x-request-id": "static-value"}}
	ctx := withProviderRequestID(context.Background(), requestID)
	if _, _, err := adapter.Chat(ctx, provider, "model-test", ChatCompletionRequest{}); err != nil {
		t.Fatalf("Chat() error = %v", err)
	}
}
