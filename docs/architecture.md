# Architecture

A private, keyless, multi-service Azure AI gateway on API Management. Clients
authenticate with an Entra ID token (client-credentials, app-role gated) — no
subscription keys, and no API keys on the model path. Every *module-created* AI
backend is private-endpoint only; a bring-your-own pool member (`endpoint_url`) is
reached over APIM's egress, and the optional Redis cache holds an access key in state.

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
│  Admission + limits (keyed by the           │
│  caller's azp claim):                       │
│    role AI.Gateway.Standard → admitted      │
│    limits ← default tier preset             │
│      (var.tiers / var.default_tier)         │
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

## The auth model

This is the canonical description. Everything else in the docs links here rather than
restating it.

Three concerns, deliberately separated:

| Concern | Where it lives | Answers | Changes |
| --- | --- | --- | --- |
| **Admission** | one Entra app role (`admission_app_role`, default `AI.Gateway.Standard`) | may this identity reach the gateway at all? | rarely; a directory operation |
| **Consumption** | named presets in `var.tiers`, selected by `var.default_tier` | what rate and token limits apply? | often; config, PR-reviewed |
| **Differentiation** | the optional [onboarding registry](../modules/onboarding/README.md) | what does *this specific team* get? | per team, by pull request |

**A token never carries limits.** It carries the admission role and nothing more. That
is the point: adding a tier is a config edit, not a change to the directory, and a
caller cannot escalate by acquiring roles.

Limits are keyed by the caller's `azp` claim (its client app id), falling back to
`appid` for v1.0 tokens. A token carrying neither is refused with
`403 missing_caller_id` rather than silently sharing one bucket with every other such
caller — see `policies/frag-entra-jwt.xml`.

There are **no APIM products**: an open product (subscription not required) can hold
any given API only once, and product-scope policies do not execute for keyless
requests. Everything is therefore enforced in the API policy chain.

### Before v2

v1 gave every tier its own app role and read the tier from the `roles` claim, ordering
branches so a caller holding several roles got its best tier. That created two
competing authorities and made adding a tier a privileged directory change. See
[upgrading-v2.md](upgrading-v2.md) to migrate.

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
