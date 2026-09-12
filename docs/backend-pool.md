# Backend pool — multi-member Foundry failover (`var.backend_pool`)

By default the gateway's Foundry backend is a single member. `var.backend_pool` turns it
into a **priority-ordered, weighted, circuit-breaker-driven pool** across multiple Foundry
/ Azure OpenAI endpoints — Microsoft's recommended **PTU-priority + PAYG-spillover**
topology: a Provisioned (PTU) endpoint absorbs traffic first; when it's exhausted, a
Standard/PAYG endpoint takes over. `backend_pool = {}` (the default) reproduces today's
single-member pool exactly — this is opt-in and fully backwards-compatible.

For the full input schema see the [Inputs](../README.md#inputs) reference
(`backend_pool`, `circuit_breaker`) in the README; this page covers how to use it
correctly.

## The pool model

The module's own Foundry account (created from the required `model_deployments`) is
always a pool member — its position is `backend_pool.primary_priority` /
`primary_weight` (default `1` / `100`). `backend_pool.members` adds more:

```hcl
members = {
  <key> = {
    # exactly ONE of the next two:
    create_account = { ... }   # module provisions a private AIServices account for this member
    endpoint_url    = "..."    # OR bring-your-own — an existing Foundry/Azure OpenAI endpoint

    priority = 2      # default 2 — see "Priority semantics" below
    weight   = 100     # default 100, range 1-100 (Azure BackendPoolItem limit)

    managed_identity_scope_id = "..."   # BYO only: grants the APIM MI access (see "Auth")
    circuit_breaker            = { ... } # optional per-member override of var.circuit_breaker
  }
}
```

Member keys must match `^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$` (1-24 chars, lowercase
alphanumeric/hyphen) — they become part of an Azure Cognitive account name for
`create_account` members. A pool holds at most **30 members total, including the
primary** (an Azure API Management limit); the module validates this at plan time.

## Priority semantics

Azure API Management's priority-based load balancing (see
[Backends in API Management](https://learn.microsoft.com/azure/api-management/backends#load-balanced-pool)),
in its own words — two separate notes from that page:

> Priority-based: Organize backends into priority groups. Send requests to higher
> priority groups first; within a group, distribute requests evenly or according to
> assigned weights.

> The API Management service uses backends in lower priority groups only when all
> backends in higher priority groups are unavailable because circuit breaker rules are
> tripped.

Lower `priority` numbers are served *first*: `priority = 1` is the highest-priority group.
For PTU-priority + PAYG-spillover, put the PTU member at `priority = 1` and the
Standard/PAYG member(s) at `priority = 2`. A priority-2 member receives **zero** traffic
until *every* priority-1 member's circuit breaker has tripped — this isn't a soft
weighting, it's a hard cutover driven entirely by breaker state.

Within a priority group, `weight` (1-100 — Azure's `BackendPoolItem` limit) distributes
load across members that share that priority — e.g. two PAYG members both at
`priority = 2` with weights `75`/`25` split roughly 3:1.

## `trip_on_429` for pools

`var.circuit_breaker.trip_on_429` defaults to `false` module-wide. With a single-member
pool that's deliberate: tripping the only backend on 429 (a client burst) would 503 the
*entire* gateway for `trip_duration`, with nowhere to fail over to.

Once you have a second, lower-priority member, that trade-off flips. For Azure OpenAI, a
`429` from a PTU deployment means **the PTU capacity is exhausted** — exactly the signal
that should trip the breaker and spill to PAYG. Set it on the PTU member specifically via
its per-member `circuit_breaker` override, leaving the global default (and any PAYG
member) untouched:

```hcl
members = {
  ptu = {
    endpoint_url    = "https://contoso-ptu.openai.azure.com/"
    priority        = 1
    circuit_breaker = { trip_on_429 = true }   # 429 == PTU exhausted -> trip -> spill
  }
}
```

Every member's breaker always trips on 5xx regardless of `trip_on_429` — that flag only
adds the `429` status range to the failure condition. `output.backend_pool_members`
surfaces each member's effective `trip_on_429` so you can confirm the override applied.

## Circuit-breaker failover: what actually trips it

APIM's backend circuit breaker counts backend **responses** — it trips only when a
member *responds* with a status code inside the configured `statusCodeRanges` (5xx
always; `429` too when `trip_on_429 = true`). It does **not** trip on connection-level
failures to an unreachable endpoint: a DNS failure, TCP refusal, or TLS error surfaces to
the caller as `BackendConnectionFailure` (HTTP `500`), and this was live-verified to
**not** trip the breaker — even with `errorReasons` included in the failure condition.

Practically: the pool fails over to the next priority group when a member **returns**
`429` (PTU exhausted — the Microsoft-documented spillover trigger) or a `5xx` response.
A member whose endpoint is simply **down or unreachable** will not trip its breaker and
so will not trigger priority failover — requests routed to it will fail with
`BackendConnectionFailure` instead of spilling to a lower-priority member. This is Azure
platform behavior (how the backend circuit breaker is implemented), not something this
module configures or can change.

## Deployment-name parity

The gateway routes by the deployment name in the request path
(`/openai/deployments/{name}/chat/completions`). For a spilled-over request to succeed
transparently, **every pool member must expose the same deployment name(s)** as the one
the client requested. If a lower-priority member is missing that deployment, a request
that spills to it returns `404 DeploymentNotFound` instead of an answer — a silent
failure mode that only shows up mid-incident, exactly when you can least afford it.

The module enforces this for **`create_account`** members: a plan-time validation
requires each `create_account` member to declare a deployment for every key in the
top-level `model_deployments`. For **bring-your-own** (`endpoint_url`) members this
can't be validated from Terraform — it's your responsibility to keep the BYO endpoint's
deployment names in sync with `model_deployments` (this is exactly why the example below
uses the *same* deployment name, `gpt-5.4-mini`, on both the PTU endpoint and the
module's own account).

## Approximate load balancing across gateway units

Azure API Management's gateway instances don't share state:

> Because of the distributed nature of the API Management architecture, backend load
> balancing is approximate. Different instances of the gateway don't synchronize and
> load balance based on the information on the same instance.
> — [Backends in API Management](https://learn.microsoft.com/azure/api-management/backends#load-balanced-pool)

Each gateway unit tracks weight distribution and circuit-breaker trip state
independently. On a **single-unit Developer SKU** (`apim_sku_name = "Developer_1"`, the
module's default) this is a non-issue — there's exactly one instance, so routing and
breaker state are deterministic. On a multi-unit **Premium** deployment
(`apim_sku_name = "Premium_N"`, N > 1, or zone-redundant via `apim_zones`), expect
weighted distribution and breaker trip/reset timing to be *approximate* across units —
one unit may still be routing to a member that another unit has already marked tripped.
Design alerting and capacity headroom around that approximation, not around
per-request determinism.

## Two spillover layers — pick the right one (or both)

This module's pool is one of *two* complementary spillover mechanisms for PTU overflow.
They operate at different layers and aren't mutually exclusive:

| | Gateway-side pool (`var.backend_pool`, this feature) | Service-side `spilloverDeploymentName` (Azure OpenAI) |
|---|---|---|
| Where it routes | Across **different** Foundry/Azure OpenAI **resources** (accounts/endpoints), or any HTTP backend | Within **one** Azure OpenAI resource — PTU deployment → Standard deployment in the *same* account |
| Trigger | Per-member circuit breaker (5xx always, 429 opt-in via `trip_on_429`) trips after `failure_count` failures in `interval` | Automatic on the PTU deployment's own non-200 response (`429` exhausted, `400` long-context, `500`/`503`) |
| Requires | Nothing beyond a second member (BYO endpoint or module-created account) | An active PTU deployment **and** a Standard deployment of the same model **in the same resource**, plus PTU quota to provision the PTU deployment itself |
| Provisioned by this module? | Yes — this is `var.backend_pool` | **No.** `azurerm_cognitive_deployment` has no `spilloverDeploymentName` argument; set it out-of-band (Azure CLI/REST/portal) on your PTU deployment if you want it |

Use the gateway-side pool when you want failover across *accounts* — different regions,
different subscriptions, a BYO PTU endpoint someone else provisioned, or resilience to a
whole-account outage. Use `spilloverDeploymentName` when you want overflow handled
*inside a single Azure OpenAI resource* with no gateway round-trip. They stack cleanly:
a PTU deployment can spill to its own in-resource Standard deployment first via
`spilloverDeploymentName`, with the gateway-side pool as the outer safety net if the
*entire* PTU account becomes unreachable. See
[Manage traffic with spillover for provisioned deployments](https://learn.microsoft.com/azure/foundry/openai/how-to/spillover-traffic-management)
for the service-side mechanism.

## Limits

- **Max 30 members per pool**, including the primary (Azure API Management limit) —
  validated at plan time.
- **Circuit breakers aren't supported on the Consumption APIM tier.** This module only
  ever provisions `Developer_1` or `Premium_N` (`apim_sku_name` is validated to that
  regex) — both support circuit breakers — so this is a non-issue for deployments made
  with this module. It matters only if you fork the module onto Consumption.

## Full example — BYO PTU at priority 1, module's Standard account at priority 2

The module's own Foundry account (built from `model_deployments`, always present) plays
the PAYG/Standard spillover role at `priority = 2`; a bring-your-own PTU endpoint takes
`priority = 1` and absorbs traffic first:

```hcl
module "ai_gateway" {
  source  = "okaneconnor/ai-gateway/azurerm"
  version = "~> 2.0"

  location        = "uksouth"
  publisher_name  = "AI Platform Team"
  publisher_email = "platform@example.com"

  # The module's own account -> Standard/PAYG spillover target. Deployment names here
  # MUST match what the PTU endpoint below serves (deployment-name parity).
  model_deployments = {
    "gpt-5.4-mini" = {
      model_name    = "gpt-5.4-mini"
      model_version = "2026-03-17"
      sku_name      = "Standard"
    }
  }

  backend_pool = {
    primary_priority = 2   # the module's Standard account is the spillover target
    primary_weight   = 100

    members = {
      ptu = {
        # Bring-your-own: an existing Provisioned (PTU) Foundry/Azure OpenAI endpoint,
        # serving the SAME deployment name(s) as model_deployments above.
        endpoint_url = "https://contoso-ptu.openai.azure.com/"
        priority     = 1     # served first -- the PTU capacity you're paying for
        weight       = 100

        # Grants the APIM managed identity "Cognitive Services OpenAI User" on the
        # PTU account so it can call it. Omit and grant access out-of-band instead.
        managed_identity_scope_id = "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/contoso-ptu"

        circuit_breaker = {
          trip_on_429   = true     # 429 on the PTU endpoint == exhausted -> spill to PAYG
          failure_count = 3
          interval      = "PT1M"
          trip_duration = "PT1M"
        }
      }
    }
  }
}
```

### Alternative: an additional module-created member

Instead of (or alongside) a BYO member, `create_account` provisions another private
AIServices account with its own deployments — e.g. a second Standard account for extra
priority-2 headroom, or a second region:

```hcl
backend_pool = {
  members = {
    payg-2 = {
      priority       = 2
      weight         = 50   # shares priority 2 with the primary, roughly 2:1 by weight
      create_account = {
        sku_name = "S0"
        model_deployments = {
          # Must declare every key in the top-level model_deployments (parity,
          # validated at plan time for create_account members).
          "gpt-5.4-mini" = {
            model_name    = "gpt-5.4-mini"
            model_version = "2026-03-17"
            sku_name      = "Standard"
          }
        }
      }
    }
  }
}
```

This provisions a private `azurerm_cognitive_account` + deployments + private endpoint
for `payg-2`, and grants the APIM managed identity `Cognitive Services OpenAI User` on
it automatically (no `managed_identity_scope_id` needed — that's only for BYO members).
When `enable_backend_diagnostics` is on (the default), each `create_account` member also
gets its own service-side diagnostic setting routed to Log Analytics, matching the
primary account's coverage.

## Auth

No policy changes are needed for any member: the gateway authenticates to backends with
a managed-identity token for the `https://cognitiveservices.azure.com` audience, which is
identical for every Azure OpenAI / Foundry endpoint. `create_account` members get the
`Cognitive Services OpenAI User` role grant automatically; for `endpoint_url` (BYO)
members, set `managed_identity_scope_id` to the member's resource ID and the module
grants the same role — or grant it yourself out-of-band and leave
`managed_identity_scope_id` unset.

## Changing pool membership

Members can be added, removed, or swapped for a different member (same key, new
endpoint) freely — each of these converges in a single `terraform apply`, including
removing **several members at once** (live-verified).

Removal needs a little help under the hood: Azure rejects deleting a backend that's
still referenced by a pool (`"Backend Entity ... is referenced in Backend Pool ... and
cannot be deleted"`), but Terraform's core dependency graph destroys a removed member's
backend *before* it updates the pool to drop that member — the dependency edge that
would order these correctly disappears the moment the member leaves the `for_each` map
(a by-design Terraform core limitation:
[hashicorp/terraform#32153](https://github.com/hashicorp/terraform/issues/32153)). To
close that gap, the module provisions a per-member destroy-time cleanup action
(`azapi_resource_action.pool_member_cleanup`) that PATCHes the pool down to the primary
member *first*, at destroy time, before the removed member's backend is deleted — so the
backend is always unreferenced by the time Terraform deletes it.

One visible trade-off: between that cleanup PATCH and the pool's own update (which runs
last in the same apply), the pool briefly holds the primary only — surviving members are
re-attached moments later in the same apply. The primary keeps serving throughout, so
this is a momentary narrowing of the pool, not an outage. You don't need to do anything
manual for any of this — add / remove / swap, single or multiple members, all just work.

## Output

`output.backend_pool_members` reports every member (including the primary) keyed by
name, with its effective `priority`, `weight`, `kind` (`"created"` or `"byo"`), and
`trip_on_429`:

```bash
terraform output -json backend_pool_members
```

```json
{
  "primary": { "priority": 2, "weight": 100, "kind": "created", "trip_on_429": false },
  "ptu":     { "priority": 1, "weight": 100, "kind": "byo",     "trip_on_429": true }
}
```

## See also

- [docs/architecture.md](architecture.md) — how the pool fits into the overall backend
  resilience picture (circuit breaker defaults, semantic cache, SKU guardrail).
- [docs/usage.md](usage.md) — deploying and testing the gateway end-to-end.
