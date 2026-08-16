package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const providerOutboundAuditLogPathEnv = "TOKENHUB_PROVIDER_AUDIT_LOG_PATH"

type providerOutboundAttemptContextKey struct{}

type providerOutboundAttemptContext struct {
	RequestID          string
	AttemptIndex       int
	RouteID            string
	ProviderID         string
	ProviderResourceID string
	ProviderModel      string

	mu            sync.Mutex
	dispatchIndex int
}

type providerOutboundAuditRecord struct {
	Version            int       `json:"version"`
	Time               time.Time `json:"time"`
	RequestID          string    `json:"request_id"`
	AttemptIndex       int       `json:"attempt_index"`
	DispatchIndex      int       `json:"dispatch_index"`
	RouteID            string    `json:"route_id,omitempty"`
	ProviderID         string    `json:"provider_id,omitempty"`
	ProviderResourceID string    `json:"provider_resource_id,omitempty"`
	ProviderModel      string    `json:"provider_model,omitempty"`
	Method             string    `json:"method"`
	Endpoint           string    `json:"endpoint"`
	Stream             bool      `json:"stream"`
	RequestBytes       int       `json:"request_bytes"`
	RequestSHA256      string    `json:"request_sha256"`
	RequestBody        string    `json:"request_body"`
}

var (
	providerOutboundAuditWriteMu   sync.Mutex
	providerOutboundAuditErrorOnce sync.Once
)

func withProviderOutboundAttempt(ctx context.Context, requestID string, attemptIndex int, route RouteSelection) context.Context {
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithValue(ctx, providerOutboundAttemptContextKey{}, &providerOutboundAttemptContext{
		RequestID:          strings.TrimSpace(requestID),
		AttemptIndex:       attemptIndex,
		RouteID:            route.Route.ID,
		ProviderID:         route.Provider.ID,
		ProviderResourceID: routeResourceID(route),
		ProviderModel:      route.ProviderModel,
	})
}

func (c *providerOutboundAttemptContext) nextDispatchIndex() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.dispatchIndex++
	return c.dispatchIndex
}

// recordProviderOutboundRequest records the exact JSON bytes prepared for an
// upstream Provider. Authentication headers and Provider URL credentials never
// enter the record. Audit failure is deliberately non-blocking for inference.
func recordProviderOutboundRequest(
	ctx context.Context,
	provider Provider,
	providerModel string,
	method string,
	endpoint string,
	body []byte,
	stream bool,
) {
	logPath := strings.TrimSpace(os.Getenv(providerOutboundAuditLogPathEnv))
	if logPath == "" || ctx == nil {
		return
	}
	attempt, _ := ctx.Value(providerOutboundAttemptContextKey{}).(*providerOutboundAttemptContext)
	if attempt == nil || attempt.RequestID == "" {
		return
	}
	model := strings.TrimSpace(providerModel)
	if model == "" {
		model = attempt.ProviderModel
	}
	hash := sha256.Sum256(body)
	record := providerOutboundAuditRecord{
		Version:            1,
		Time:               time.Now().UTC(),
		RequestID:          attempt.RequestID,
		AttemptIndex:       attempt.AttemptIndex,
		DispatchIndex:      attempt.nextDispatchIndex(),
		RouteID:            attempt.RouteID,
		ProviderID:         firstNonEmpty(strings.TrimSpace(provider.ID), attempt.ProviderID),
		ProviderResourceID: attempt.ProviderResourceID,
		ProviderModel:      model,
		Method:             strings.ToUpper(strings.TrimSpace(method)),
		Endpoint:           providerAuditEndpoint(endpoint),
		Stream:             stream,
		RequestBytes:       len(body),
		RequestSHA256:      hex.EncodeToString(hash[:]),
		RequestBody:        string(body),
	}
	encoded, err := json.Marshal(record)
	if err == nil {
		providerOutboundAuditWriteMu.Lock()
		err = appendProviderOutboundAuditLine(logPath, encoded)
		providerOutboundAuditWriteMu.Unlock()
	}
	if err != nil {
		providerOutboundAuditErrorOnce.Do(func() {
			log.Printf("provider outbound audit unavailable: %v", err)
		})
	}
}

func appendProviderOutboundAuditLine(logPath string, encoded []byte) error {
	file, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	line := make([]byte, 0, len(encoded)+1)
	line = append(line, encoded...)
	line = append(line, '\n')
	_, writeErr := file.Write(line)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

func providerAuditEndpoint(endpoint string) string {
	endpoint = strings.TrimSpace(endpoint)
	parsed, err := url.Parse(endpoint)
	if err != nil || (!parsed.IsAbs() && parsed.Host == "") {
		return endpoint
	}
	if parsed.EscapedPath() == "" {
		return "/"
	}
	return parsed.EscapedPath()
}
