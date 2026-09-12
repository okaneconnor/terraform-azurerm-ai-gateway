# Onboarding a team

A platform runbook for granting, handing off, verifying, and revoking a team's
access to the AI gateway. Access is a **single Entra app-role assignment** of the
gateway's admission role — no secrets are distributed by the platform, and access
is instantly revocable.

Admission and configuration are deliberately separate concerns:

- **Admission** (this runbook) — the identity holds the gateway's admission role
  (`admission_app_role`, default `AI.Gateway.Standard`). A directory operation,
  needed once per identity.
- **Consumption config** — limits and quotas come from the gateway's tier presets
  (`var.tiers` / `var.default_tier`), not from the role. Admitted callers get the
  default preset — until the registry's **overrides seam** is activated, at which
  point each registered team gets its tier preset plus its own reviewed
  overrides (limits, model allowlist, content-safety thresholds) and
  unregistered callers are refused with `403 not_onboarded`. See
  [`modules/onboarding`](../modules/onboarding/README.md#the-overrides-seam).

## Prerequisites

- The team has a **workload identity** — an Entra app registration or a managed
  identity (a managed identity is a service principal; everything below applies
  identically).
- Someone with rights to assign app-roles on the gateway app (Application
  Administrator / Cloud Application Administrator, or an owner of the gateway app
  registration) — **or**, for the Terraform path, a principal allowed to create
  app-role assignments.
- The gateway is deployed and its outputs are readable: `gateway_app_client_id`,
  `gateway_app_object_id`, `gateway_app_role_id`, `apim_gateway_url`, `tenant_id`.

## 1. Admit the team (assign the admission role)

### The team registry (recommended)

Onboarding is a **reviewed YAML file in its own Terraform state**, applied with
the [`modules/onboarding`](../modules/onboarding/README.md) submodule — wired to
the gateway purely by outputs, so an onboarding apply can never plan the gateway
and needs Entra permissions only. A team onboards, changes tier, adds a service
or offboards by pull request; validation fails the plan with a message naming
the offending entry, and the PR diff is the audit trail.

```yaml
# teams.yaml — add your team, raise the PR
version: v1
teams:
  - team: team-alpha
    owner: alpha-devs
    tier: standard
    services:
      - service: chat
        client_id: <app/client GUID>
        principal_object_id: <SP object GUID>
```

```hcl
module "onboarding" {
  source  = "okaneconnor/ai-gateway/azurerm//modules/onboarding"
  version = "~> 2.0"

  registry_file         = "${path.module}/teams.yaml"
  gateway_app_object_id = data.terraform_remote_state.gateway.outputs.gateway_app_object_id
  gateway_app_role_id   = data.terraform_remote_state.gateway.outputs.gateway_app_role_id
  tier_names            = data.terraform_remote_state.gateway.outputs.tier_names
}
```

See the [submodule README](../modules/onboarding/README.md) for the schema, the
validation rules, and the full lifecycle. `examples/onboarding` is a runnable
two-state layout.

### Raw Terraform (one-off)

The registry is the recommended shape; a single ad-hoc admission is just the
resource the registry manages for you:

```hcl
resource "azuread_app_role_assignment" "team_chat_service" {
  app_role_id         = data.terraform_remote_state.gateway.outputs.gateway_app_role_id
  principal_object_id = "<team service principal OBJECT id>"
  resource_object_id  = data.terraform_remote_state.gateway.outputs.gateway_app_object_id
}
```

For a service principal or managed identity, `principal_object_id` is the
**object id** (not the application/client id):

```bash
az ad sp show --id <app-id-or-object-id> --query id -o tsv   # app registration
az identity show -g <rg> -n <mi-name> --query principalId -o tsv  # managed identity
```

Removing the resource (or `terraform destroy` on the onboarding state) revokes
access. `terraform plan` against the gateway state shows **zero changes** either
way — that separation is the point.

### Portal

1. **Entra ID → Enterprise applications →** the gateway app (search by
   `gateway_app_client_id`).
2. **Users and groups → Add user/group.**
3. Select the team's service principal and **Assign** (the only role is the
   admission role). Note: the portal blade cannot assign roles to **managed
   identities** — use the Terraform or Graph path for those.

### az / Microsoft Graph

Assignments are created on the **resource** service principal's
`appRoleAssignedTo` relationship (the form Microsoft Graph documents for granting
an app role to a client service principal):

```bash
TEAM_SP=$(az ad sp show --id <team-app-id> --query id -o tsv)
GW_SP=$(terraform output -raw gateway_app_object_id)
ROLE=$(terraform output -raw gateway_app_role_id)

az rest --method post \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GW_SP/appRoleAssignedTo" \
  --body "{\"principalId\":\"$TEAM_SP\",\"resourceId\":\"$GW_SP\",\"appRoleId\":\"$ROLE\"}"
```

## 2. Hand off (non-secret)

Give the team these values — **none of them are secrets**:

| Value | From | Used for |
| --- | --- | --- |
| `gateway_app_client_id` | `terraform output -raw gateway_app_client_id` | Token audience/scope (`<gateway_app_client_id>/.default`) |
| `apim_gateway_url` | `terraform output -raw apim_gateway_url` | Base URL for API calls |
| `tenant_id` | `terraform output -raw tenant_id` | Token endpoint tenant |

The team keeps their **own** credentials — the platform never sees or distributes
them. A managed-identity workload holds no secret at all.

## 3. Team calls the gateway

The team requests a token for the gateway's scope and calls with a bearer token.

```bash
# Client-credentials token (the team runs this with THEIR client_id/secret; a
# managed identity uses DefaultAzureCredential/ManagedIdentityCredential instead).
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/<tenant_id>/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=<team-client-id>" \
  -d "client_secret=<team-client-secret>" \
  -d "scope=<gateway_app_client_id>/.default" \
  | jq -r .access_token)

# Call a model.
curl -s -X POST \
  "<apim_gateway_url>/openai/deployments/<model>/chat/completions?api-version=2024-10-21" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":10}'
```

Notes:

- **GPT-5 models reject `max_tokens`** — use `max_completion_tokens` or omit it.
- The `roles` claim proves admission; the `azp` claim keys the rate limits, token
  limits and cache partition — a client never sees another client's cached
  completion.
- **Internal-mode gateways have no public endpoint.** In `Internal` network mode
  the request must originate from inside the VNet. See
  [usage.md → Internal VNet mode](usage.md).

## 4. Verify

```bash
CHAT="<apim_gateway_url>/openai/deployments/<model>/chat/completions?api-version=2024-10-21"
BODY='{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":10}'

# Unauthenticated -> 401
curl -s -o /dev/null -w "no-token  %{http_code}\n" -X POST "$CHAT" \
  -H "Content-Type: application/json" -d "$BODY"

# Admitted -> 200
curl -s -o /dev/null -w "admitted  %{http_code}\n" -X POST "$CHAT" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "$BODY"
```

Expected: no-token `401`, admitted `200`.

## 5. Revoke (de-provision)

Terraform path: remove the `azuread_app_role_assignment` (or destroy the
onboarding state) and apply.

Graph path — find and delete the assignment on the **resource** SP:

```bash
AID=$(az rest --method get \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GW_SP/appRoleAssignedTo" \
  --query "value[?principalId=='$TEAM_SP'].id | [0]" -o tsv)

az rest --method delete \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GW_SP/appRoleAssignedTo/$AID"
```

Already-issued tokens remain valid until they expire (up to ~60–90 minutes);
**newly requested tokens** no longer carry the role and are rejected. Re-run the
**Verify** step with a fresh token: expect `401`/`403`.

## Why keyless

- **No secrets distributed by the platform** — the team uses its own credentials
  (or none, with a managed identity); the platform holds nothing to leak or
  rotate.
- **Access = one app-role assignment** — grant and revoke are one Graph call, one
  portal action, or one tiny Terraform resource; revocation applies from the next
  token.
- **Onboarding never touches the gateway** — the assignment lives outside the
  gateway state, keyed by two stable outputs.
- **Chargeback** — usage is attributed per team via the App ID (`azp`) dimension
  on the token metric, so cost/quota reporting needs no shared keys.
