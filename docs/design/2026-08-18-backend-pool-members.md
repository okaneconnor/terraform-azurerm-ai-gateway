# Design — Multi-member Foundry backend pool (PTU priority + PAYG spillover)

Issue: #15 · Branch: `feat/backend-pool-members` · Date: 2026-08-18

## Summary

Turn the module's single-member APIM backend pool into a **priority-ordered, weighted,
circuit-breaker-driven pool** so consumers can run Microsoft's recommended
**PTU-priority + PAYG-spillover** topology: a Provisioned (PTU) endpoint at priority 1
with Standard / GlobalStandard endpoints as overflow at priority 2. Failover is driven by
per-member circuit breakers. The change is **fully backwards-compatible** — the default
configuration produces exactly today's single-member pool.

## Background — the gap

Today (`resilience.tf`):

- One `azurerm_cognitive_account.foundry` account, N deployments (`var.model_deployments`).
- One `azapi_resource.foundry_member` (`type = Single`) → one `azapi_resource.foundry_pool`
  (`type = Pool`) whose `pool.services` has a single entry at priority 1.

The issue calls this "the module's most significant gap": with one member the circuit
breaker has nowhere to fail over to, which is why `trip_on_429` defaults off (deliberately
diverging from Microsoft's sample). The PTU-baseline-plus-PAYG-overflow pattern cannot be
built at all.

## Microsoft best-practice grounding (cross-checked via MS Learn)

- **Priority-based load balancing**: "Send requests to higher priority groups first; within
  a group, distribute according to weight. The service uses backends in lower priority
  groups **only when all backends in higher priority groups are unavailable because circuit
  breaker rules are tripped**." → priority-1 PTU, priority-2 PAYG spillover.
  (`learn.microsoft.com/azure/api-management/backends#load-balanced-pool`)
- **Circuit breaker for Azure OpenAI**: "implement circuit breaker rules to handle the 429
  responses and accept the `Retry-After` duration." Pools support **up to 30** backends;
  a backend circuit breaker supports **one rule**. CB is available in Developer + Premium
  (not Consumption) → testable on the current Developer stack.
- **Managed-identity auth is uniform**: the module authenticates to backends in
  `frag-backend-mi.xml` with `authentication-managed-identity resource="https://cognitiveservices.azure.com"`.
  That audience is identical for every Azure OpenAI endpoint, so multi-member needs **no
  policy change** — only a per-member **RBAC role grant** (`Cognitive Services OpenAI User`).
- **AI-gateway resiliency guidance** (`genai-gateway-capabilities`, Foundry HA doc): backend
  load-balancer + circuit breaker with priority routing is *the* documented pattern for
  "optimal utilization of specific Foundry endpoints, particularly PTU instances."

## Design

### Input model

One new grouped variable, default `{}` (⇒ unchanged behavior):

```hcl
variable "backend_pool" {
  type = object({
    primary_priority = optional(number, 1)   # the module's own Foundry account as a member
    primary_weight   = optional(number, 100)
    members = optional(map(object({
      # exactly ONE of the next two (validated):
      create_account = optional(object({      # module provisions this member
        location          = optional(string)  # defaults to module location
        sku_name          = optional(string, "S0")
        model_deployments = map(object({
          model_name    = string
          model_version = string
          model_format  = optional(string, "OpenAI")
          sku_name      = string              # Standard / GlobalStandard / Provisioned…
          capacity      = number
        }))
      }))
      endpoint_url = optional(string)          # BYO existing endpoint, e.g. https://x.openai.azure.com/

      managed_identity_scope_id = optional(string)  # BYO: account resource id to grant APIM MI on
      priority                  = optional(number, 2)
      weight                    = optional(number, 100)
      circuit_breaker           = optional(object({ … same shape as var.circuit_breaker … }))
    })), {})
  })
  default = {}
}
```

A member is **module-created** (`create_account` set) **XOR bring-your-own**
(`endpoint_url` set).

**Deployment-name parity (correctness constraint):** the gateway routes by the deployment
name in the request path (`/openai/deployments/{name}/…`). For failover to be transparent,
every pool member must expose the **same deployment name(s)** as the primary — otherwise a
request that spills to a member lacking that deployment 404s (`DeploymentNotFound`). The
module validates that each `create_account` member declares a deployment for every name in
`var.model_deployments`; for BYO members this is the caller's responsibility (documented).

### Resources

Per **module-created** member:
- `azurerm_cognitive_account.member[k]` — private, system-assigned MI, `network_acls` Deny,
  `public_network_access_enabled = false`, `local_auth_enabled = false` (matches the primary).
- `azurerm_cognitive_deployment.member_model[k/deployment]` — flattened members × deployments.
- Private endpoint + DNS A-record for each member account (reuses the primary's PE pattern).
- `azurerm_role_assignment.member_openai[k]` — APIM MI → `Cognitive Services OpenAI User`.

Per **BYO** member:
- `azapi_resource.member_backend[k]` (`type = Single`) → `endpoint_url`.
- Optional `azurerm_role_assignment` if `managed_identity_scope_id` is set (else the caller
  grants MI access out-of-band; documented).

Shared:
- Each member (created or BYO) gets a `Single` backend with its own circuit breaker
  (per-member override or inherited `var.circuit_breaker`).
- `azapi_resource.foundry_pool.pool.services` is rebuilt dynamically:
  `[{ primary, primary_priority, primary_weight }] + [ each member ]`.
- The existing primary `foundry_member` stays; its pool entry uses `primary_priority` /
  `primary_weight`.

### Auth model

Unchanged policy chain. MI token audience (`cognitiveservices.azure.com`) already covers
every member. Only additions are the per-member RBAC grants above.

### Circuit breaker / `trip_on_429`

Per the issue's ask to revisit the default now that failover exists: **keep the global
`var.circuit_breaker.trip_on_429` default unchanged** (flipping it would make existing
single-member users fail-fast on 429 with nowhere to spill). Instead, docs + an example
show setting `trip_on_429 = true` for pools, where a 429 = PTU exhausted ⇒ spill to PAYG.
Per-member `circuit_breaker` overrides let a PTU member trip on 429 while a PAYG member
trips only on 5xx.

### Validation (plan-time)

- Each member sets **exactly one** of `create_account` / `endpoint_url`.
- `priority >= 1`; `weight` in `1..1000`.
- Total pool size (`1 + length(members)`) `<= 30`.
- Every `create_account` member declares a deployment for each name in
  `var.model_deployments` (deployment-name parity).

### Backwards compatibility

`backend_pool = {}` ⇒ primary member at priority 1 / weight 100, no extra members ⇒ byte-for-byte
today's single-member pool. `var.circuit_breaker` untouched.

## Explicitly out of scope (documented, not built)

- **`spilloverDeploymentName`** — the service-side Azure OpenAI complement (PTU → Standard
  *within one resource*). `azurerm_cognitive_deployment` does **not** expose it, and testing
  needs real PTU quota. The gateway-side pool already delivers spillover across
  accounts/endpoints. Documented as the alternative/complementary option; possible future
  azapi-based enhancement.
- **Session affinity** (`sessionAffinity`) — only needed for stateful backends (Assistants
  API). Not enabled; noted as available.
- **Multiple primary accounts** — the primary stays a single module account; additional
  capacity is expressed as members.

## Testing plan

All feature paths behaviorally verified on the live Developer stack (per the module's
test-everything rule); Cognitive accounts are free, only token usage costs.

**Live:**
1. Deploy a 2nd **module-created** member (Standard deployment) at priority 2, primary at
   priority 1 → confirm normal traffic is served by priority 1.
2. **Force priority-1 to trip** (deterministic 5xx/429 from the primary member, e.g. a member
   pointed at an invalid deployment / a tightened `failure_count`) → confirm **spillover to
   the priority-2 member**, then recovery after `trip_duration`. Evidence from
   `ApiManagementGatewayLogs` (`BackendId` / `PoolIsInactive`) + response success.
3. **BYO member**: add a member with `endpoint_url` = the primary's endpoint and
   `managed_identity_scope_id` = the primary account id → confirm the BYO wiring + MI grant.
4. **Regression**: default config ⇒ single-member pool; existing smoke suite passes.

**Unit (`terraform test`):**
- default ⇒ pool has 1 service (primary).
- 2 members ⇒ pool has 3 services, correct priorities/weights.
- XOR validation: both / neither of `create_account`,`endpoint_url` ⇒ error.
- pool size > 30 ⇒ error.
- `create_account` member missing a `var.model_deployments` name ⇒ error (parity).
- per-member `circuit_breaker` override renders into the member backend.

## Docs to update

- `variables.tf` doc + README (terraform-docs regen).
- New `docs/backend-pool.md` (or a `docs/usage.md` section): PTU+PAYG pattern, priority
  semantics, **approximate load-balancing across units** caveat, the **two spillover layers**,
  `trip_on_429` guidance.
- An `examples/` snippet for the PTU+PAYG pool.
- `CHANGELOG.md` `[Unreleased]`.

## Risks / notes

- `Microsoft.ApiManagement/service/backends@2024-06-01-preview` `pool.services[].{priority,weight}`
  is already used by the module and matches MS ARM examples — low risk.
- A private endpoint per created member adds cost/resources but preserves the module's
  private-by-default posture.
- Deterministically tripping the priority-1 breaker for the spillover test needs a reliable
  failure trigger; the implementation plan will pin one (invalid deployment name ⇒
  `DeploymentNotFound`, or a scoped `failure_count = 1`).
