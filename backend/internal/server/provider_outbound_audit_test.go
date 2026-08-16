package server

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProviderOutboundAuditRecordsExactBodyWithoutCredentials(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "provider-outbound.log")
	t.Setenv(providerOutboundAuditLogPathEnv, logPath)
	resource := &ProviderResource{ID: "resource-one"}
	route := RouteSelection{
		Route:         ModelRoute{ID: "route-one"},
		Provider:      Provider{ID: "provider-one", APIKey: "must-not-be-recorded"},
		Resource:      resource,
		ProviderModel: "DeepSeek-V4-Pro",
	}
	ctx := withProviderOutboundAttempt(context.Background(), "req-provider-audit", 2, route)
	body := []byte(`{"model":"DeepSeek-V4-Pro","messages":[{"role":"system","content":"7KQ\\n\\n9DX"},{"role":"user","content":"3VN"}]}`)

	recordProviderOutboundRequest(ctx, route.Provider, route.ProviderModel, "POST", "https://provider.example/v1/chat/completions?api_key=secret", body, false)

	encoded, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	var record providerOutboundAuditRecord
	if err := json.Unmarshal(encoded, &record); err != nil {
		t.Fatal(err)
	}
	if record.RequestID != "req-provider-audit" || record.AttemptIndex != 2 || record.DispatchIndex != 1 {
		t.Fatalf("unexpected correlation: %#v", record)
	}
	if record.Endpoint != "/v1/chat/completions" || record.ProviderModel != "DeepSeek-V4-Pro" {
		t.Fatalf("unexpected provider target: %#v", record)
	}
	if record.RequestBody != string(body) || record.RequestBytes != len(body) {
		t.Fatalf("request body was not preserved exactly: %#v", record)
	}
	if string(encoded) == "" || containsAny(string(encoded), "must-not-be-recorded", "api_key=secret") {
		t.Fatalf("credentials leaked into provider audit log: %s", encoded)
	}
}

func TestProviderOutboundAuditNumbersRepeatedDispatches(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "provider-outbound.log")
	t.Setenv(providerOutboundAuditLogPathEnv, logPath)
	ctx := withProviderOutboundAttempt(context.Background(), "req-retry", 1, RouteSelection{})

	recordProviderOutboundRequest(ctx, Provider{}, "model", "POST", "/v1/responses", []byte(`{"retry":1}`), true)
	recordProviderOutboundRequest(ctx, Provider{}, "model", "POST", "/v1/responses", []byte(`{"retry":2}`), true)

	file, err := os.Open(logPath)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	for want := 1; want <= 2; want++ {
		var record providerOutboundAuditRecord
		if err := decoder.Decode(&record); err != nil {
			t.Fatal(err)
		}
		if record.DispatchIndex != want {
			t.Fatalf("dispatch index=%d want=%d", record.DispatchIndex, want)
		}
	}
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if candidate != "" && strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
