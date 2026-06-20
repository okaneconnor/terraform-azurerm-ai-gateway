# Architecture

A private, keyless, multi-service Azure AI gateway on API Management. Clients
authenticate with an Entra ID token (client-credentials, app-role gated) — no
subscription keys, no API keys anywhere. Every AI backend is private-endpoint only.

```
Client app (Entra client-credentials)
        │
        │  HTTPS + Bearer token (JWT)
        ▼
┌─────────────────────────────────────────────┐
│  APIM (External VNet injection)             │
│                                             │
│  Inbound policy chain (Foundry/OpenAI API): │
│    ai-ip-allow → ai-auth-entra-jwt          │
│    → ai-tier-rate → ai-tier-tokens          │
│    → managed-identity auth                  │
│    → ai-content-safety (EVERY prompt)       │
│    → llm-semantic-cache-lookup (Redis)      │
│    → set-backend foundry-pool (CB)          │
│    → ai-token-metrics                       │
│  outbound: llm-semantic-cache-store         │
│                                             │
│  Tiering (rendered from var.tiers,          │
│  keyed by the caller's azp claim):          │
│    role AI.Gateway.Production               │
│      → 150k TPM / 120 req/min               │
│    role AI.Gateway.Sandbox                  │
│      → 20k TPM / 30 req/min                 │
│                                             │
│  APIs:                                      │
│    /openai        → AI Foundry (your models)│
│    /contentsafety → Content Safety (wildcard)│
│    /speech        → Speech         (wildcard)│
│    /language      → Language       (wildcard)│
│    /docintel      → Document Intel.(wildcard)│
└───────────────────┬─────────────────────────┘
                    │  Private endpoints (VNet)
          ┌─────────┼──────────┐
          ▼         ▼          ▼ ...
   AI Foundry   Content    Speech / Language /
   (AIServices) Safety     Document Intelligence
   your models             (all private, keys disabled)
```

## Keyless backends

APIM authenticates to all backends with its **system-assigned managed identity** —
`local_auth_enabled = false` on every Cognitive account, so there is no key plane at
all. Backends have `public_network_access_enabled = false` and are only reachable via
private endpoints inside the VNet.

**Content safety runs before the semantic cache**, so every prompt is screened —
including ones answered from cache. (The cost is one Content Safety call per request
rather than per cache-miss; this is the deliberate default.)

## Keyless tiering (no APIM products)

There are **no APIM products** — an open product (subscription not required) can hold
any given API only once, and product-scope policies don't execute for keyless
requests. Tiering is therefore enforced in the **API policy** via the Entra `roles`
claim, with rate/token limits keyed by the `azp` (client app id) claim. Tier branches
are ordered by `tokens_per_minute` descending, so a client holding several roles gets
its best tier.

## Wildcard passthrough services

The non-OpenAI service APIs are imported without an OpenAPI definition, so they expose
**wildcard passthrough** operations (`GET`/`POST` on `/*`): the client appends the real
service path and APIM forwards it to the private backend.

> **Path note:** APIM strips the API path prefix before forwarding. Append the
> backend's own path after the prefix. For the **Language** service, whose REST path is
> itself `/language/:analyze-text`, the working gateway URL is
> `/{gw}/language/language/:analyze-text?api-version=2024-11-01` (gateway prefix +
> backend prefix). Speech / Content Safety / Document Intelligence don't have that
> collision.

## Resilience & caching (Foundry path)

- **Backend pool + circuit breaker** — the Foundry endpoint sits behind an APIM
  load-balanced pool (`foundry-pool`) with a configurable breaker (`circuit_breaker`).
  The default trips on **5xx only**: with a single-member pool, tripping on 429 would
  let one bursty client 503 the whole gateway for the trip duration. Set
  `trip_on_429 = true` when you run a multi-member pool where failover actually helps.
  A second member is one more `pool.services[]` entry.
- **Semantic caching** — identical/similar prompts are served from **Azure Managed
  Redis** (RediSearch, private endpoint) via `llm-semantic-cache-lookup`/`-store`,
  vectorised by the embeddings deployment you name in
  `semantic_cache.embeddings_deployment`. The cache is partitioned per client app
  (`azp`), so teams never share completions. Disable with
  `semantic_cache.enabled = false` (skips Redis entirely).
- **Deployment-SKU guardrail** — an Azure Policy **allowlist**
  (`deployment_sku_policy.allowed_sku_names`, default `["Standard"]`) denies
  model-deployment SKUs that process data outside the region (`GlobalStandard`,
  `GlobalBatch`, `GlobalProvisionedManaged`, `DataZone*`, and anything Azure adds
  later — allowlists fail closed).

## Data residency

The default configuration keeps inference **in-region**:

- Model deployments default to the `Standard` SKU (in-region processing). `Global*`
  SKUs route worldwide; `DataZone*` SKUs route within the US or EU data zone — for UK
  workloads note the EU data zone **excludes the UK**.
- The deployment-SKU policy denies out-of-region SKUs *including out-of-band
  deployments* made via portal/CLI.
- LLM token logging records token counts and model names only — prompt/completion
  **bodies are never logged** (that's a separate opt-in this module deliberately
  doesn't set).
- For UK workloads specifically: ukwest does not offer equivalent AI service coverage,
  so there is no in-UK multi-region failover. Use Premium with availability zones for
  in-region HA, and document the single-region risk.
