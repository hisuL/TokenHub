import fs from "node:fs";

const configPath = process.argv[2] || "/silang-config/models.json";
const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
if (!config.enabled) {
  console.log("Model bootstrap is disabled; no changes were made.");
  process.exit(0);
}

const adminToken = process.env.TOKENHUB_ADMIN_TOKEN;
if (!adminToken) throw new Error("TOKENHUB_ADMIN_TOKEN is missing");
const base = "http://127.0.0.1:8080";

async function api(method, path, body) {
  const response = await fetch(base + path, {
    method,
    headers: {
      Authorization: `Bearer ${adminToken}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let parsed = null;
  if (text) {
    try { parsed = JSON.parse(text); } catch { parsed = text; }
  }
  if (!response.ok) {
    throw new Error(`${method} ${path} returned ${response.status}: ${text}`);
  }
  return parsed;
}

const provider = config.provider;
if (!provider?.id || !provider?.resource_id || !provider?.base_url) {
  throw new Error("provider.id, provider.resource_id and provider.base_url are required");
}
if (!Array.isArray(config.models) || config.models.length === 0) {
  throw new Error("at least one model is required");
}

const providerCatalogModels = config.models.map((model) => ({
  id: model.upstream_name,
  name: model.upstream_name,
  display_name: model.display_name || model.public_name,
  canonical_name: model.public_name,
  category: "custom",
  family: "custom",
  type: "chat",
  context_window: model.context_window || 131072,
  max_output_tokens: model.max_output_tokens || 8192,
  input_price_usd_per_1m: model.input_price_usd_per_1m || 0,
  output_price_usd_per_1m: model.output_price_usd_per_1m || 0,
  input_modalities: ["text"],
  output_modalities: ["text"],
  capabilities: ["chat", "reasoning"],
  supported_parameters: ["temperature", "top_p", "tools", "tool_choice", "reasoning_effort"],
  metadata: { source: "silang-offline-bootstrap" }
}));

const providers = (await api("GET", "/api/admin/providers"))?.data ?? [];
if (!providers.some((item) => item.id === provider.id)) {
  await api("POST", "/api/admin/providers", {
    id: provider.id,
    catalog_id: "custom",
    name: provider.name || "SGLang Router",
    type: "openai_compatible",
    base_url: provider.base_url,
    status: "active",
    healthy: true,
    priority: 1,
    options: {
      claude_code_attribution_policy: "strip",
      preserve_reasoning_content: "true",
      reasoning_effort_map: '{"minimal":"low","xhigh":"max"}',
      reasoning_effort_unsupported: "omit",
      reasoning_effort_values: "none,low,medium,high,max"
    },
    selected_models: config.models.map((model) => model.upstream_name),
    custom_models: providerCatalogModels
  });
}

const providerModels = (await api("GET", `/api/admin/provider-models?provider_id=${encodeURIComponent(provider.id)}`))?.data ?? [];
const missingProviderModels = providerCatalogModels.filter(
  (model) => !providerModels.some((existing) => existing.upstream_model === model.id)
);
if (missingProviderModels.length > 0) {
  await api("POST", "/api/admin/provider-models/import", {
    provider_id: provider.id,
    publish: false,
    models: missingProviderModels
  });
}

const resources = (await api("GET", "/api/admin/provider-resources"))?.data ?? [];
if (!resources.some((item) => item.id === provider.resource_id)) {
  await api("POST", "/api/admin/provider-resources", {
    id: provider.resource_id,
    provider_id: provider.id,
    name: `${provider.name || "SGLang Router"} Resource`,
    resource_type: "api_key",
    base_url: provider.base_url,
    api_key: provider.api_key || "not-required",
    environment: "production",
    status: "active",
    healthy: true,
    priority: 1,
    weight: 100,
    rate_limit_rpm: 0,
    token_limit_tpm: 0,
    max_concurrency: 0
  });
}

const externalModels = (await api("GET", "/api/admin/models"))?.data ?? [];
for (const model of config.models) {
  if (externalModels.some((existing) => existing.name === model.public_name)) continue;
  await api("POST", "/api/admin/models", {
    id: model.public_name,
    name: model.public_name,
    category: "custom",
    family: "custom",
    modality: "chat",
    context_window: model.context_window || 131072,
    input_price_usd_per_1m: model.input_price_usd_per_1m || 0,
    output_price_usd_per_1m: model.output_price_usd_per_1m || 0,
    input_modalities: ["text"],
    output_modalities: ["text"],
    capabilities: ["chat", "reasoning"],
    supported_parameters: ["temperature", "top_p", "tools", "tool_choice", "reasoning_effort"],
    metadata: {
      source: "silang-offline-bootstrap",
      max_output_tokens: String(model.max_output_tokens || 8192)
    },
    status: "active"
  });
}

const existingRoutes = (await api("GET", "/api/admin/routing-rules"))?.data ?? [];
for (const model of config.models) {
  if (existingRoutes.some((route) => route.model_name === model.public_name)) continue;
  await api("POST", "/api/admin/routing-rules", {
    model_name: model.public_name,
    provider_id: provider.id,
    provider_resource_id: provider.resource_id,
    resource_group: "",
    sticky_session: true,
    provider_model: model.upstream_name,
    priority: 1,
    weight: 100,
    quality_score: 60,
    cost_score: 60,
    status: "active",
    strategy: "priority_weighted",
    project_scope: "all",
    project_ids: [],
    tags: ["silang", "sglang"]
  });
}

console.log(`Configured provider ${provider.id} with ${config.models.length} model route(s).`);
