# AI Gateway v2 — Private, Multi-Service, Entra-Keyless

Private Azure API Management gateway fronting multiple Azure AI services. Clients authenticate with an Entra ID token (client-credentials, app-role gated). No subscription keys. All AI backends are private-endpoint only.

---

## Architecture

```
Client app (Entra client-credentials)
        │
        │  HTTPS + Bearer token (JWT)
        ▼
┌─────────────────────────────────────────────┐
│  APIM Developer (External VNet, uksouth)    │
│                                             │
│  Inbound policy chain (per-API):            │
│    ai-ip-allow  →  ai-auth-entra-jwt        │
│    set-backend  →  ai-backend-managed-id    │
│    ai-content-safety  →  ai-token-metrics   │
│                                             │
│  Products (keyless):                        │
│    ai-sandbox (20k TPM / 30 req/min)        │
│    ai-production-standard (150k TPM / 120)  │
│                                             │
│  APIs:                                      │
│    /openai       → AI Foundry (gpt-4.1-mini)│
│    /contentsafety→ Content Safety           │
│    /speech       → Speech                  │
│    /language     → Language                 │
│    /docintel     → Document Intelligence    │
│    /mytools      → Governed MCP (optional)  │
└───────────────────┬─────────────────────────┘
                    │  Private endpoints (VNet)
          ┌─────────┼──────────┐
          ▼         ▼          ▼ ...
   AI Foundry   Content    Speech / Language /
   (AIServices) Safety     Document Intelligence
   gpt-4.1-mini            (all private, public off)
```

APIM authenticates to all backends with its **system-assigned managed identity** (no keys stored anywhere). Backends have `public_network_access_enabled = false` and are only reachable via private endpoints inside the VNet.

---

## UK Data-Residency Findings

These findings must be understood before deploying for HMCTS or any UK-resident workload.

**In-region model processing**

`gpt-4.1-mini` is deployed as `Standard` (not `GlobalStandard` or `DataZoneStandard`). This ensures inference runs in-region (uksouth). Do **not** change the `sku_name` to `GlobalStandard` (routes worldwide) or `DataZoneStandard` (routes within the EU data zone, which excludes the UK).

**Content Safety uksouth availability**

Content Safety is available in uksouth as of 2026-05-30. Verify regional availability before deployment using the Azure Products by Region page, as this can change.

**No UK HA twin**

ukwest does not offer equivalent AI service coverage and is not a viable HA twin for this workload. There is no in-UK multi-region failover available. This is a known gap; document it for Security/Architecture sign-off before production use.

**Azure Policy enforcement (optional)**

A deny policy for `GlobalStandard`/`DataZoneStandard` deployment types is documented in `governance.tf` as a comment. Enable it to prevent accidental non-UK routing.

---

## Prerequisites

- Terraform >= 1.9.0
- Azure CLI authenticated (`az login`) with access to the work subscription (`230414f6-3458-4f1a-9f5c-488281e13c14`)
- Entra ID permissions: ability to create app registrations and grant app-role assignments in the tenant
- The following provider versions are pinned automatically: azurerm ~> 4.74, azuread ~> 3.0, azapi ~> 2.0, random ~> 3.6

---

## Deploy

```bash
terraform init
terraform plan   # review; expect ~60 resources to create
terraform apply  # takes 20-45 min (APIM VNet injection is slow)
```

After apply, capture the outputs:

```bash
terraform output apim_gateway_url
terraform output tenant_id
terraform output gateway_app_client_id
terraform output client_app_id
terraform output -raw client_app_secret   # sensitive
terraform output chat_deployment_name
```

---

## Get a Token

Export the output values as environment variables, then run:

```bash
export TENANT_ID=$(terraform output -raw tenant_id)
export CLIENT_ID=$(terraform output -raw client_app_id)
export CLIENT_SECRET=$(terraform output -raw client_app_secret)
export GATEWAY_APP_ID=$(terraform output -raw gateway_app_client_id)

TOKEN=$(./test/get-token.sh)
```

The script calls the Entra v2 token endpoint with `scope=api://<gateway_app_id>/.default` and prints the raw access token.

---

## Run Smoke Tests

```bash
export GATEWAY_URL=$(terraform output -raw apim_gateway_url)
export TOKEN=<token from above>
export DEPLOYMENT=$(terraform output -raw chat_deployment_name)
export FOUNDRY_ENDPOINT=<foundry endpoint from az or portal>

./test/smoke.sh
```

Expected output:
```
1) Foundry chat via gateway (expect 200):
  HTTP 200
2) No token (expect 401):
  HTTP 401
3) Direct backend call, bypassing APIM (expect failure - public access disabled):
  HTTP 000 (000/403 = blocked, good)
```

Test 3 confirms that no client can reach the AI backend directly — only APIM can, via the private endpoint.

---

## Entra App-Role Onboarding (How a Team Gets Access)

The gateway Entra application exposes two app roles:

| Role value | Product tier |
|---|---|
| `AI.Gateway.Sandbox` | 20k TPM, 30 req/min |
| `AI.Gateway.Production` | 150k TPM, 120 req/min |

To onboard a team's application:

1. The team creates (or provides) their Entra app registration `client_id`.
2. An admin with the `AppRoleAssignment.ReadWrite.All` permission runs:

```bash
# Grant the Sandbox role to the team's service principal
az ad app permission add \
  --id <team-client-id> \
  --api <gateway-app-client-id> \
  --api-permissions <sandbox-role-uuid>=Role

az ad app permission grant --id <team-client-id> --api <gateway-app-client-id>
```

Or via the Azure portal: Enterprise applications → gateway app → Users and groups → Add assignment → select the team's service principal → assign the role.

3. The team uses their own `CLIENT_ID` and `CLIENT_SECRET` in `get-token.sh` with `GATEWAY_APP_ID` set to the gateway app's client ID. The resulting token will contain the assigned role in the `roles` claim, which APIM validates.

The demo client app created by Terraform is pre-assigned the `AI.Gateway.Sandbox` role and is suitable for testing only. Rotate or delete it before production.

---

## MCP Usage

The governed MCP endpoint is enabled when `var.enable_mcp = true` (default). It proxies the configured `existing_mcp_server_url` (default: Microsoft Learn MCP) through APIM with the same Entra JWT + IP-allow policy chain and a rate limit of 60 calls/min keyed by client app ID (`azp` claim).

To call the MCP endpoint:

```
https://<apim-gateway-url>/mytools
Authorization: Bearer <token>
```

To disable MCP governance: set `enable_mcp = false` in `terraform.tfvars` and re-apply.

To point at a different MCP server: set `existing_mcp_server_url` in `terraform.tfvars`.

---

## A2A Agent API (Manual Step)

There is no stable ARM resource type for A2A agent API registration as of 2026-05-30. It is portal-only.

To register an A2A agent API:

1. Navigate to your APIM instance in the Azure portal.
2. APIs → + Add API → A2A Agent.
3. Follow the wizard to import the agent manifest.
4. The API auto-syncs to the API Center instance created by `apicenter.tf`.

Terraform management of A2A APIs will be added when Microsoft publishes a stable ARM `apiType` for A2A. Track: [Azure API Management roadmap](https://aka.ms/apimroadmap).

---

## Production-Hardening Appendix

### Swap to Premium tier + Internal VNet + App Gateway/WAF

The Developer tier has no SLA and no zone redundancy. For production:

1. Change `sku_name = "Premium_1"` (or `Premium_2` for zone redundancy).
2. Change `virtual_network_type = "Internal"` to remove APIM's public IP entirely.
3. Front APIM with Azure Application Gateway + WAF v2 to provide the public ingress point with DDoS protection, TLS offload, and OWASP ruleset.

```hcl
# apim.tf
sku_name             = "Premium_2"   # 2 units for zone redundancy
virtual_network_type = "Internal"

zones = ["1", "2"]   # zone-redundant Premium
```

### UK High Availability Strategy

As noted in the data-residency findings, ukwest does not offer equivalent AI service coverage. Options:

- **Active-passive within uksouth**: deploy APIM Premium with 2 units across availability zones 1 and 2. This provides infrastructure HA without multi-region.
- **Accept the gap**: document the single-region risk in the risk register and set an RTO/RPO that matches uksouth's SLA.
- **Monitor Microsoft's roadmap**: ukwest AI service coverage may expand; re-evaluate quarterly.

### Azure Policy: Deny Global Deployment Types

See `governance.tf` for the documented policy control. When ready to enforce:

1. Find or create a policy definition that denies `Microsoft.CognitiveServices/accounts/deployments` where `sku.name` in `["GlobalStandard","DataZoneStandard"]`.
2. Assign it to the resource group or subscription scope.
3. This prevents any team member from accidentally creating a non-UK-resident model deployment.

### Rotate Client Secrets via Key Vault

The demo `client_app_secret` is output by Terraform (sensitive). For production:

1. Store the secret in Key Vault as a versioned secret.
2. Use `azurerm_key_vault_secret` to write it post-creation.
3. Configure APIM named values to reference the Key Vault secret (Key Vault references, not inline).
4. Rotate on the `azuread_application_password` resource by setting `end_date` and creating a replacement before expiry.

### CI/CD

```yaml
# Recommended pipeline steps:
# 1. terraform fmt -check -recursive
# 2. terraform validate
# 3. terraform plan -out=tfplan (review gate)
# 4. terraform apply tfplan  (manual approval for production)
```

Use a service principal or managed identity for the pipeline. Store `ARM_SUBSCRIPTION_ID` and OIDC credentials in pipeline secrets, not in `terraform.tfvars`.

### Remote State

For team use, replace local state with a remote backend:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstate<unique>"
    container_name       = "tfstate"
    key                  = "ai-gateway/terraform.tfstate"
  }
}
```

Use a separate storage account with soft-delete and versioning enabled. Lock the state container so concurrent applies are prevented.
