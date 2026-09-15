# Onboarding example — the consumer's two-state layout

What a consumer actually runs. Two Terraform states, deliberately separate:

| State | Contains | Credentials it needs | Changes when |
| --- | --- | --- | --- |
| **gateway** (see [`../complete`](../complete)) | APIM, Foundry, networking, policies | Azure subscription rights | the platform changes |
| **onboarding** (this directory) | one role assignment per service + the rendered team policy | Entra rights, plus write access to the one APIM service when the seam is on | a team onboards or changes config |

A team's pull request touches `teams.yaml` and nothing else. `terraform plan` on
the **gateway** state shows zero changes — that property is the point of the
split, and it is worth asserting in CI.

## Wiring

The onboarding state takes the gateway's outputs as inputs. Pass them however
your estate moves values between states — CI variables or a shared tfvars file.
Onboarding needs eight non-secret values, never the gateway's state or its
credentials, and that is what keeps the two states independent.

Admission only:

```hcl
gateway_app_object_id = <gateway output>
gateway_app_role_id   = <gateway output>
tier_names            = <gateway output>
```

Plus these to activate the overrides seam:

```hcl
apim_id                    = <gateway output>
tiers                      -> tier_limits
canonical_models           = <gateway output>
model_map                  = <gateway output>
rate_limit_renewal_seconds = <gateway output>
content_safety_contract    -> content_safety
```

```bash
terraform apply -var-file=gateway-outputs.tfvars
```

## The two modes

Leaving `apim_id` unset grants **admission only**: every admitted caller gets the
gateway's default tier preset. This is the original behaviour and needs only the
`azuread` provider.

Setting `apim_id` (with the other seam inputs) additionally makes the registry
the authority on limits, model allowlists and content-safety settings, rendered
into gateway-owned policy fragments.

**Enabling it is fail closed.** A caller that holds the admission role but has no
entry in `teams.yaml` is refused with `403 not_onboarded` — otherwise a team
could dodge its allowlist and content-safety settings by simply not registering.
Register every existing caller *before* you turn it on. Policy also reaches the
gateway eventually-consistently, so a newly onboarded caller can briefly still
see `403 not_onboarded` for a few tens of seconds after the apply returns.

## Merge order

Most specific wins. **Maps merge per key; lists replace wholesale.**

| Setting | Layers, highest first |
| --- | --- |
| `limits.*` | service → team → the team's tier preset |
| `allowed_models` | service → team → `defaults.yaml` → every canonical model |
| `content_safety.categories.*` | service → team → `defaults.yaml` → the gateway's settings |

`limit_maxima` in `main.tf` caps the **effective** result, so no team PR can
exceed the platform's ceilings whatever it writes. Quota ceilings are compared as
tokens-per-day, so shortening `token_quota_period` cannot be used to slip past
one.

The `effective_policies` output prints the fully merged result per service — the
answer to "what does this team actually get", without reading policy XML.

## What a team's PR looks like

```diff
   - team: research
     tier: standard
     limits:
-      tokens_per_minute: 50000
+      tokens_per_minute: 80000
```

That plans exactly one resource in this state — the policy write — and nothing
in the gateway's.
