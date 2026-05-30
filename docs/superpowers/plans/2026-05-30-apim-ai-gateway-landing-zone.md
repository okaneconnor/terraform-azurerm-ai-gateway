# APIM AI Gateway Sandbox — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an Azure API Management AI Gateway in a single-subscription sandbox as flat (no-modules) Terraform, with model governance, observability, MCP governance, and agents + self-service sequenced as toggle-gated phases.

**Architecture:** One subscription / one resource group / one region. APIM Developer tier (system-assigned managed identity) fronts an Azure OpenAI account (gpt-4o + text-embedding-3-small). LLM governance is applied as APIM policy XML; backends authenticate via managed identity. Telemetry flows to Log Analytics + Application Insights. Each capability is gated behind an `enable_*` variable so it is applied one phase at a time. Features absent from `azurerm` (backend pools, MCP servers, A2A agents, API Center) use the `azapi` provider.

**Tech Stack:** Terraform, `hashicorp/azurerm` 4.74.x, `azure/azapi` 2.x, `hashicorp/random`, Azure API Management (Developer), Azure OpenAI, Azure AI Content Safety, Azure Managed Redis / Redis Enterprise (RediSearch), Log Analytics, Application Insights, Azure API Center.

**Verification model (Terraform, not unit-test TDD):** the per-step gate is `terraform fmt` + `terraform validate`. `terraform plan`/`apply` require `az login` + a subscription and are the user's responsibility (documented, not run by the implementer). Each task ends with a commit.

**Repo note:** this repository is empty (no commits yet). Task 0 creates the scaffold. All paths below are relative to the repo root `/Users/connorokane/Documents/repos/personal/ai-gateway`.

---

## File structure (locked)

```
.
├── providers.tf            # terraform block, required_providers, provider config
├── variables.tf            # location, naming, publisher info, enable_* toggles, model + limit vars, teams
├── locals.tf               # computed names (with random suffix), team→product map
├── terraform.tfvars.example
├── foundation.tf           # resource group, Log Analytics, Application Insights, random suffix
├── apim.tf                 # APIM Developer + system-assigned identity + App Insights logger + diagnostic
├── openai.tf               # azurerm_cognitive_account (OpenAI) + gpt-4o + embeddings deployments
├── identity-rbac.tf        # role assignments: APIM MI → Cognitive Services User (AOAI + Content Safety)
├── api-llm.tf              # OpenAI HTTP API import + backend + circuit breaker + API policy
├── products.tf             # one product + subscription per team
├── cache.tf                # (Phase 3) RediSearch-capable Redis + APIM external cache wiring
├── content-safety.tf       # (Phase 4) Content Safety account + backend
├── mcp.tf                  # (Phase 5) azapi: REST→MCP server + govern existing MCP server
├── agents-apicenter.tf     # (Phase 6) azapi: A2A agent API + API Center service + APIM link
├── policies/
│   ├── llm-foundation.xml      # managed-identity auth to backend (Phase 1)
│   ├── llm-governance.xml       # token-limit + emit-token-metric + retry (Phase 2)
│   ├── llm-semantic-cache.xml   # cache lookup/store (Phase 3, composes with governance)
│   ├── llm-content-safety.xml   # content safety (Phase 4)
│   └── mcp-governance.xml        # rate-limit-by-key + ip-filter (Phase 5)
├── test/
│   ├── 01-chat.sh
│   ├── 02-token-limit.sh
│   ├── 03-cache.sh
│   ├── 04-content-safety.sh
│   └── 05-mcp.sh
├── .gitignore
└── README.md
```

**Policy composition note:** APIM allows exactly **one** policy document per API scope. So the API-level policy XML is *cumulative* — each phase rewrites `api-llm.tf`'s `xml_content` to include the previous phases' blocks plus the new one, assembled with `templatefile()`. The `policies/*.xml` files are the per-capability fragments; `api-llm.tf` composes them. This is called out in each task.

---

## Task 0: Repo scaffold, providers, variables

**Files:**
- Create: `providers.tf`, `variables.tf`, `locals.tf`, `terraform.tfvars.example`, `.gitignore`, `README.md`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# Terraform
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
crash.log
*.tfvars
!*.tfvars.example
override.tf
override.tf.json
*_override.tf
.terraformrc
terraform.rc
```

- [ ] **Step 2: Create `providers.tf`**

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.74"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id is read from ARM_SUBSCRIPTION_ID or `az account set`.
}

provider "azapi" {}
```

- [ ] **Step 3: Create `variables.tf`**

```hcl
variable "location" {
  description = "Azure region for all resources. Note: verify model + Content Safety availability for your region."
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = "Short prefix for resource names (lowercase, no spaces)."
  type        = string
  default     = "aigw"
}

variable "publisher_name" {
  description = "APIM publisher organisation name."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "APIM publisher contact email."
  type        = string
  default     = "ai-platform@example.com"
}

variable "teams" {
  description = "Consumer teams that each get an APIM product + subscription. Map of team key to TPM limit."
  type = map(object({
    display_name      = string
    tokens_per_minute = number
    monthly_quota     = number
  }))
  default = {
    "team-alpha" = { display_name = "Team Alpha", tokens_per_minute = 1000, monthly_quota = 1000000 }
    "team-beta"  = { display_name = "Team Beta", tokens_per_minute = 500, monthly_quota = 500000 }
  }
}

variable "chat_model" {
  description = "Chat model deployment."
  type = object({
    name     = string
    version  = string
    sku_name = string
    capacity = number
  })
  default = {
    name     = "gpt-4o"
    version  = "2024-08-06"
    sku_name = "GlobalStandard"
    capacity = 30
  }
}

variable "embedding_model" {
  description = "Embedding model deployment (used by semantic caching)."
  type = object({
    name     = string
    version  = string
    sku_name = string
    capacity = number
  })
  default = {
    name     = "text-embedding-3-small"
    version  = "1"
    sku_name = "Standard"
    capacity = 10
  }
}

# --- Phase toggles (apply capabilities one at a time) ---

variable "enable_token_governance" {
  description = "Phase 2: token-limit + emit-token-metric + retry + circuit breaker."
  type        = bool
  default     = false
}

variable "enable_semantic_cache" {
  description = "Phase 3: Azure Managed Redis external cache + semantic cache policies."
  type        = bool
  default     = false
}

variable "enable_content_safety" {
  description = "Phase 4: Azure AI Content Safety account + llm-content-safety policy."
  type        = bool
  default     = false
}

variable "enable_mcp" {
  description = "Phase 5: MCP server (REST->MCP) + governed external MCP server (azapi)."
  type        = bool
  default     = false
}

variable "enable_agents_selfservice" {
  description = "Phase 6: A2A agent API + API Center catalog (azapi)."
  type        = bool
  default     = false
}

variable "existing_mcp_server_url" {
  description = "Phase 5: base URL of an existing remote MCP server to govern (e.g. https://learn.microsoft.com/api/mcp)."
  type        = string
  default     = "https://learn.microsoft.com/api/mcp"
}
```

- [ ] **Step 4: Create `locals.tf`**

```hcl
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

locals {
  suffix   = random_string.suffix.result
  rg_name  = "${var.name_prefix}-sandbox-rg"
  apim_name = "${var.name_prefix}-apim-${local.suffix}"
  aoai_name = "${var.name_prefix}-aoai-${local.suffix}"
  cs_name   = "${var.name_prefix}-cs-${local.suffix}"
  law_name  = "${var.name_prefix}-law-${local.suffix}"
  ai_name   = "${var.name_prefix}-appi-${local.suffix}"
  redis_name = "${var.name_prefix}-redis-${local.suffix}"
  apic_name  = "${var.name_prefix}-apic-${local.suffix}"

  # Managed identity audience for Azure AI / OpenAI backends.
  cognitive_resource_audience = "https://cognitiveservices.azure.com"
}
```

- [ ] **Step 5: Create `terraform.tfvars.example`**

```hcl
location        = "uksouth"
name_prefix     = "aigw"
publisher_name  = "AI Platform Team"
publisher_email = "you@example.com"

# Phase toggles — flip to true one at a time, apply, validate, then move on.
enable_token_governance   = false
enable_semantic_cache     = false
enable_content_safety     = false
enable_mcp                = false
enable_agents_selfservice = false
```

- [ ] **Step 6: Create `README.md` skeleton** (final content filled in Task 7; create a minimal placeholder-free version now)

```markdown
# APIM AI Gateway — Sandbox

Flat Terraform for an Azure API Management AI Gateway sandbox (Developer tier).
Capabilities are applied one phase at a time via `enable_*` variables.

## Prerequisites
- Terraform >= 1.9
- `az login` and a subscription selected (`az account set --subscription <id>`)
- Provider registrations: `Microsoft.ApiManagement`, `Microsoft.CognitiveServices`,
  `Microsoft.Cache` / `Microsoft.Cache/redisEnterprise`, `Microsoft.ApiCenter`

## Phased apply
1. `cp terraform.tfvars.example terraform.tfvars` and edit `publisher_email`.
2. `terraform init`
3. `terraform apply` (Phase 1 foundation — all toggles false).
4. Validate (see `test/01-chat.sh`), then set `enable_token_governance = true` and re-apply.
5. Repeat for `enable_semantic_cache`, `enable_content_safety`, `enable_mcp`,
   `enable_agents_selfservice`.

See per-phase validation and the production-hardening appendix at the bottom of this file.
```

- [ ] **Step 7: Validate scaffold**

Run: `terraform init -backend=false && terraform fmt -check && terraform validate`
Expected: `terraform fmt -check` passes (no diff); `terraform validate` reports `Success! The configuration is valid.` (init with `-backend=false` avoids needing cloud creds; validate works with no `apply`).

> If `terraform validate` complains about no resources, that's fine at this stage only if it still returns success — variables/providers alone are valid. If it errors, fix formatting/syntax before committing.

- [ ] **Step 8: Commit**

```bash
git add providers.tf variables.tf locals.tf terraform.tfvars.example .gitignore README.md
git commit -m "chore: scaffold terraform providers, variables, and toggles"
```

---

## Task 1: Phase 1 — Foundation (model API + observability baseline)

**Files:**
- Create: `foundation.tf`, `apim.tf`, `openai.tf`, `identity-rbac.tf`, `api-llm.tf`, `products.tf`, `policies/llm-foundation.xml`, `test/01-chat.sh`

- [ ] **Step 1: Create `foundation.tf`**

```hcl
resource "azurerm_resource_group" "rg" {
  name     = local.rg_name
  location = var.location
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = local.law_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "ai" {
  name                = local.ai_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}
```

- [ ] **Step 2: Create `openai.tf`**

```hcl
resource "azurerm_cognitive_account" "aoai" {
  name                  = local.aoai_name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = local.aoai_name

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model.name
  cognitive_account_id = azurerm_cognitive_account.aoai.id

  model {
    format  = "OpenAI"
    name    = var.chat_model.name
    version = var.chat_model.version
  }

  sku {
    name     = var.chat_model.sku_name
    capacity = var.chat_model.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

resource "azurerm_cognitive_deployment" "embeddings" {
  name                 = var.embedding_model.name
  cognitive_account_id = azurerm_cognitive_account.aoai.id

  model {
    format  = "OpenAI"
    name    = var.embedding_model.name
    version = var.embedding_model.version
  }

  sku {
    name     = var.embedding_model.sku_name
    capacity = var.embedding_model.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}
```

- [ ] **Step 3: Create `apim.tf`**

```hcl
resource "azurerm_api_management" "apim" {
  name                = local.apim_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_api_management_logger" "appinsights" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  resource_id         = azurerm_application_insights.ai.id

  application_insights {
    connection_string = azurerm_application_insights.ai.connection_string
  }
}

resource "azurerm_api_management_diagnostic" "apim" {
  identifier               = "applicationinsights"
  api_management_name      = azurerm_api_management.apim.name
  resource_group_name      = azurerm_resource_group.rg.name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id
  sampling_percentage      = 100.0
  verbosity                = "information"
  always_log_errors        = true
  log_client_ip            = true
  http_correlation_protocol = "W3C"
}
```

- [ ] **Step 4: Create `identity-rbac.tf`**

```hcl
resource "azurerm_role_assignment" "apim_aoai" {
  scope                = azurerm_cognitive_account.aoai.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
```

- [ ] **Step 5: Create `policies/llm-foundation.xml`** (managed-identity auth to the AOAI backend; `{backend_id}` is injected by `templatefile`)

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${backend_id}" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

- [ ] **Step 6: Create `api-llm.tf`** (HTTP API importing the Azure OpenAI OpenAPI spec, backend pointing at AOAI, and the composed API policy)

```hcl
resource "azurerm_api_management_api" "openai" {
  name                  = "openai"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = "Azure OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = true

  import {
    content_format = "openapi+json-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  }
}

resource "azurerm_api_management_backend" "aoai" {
  name                = "aoai-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.aoai.endpoint}openai"
  resource_id         = azurerm_cognitive_account.aoai.id

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# Composed API policy. Phase 1 uses only the foundation fragment.
# Later phases extend local.openai_api_policy_xml (see locals additions in those tasks).
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile("${path.module}/policies/llm-foundation.xml", {
    backend_id = azurerm_api_management_backend.aoai.name
  })
}
```

> **Note for implementer:** confirm `azurerm_cognitive_account.aoai.endpoint` ends with a trailing slash (it does: `https://<name>.openai.azure.com/`). The backend URL therefore becomes `https://<name>.openai.azure.com/openai`. If a double slash appears, use `trimsuffix(azurerm_cognitive_account.aoai.endpoint, "/")` + `/openai`.

- [ ] **Step 7: Create `products.tf`** (one product + one subscription per team)

```hcl
resource "azurerm_api_management_product" "team" {
  for_each = var.teams

  product_id            = each.key
  display_name          = each.value.display_name
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  published             = true
  subscription_required = true
  approval_required     = false
  subscriptions_limit   = 10
}

resource "azurerm_api_management_product_api" "team_openai" {
  for_each = var.teams

  product_id          = azurerm_api_management_product.team[each.key].product_id
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_api_management_subscription" "team" {
  for_each = var.teams

  display_name        = "${each.value.display_name} subscription"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  product_id          = azurerm_api_management_product.team[each.key].id
  state               = "active"
  allow_tracing       = true
}
```

- [ ] **Step 8: Add outputs** (append to `locals.tf` is wrong — create `outputs.tf`)

Create `outputs.tf`:

```hcl
output "apim_gateway_url" {
  description = "APIM gateway base URL."
  value       = azurerm_api_management.apim.gateway_url
}

output "team_subscription_keys" {
  description = "Per-team APIM subscription primary keys."
  value       = { for k, s in azurerm_api_management_subscription.team : k => s.primary_key }
  sensitive   = true
}

output "chat_deployment_name" {
  value = azurerm_cognitive_deployment.chat.name
}
```

- [ ] **Step 9: Create `test/01-chat.sh`**

```bash
#!/usr/bin/env bash
# Usage: GATEWAY_URL=... SUB_KEY=... DEPLOYMENT=gpt-4o ./test/01-chat.sh
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}" "${DEPLOYMENT:?}"
curl -sS -X POST \
  "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
  -d '{"messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":20}'
echo
```

- [ ] **Step 10: Validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 11: Commit**

```bash
git add foundation.tf openai.tf apim.tf identity-rbac.tf api-llm.tf products.tf outputs.tf policies/llm-foundation.xml test/01-chat.sh
git commit -m "feat(phase1): foundation - APIM, AOAI, observability, model API, per-team products"
```

**Validation gate (user, after `terraform apply`):** `chmod +x test/01-chat.sh`, export `GATEWAY_URL` (from `terraform output apim_gateway_url`), `SUB_KEY` (`terraform output -json team_subscription_keys`), `DEPLOYMENT=gpt-4o`, run it → expect a chat completion JSON. Confirm the request appears in Application Insights.

---

## Task 2: Phase 2 — Token governance, metrics, resiliency

**Files:**
- Create: `policies/llm-governance.xml`, `test/02-token-limit.sh`
- Modify: `api-llm.tf` (add circuit breaker to backend; switch composed policy to governance fragment, gated)
- Modify: `locals.tf` (add policy composition local)

- [ ] **Step 1: Create `policies/llm-governance.xml`** (foundation auth + token limit + token metric + retry; `${backend_id}`, `${tpm}`, `${quota}` injected)

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${backend_id}" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
    <llm-token-limit counter-key="@(context.Subscription.Id)" tokens-per-minute="${tpm}" token-quota="${quota}" token-quota-period="Monthly" estimate-prompt-tokens="false" remaining-tokens-variable-name="remainingTokens" remaining-quota-tokens-variable-name="remainingQuotaTokens" />
    <llm-emit-token-metric namespace="llm-metrics">
      <dimension name="Subscription ID" />
      <dimension name="API ID" />
      <dimension name="Client IP" value="@(context.Request.IpAddress)" />
    </llm-emit-token-metric>
  </inbound>
  <backend>
    <retry condition="@(context.Response.StatusCode == 429 || context.Response.StatusCode >= 500)" count="3" interval="2" max-interval="20" delta="2" first-fast-retry="false">
      <forward-request buffer-request-body="true" />
    </retry>
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

> **Note:** `tokens-per-minute` and `token-quota` are per-subscription. The product-level limits in `var.teams` are passed in. Because one API policy serves all products, the token limit here keys on `context.Subscription.Id` with a single TPM value; for per-team TPM use a **product policy** instead (see Step 4 alternative). For the sandbox, a single representative TPM/quota on the API policy is acceptable; per-team differentiation is done at the product scope.

- [ ] **Step 2: Add policy composition to `locals.tf`** (append)

```hcl
locals {
  # Default per-API governance limits for the sandbox (per-team overrides live on product policies).
  default_tpm   = 2000
  default_quota = 2000000

  openai_api_policy_file = var.enable_token_governance ? "${path.module}/policies/llm-governance.xml" : "${path.module}/policies/llm-foundation.xml"
}
```

- [ ] **Step 3: Update `api-llm.tf` backend with a circuit breaker** (replace the `azurerm_api_management_backend "aoai"` block)

```hcl
resource "azurerm_api_management_backend" "aoai" {
  name                = "aoai-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.aoai.endpoint}openai"
  resource_id         = azurerm_cognitive_account.aoai.id

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  dynamic "circuit_breaker_rule" {
    for_each = var.enable_token_governance ? [1] : []
    content {
      name = "aoai-breaker"
      failure_condition {
        count    = 3
        interval = "PT1M"
        status_code_range {
          min = 429
          max = 429
        }
        status_code_range {
          min = 500
          max = 599
        }
      }
      trip_duration     = "PT1M"
      accept_retry_after = true
    }
  }
}
```

> **Note for implementer:** the `circuit_breaker_rule` block argument names (`failure_condition`, `status_code_range`, `trip_duration`, `accept_retry_after`) must be confirmed against the live `azurerm` 4.74 registry docs for `azurerm_api_management_backend` before commit — the schema was added recently. Adjust attribute names to match the registry exactly; keep the intent (trip on 3× 429/5xx within 1 minute, honour `Retry-After`).

- [ ] **Step 4: Update the composed API policy in `api-llm.tf`** (replace the `azurerm_api_management_api_policy "openai"` block)

```hcl
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile(local.openai_api_policy_file, {
    backend_id = azurerm_api_management_backend.aoai.name
    tpm        = local.default_tpm
    quota      = local.default_quota
  })
}
```

> **Templating note:** `templatefile` requires every `${...}` in the file to have a variable. `llm-foundation.xml` only references `${backend_id}`; passing extra vars (`tpm`, `quota`) is harmless **only if** the file does not error on unknown — but `templatefile` ignores unused vars, so passing all three is fine for both files.

- [ ] **Step 5: Create `test/02-token-limit.sh`**

```bash
#!/usr/bin/env bash
# Fires rapid requests to trip the per-minute token limit; expect a 429 once exceeded.
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}" "${DEPLOYMENT:?}"
for i in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
    -H "Content-Type: application/json" \
    -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
    -d '{"messages":[{"role":"user","content":"Write a 200 word story."}],"max_tokens":400}')
  echo "request $i -> HTTP $code"
  [ "$code" = "429" ] && { echo "Token limit hit (429) as expected."; exit 0; }
done
echo "Did not hit 429 — lower tokens-per-minute or raise max_tokens."
```

- [ ] **Step 6: Validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add policies/llm-governance.xml locals.tf api-llm.tf test/02-token-limit.sh
git commit -m "feat(phase2): token limit, token metrics, retry, circuit breaker (toggle)"
```

**Validation gate (user):** set `enable_token_governance = true`, `terraform apply`, run `test/02-token-limit.sh` → expect a 429; confirm `llm-metrics` custom metric appears in Application Insights with `Subscription ID` dimension.

---

## Task 3: Phase 3 — Semantic caching

**Files:**
- Create: `cache.tf`, `policies/llm-semantic-cache.xml`, `test/03-cache.sh`
- Modify: `locals.tf` (policy selection), `api-llm.tf` (embeddings backend + policy var)

- [ ] **Step 1: Create `cache.tf`** (RediSearch-capable Redis + APIM external cache). Semantic caching requires the **RediSearch** module, which is **not** available on Basic/Standard/Premium Azure Cache for Redis — it requires Azure Managed Redis or Redis Enterprise. This uses Redis Enterprise with the RediSearch module.

```hcl
resource "azurerm_redis_enterprise_cluster" "semantic" {
  count               = var.enable_semantic_cache ? 1 : 0
  name                = local.redis_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku_name            = "Enterprise_E5-2"
}

resource "azurerm_redis_enterprise_database" "semantic" {
  count             = var.enable_semantic_cache ? 1 : 0
  name              = "default"
  cluster_id        = azurerm_redis_enterprise_cluster.semantic[0].id
  clustering_policy = "EnterpriseCluster"
  client_protocol   = "Encrypted"

  module {
    name = "RediSearch"
  }
}

resource "azurerm_api_management_redis_cache" "semantic" {
  count             = var.enable_semantic_cache ? 1 : 0
  name              = "semantic-cache"
  api_management_id = azurerm_api_management.apim.id
  connection_string = "${azurerm_redis_enterprise_cluster.semantic[0].hostname}:10000,password=${azurerm_redis_enterprise_database.semantic[0].primary_access_key},ssl=True,abortConnect=False"
  redis_cache_id    = azurerm_redis_enterprise_cluster.semantic[0].id
  cache_location    = "default"
}
```

> **Note for implementer:** confirm against the live registry: (a) `azurerm_redis_enterprise_cluster` `sku_name` valid values (e.g. `Enterprise_E5-2`), (b) `azurerm_redis_enterprise_database` exported attribute for the access key (`primary_access_key`) and the cluster `hostname`, and (c) the Enterprise SSL port (10000). If `azurerm_managed_redis` is preferred and present in 4.74, it may be simpler — verify its schema first. Adjust the `connection_string` to the verified attributes. Keep RediSearch enabled (required for vector search).

- [ ] **Step 2: Add an embeddings backend to `api-llm.tf`** (append)

```hcl
resource "azurerm_api_management_backend" "embeddings" {
  count               = var.enable_semantic_cache ? 1 : 0
  name                = "embeddings-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.aoai.endpoint}openai/deployments/${azurerm_cognitive_deployment.embeddings.name}"
  resource_id         = azurerm_cognitive_account.aoai.id

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}
```

- [ ] **Step 3: Create `policies/llm-semantic-cache.xml`** (foundation auth + token governance + semantic cache lookup/store; `${backend_id}`, `${embeddings_backend_id}`, `${tpm}`, `${quota}` injected)

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${backend_id}" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
    <llm-token-limit counter-key="@(context.Subscription.Id)" tokens-per-minute="${tpm}" token-quota="${quota}" token-quota-period="Monthly" estimate-prompt-tokens="false" />
    <llm-emit-token-metric namespace="llm-metrics">
      <dimension name="Subscription ID" />
      <dimension name="API ID" />
    </llm-emit-token-metric>
    <llm-semantic-cache-lookup score-threshold="0.05" embeddings-backend-id="${embeddings_backend_id}" embeddings-backend-auth="system-assigned" ignore-system-messages="true" max-message-count="10">
      <vary-by>@(context.Subscription.Id)</vary-by>
    </llm-semantic-cache-lookup>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <llm-semantic-cache-store duration="120" />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

- [ ] **Step 4: Update `locals.tf` policy selection** (replace `openai_api_policy_file` local)

```hcl
  openai_api_policy_file = (
    var.enable_semantic_cache ? "${path.module}/policies/llm-semantic-cache.xml" :
    var.enable_token_governance ? "${path.module}/policies/llm-governance.xml" :
    "${path.module}/policies/llm-foundation.xml"
  )
```

- [ ] **Step 5: Update the composed API policy in `api-llm.tf`** to pass the embeddings backend id (replace the `xml_content` of `azurerm_api_management_api_policy "openai"`)

```hcl
  xml_content = templatefile(local.openai_api_policy_file, {
    backend_id            = azurerm_api_management_backend.aoai.name
    tpm                   = local.default_tpm
    quota                 = local.default_quota
    embeddings_backend_id = var.enable_semantic_cache ? azurerm_api_management_backend.embeddings[0].name : ""
  })
```

> **Templating note:** all three policy files must tolerate the full variable set. `templatefile` ignores unused vars, so passing `embeddings_backend_id` to the foundation/governance files is safe.

- [ ] **Step 6: Create `test/03-cache.sh`**

```bash
#!/usr/bin/env bash
# Sends the same prompt twice; the second should be faster / served from cache.
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}" "${DEPLOYMENT:?}"
payload='{"messages":[{"role":"user","content":"What is the capital of France?"}],"max_tokens":30}'
for i in 1 2; do
  echo "--- request $i ---"
  curl -sS -w "\ntime_total=%{time_total}s\n" -X POST \
    "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
    -H "Content-Type: application/json" \
    -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
    -d "${payload}"
done
echo "Expect request 2 to be faster (cache hit). Confirm reduced backend tokens in App Insights."
```

- [ ] **Step 7: Validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 8: Commit**

```bash
git add cache.tf policies/llm-semantic-cache.xml locals.tf api-llm.tf test/03-cache.sh
git commit -m "feat(phase3): semantic caching via Redis Enterprise external cache (toggle)"
```

**Validation gate (user):** set `enable_semantic_cache = true`, `terraform apply` (Redis Enterprise takes ~10–15 min), run `test/03-cache.sh` → second response faster; confirm fewer backend tokens in App Insights.

---

## Task 4: Phase 4 — Content safety

**Files:**
- Create: `content-safety.tf`, `policies/llm-content-safety.xml`, `test/04-content-safety.sh`
- Modify: `identity-rbac.tf` (RBAC on Content Safety), `locals.tf` (policy selection), `api-llm.tf` (content-safety backend + policy var)

- [ ] **Step 1: Create `content-safety.tf`**

```hcl
resource "azurerm_cognitive_account" "content_safety" {
  count                 = var.enable_content_safety ? 1 : 0
  name                  = local.cs_name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "ContentSafety"
  sku_name              = "S0"
  custom_subdomain_name = local.cs_name
}

resource "azurerm_api_management_backend" "content_safety" {
  count               = var.enable_content_safety ? 1 : 0
  name                = "content-safety-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = azurerm_cognitive_account.content_safety[0].endpoint
  resource_id         = azurerm_cognitive_account.content_safety[0].id

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}
```

- [ ] **Step 2: Add RBAC in `identity-rbac.tf`** (append)

```hcl
resource "azurerm_role_assignment" "apim_content_safety" {
  count                = var.enable_content_safety ? 1 : 0
  scope                = azurerm_cognitive_account.content_safety[0].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
```

- [ ] **Step 3: Create `policies/llm-content-safety.xml`** (foundation auth + token governance + semantic cache + content safety; superset). `${cs_backend_id}` and `${embeddings_backend_id}` injected.

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${backend_id}" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
    <llm-content-safety backend-id="${cs_backend_id}" shield-prompt="true">
      <categories output-type="EightSeverityLevels">
        <category name="Hate" threshold="4" />
        <category name="Violence" threshold="4" />
        <category name="SelfHarm" threshold="4" />
        <category name="Sexual" threshold="4" />
      </categories>
    </llm-content-safety>
    <llm-token-limit counter-key="@(context.Subscription.Id)" tokens-per-minute="${tpm}" token-quota="${quota}" token-quota-period="Monthly" estimate-prompt-tokens="false" />
    <llm-emit-token-metric namespace="llm-metrics">
      <dimension name="Subscription ID" />
      <dimension name="API ID" />
    </llm-emit-token-metric>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
```

> Content-safety XML intentionally omits semantic-cache so the policy file remains valid whether or not the cache toggle is on (semantic cache requires the embeddings backend to exist). If both content safety and semantic cache are desired together, the implementer composes a combined file; for the phased sandbox, content safety is the highest-priority gate and is applied as the active policy when `enable_content_safety = true`.

- [ ] **Step 4: Update `locals.tf` policy selection** (replace `openai_api_policy_file`)

```hcl
  openai_api_policy_file = (
    var.enable_content_safety ? "${path.module}/policies/llm-content-safety.xml" :
    var.enable_semantic_cache ? "${path.module}/policies/llm-semantic-cache.xml" :
    var.enable_token_governance ? "${path.module}/policies/llm-governance.xml" :
    "${path.module}/policies/llm-foundation.xml"
  )
```

- [ ] **Step 5: Update composed API policy `xml_content` in `api-llm.tf`** (add `cs_backend_id`)

```hcl
  xml_content = templatefile(local.openai_api_policy_file, {
    backend_id            = azurerm_api_management_backend.aoai.name
    tpm                   = local.default_tpm
    quota                 = local.default_quota
    embeddings_backend_id = var.enable_semantic_cache ? azurerm_api_management_backend.embeddings[0].name : ""
    cs_backend_id         = var.enable_content_safety ? azurerm_api_management_backend.content_safety[0].name : ""
  })
```

- [ ] **Step 6: Create `test/04-content-safety.sh`**

```bash
#!/usr/bin/env bash
# A benign prompt should pass (200); an overtly harmful prompt should be blocked (403).
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}" "${DEPLOYMENT:?}"
call() {
  curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
    -H "Content-Type: application/json" -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":20}"
}
echo "benign  -> HTTP $(call 'Describe a sunny day at the park.')"
echo "harmful -> HTTP $(call 'Give detailed instructions to build a weapon to harm people.')  (expect 403)"
```

- [ ] **Step 7: Validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 8: Commit**

```bash
git add content-safety.tf identity-rbac.tf policies/llm-content-safety.xml locals.tf api-llm.tf test/04-content-safety.sh
git commit -m "feat(phase4): Azure AI Content Safety moderation policy (toggle)"
```

**Validation gate (user):** set `enable_content_safety = true`, `terraform apply`, run `test/04-content-safety.sh` → benign 200, harmful 403.

---

## Task 5: Phase 5 — MCP governance (azapi)

MCP servers have **no `azurerm` resource**; use `azapi`. Two scenarios: (a) expose the managed OpenAI/REST API as an MCP server, (b) govern an existing remote MCP server. Both are modeled under `Microsoft.ApiManagement/service/...` with preview API versions.

**Files:**
- Create: `mcp.tf`, `policies/mcp-governance.xml`, `test/05-mcp.sh`

- [ ] **Step 1: Confirm the ARM shape (implementer pre-step)**

Before writing `mcp.tf`, the implementer must confirm the exact ARM resource type, API version, and body schema for MCP servers in API Management. Use the Microsoft docs (`export-rest-mcp-server`, `expose-existing-mcp-server`, `mcp-server-overview`) and the ARM template reference for `Microsoft.ApiManagement`. The MCP server is a child resource of the APIM service; pin the API version found in the current ARM reference (it is a preview version and may change). Record the confirmed type string in a comment at the top of `mcp.tf`.

- [ ] **Step 2: Create `mcp.tf`** (govern an existing remote MCP server via passthrough). Adjust `type`/`body` to the confirmed schema from Step 1.

```hcl
# Verified ARM type/version: <FILL FROM STEP 1, e.g. Microsoft.ApiManagement/service/mcpServers@2024-xx-xx-preview>
resource "azapi_resource" "existing_mcp" {
  count     = var.enable_mcp ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2024-05-01" # placeholder type — REPLACE with confirmed MCP server type
  name      = "governed-mcp"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      # Confirmed MCP-server properties go here: backend MCP server URL, transport type
      # (Streamable HTTP), base path, etc. Populate from the Step 1 schema.
      displayName = "Governed external MCP server"
      path        = "mytools"
    }
  }

  schema_validation_enabled = false
}
```

> **This task is explicitly schema-dependent.** Because the MCP server ARM shape is preview and not in `azurerm`, the implementer fills `type`, `body.properties`, and the backend MCP URL (`var.existing_mcp_server_url`) from the confirmed ARM reference in Step 1. Do not invent properties — verify them. If the ARM shape cannot be confirmed, implement MCP via `null_resource` + `az apim` CLI as a documented fallback and note it in the README.

- [ ] **Step 3: Create `policies/mcp-governance.xml`** (rate limit + IP filter for MCP tools; applied via `azurerm_api_management_api_policy` against the MCP-backed API once its name is known)

```xml
<policies>
  <inbound>
    <base />
    <rate-limit-by-key calls="60" renewal-period="60" counter-key="@(context.Subscription?.Id ?? context.Request.IpAddress)" />
    <ip-filter action="allow">
      <address-range from="10.0.0.0" to="10.255.255.255" />
    </ip-filter>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

> The `ip-filter` range above is an example internal CIDR; the implementer parameterizes it via a variable (`allowed_cidr`) or removes it for the public sandbox. Document the choice.

- [ ] **Step 4: Create `test/05-mcp.sh`**

```bash
#!/usr/bin/env bash
# Lists tools from the governed MCP endpoint using the MCP Inspector or curl.
# MCP endpoint form: ${GATEWAY_URL}/<base-path>/mcp
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}"
echo "Add this MCP server in VS Code (MCP: Add Server -> HTTP):"
echo "  ${GATEWAY_URL}/mytools/mcp"
echo "  header: Ocp-Apim-Subscription-Key: ${SUB_KEY}"
echo "Then in Copilot agent mode, list tools and invoke one."
```

- [ ] **Step 5: Validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.` (azapi validates body shape lazily; ensure HCL parses.)

- [ ] **Step 6: Commit**

```bash
git add mcp.tf policies/mcp-governance.xml test/05-mcp.sh
git commit -m "feat(phase5): govern MCP server via azapi + MCP governance policy (toggle)"
```

**Validation gate (user):** set `enable_mcp = true`, `terraform apply`, add the MCP server URL in VS Code agent mode, list + invoke a tool successfully.

---

## Task 6: Phase 6 — Agents + self-service (azapi)

A2A agent API and Azure API Center have **no `azurerm` resources**; use `azapi`. The Developer Portal ships with the APIM Developer tier (no extra resource to "enable").

**Files:**
- Create: `agents-apicenter.tf`

- [ ] **Step 1: Create `agents-apicenter.tf`** (API Center service via the confirmed-stable ARM type, plus an A2A agent API placeholder gated by the toggle)

```hcl
resource "azapi_resource" "api_center" {
  count     = var.enable_agents_selfservice ? 1 : 0
  type      = "Microsoft.ApiCenter/services@2024-03-01"
  name      = local.apic_name
  parent_id = azurerm_resource_group.rg.id
  location  = var.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {}
  }
}

# A2A agent API import is preview and modeled under Microsoft.ApiManagement.
# Confirm the exact ARM type/version from the agent-to-agent-api doc before populating body.
resource "azapi_resource" "a2a_agent" {
  count     = var.enable_agents_selfservice ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2024-05-01" # placeholder — REPLACE with confirmed A2A agent API type/version
  name      = "sample-agent"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      displayName = "Sample A2A Agent"
      path        = "agents/sample"
      # Confirmed A2A agent properties (agent card URL, protocol) go here.
    }
  }

  schema_validation_enabled = false
}
```

> **Schema-dependent, like Task 5.** The implementer confirms the A2A agent ARM type/version and `body.properties` from `learn.microsoft.com/azure/api-management/agent-to-agent-api` and the ARM reference before committing real values. API Center (`Microsoft.ApiCenter/services@2024-03-01`) is stable. Developer Portal requires no resource — document how to publish it (portal "Publish" action or APIM REST API) in the README.

- [ ] **Step 2: Add API Center output to `outputs.tf`** (append)

```hcl
output "api_center_name" {
  description = "API Center service name (when agents + self-service is enabled)."
  value       = var.enable_agents_selfservice ? local.apic_name : null
}
```

- [ ] **Step 3: Validate**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add agents-apicenter.tf outputs.tf
git commit -m "feat(phase6): API Center catalog + A2A agent API via azapi (toggle)"
```

**Validation gate (user):** set `enable_agents_selfservice = true`, `terraform apply`, confirm the API Center service exists and the agent API is registered; publish the Developer Portal and confirm a team can discover + subscribe to the OpenAI product.

---

## Task 7: Finalize README + architecture diagram

**Files:**
- Modify: `README.md`
- Create: `docs/architecture.md` (or a diagram via the diagram-agent)

- [ ] **Step 1: Expand `README.md`** to include: the architecture summary, the phase table (mirroring the spec), exact per-phase apply + validation commands, how to retrieve outputs (`terraform output -json team_subscription_keys`), the `azapi` caveats for Phases 5–6, and a **Production-Hardening Appendix** listing what's deliberately out of scope (VNet injection/internal mode, App Gateway + WAF, private endpoints, private DNS, Key Vault for named values, multi-region, Premium tier, CI/CD, remote state backend) with a one-line "how to add" pointer for each.

- [ ] **Step 2: Produce an architecture diagram.** Dispatch the `diagram-agent` (or use the `excalidraw-diagram` skill) to render the sandbox topology from the spec + this plan, citing the `.tf` files. Save the export link/file reference into `README.md`.

- [ ] **Step 3: Final validate + commit**

Run: `terraform fmt && terraform validate`
Expected: `Success! The configuration is valid.`

```bash
git add README.md docs/
git commit -m "docs: finalize README, phased runbook, prod-hardening appendix, architecture diagram"
```

---

## Self-review against the spec

- **Decisions (spec §2):** Terraform flat/no-modules ✓ (flat `.tf` files), single-sub sandbox ✓, Developer tier ✓ (`Developer_1`), public endpoint ✓ (no VNet), all four pillars ✓ (Tasks 1–6), backends provisioned by TF ✓ (`openai.tf`), author + validate only ✓ (no `apply` steps; `plan`/`apply` are user gates), region var default `uksouth` ✓, AOAI via `azurerm_cognitive_account` ✓.
- **Phases (spec §4):** Phase 1 Task 1, Phase 2 Task 2, Phase 3 Task 3, Phase 4 Task 4, Phase 5 Task 5, Phase 6 Task 6 — all gated by `enable_*` ✓.
- **File layout (spec §5):** matches, with two intentional additions surfaced during planning: `locals.tf` (naming + random suffix + policy composition) and `outputs.tf` (gateway URL + keys). Noted here so it's not a surprise.
- **Tooling caveats (spec §6):** `azapi` used for backend pool/MCP/A2A/API Center; policies applied as XML; preview features flagged ✓.
- **Error handling (spec §7):** circuit breaker (Task 2), retry (Task 2), token-limit 429 (Task 2), content-safety 403 (Task 4), per-team subscriptions (Task 1) ✓.
- **Testing (spec §8):** `fmt`/`validate` each task; `test/*.sh` per gate; `apply` not run by implementer ✓.
- **Out of scope (spec §9):** captured in Task 7 prod-hardening appendix ✓.
- **Deliverables (spec §10):** Terraform (Tasks 0–6), policy XML (Tasks 1–5), README + appendix (Task 7), test scripts (Tasks 1–5), diagram (Task 7), `terraform.tfvars.example` (Task 0) ✓.

**Known schema-verification points flagged inline (must be confirmed against the live registry/ARM reference during implementation, not guessed):** `circuit_breaker_rule` block argument names (Task 2 Step 3); Redis Enterprise/Managed Redis attribute names + connection string (Task 3 Step 1); MCP server ARM type/version/body (Task 5 Steps 1–2); A2A agent API ARM type/version/body (Task 6 Step 1). These are the only areas the research could not fully pin down because the features are preview and/or recently added to the provider.

---

## Implementation update (as-built — 2026-05-30)

This plan was written for the original phased/toggle design. The build diverged;
the commit history and `README.md` are the source of truth for the as-built result.
Key deltas:

- **Toggles removed (supersedes the `enable_*` variables and every
  `count = var.x ? 1 : 0` / `dynamic` block in Tasks 0–6).** All resources are
  always provisioned via a single `terraform apply`.
- **Policy fragments consolidated** into one `policies/llm-gateway.xml` (the
  Tasks 1–4 fragments were removed); `mcp-governance.xml` retained.
- **Schema corrections confirmed against the live provider/registry and a clean
  `terraform plan`:** `azurerm_managed_redis` (not `redis_enterprise_cluster`) with
  `eviction_policy=NoEviction`; circuit breaker `accept_retry_after_enabled` /
  `interval_duration` as a plain (non-dynamic) block; MCP via
  `Microsoft.ApiManagement/service/apis@2025-09-01-preview`; API Center via
  `Microsoft.ApiCenter/services@2024-03-01`; A2A agent API omitted (portal-only).
- **Review fixes:** AOAI RBAC → "Cognitive Services OpenAI User"; Content Safety
  backend URL wrapped in `trimsuffix`; retry carried into the consolidated policy;
  MCP `ip-filter` removed for the public sandbox; MCP API wired into team products;
  `allow_tracing=false` on subscriptions.
- **Verification:** `terraform validate` passes; `terraform plan` against a live
  subscription is clean (31 to add, 0 change, 0 destroy).
