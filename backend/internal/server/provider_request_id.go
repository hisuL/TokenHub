package server

import (
	"context"
	"net/http"
	"strings"
)

type providerRequestIDContextKey struct{}

func withProviderRequestID(ctx context.Context, requestID string) context.Context {
	if ctx == nil {
		ctx = context.Background()
	}
	requestID = strings.TrimSpace(requestID)
	if requestID == "" {
		return ctx
	}
	return context.WithValue(ctx, providerRequestIDContextKey{}, requestID)
}

func applyProviderRequestID(request *http.Request) {
	if request == nil {
		return
	}
	requestID, _ := request.Context().Value(providerRequestIDContextKey{}).(string)
	if requestID = strings.TrimSpace(requestID); requestID != "" {
		request.Header.Set("x-request-id", requestID)
	}
}
