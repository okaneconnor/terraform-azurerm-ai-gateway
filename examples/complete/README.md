# Complete example — full AI gateway

Deploys the **entire** gateway from the required inputs plus a few overrides:
VNet-injected APIM with keyless Entra auth, an AI Foundry account + your model
deployments, two consumption tiers (rate/token limited), four Cognitive Services as
authenticated passthrough APIs, inbound content safety, a private RBAC Key Vault, a
data-residency policy, and full observability. Everything not set in `main.tf` uses a
module default.

## Prerequisites

- Terraform >= 1.9, and the Azure CLI logged in (`az login`).
- Permission to create Entra app registrations (or set `existing_gateway_app` to bring
  your own).
- Quota for the models in `main.tf` in your region — adjust `model_deployments` to
  models/versions you actually hold.

## Deploy

```bash
terraform init
terraform apply -var subscription_id=<your-sub-id>   # APIM VNet provisioning ~30-45 min
```

## Smoke-test it

`create_demo_clients = true` gives you a ready client per tier. Get a token and call:

```bash
export TENANT=$(terraform output -raw tenant_id)
export GWAPP=$(terraform output -raw gateway_app_client_id)
export GWURL=$(terraform output -raw gateway_url)
CID=$(terraform output -json demo_clients | jq -r '."ai-production-standard".client_id')
CSEC=$(terraform output -json demo_clients | jq -r '."ai-production-standard".client_secret')

TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  -d grant_type=client_credentials -d "client_id=$CID" -d "client_secret=$CSEC" \
  -d "scope=$GWAPP/.default" | jq -r .access_token)

# No token -> 401; valid token -> 200
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  "$GWURL/openai/deployments/gpt-5.4-mini/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":16}'
```

See the module's [usage guide](../../docs/usage.md) for onboarding your own teams,
tier differentiation, content-safety, and residency tests.

## Production notes

- **Private ingress:** set `apim_virtual_network_type = "Internal"` and front the
  gateway with Application Gateway / WAF.
- **SLA + zones:** set `apim_sku_name = "Premium_2"` and `apim_zones = ["1","2"]` for a
  zone-redundant Premium gateway (the module auto-creates the required public IP).
- **Semantic cache** is opt-in (`semantic_cache = { enabled = true, ... }`). It needs
  Azure Managed Redis; if the default `Balanced_B0` fails to provision in your
  subscription, override `redis_sku_name` (e.g. `"MemoryOptimized_M10"`).
- Set `create_demo_clients = false` — real consumers bring their own Entra clients and
  are granted a tier app-role.

## Teardown

```bash
terraform destroy -var subscription_id=<your-sub-id>
```
