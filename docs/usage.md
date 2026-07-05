# Usage guide

How to deploy the gateway, get a token, onboard teams, and run the live tests. For
the full input/output reference see the generated tables in the
[README](../README.md). For the architecture and design rationale see
[architecture.md](architecture.md).

## Deploy

Call the module from your own root configuration. The required inputs are `location`,
publisher info, and `model_deployments` — everything else is optional with a sensible
default. The module ships **no default model**: Azure deprecates model versions over
time, so you choose current models for your region.

```hcl
# main.tf
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
provider "azuread" {}
provider "azapi" {}

module "ai_gateway" {
  source  = "okaneconnor/ai-gateway/azurerm"
  version = "~> 1.0"

  location        = "uksouth"
  publisher_name  = "AI Platform Team"
  publisher_email = "platform@example.com"

  # Required — pick current, non-deprecating models. Check availability/SKUs with:
  #   az cognitiveservices account list-models -n <foundry-acct> -g <rg>
  # gpt-5.4-mini is only offered on GlobalStandard, so the SKU allowlist must permit
  # it (GlobalStandard leaves the region; use a Standard-SKU model to stay in-region).
  model_deployments = {
    "gpt-5.4-mini" = {
      model_name    = "gpt-5.4-mini"
      model_version = "2026-03-17"
      sku_name      = "GlobalStandard"
    }
    "text-embedding-3-small" = {
      model_name    = "text-embedding-3-small"
      model_version = "1"
      sku_name      = "Standard"
    }
  }
  # Semantic caching is opt-in (enabled=false by default) — it needs an Azure
  # Managed Redis (RediSearch) instance available in your region. Set enabled=true
  # to turn it on.
  semantic_cache        = { enabled = true, embeddings_deployment = "text-embedding-3-small" }
  deployment_sku_policy = { allowed_sku_names = ["Standard", "GlobalStandard"] }

  # Optional — create one demo client app (with secret) per tier for end-to-end
  # testing. Leave false (default) for real deployments.
  create_demo_clients = true
}
```

```bash
terraform init
terraform apply -var subscription_id=<sub-id>   # APIM VNet provisioning takes ~30-45 min
```

> Providers are configured by the **caller** (above) — the module itself only pins
> `required_providers`. You need Entra permissions to create app registrations (or
> set `existing_gateway_app`).

### Internal VNet mode (private gateway)

With `apim_virtual_network_type = "Internal"` the gateway has **no public endpoint** —
it is reachable only at a private VIP inside the VNet, and **DNS is yours to wire**. The
module creates private DNS zones for the backends (Foundry, Key Vault, …) but not for
the gateway hostname, so `apim_gateway_url` will not resolve for anyone until you either:

- create an A record for the gateway host → the APIM private IP
  (`az apim show … --query privateIpAddresses`) in your own private DNS zone
  (`azure-api.net`) linked to the VNet, or
- front the gateway with Application Gateway / a WAF for ingress.

For a quick test from inside the VNet without DNS, resolve the host manually, e.g.
`curl --resolve <host>:443:<private-ip> https://<host>/openai/...`.

## Bring-your-own (landing-zone adoption)

For platform/landing-zone setups the module can compose with infrastructure you
already own — set any of these and the module skips creating that piece:

| Variable | Bring your own… |
|---|---|
| `existing_resource_group_name` | Resource group (deploy into a pre-created RG) |
| `existing_network` | VNet + APIM/PE subnets (inject into a spoke instead of an isolated VNet) |
| `existing_private_dns_zone_ids` | Private DNS zones (hub-managed DNS) |
| `existing_log_analytics_workspace_id` | Log Analytics workspace (central logging) |
| `existing_application_insights` | Application Insights instance |
| `existing_gateway_app` | Entra gateway app registration (restricted tenants) |

When you bring your own network you own the APIM subnet's NSG — see the
[APIM VNet reference](https://learn.microsoft.com/azure/api-management/virtual-network-reference)
for the required inbound (3443 from `ApiManagement`, 6390 from `AzureLoadBalancer`)
and outbound rules.

Integration **outputs** for peering / wiring the gateway into your estate:
`apim_principal_id`, `vnet_id`, `apim_subnet_id`, `pe_subnet_id`,
`private_dns_zone_ids` (map), `key_vault_id`/`key_vault_uri`,
`application_insights_connection_string` (sensitive),
`log_analytics_workspace_resource_id`, plus the usual `apim_gateway_url`,
`gateway_app_client_id`, `tenant_id`, `demo_clients` (sensitive),
`resource_group_name`, `foundry_account_name`, `log_analytics_workspace_guid`.

## Get a token

Run these from the directory you deployed the module in, with
`create_demo_clients = true` (the demo clients are a per-tier test identity).

```bash
export TENANT_ID=$(terraform output -raw tenant_id)
export GATEWAY_APP_ID=$(terraform output -raw gateway_app_client_id)
export CLIENT_ID=$(terraform output -json demo_clients | jq -r '."ai-sandbox".client_id')
export CLIENT_SECRET=$(terraform output -json demo_clients | jq -r '."ai-sandbox".client_secret')

# Client-credentials token. The scope is the gateway app's bare client-ID GUID +
# /.default — NOT api://<guid>/.default (that needs a registered identifier URI and
# yields AADSTS500011).
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d grant_type=client_credentials -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" -d "scope=$GATEWAY_APP_ID/.default" | jq -r .access_token)
```

Then call the gateway:

```bash
GATEWAY_URL=$(terraform output -raw apim_gateway_url)
curl -s -X POST "$GATEWAY_URL/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"messages":[{"role":"user","content":"hello"}],"max_tokens":10}'
```

## Onboarding a team (app-role assignment)

1. The team creates (or provides) their Entra app registration `client_id`.
2. An admin assigns one of the gateway app's roles to the team's service principal
   (portal: Enterprise applications → gateway app → Users and groups → Add assignment;
   or `az ad app permission add/grant`).
3. The team requests tokens with their own credentials and
   `scope=<gateway_app_client_id>/.default`. The `roles` claim drives their tier; the
   `azp` claim keys their limits and cache partition.

## Tests

**Unit tests** (no Azure credentials — mocked providers), from a checkout of this module:

```bash
terraform init -backend=false && terraform test
```

**Live smoke checks** against a real deployment with `create_demo_clients = true`.
Export `$TOKEN`, `$GATEWAY_URL`, and `$GATEWAY_APP_ID` as shown in
[Get a token](#get-a-token), then:

```bash
CHAT="$GATEWAY_URL/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2024-10-21"
BODY='{"messages":[{"role":"user","content":"hello"}],"max_tokens":10}'

# Auth — valid token 200, no token 401
curl -s -o /dev/null -w "valid  %{http_code}\n" -X POST "$CHAT" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "$BODY"
curl -s -o /dev/null -w "none   %{http_code}\n" -X POST "$CHAT" -H "Content-Type: application/json" -d "$BODY"

# Content safety — a harmful prompt is blocked (403)
curl -s -o /dev/null -w "unsafe %{http_code}\n" -X POST "$CHAT" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"messages":[{"role":"user","content":"<a clearly harmful prompt>"}],"max_tokens":10}'

# Data residency — Azure Policy denies an out-of-band deployment on a SKU outside
# your allowed_sku_names (the module's cross-validation already blocks it in Terraform;
# this proves the runtime backstop for portal/CLI deployments). Use any SKU NOT in your
# allowlist — here GlobalBatch, which the example allowlist ["Standard","GlobalStandard"]
# denies.
az cognitiveservices account deployment create \
  -g "$(terraform output -raw resource_group_name)" -n "$(terraform output -raw foundry_account_name)" \
  --deployment-name probe --model-name gpt-5.4-mini --model-version 2026-03-17 \
  --model-format OpenAI --sku-name GlobalBatch --sku-capacity 1   # expect RequestDisallowedByPolicy
```

Expected: valid `200`, no-token `401`, harmful `403`, SKU deployment denied. Repeating an
identical prompt returns the same completion `id` (semantic-cache hit); a sandbox-tier
client eventually returns `429` once its rate/token window is exhausted. The cache is
partitioned per client (`azp`), so a second client never sees another's completion.

Avoid running `test-tiers.sh` and `test-cache.sh` back-to-back — the tier test
exhausts rate windows and the collateral throttling makes the cache test flaky.
