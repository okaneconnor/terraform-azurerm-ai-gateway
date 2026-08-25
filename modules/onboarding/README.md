# onboarding — declarative team registry

Team onboarding for the AI gateway as **one reviewed YAML file in its own
Terraform state**. A team present in the registry is onboarded; a team removed is
deprovisioned on the next apply. Teams onboard, raise changes and offboard by
pull request — the PR diff is the audit trail, and platform review of that PR is
the approval gate.

This module holds **azuread resources only**. The state that applies it needs
Entra permissions (create app-role assignments), never gateway credentials — and
an onboarding apply can never plan the gateway. The only coupling to the gateway
is three of its outputs.

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

`tier` is recorded and validated against the gateway's presets; per-team limit
enforcement keyed on these entries is layered on by the gateway's team-overrides
policy (see the module CHANGELOG for what is live).

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

## Lifecycle

| Action | Change |
| --- | --- |
| Onboard a team | add its entry, merge, apply |
| Add a service | add one list item |
| Change a team's tier | edit one line |
| Offboard | remove the entry — the assignment is destroyed and freshly issued tokens stop carrying the admission role (already-issued tokens live out their ≤90-minute expiry) |

In every case: `terraform plan` on the **gateway** state shows zero changes.
