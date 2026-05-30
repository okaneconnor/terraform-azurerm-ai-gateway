# APIM AI Gateway — Sandbox Landing Zone (Design)

**Date:** 2026-05-30
**Status:** Approved (brainstorming) — pending implementation plan
**Author:** Connor O'Kane (with Claude Code)

## 1. Context & goal

The organisation wants to enable developers and teams to freely use **in-house AI**
— internal models, AI endpoints, MCP servers, and agents — under **central
governance**. Think of it as an "AI landing zone": a single, governed front door
through which teams self-serve AI capabilities with cost control, safety,
observability, and access management applied centrally.

We are building this on **Azure API Management (APIM) as an AI Gateway**. Per
Microsoft Cloud Adoption Framework, AI does not need a separate landing zone — it
is a workload that sits behind a gateway. This effort builds that gateway and the
governance around it.

This iteration is a **single-subscription sandbox** to prove the capabilities
end-to-end before any production hardening.

### What the APIM AI Gateway provides (grounding)

The AI Gateway is not a separate product — it is capabilities layered on the
existing APIM gateway:

- **Model governance** — onboard OpenAI/Anthropic/Foundry/Bedrock/self-hosted LLMs
  as APIs; authenticate to backends with managed identity.
- **Cost & fairness** — `llm-token-limit` (TPM + quotas per consumer).
- **Performance/cost** — semantic caching (`llm-semantic-cache-lookup/store`) via
  an external Redis-compatible cache.
- **Resiliency** — backend pools (round-robin/weighted/priority load balancing) +
  circuit breaker (e.g. PTU→PAYG spillover) + retry.
- **Safety** — prompt moderation via Azure AI Content Safety (`llm-content-safety`).
- **MCP governance** — expose REST APIs as MCP servers, or govern existing MCP
  servers (auth, rate-limit, IP filter).
- **Agents** — import & govern A2A agent APIs; register custom agents.
- **Observability** — token metrics per consumer (`llm-emit-token-metric`),
  prompt/completion logging → App Insights / Azure Monitor, built-in dashboards.
- **Self-service** — org catalog via Azure API Center + Developer Portal.

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| IaC tooling | **Terraform, flat config, no modules** | Write only the resources we need for our own sandbox; KISS. Org standard is Terraform. |
| Platform context | **Single-subscription sandbox** | Prove capabilities first; harden later. |
| APIM tier | **Developer** | Supports all needed AI-gateway features; no SLA; cheapest non-prod. |
| Network exposure | **Public endpoint** | Sandbox simplicity. VNet/WAF/private endpoints deferred to prod-hardening appendix. |
| Capability scope | **All four pillars** (model gov, MCP gov, agents + self-service, observability) | Sequenced one capability per phase. |
| Backends | **Provisioned by Terraform** | Self-contained sandbox: Terraform creates AOAI + model deployments to govern. |
| My actions | **Author + `terraform fmt`/`validate` only** | No `apply`. `plan` only if user is `az login`-authenticated, else documented as user step. |
| Region | `location` variable, default `uksouth` | Override freely. |
| Backend resource | Azure OpenAI via `azurerm_cognitive_account` (kind `OpenAI`) | Simplest, well-supported for sandbox; Foundry noted as future option. |

## 3. Architecture

One subscription, one resource group, one region. All public-endpoint for sandbox.

```
Client / dev team app
   │  (APIM subscription key per team  ·  later: OAuth)
   ▼
Azure API Management — Developer tier  (system-assigned managed identity)
   │   inbound:  auth(MI) → token-limit → semantic-cache-lookup → content-safety
   │   backend:  load-balanced pool + circuit breaker + retry
   │   outbound: cache-store → emit-token-metric → logging
   ├─► Azure OpenAI account  (gpt-4o chat + text-embedding-3-small)   [MI: Cognitive Services User]
   ├─► Azure AI Content Safety                                        [MI: Cognitive Services User]
   ├─► Azure Managed Redis  (external cache for semantic caching)
   └─► sample REST API + a govern-able MCP server (later phases)
   │
   └─► Log Analytics workspace + Application Insights
        (APIM logger + diagnostics, token metrics, prompt/completion logs)
```

### Data flow

Client → APIM (subscription key) → inbound policy chain (managed-identity auth to
backend, token limit, semantic-cache lookup, content-safety moderation) →
load-balanced backend pool (AOAI) with circuit breaker/retry → outbound policy
chain (semantic-cache store, emit token metric, log prompt/completion) → response.
Telemetry flows to Application Insights / Log Analytics.

## 4. Capability phasing

Each phase is one `terraform apply`, gated behind an `enable_*` variable, with a
validation gate before enabling the next.

| Phase | Capability | Added resources / policies | Validation gate |
|---|---|---|---|
| **1 Foundation** | Model governance baseline + observability baseline | RG, Log Analytics, App Insights, APIM Developer, AOAI + gpt-4o + text-embedding-3-small, system-assigned MI + `Cognitive Services User` RBAC, AOAI imported as LLM API, App Insights logger + APIM diagnostics, one Product + Subscription per "team" | curl a chat completion through the gateway; request visible in App Insights |
| **2 Cost & fairness** | Model governance depth | `llm-token-limit` (TPM + quota per subscription), `llm-emit-token-metric` with team/API/IP dimensions, backend pool + circuit breaker, `retry` policy | exceed limit → HTTP 429; token metric visible in App Insights |
| **3 Semantic caching** | Performance / cost | Azure Managed Redis as APIM external cache, `llm-semantic-cache-lookup` + `llm-semantic-cache-store` using the embeddings deployment | repeat a semantically similar prompt → cache hit, reduced backend tokens |
| **4 Safety** | Prompt/agent safety | Azure AI Content Safety resource + MI RBAC + `llm-content-safety` policy | a harmful/jailbreak prompt is blocked at the gateway |
| **5 MCP governance** | MCP | Expose the sample REST API as an MCP server; govern an existing remote MCP server with `rate-limit-by-key`, `ip-filter`, auth | invoke a tool from an MCP client (VS Code agent mode or curl) |
| **6 Agents + self-service** | Agents + self-service | Import an A2A agent API; Azure API Center catalog for APIs/MCP/agents; enable Developer Portal for self-service team onboarding | agent API registered; a team discovers + subscribes via the portal |

## 5. File layout (flat — no modules)

```
.
├── providers.tf            # azurerm (+ azapi for newest features), terraform block, versions
├── variables.tf            # location, prefix, enable_* toggles, model names, team list, tpm limits
├── terraform.tfvars.example
├── foundation.tf           # resource group, Log Analytics, Application Insights
├── apim.tf                 # APIM Developer instance + system-assigned identity + logger + diagnostics
├── openai.tf               # azurerm_cognitive_account (OpenAI) + model deployments
├── identity-rbac.tf        # role assignments: APIM MI → Cognitive Services User on AOAI + Content Safety
├── api-llm.tf              # LLM API import, backend, backend pool, API/product policies
├── products.tf             # one product + subscription per team
├── cache.tf                # (phase 3) Azure Managed Redis + APIM external cache wiring
├── content-safety.tf       # (phase 4) Content Safety account + RBAC
├── mcp.tf                  # (phase 5) sample REST API + MCP server + governed external MCP server
├── agents-apicenter.tf     # (phase 6) A2A agent API + API Center + dev portal config
├── policies/               # *.xml policy fragments referenced by the *.tf policy resources
│   ├── llm-foundation.xml
│   ├── llm-token-limit.xml
│   ├── llm-semantic-cache.xml
│   ├── llm-content-safety.xml
│   └── mcp-governance.xml
├── test/                   # curl scripts per phase (chat completion, 429, cache hit, content-safety block, mcp tool call)
└── README.md               # per-phase apply + validation instructions, prod-hardening appendix
```

Resources map to `azurerm` types where available (`azurerm_api_management`,
`azurerm_api_management_api`, `_backend`, `_api_policy`, `_product`,
`_subscription`, `_logger`, `_diagnostic`, `azurerm_api_management_redis_cache`,
`azurerm_cognitive_account`, `azurerm_cognitive_deployment`,
`azurerm_role_assignment`, `azurerm_log_analytics_workspace`,
`azurerm_application_insights`).

## 6. Tooling caveats (honest)

- The newest AI-gateway features — **MCP server resource** and **A2A agent API** —
  may not yet have first-class `azurerm` resources. Where they don't, use the
  **`azapi` provider** to call the ARM API directly. The implementation must verify
  exact provider support against the current `azurerm`/`azapi` versions (via the
  terraform-specialist agent / Terraform registry) before committing to an
  approach.
- The LLM **policies** (`llm-token-limit`, `llm-semantic-cache-*`,
  `llm-content-safety`, `llm-emit-token-metric`) are applied as **policy XML** via
  `azurerm_api_management_api_policy` / product policy — no dedicated resource
  needed.
- Some features (A2A agent import, AI gateway in Foundry) are **preview**; flag
  preview status in the README.

## 7. Error handling & resiliency

- Backend **circuit breaker** trips on repeated failures, honouring `Retry-After`.
- **Retry** policy with exponential backoff for transient 429s from the backend.
- **Token limit** returns 429 with remaining-token headers to the consumer.
- **Content safety** blocks and returns a clear error when a prompt is flagged.
- Per-team **subscriptions** isolate one team's overuse from another's quota.

## 8. Testing & validation

- `terraform fmt -check` and `terraform validate` run by me (no cloud creds).
- `terraform plan` documented as a user step (needs `az login` + subscription);
  run by me only if the user has authenticated.
- **No `terraform apply`** performed by me.
- `test/` curl scripts give a manual end-to-end check for each phase's validation
  gate.

## 9. Out of scope (this iteration)

- Production networking: VNet injection, internal mode, Application Gateway + WAF,
  private endpoints, private DNS zones. Captured as a **prod-hardening appendix**
  in the README, not built.
- Multi-region / zone redundancy (not available on Developer tier).
- Terraform modules, remote state backend, CI/CD pipelines.
- Real production model quotas / PTU procurement.

## 10. Deliverables

1. Flat Terraform configuration implementing Phases 1–6 (toggle-gated).
2. Policy XML fragments under `policies/`.
3. `README.md` with per-phase apply + validation steps and a prod-hardening
   appendix.
4. `test/` curl scripts per validation gate.
5. An architecture diagram of the sandbox.
6. `terraform.tfvars.example`.
