# Onboarding a team

A platform runbook for granting, handing off, verifying, and revoking a team's
access to the AI gateway. Access is a **single Entra app-role assignment** — no
secrets are distributed by the platform, and access is instantly revocable.

The commands below were verified live. Run them from a checkout that has the
deployment's Terraform state (or replace the `terraform output` calls with the
literal values you handed off).

## Prerequisites

- The team has an Entra **app registration** and can give you its `client_id`
  (the application/client ID of the app they will use to request tokens).
- You are an **admin** with rights to assign app-roles on the gateway app
  (Application Administrator / Cloud Application Administrator, or an owner of the
  gateway app registration).
- The gateway is deployed and you can read its outputs:
  `gateway_app_client_id`, `apim_gateway_url`, `tenant_id`.

## 1. Grant a tier (assign an app-role)

Each tier is an app-role on the gateway app — e.g. `AI.Gateway.Sandbox`,
`AI.Gateway.Standard`, `AI.Gateway.Premium`. Assigning the role to the team's
service principal is what lets their tokens carry the tier in the `roles` claim.

### Portal

1. **Entra ID → Enterprise applications →** the gateway app (search by the
   `gateway_app_client_id`).
2. **Users and groups → Add user/group.**
3. Select the team's service principal, pick the tier role (e.g.
   `AI.Gateway.Sandbox`), and **Assign**.

### az / Microsoft Graph

```bash
# Object IDs of the two service principals, and the role ID to grant.
TEAM_SP=$(az ad sp show --id <team-app-id> --query id -o tsv)
GW_SP=$(az ad sp show --id $(terraform output -raw gateway_app_client_id) --query id -o tsv)
ROLE=$(az ad sp show --id $(terraform output -raw gateway_app_client_id) \
  --query "appRoles[?value=='AI.Gateway.Sandbox'].id | [0]" -o tsv)

az rest --method post \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$TEAM_SP/appRoleAssignments" \
  --body "{\"principalId\":\"$TEAM_SP\",\"resourceId\":\"$GW_SP\",\"appRoleId\":\"$ROLE\"}"
```

Change `AI.Gateway.Sandbox` to the tier you are granting. A team can hold at most
one tier — if you are moving a team, revoke the old assignment (step 4) first.

## 2. Hand off (non-secret)

Give the team these values — **none of them are secrets**:

| Value | From | Used for |
| --- | --- | --- |
| `gateway_app_client_id` | `terraform output -raw gateway_app_client_id` | Token audience/scope (`<gateway_app_client_id>/.default`) |
| `apim_gateway_url` | `terraform output -raw apim_gateway_url` | Base URL for API calls |
| `tenant_id` | `terraform output -raw tenant_id` | Token endpoint tenant |
| Tier granted | the role you assigned in step 1 | Their rate/token limits and cache partition |

The team keeps their **own** app credentials — the platform never sees or
distributes them.

## 3. Team calls the gateway

The team requests a **client-credentials** token with their own app credentials
and the gateway app as the scope, then calls the gateway with a bearer token.

```bash
# Client-credentials token (the team runs this with THEIR client_id/secret).
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
  Older models still accept `max_tokens`.
- The `roles` claim in the token drives the tier; the `azp` claim keys the rate
  limits and cache partition — a client never sees another client's cached
  completion.
- **Internal-mode gateways have no public endpoint.** In `Internal` network mode
  the request must originate from inside the VNet (or a peered network / private
  DNS resolver). See [usage.md → Internal VNet mode](usage.md).

## 4. Verify

```bash
CHAT="<apim_gateway_url>/openai/deployments/<model>/chat/completions?api-version=2024-10-21"
BODY='{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":10}'

# Unauthenticated -> 401
curl -s -o /dev/null -w "no-token  %{http_code}\n" -X POST "$CHAT" \
  -H "Content-Type: application/json" -d "$BODY"

# Onboarded -> 200
curl -s -o /dev/null -w "onboarded %{http_code}\n" -X POST "$CHAT" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "$BODY"
```

Expected: no-token `401`, onboarded `200`.

## 5. Revoke (de-provision)

Deleting the app-role assignment cuts the team off immediately — no secret
rotation, no redeploy.

```bash
# Find the assignment for this team on the gateway app, then delete it.
AID=$(az rest --method get \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$TEAM_SP/appRoleAssignments" \
  --query "value[?resourceId=='$GW_SP'].id | [0]" -o tsv)

az rest --method delete \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$TEAM_SP/appRoleAssignments/$AID"
```

Re-run the **Verify** step: the onboarded call should now return `401`/`403`.

## Why keyless

- **No secrets distributed by the platform** — the team uses its own app
  credentials; the platform holds nothing to leak or rotate.
- **Access = one app-role assignment** — grant and revoke are a single Graph call
  (or one portal action), and revocation is instant.
- **Chargeback** — usage is attributed per team via the App ID (`azp`) dimension
  on the token metric, so cost/quota reporting needs no shared keys.
