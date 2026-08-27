# onboarding — declarative team registry

Team onboarding for the AI gateway as **one reviewed YAML file in its own
Terraform state**. A team present in the registry is onboarded; a team removed is
deprovisioned on the next apply. Teams onboard, raise changes and offboard by
pull request — the PR diff is the audit trail, and platform review of that PR is
the approval gate.

By default this module holds **azuread resources only**. The state that applies
it needs Entra permissions (create app-role assignments), never gateway
credentials — and an onboarding apply can never plan the gateway. Setting
`apim_id` activates the **overrides seam** (below): the module then also owns
the content of two gateway policy fragments via `azapi`, which widens its
credential needs to write access on that one APIM service — still never the
gateway's Terraform state.

```hcl
data "terraform_remote_state" "gateway" {
  backend = "azurerm" # wherever the gateway state lives
  config  = { /* ... */ }
}

module "onboarding" {
  source  = "okaneconnor/ai-gateway/azurerm//modules/onboarding"
  version = "~> 2.0"

  registry_file         = "${path.module}/teams.yaml"
  gateway_app_object_id = data.terraform_remote_state.gateway.outputs.gateway_app_object_id
  gateway_app_role_id   = data.terraform_remote_state.gateway.outputs.gateway_app_role_id
  tier_names            = data.terraform_remote_state.gateway.outputs.tier_names

  # Optional — activates per-team enforcement (limits, allowlists, content safety):
  apim_id                    = data.terraform_remote_state.gateway.outputs.apim_id
  tier_limits                = data.terraform_remote_state.gateway.outputs.tiers
  canonical_models           = data.terraform_remote_state.gateway.outputs.canonical_models
  rate_limit_renewal_seconds = data.terraform_remote_state.gateway.outputs.rate_limit_renewal_seconds
  content_safety             = data.terraform_remote_state.gateway.outputs.content_safety_contract
  defaults_file              = "${path.module}/defaults.yaml" # optional platform defaults
}
```

## The registry

```yaml
version: v1
teams:
  - team: team-alpha          # lowercase kebab-case, unique
    owner: alpha-devs         # contact/alias for governance — not read by Terraform
    tier: standard            # must be one of the gateway's tier_names
    services:
      - service: chat         # lowercase kebab-case, unique within the team
        client_id: <app/client GUID>            # the identity that calls the gateway (azp)
        principal_object_id: <SP object GUID>   # what the admission assignment binds to
```

A **service is an Entra identity** — an app registration or a managed identity.
That identity's `azp` claim is what the gateway keys limits, quotas, cache
partitions and chargeback on, so one identity per service is enforced: sharing
one would merge two services' attribution, limits and revocation.

For an app registration:

```bash
az ad sp show --id <app-client-id> --query "{client_id:appId,principal_object_id:id}" -o json
```

For a managed identity, `client_id` is the identity's client id and
`principal_object_id` its `principalId`.

`tier` is validated against the gateway's presets and — once the overrides seam
is active — selects the preset that seeds the team's limits.

## The overrides seam

With `apim_id` set, this module renders per-team policy from the registry and
writes it into two gateway-owned-but-inert policy fragments
(`ai-team-overrides`, `ai-team-content-safety`) via `azapi_update_resource`.
The gateway created those fragments with `ignore_changes` on their content, so:

- a registry change plans **only** the fragment update, in this state;
- a gateway apply never overwrites team policy;
- destroying this module resets both fragments to inert (destroy-time twin) —
  the gateway falls back to its tier presets for every caller.

**Fail closed:** while the seam is active, a caller that holds the admission
role but has no registry entry is refused with `403 not_onboarded`. Anything
else would let a caller dodge model allowlists and content-safety overrides by
simply not registering. Register every existing caller *before* activating the
seam. The seam covers the LLM surfaces (`/v1` facade and the legacy `/openai`
path); passthrough `ai_services` APIs keep the platform tier limits.

Apply ordering: the gateway must be applied (fragments exist) before this
module's first apply with `apim_id` set.

### Overrides in the registry

Teams and services take three optional keys; a service inherits its team's
values, a team inherits the platform's:

```yaml
version: v1
teams:
  - team: team-beta
    owner: beta-devs
    tier: standard                    # seeds limits from the gateway preset
    limits: { tokens_per_minute: 50000 }   # other limit keys inherit the tier
    allowed_models: [gpt-5-mini]      # replaces the default list wholesale
    services:
      - service: chat
        client_id: <GUID>
        principal_object_id: <GUID>
        limits: { rate_limit_calls: 5 }    # service beats team beats tier
        content_safety:
          categories:
            violence: { threshold: 2 }     # other categories inherit
```

`defaults.yaml` (optional, platform-authored) sets what tiers do not carry:

```yaml
allowed_models: [gpt-5-mini, gpt-4o]  # default allowlist (canonical names)
content_safety:                       # default category tuning
  categories:
    hate: { threshold: 3 }
```

### Merge semantics

Most specific wins. **Maps merge per key; lists replace wholesale.**

| Setting | Layers (highest first) |
| --- | --- |
| `limits.*` | service → team → the team's **tier preset** |
| `allowed_models` | service → team → `defaults.yaml` → all canonical models |
| `content_safety.categories.*.{enabled,threshold}` | service → team → `defaults.yaml` → the gateway's platform settings |

`shield_prompt` and `enforce_on_completions` stay the platform's decision —
teams tune categories and thresholds only. `content_safety.enabled: false`
(skipping ALL screening for that caller, Prompt Shield included) is refused
unless the platform sets `allow_team_content_safety_opt_out = true`.
`limit_maxima` optionally caps every **effective** (post-merge) limit.

A team's PR to raise its own token budget is one line —

```diff
   - team: team-beta
     tier: standard
-    limits: { tokens_per_minute: 50000 }
+    limits: { tokens_per_minute: 80000 }
```

— and the plan that PR produces touches one resource
(`azapi_update_resource.team_overrides`), in the onboarding state only.

The `effective_policies` output is the audit view: the fully merged limits,
allowlist and content-safety settings every registered service actually gets.

## Validation

Every rule fails the **plan** with a message naming the offending entry, so a
team can fix its own PR without platform help:

| Rule | Why it exists |
| --- | --- |
| `version: v1`, no unknown keys anywhere | a misspelled key (`groupId`, `clientid`) would otherwise be silently ignored — the team gets different behaviour than their file appears to request |
| required fields on every team and service | — |
| lowercase kebab-case names, 1–32 chars | names feed derived resource keys |
| ids are GUID-shaped | `principal_object_id` is the SP **object id**, not the application id |
| **placeholder-GUID detection** | `11111111-2222-…` means someone copied the docs example without substituting |
| unique team names | one entry per team; its services live under it |
| **derived-key collision** (`<team>-<service>`) | team `a` + service `b-c` and team `a-b` + service `c` derive the same key, and a `for_each` would silently collapse them — one team quietly receiving another's assignment |
| identity claimed once, ever (`client_id` and `principal_object_id`) | shared identity = merged attribution, limits and revocation |
| `tier` exists on the gateway | a registry can never reference a preset the gateway does not define |
| overrides declared but seam inactive | limits/allowlists/CS in the registry with no `apim_id` would silently do nothing |
| limit values are positive integers; quota period is a real period | rendered verbatim into policy — reject at plan, not at APIM |
| `allowed_models` non-empty and ⊆ the gateway's canonical models | an empty list blocks everything; an unknown name can never match |
| content-safety keys/categories known, thresholds integer 0–7, flags boolean | a misspelled category would silently keep the default |
| opt-out only when the platform allows it | screening is a platform guarantee |
| effective limits ≤ `limit_maxima` (when set) | a team PR cannot exceed platform ceilings |

## Lifecycle

| Action | Change |
| --- | --- |
| Onboard a team | add its entry, merge, apply |
| Add a service | add one list item |
| Change a team's tier | edit one line |
| Offboard | remove the entry — the assignment is destroyed and freshly issued tokens stop carrying the admission role (already-issued tokens live out their ≤90-minute expiry) |

In every case: `terraform plan` on the **gateway** state shows zero changes.
