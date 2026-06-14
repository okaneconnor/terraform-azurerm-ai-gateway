# Usage guide

How to deploy the gateway, get a token, onboard teams, and run the live tests. For
the full input/output reference see the generated tables in the
[README](../README.md). For the architecture and design rationale see
[architecture.md](architecture.md).

## Deploy

Call the module from your own root configuration. The minimum is `location` plus
publisher info — everything else is an optional variable with a sensible default.

```hcl
# main.tf
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
provider "azuread" {}
provider "azapi" {}

module "ai_gateway" {
  source = "github.com/okaneconnor/ai-gateway"

  location        = "uksouth"
  publisher_name  = "AI Platform Team"
  publisher_email = "platform@example.com"

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
`create_demo_clients = true`. Replace `<repo>` with the path to a checkout of this
module (the helper scripts live under its `test/`).

```bash
export TENANT_ID=$(terraform output -raw tenant_id)
export GATEWAY_APP_ID=$(terraform output -raw gateway_app_client_id)
export CLIENT_ID=$(terraform output -json demo_clients | jq -r '."ai-sandbox".client_id')
export CLIENT_SECRET=$(terraform output -json demo_clients | jq -r '."ai-sandbox".client_secret')

TOKEN=$(<repo>/test/get-token.sh)
```

The script requests `scope=<gateway_app_client_id>/.default` from the Entra v2 token
endpoint — the **bare client-ID GUID** form, *not* `api://<guid>/.default` (that form
would require `api://<guid>` to be a registered identifier URI, which it is not; using
it yields `AADSTS500011`).

Then call the gateway:

```bash
GATEWAY_URL=$(terraform output -raw apim_gateway_url)
curl -s -X POST "$GATEWAY_URL/openai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-10-21" \
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

**Module unit tests** (no Azure credentials — mocked providers), from a checkout of
this module:

```bash
terraform init -backend=false && terraform test
```

**Live tests** against a deployment with demo clients
(`create_demo_clients = true`). Export the outputs from your deployment directory,
then run the scripts from a checkout of this module:

```bash
# from your module deployment directory:
export TENANT_ID=$(terraform output -raw tenant_id)
export GATEWAY_APP_ID=$(terraform output -raw gateway_app_client_id)
export GATEWAY_URL=$(terraform output -raw apim_gateway_url)
export DEPLOYMENT=gpt-4.1-mini
export CLIENT_ID=$(terraform output -json demo_clients | jq -r '."ai-sandbox".client_id')
export CLIENT_SECRET=$(terraform output -json demo_clients | jq -r '."ai-sandbox".client_secret')
export SANDBOX_CLIENT_ID=$CLIENT_ID SANDBOX_CLIENT_SECRET=$CLIENT_SECRET
export PROD_CLIENT_ID=$(terraform output -json demo_clients | jq -r '."ai-production-standard".client_id')
export PROD_CLIENT_SECRET=$(terraform output -json demo_clients | jq -r '."ai-production-standard".client_secret')
export TOKEN=$(<repo>/test/get-token.sh)
export RG=$(terraform output -raw resource_group_name)
export FOUNDRY=$(terraform output -raw foundry_account_name)
```

| Script | What it covers |
|---|---|
| `test/test-suite.sh` | Auth, content safety, cache hit, passthrough, abuse, rate limit |
| `test/test-tiers.sh` | Tier separation (sandbox throttles, production doesn't) |
| `test/test-cache.sh` | Semantic cache correctness + per-client isolation |
| `test/test-residency.sh` | Deployment-SKU policy denies GlobalStandard |
| `scripts/scan.sh` | Static security scan (tfsec / checkov; fails closed if neither installed) |

Avoid running `test-tiers.sh` and `test-cache.sh` back-to-back — the tier test
exhausts rate windows and the collateral throttling makes the cache test flaky.
