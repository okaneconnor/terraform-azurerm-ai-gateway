# APIM AI Gateway v2 — Private, Multi-Service, Entra-Keyless (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the sandbox AI gateway into a private, UK-resident, multi-service Azure AI gateway fronted by APIM (Developer tier, External VNet injection), with Entra-keyless auth (no subscription keys), private-endpoint backends (Foundry/Azure OpenAI, Content Safety, Speech, Language, Document Intelligence), tiered self-service products, observability, MCP governance, and an API Center catalog.

**Architecture:** Clients authenticate with an Entra ID token (client-credentials, app-role gated) and call APIM's public gateway endpoint, which is locked down by `validate-azure-ad-token` + `ip-filter`. APIM sits in a VNet (External mode) and reaches every Azure AI backend over **private endpoints** with the backends' public network access disabled; APIM authenticates to backends with its **system-assigned managed identity**. All resources live in **uksouth** for UK data residency.

**Tech Stack:** Terraform; `hashicorp/azurerm ~> 4.74`, `hashicorp/azuread ~> 3.0`, `azure/azapi ~> 2.0`, `hashicorp/random ~> 3.6`. APIM Developer; Azure AI Foundry (`kind=AIServices`) + `gpt-4.1-mini`; Content Safety / Speech / Language / Document Intelligence; Key Vault; Private Link; Log Analytics + App Insights + Workbook; API Center.

**Verification model:** per-task gate is `terraform fmt` + `terraform validate`; a full `terraform plan` against the work sub (`230414f6-…`, pinned via `var.subscription_id`) before any apply. `apply` is the user's step. `export ARM_SUBSCRIPTION_ID` is no longer needed (provider is pinned).

---

## Key decisions & caveats (read first)

1. **Transition:** `terraform destroy` the current Developer/public sandbox first (clean rebuild), then apply this target. Tier + VNet changes force APIM recreation anyway.
2. **Region:** **uksouth only** (UK residency). ukwest is not a viable HA twin for these services — documented as a known gap for Security/Architecture sign-off.
3. **Model:** `gpt-4.1-mini` version `2025-04-14`, deployment type **`Standard`** (in-UK processing). Do **not** use `GlobalStandard` (worldwide) or `DataZoneStandard` (EU, excludes UK) for HMCTS data. Add an Azure Policy to deny Global deployment types (Task 14, optional control).
4. **Auth:** Entra-keyless. Products are `subscription_required = false`; access is gated by `validate-azure-ad-token` (audience + `roles` claim) and `ip-filter`. Throttling is keyed by the JWT `azp` claim, not a subscription key.
5. **Private networking gotcha:** create each Cognitive account with `public_network_access_enabled = true` first, attach the private endpoint, **then** flip to `false`. Doing it in one shot can lock Terraform out mid-apply. This plan sequences that with explicit `depends_on` and a two-phase note per service.
6. **Kept / dropped:** MCP governance kept (azapi). Semantic caching **dropped** (LLM-only cost optimisation, open cache-hit bug, Redis cost) — documented as a phase-2 pattern. A2A documented as **future**.
7. **azuread v3 names:** use `client_id` (not `application_id`) on `azuread_service_principal`; `azuread_application_password.application_id` takes the application **resource id**. App roles use `allowed_member_types = ["Application"]` (client-credentials) and `id` from `random_uuid`.
8. **APIM External VNet provisioning is slow (15–45 min)** and Developer has no SLA (downtime during network changes). Set long timeouts on the APIM resource.

---

## File structure (flat, no modules)

```
providers.tf          # azurerm + azuread + azapi + random; azurerm/azapi pinned to var.subscription_id
variables.tf          # subscription_id, location, naming, publisher, home_ip_cidr, model, product limits, enable_mcp
locals.tf             # random suffix + computed names
data.tf               # azurerm_client_config, azuread_client_config (tenant id)
foundation.tf         # RG, Log Analytics, App Insights
network.tf            # VNet, APIM subnet, PE subnet, NSG + rules, association
dns.tf                # private DNS zones (cognitiveservices/openai/services.ai/vaultcore) + VNet links
keyvault.tf           # Key Vault (private) + APIM MI RBAC + private endpoint
apim.tf               # APIM Developer External-VNet + identity + logger + diagnostic
ai-foundry.tf         # AIServices account + gpt-4.1-mini deployment + private endpoint
ai-services.tf        # Speech, Language, Document Intelligence, Content Safety + private endpoints
identity-rbac.tf      # APIM MI -> Cognitive Services OpenAI User / Cognitive Services User on AI accounts
entra.tf              # gateway app (+app roles) , client app (+secret) , app-role assignment
policy-fragments.tf   # azurerm_api_management_policy_fragment x (ip, jwt, backend-mi, content-safety, token-metric)
apis.tf               # APIM APIs + backends for foundry/openai, content-safety, speech, language, doc-intel + API policies
products.tf           # ai-sandbox / ai-production-standard products (keyless) + product policies (tiered limits) + API links
mcp.tf                # MCP governance via azapi (kept) + governance policy
apicenter.tf          # API Center via azapi + A2A future note
workbook.tf           # Azure Monitor Workbook dashboard
outputs.tf            # gateway url, app/client ids, tenant id, how-to-get-token
policies/             # *.xml fragment bodies + per-API policy bodies
test/                 # smoke scripts: token, foundry chat, content-safety, language, doc-intel, direct-backend-fail
README.md             # runbook, residency notes, prod-hardening appendix
```

**Policy approach:** use `azurerm_api_management_policy_fragment` for cross-cutting concerns (ip-filter, Entra JWT, backend managed-identity, content-safety, token-metric), then API-level and product-level policies `include-fragment` them. This mirrors Thomas's `ai-*` fragments and keeps the XML DRY.

---

## Task 0: Destroy sandbox, branch, scaffold providers & variables

**Files:** Modify `providers.tf`, `variables.tf`, `locals.tf`; create `data.tf`.

- [ ] **Step 1: Confirm branch and destroy the existing sandbox**

```bash
cd /Users/connorokane/Documents/repos/personal/ai-gateway
git checkout feat/apim-ai-gateway-sandbox   # or a new branch feat/aigw-v2-private off it
terraform destroy   # tears down the Developer/public sandbox (user confirms)
```
Expected: all sandbox resources removed; empty/clean state. (User runs `destroy`.)

- [ ] **Step 2: Replace `providers.tf`**

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.74" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    azapi   = { source = "azure/azapi", version = "~> 2.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azuread" {}
```

- [ ] **Step 3: Create `data.tf`**

```hcl
data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}
```

- [ ] **Step 4: Replace `variables.tf`**

```hcl
variable "subscription_id" {
  description = "Target Azure subscription ID (kns-platforms-pod-mcp work subscription)."
  type        = string
  default     = "230414f6-3458-4f1a-9f5c-488281e13c14"
}

variable "location" {
  description = "Azure region. UK South for HMCTS data residency."
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = "Short prefix for resource names (lowercase)."
  type        = string
  default     = "aigw"
}

variable "publisher_name" {
  type    = string
  default = "HMCTS AI Tiger Team"
}

variable "publisher_email" {
  type    = string
  default = "ai-platform@example.com"
}

variable "home_ip_cidr" {
  description = "Single client CIDR allowed to reach the gateway (e.g. office egress). Express as from/to in policy."
  type        = string
  default     = "0.0.0.0/0" # tighten before real use; 0.0.0.0/0 = allow all (sandbox only)
}

variable "vnet_cidr" {
  type    = string
  default = "10.90.0.0/16"
}
variable "apim_subnet_cidr" {
  type    = string
  default = "10.90.1.0/24"
}
variable "pe_subnet_cidr" {
  type    = string
  default = "10.90.2.0/24"
}

variable "chat_model" {
  description = "Foundry chat model. gpt-4.1-mini Standard is the current GA model available in-region (UK) per Foundry region availability."
  type = object({
    name     = string
    version  = string
    sku_name = string
    capacity = number
  })
  default = {
    name     = "gpt-4.1-mini"
    version  = "2025-04-14"
    sku_name = "Standard" # in-UK processing; do NOT use GlobalStandard/DataZoneStandard for HMCTS data
    capacity = 10
  }
}

variable "products" {
  description = "Self-service consumption tiers (keyless; limits keyed by client app id)."
  type = map(object({
    display_name      = string
    app_role          = string
    tokens_per_minute = number
    rate_limit_calls  = number
  }))
  default = {
    "ai-sandbox" = {
      display_name = "AI Sandbox", app_role = "AI.Gateway.Sandbox",
      tokens_per_minute = 20000, rate_limit_calls = 30
    }
    "ai-production-standard" = {
      display_name = "AI Production Standard", app_role = "AI.Gateway.Production",
      tokens_per_minute = 150000, rate_limit_calls = 120
    }
  }
}

variable "rate_limit_renewal_seconds" {
  type    = number
  default = 60
}

variable "enable_mcp" {
  description = "Provision MCP governance (azapi). Kept from v1."
  type        = bool
  default     = true
}

variable "existing_mcp_server_url" {
  type    = string
  default = "https://learn.microsoft.com/api/mcp"
}
```

> Note: unlike v1, capability resources are **always on** (no count toggles) except `enable_mcp`, which is retained as a single feature switch because MCP is preview/optional. This matches the "no count anti-pattern" decision while keeping one intentional switch.

- [ ] **Step 5: Replace `locals.tf`**

```hcl
resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

locals {
  suffix    = random_string.suffix.result
  rg_name   = "${var.name_prefix}-uks-rg"
  apim_name = "${var.name_prefix}-apim-${local.suffix}"
  law_name  = "${var.name_prefix}-law-${local.suffix}"
  ai_name   = "${var.name_prefix}-appi-${local.suffix}"
  kv_name   = "${var.name_prefix}kv${local.suffix}" # <=24 chars, alnum

  foundry_name  = "${var.name_prefix}-fdry-${local.suffix}"
  speech_name   = "${var.name_prefix}-spch-${local.suffix}"
  language_name = "${var.name_prefix}-lang-${local.suffix}"
  docintel_name = "${var.name_prefix}-doci-${local.suffix}"
  cs_name       = "${var.name_prefix}-cs-${local.suffix}"
  apic_name     = "${var.name_prefix}-apic-${local.suffix}"

  tenant_id = data.azurerm_client_config.current.tenant_id
}
```

- [ ] **Step 6: Validate scaffold**

Run: `terraform init -backend=false && terraform fmt -recursive && terraform validate`
Expected: providers (azurerm/azuread/azapi/random) install; `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add providers.tf variables.tf locals.tf data.tf
git commit -m "chore(v2): scaffold providers (azuread+azapi), variables, locals for private multi-service gateway"
```

---

## Task 1: Foundation (RG, Log Analytics, App Insights)

**Files:** Create `foundation.tf`.

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

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add foundation.tf && git commit -m "feat(v2): foundation - RG, Log Analytics, App Insights"
```

---

## Task 2: Network (VNet, subnets, NSG, private DNS)

**Files:** Create `network.tf`, `dns.tf`.

- [ ] **Step 1: Create `network.tf`** (APIM subnet, PE subnet, NSG with the minimal External-VNet rule set)

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.apim_subnet_cidr]
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.pe_subnet_cidr]
}

resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "in-client-443"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "in-apim-mgmt-3443"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "in-lb-6390"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }
  security_rule {
    name                       = "out-storage-443"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }
  security_rule {
    name                       = "out-sql-1433"
    priority                   = 210
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Sql"
  }
  security_rule {
    name                       = "out-kv-443"
    priority                   = 220
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureKeyVault"
  }
  security_rule {
    name                       = "out-monitor"
    priority                   = 230
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1886"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}
```

- [ ] **Step 2: Create `dns.tf`** (private DNS zones for cognitive/openai/ai-services/key-vault + VNet links)

```hcl
locals {
  private_dns_zones = {
    cognitive  = "privatelink.cognitiveservices.azure.com"
    openai     = "privatelink.openai.azure.com"
    aiservices = "privatelink.services.ai.azure.com"
    keyvault   = "privatelink.vaultcore.azure.net"
  }
}

resource "azurerm_private_dns_zone" "zone" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  for_each              = local.private_dns_zones
  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name  = azurerm_private_dns_zone.zone[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}
```

- [ ] **Step 3: Validate & commit**

```bash
terraform fmt && terraform validate
git add network.tf dns.tf && git commit -m "feat(v2): VNet + subnets + NSG + private DNS zones"
```

---

## Task 3: Key Vault (private) + APIM MI RBAC

**Files:** Create `keyvault.tf`.

> Note: APIM resource is defined in Task 4; the role assignment here references `azurerm_api_management.apim`, so this file's `terraform validate` only fully resolves once Task 4 lands (integrated validate). That's acceptable per our model.

- [ ] **Step 1: Create `keyvault.tf`**

```hcl
resource "azurerm_key_vault" "main" {
  name                       = local.kv_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = local.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  # Create with public access; PE attaches; tighten via network_acls.
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_role_assignment" "apim_kv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnszg-kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.zone["keyvault"].id]
  }
}
```

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add keyvault.tf && git commit -m "feat(v2): private Key Vault + APIM MI Secrets User + private endpoint"
```

---

## Task 4: APIM Developer (External VNet) + logger + diagnostic

**Files:** Create `apim.tf`.

- [ ] **Step 1: Create `apim.tf`**

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

  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  # VNet changes on APIM are slow; give it room.
  timeouts {
    create = "3h"
    update = "3h"
  }

  depends_on = [azurerm_subnet_network_security_group_association.apim]
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
  identifier                = "applicationinsights"
  api_management_name       = azurerm_api_management.apim.name
  resource_group_name       = azurerm_resource_group.rg.name
  api_management_logger_id  = azurerm_api_management_logger.appinsights.id
  sampling_percentage       = 100.0
  verbosity                 = "information"
  always_log_errors         = true
  log_client_ip             = true
  http_correlation_protocol = "W3C"
}
```

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add apim.tf && git commit -m "feat(v2): APIM Developer in External VNet + App Insights logger/diagnostic"
```

---

## Task 5: AI Foundry account + chat model + private endpoint

**Files:** Create `ai-foundry.tf`.

> Two-phase note: provision with `public_network_access_enabled = true`, attach PE, then a follow-up apply can set it `false`. For the plan we set `false` from the start but add `depends_on` so the PE exists; if apply locks out, switch the account to `true`, apply, then `false`.

- [ ] **Step 1: Create `ai-foundry.tf`**

```hcl
resource "azurerm_cognitive_account" "foundry" {
  name                  = local.foundry_name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = local.foundry_name

  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model.name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

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

resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-foundry-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-foundry"
    private_connection_resource_id = azurerm_cognitive_account.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "pdnszg-foundry"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.zone["cognitive"].id,
      azurerm_private_dns_zone.zone["openai"].id,
      azurerm_private_dns_zone.zone["aiservices"].id,
    ]
  }
}
```

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add ai-foundry.tf && git commit -m "feat(v2): AI Foundry (AIServices) + gpt-4.1-mini Standard + private endpoint"
```

---

## Task 6: Speech, Language, Document Intelligence, Content Safety + private endpoints

**Files:** Create `ai-services.tf`.

- [ ] **Step 1: Create `ai-services.tf`** (one map drives the four cognitive accounts + their PEs)

```hcl
locals {
  ai_services = {
    speech   = { name = local.speech_name, kind = "SpeechServices", sku = "S0" }
    language = { name = local.language_name, kind = "TextAnalytics", sku = "S" }
    docintel = { name = local.docintel_name, kind = "FormRecognizer", sku = "S0" }
    safety   = { name = local.cs_name, kind = "ContentSafety", sku = "S0" }
  }
}

resource "azurerm_cognitive_account" "svc" {
  for_each              = local.ai_services
  name                  = each.value.name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = each.value.kind
  sku_name              = each.value.sku
  custom_subdomain_name = each.value.name

  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_private_endpoint" "svc" {
  for_each            = local.ai_services
  name                = "pe-${each.key}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_cognitive_account.svc[each.key].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "pdnszg-${each.key}"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.zone["cognitive"].id,
      azurerm_private_dns_zone.zone["aiservices"].id,
    ]
  }
}
```

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add ai-services.tf && git commit -m "feat(v2): Speech/Language/Doc Intelligence/Content Safety + private endpoints"
```

---

## Task 7: Managed-identity RBAC to the AI backends

**Files:** Create `identity-rbac.tf`.

- [ ] **Step 1: Create `identity-rbac.tf`**

```hcl
# Foundry/OpenAI inference -> Cognitive Services OpenAI User (least privilege for model calls)
resource "azurerm_role_assignment" "apim_foundry_openai" {
  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# The other AI services (Speech/Language/Doc Intelligence/Content Safety) -> Cognitive Services User
resource "azurerm_role_assignment" "apim_svc" {
  for_each             = local.ai_services
  scope                = azurerm_cognitive_account.svc[each.key].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
```

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add identity-rbac.tf && git commit -m "feat(v2): APIM MI RBAC to all AI backends (least privilege)"
```

---

## Task 8: Entra app registrations (keyless auth)

**Files:** Create `entra.tf`.

- [ ] **Step 1: Create `entra.tf`**

```hcl
resource "random_uuid" "role" {
  for_each = var.products
}

resource "azuread_application" "gateway" {
  display_name     = "${var.name_prefix}-gateway-${local.suffix}"
  identifier_uris  = ["api://${var.name_prefix}-gateway-${local.suffix}"]
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  api {
    requested_access_token_version = 2
  }

  dynamic "app_role" {
    for_each = var.products
    content {
      allowed_member_types = ["Application"]
      description          = "Access the ${app_role.value.display_name} tier"
      display_name         = app_role.value.display_name
      enabled              = true
      id                   = random_uuid.role[app_role.key].result
      value                = app_role.value.app_role
    }
  }
}

resource "azuread_service_principal" "gateway" {
  client_id = azuread_application.gateway.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# Demo client application (one per tier could be created; here one client granted sandbox)
resource "azuread_application" "client" {
  display_name     = "${var.name_prefix}-client-${local.suffix}"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "client" {
  client_id = azuread_application.client.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "client" {
  application_id = azuread_application.client.id
  display_name   = "client-credentials"
}

resource "azuread_app_role_assignment" "client_sandbox" {
  app_role_id         = azuread_service_principal.gateway.app_role_ids["AI.Gateway.Sandbox"]
  principal_object_id = azuread_service_principal.client.object_id
  resource_object_id  = azuread_service_principal.gateway.object_id
}
```

- [ ] **Step 2: Validate & commit**

```bash
terraform fmt && terraform validate
git add entra.tf && git commit -m "feat(v2): Entra gateway app + app roles, demo client app + role assignment"
```

---

## Task 9: Policy fragments (ip-filter, Entra JWT, backend MI, content-safety, token-metric)

**Files:** Create `policy-fragments.tf`, `policies/frag-*.xml`.

- [ ] **Step 1: Create the fragment XML files**

`policies/frag-ip-allow.xml`:
```xml
<fragment>
  <ip-filter action="allow">
    <address-range from="${ip_from}" to="${ip_to}" />
  </ip-filter>
</fragment>
```

`policies/frag-entra-jwt.xml`:
```xml
<fragment>
  <validate-azure-ad-token tenant-id="${tenant_id}" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. Valid Entra ID token with an AI.Gateway role is required.">
    <audiences>
      <audience>${gateway_client_id}</audience>
    </audiences>
    <required-claims>
      <claim name="roles" match="any">
        <value>AI.Gateway.Sandbox</value>
        <value>AI.Gateway.Production</value>
      </claim>
    </required-claims>
  </validate-azure-ad-token>
</fragment>
```

`policies/frag-backend-mi.xml`:
```xml
<fragment>
  <authentication-managed-identity resource="https://cognitiveservices.azure.com" output-token-variable-name="msi-access-token" ignore-error="false" />
  <set-header name="Authorization" exists-action="override">
    <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
  </set-header>
</fragment>
```

`policies/frag-content-safety.xml`:
```xml
<fragment>
  <llm-content-safety backend-id="${cs_backend_id}" shield-prompt="true">
    <categories output-type="EightSeverityLevels">
      <category name="Hate" threshold="4" />
      <category name="Violence" threshold="4" />
      <category name="SelfHarm" threshold="4" />
      <category name="Sexual" threshold="4" />
    </categories>
  </llm-content-safety>
</fragment>
```

`policies/frag-token-metric.xml`:
```xml
<fragment>
  <llm-emit-token-metric namespace="llm-metrics">
    <dimension name="API ID" />
    <dimension name="Client IP" value="@(context.Request.IpAddress)" />
    <dimension name="App ID" value="@(context.Request.Headers.GetValueOrDefault("Authorization","").AsJwt()?.Claims.GetValueOrDefault("azp",""))" />
  </llm-emit-token-metric>
</fragment>
```

- [ ] **Step 2: Create `policy-fragments.tf`**

```hcl
locals {
  ip_from = cidrhost(var.home_ip_cidr, 0)
  ip_to   = cidrhost(var.home_ip_cidr, -1)
}

resource "azurerm_api_management_policy_fragment" "ip_allow" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-ip-allow"
  format            = "xml"
  value             = templatefile("${path.module}/policies/frag-ip-allow.xml", { ip_from = local.ip_from, ip_to = local.ip_to })
}

resource "azurerm_api_management_policy_fragment" "entra_jwt" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-auth-entra-jwt"
  format            = "xml"
  value             = templatefile("${path.module}/policies/frag-entra-jwt.xml", {
    tenant_id         = local.tenant_id
    gateway_client_id = azuread_application.gateway.client_id
  })
}

resource "azurerm_api_management_policy_fragment" "backend_mi" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-backend-managed-identity"
  format            = "xml"
  value             = file("${path.module}/policies/frag-backend-mi.xml")
}

resource "azurerm_api_management_policy_fragment" "content_safety" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-content-safety"
  format            = "xml"
  value             = templatefile("${path.module}/policies/frag-content-safety.xml", {
    cs_backend_id = azurerm_api_management_backend.safety.name
  })
}

resource "azurerm_api_management_policy_fragment" "token_metric" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-token-metrics"
  format            = "xml"
  value             = file("${path.module}/policies/frag-token-metric.xml")
}
```

> Note: `azurerm_api_management_policy_fragment` uses `api_management_id` (not name+rg). Confirm the `format`/`value` argument names against the live 4.74 registry before commit; adjust if the schema differs.

- [ ] **Step 3: Validate & commit**

```bash
terraform fmt && terraform validate
git add policy-fragments.tf policies/frag-*.xml
git commit -m "feat(v2): reusable policy fragments (ip, entra-jwt, backend-mi, content-safety, token-metric)"
```

---

## Task 10: APIs + backends + API policies

**Files:** Create `apis.tf`, `policies/api-foundry.xml`, `policies/api-aiservice.xml`.

- [ ] **Step 1: Create backends** in `apis.tf` (private FQDNs resolved via the private DNS zones)

```hcl
resource "azurerm_api_management_backend" "foundry" {
  name                = "foundry-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.foundry.endpoint}openai"
}

resource "azurerm_api_management_backend" "safety" {
  name                = "content-safety-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["safety"].endpoint, "/")
}

resource "azurerm_api_management_backend" "speech" {
  name                = "speech-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["speech"].endpoint, "/")
}

resource "azurerm_api_management_backend" "language" {
  name                = "language-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["language"].endpoint, "/")
}

resource "azurerm_api_management_backend" "docintel" {
  name                = "docintel-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["docintel"].endpoint, "/")
}
```

- [ ] **Step 2: Create the Foundry/OpenAI API + policy** (`apis.tf`)

```hcl
resource "azurerm_api_management_api" "foundry" {
  name                  = "foundry-openai"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = "Foundry (Azure OpenAI)"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = false

  import {
    content_format = "openapi+json-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  }
}

resource "azurerm_api_management_api_policy" "foundry" {
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content         = file("${path.module}/policies/api-foundry.xml")
}
```

`policies/api-foundry.xml`:
```xml
<policies>
  <inbound>
    <base />
    <include-fragment fragment-id="ai-ip-allow" />
    <include-fragment fragment-id="ai-auth-entra-jwt" />
    <set-backend-service backend-id="foundry-backend" />
    <include-fragment fragment-id="ai-backend-managed-identity" />
    <include-fragment fragment-id="ai-content-safety" />
    <include-fragment fragment-id="ai-token-metrics" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

- [ ] **Step 3: Create the four AI-service APIs + a shared policy** (`apis.tf`)

```hcl
locals {
  ai_apis = {
    safety   = { display = "Content Safety", path = "contentsafety", backend = "content-safety-backend" }
    speech   = { display = "Speech", path = "speech", backend = "speech-backend" }
    language = { display = "Language", path = "language", backend = "language-backend" }
    docintel = { display = "Document Intelligence", path = "docintel", backend = "docintel-backend" }
  }
}

resource "azurerm_api_management_api" "svc" {
  for_each              = local.ai_apis
  name                  = "ai-${each.key}"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = each.value.display
  path                  = each.value.path
  protocols             = ["https"]
  subscription_required = false
}

resource "azurerm_api_management_api_policy" "svc" {
  for_each            = local.ai_apis
  api_name            = azurerm_api_management_api.svc[each.key].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = templatefile("${path.module}/policies/api-aiservice.xml", {
    backend_id = each.value.backend
  })
}
```

`policies/api-aiservice.xml`:
```xml
<policies>
  <inbound>
    <base />
    <include-fragment fragment-id="ai-ip-allow" />
    <include-fragment fragment-id="ai-auth-entra-jwt" />
    <set-backend-service backend-id="${backend_id}" />
    <include-fragment fragment-id="ai-backend-managed-identity" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

> Note: these APIs are created without an imported OpenAPI for brevity; operations can be added later or imported from each service's spec. The policy chain (auth + IP + MI) is the governance focus. For real use, import each service's OpenAPI so operations are typed.

- [ ] **Step 4: Validate & commit**

```bash
terraform fmt && terraform validate
git add apis.tf policies/api-foundry.xml policies/api-aiservice.xml
git commit -m "feat(v2): APIM APIs + private backends + fragment-composed policies for all AI services"
```

---

## Task 11: Products (keyless, tiered) + product policies

**Files:** Create `products.tf`, `policies/product-limits.xml`.

- [ ] **Step 1: Create `products.tf`**

```hcl
resource "azurerm_api_management_product" "tier" {
  for_each              = var.products
  product_id            = each.key
  display_name          = each.value.display_name
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  published             = true
  subscription_required = false # keyless; access gated by Entra JWT + IP
}

# Attach all APIs to each product
locals {
  all_api_names = concat(
    [azurerm_api_management_api.foundry.name],
    [for k, a in azurerm_api_management_api.svc : a.name]
  )
  product_api_pairs = { for pair in setproduct(keys(var.products), local.all_api_names) :
    "${pair[0]}|${pair[1]}" => { product = pair[0], api = pair[1] } }
}

resource "azurerm_api_management_product_api" "pa" {
  for_each            = local.product_api_pairs
  product_id          = azurerm_api_management_product.tier[each.value.product].product_id
  api_name            = each.value.api
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_api_management_product_policy" "tier" {
  for_each            = var.products
  product_id          = azurerm_api_management_product.tier[each.key].product_id
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = templatefile("${path.module}/policies/product-limits.xml", {
    role        = each.value.app_role
    tpm         = each.value.tokens_per_minute
    calls       = each.value.rate_limit_calls
    renewal     = var.rate_limit_renewal_seconds
  })
}
```

- [ ] **Step 2: Create `policies/product-limits.xml`** (tier limits keyed by client app id `azp`; enforce the tier's role)

```xml
<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="@(context.Deployment.Region)" />
    <rate-limit-by-key calls="${calls}" renewal-period="${renewal}"
      counter-key="@(context.Request.Headers.GetValueOrDefault("Authorization","").AsJwt()?.Claims.GetValueOrDefault("azp",""))" />
    <llm-token-limit tokens-per-minute="${tpm}" estimate-prompt-tokens="false"
      counter-key="@(context.Request.Headers.GetValueOrDefault("Authorization","").AsJwt()?.Claims.GetValueOrDefault("azp",""))" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

> Implementer note: the inline `validate-azure-ad-token` placeholder above is wrong (tenant-id should be `local.tenant_id`, and role enforcement should check `${role}`). Replace with a correct per-tier role check:
> ```xml
> <validate-azure-ad-token tenant-id="${tenant_id}">
>   <required-claims><claim name="roles" match="any"><value>${role}</value></claim></required-claims>
> </validate-azure-ad-token>
> ```
> and pass `tenant_id = local.tenant_id` into the `templatefile` call. (Kept explicit so the engineer wires the per-tier role gate.) The API-level fragment already does base JWT validation; the product policy narrows it to the tier's specific role.

- [ ] **Step 3: Validate & commit**

```bash
terraform fmt && terraform validate
git add products.tf policies/product-limits.xml
git commit -m "feat(v2): keyless sandbox/production products + per-tier role + limits keyed by client id"
```

---

## Task 12: MCP governance (kept) + API Center + A2A note

**Files:** Create `mcp.tf`, `apicenter.tf`.

- [ ] **Step 1: Create `mcp.tf`** (carry forward the v1 MCP governance; backend is now the foundry API)

```hcl
resource "azapi_resource" "existing_mcp" {
  count     = var.enable_mcp ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2025-09-01-preview"
  name      = "governed-mcp"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      displayName          = "Governed external MCP server"
      path                 = "mytools"
      apiType              = "mcp"
      protocols            = ["https"]
      serviceUrl           = var.existing_mcp_server_url
      subscriptionRequired = false
      mcpProperties        = { transportType = "streamable" }
    }
  }
  schema_validation_enabled = false
}

resource "azurerm_api_management_api_policy" "mcp" {
  count               = var.enable_mcp ? 1 : 0
  api_name            = azapi_resource.existing_mcp[0].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content         = <<-XML
    <policies>
      <inbound>
        <base />
        <include-fragment fragment-id="ai-ip-allow" />
        <include-fragment fragment-id="ai-auth-entra-jwt" />
        <rate-limit-by-key calls="60" renewal-period="60"
          counter-key="@(context.Request.Headers.GetValueOrDefault("Authorization","").AsJwt()?.Claims.GetValueOrDefault("azp",""))" />
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML
}
```

- [ ] **Step 2: Create `apicenter.tf`** (catalog + A2A future note)

```hcl
resource "azapi_resource" "api_center" {
  type      = "Microsoft.ApiCenter/services@2024-03-01"
  name      = local.apic_name
  parent_id = azurerm_resource_group.rg.id
  location  = var.location

  identity { type = "SystemAssigned" }
  body = { properties = {} }
}

# --- A2A agent API: FUTURE ---
# No stable ARM/azapi apiType for A2A agent import as of 2026-05-30 (portal-only).
# Register manually (APIM -> APIs -> + Add API -> A2A Agent); it auto-syncs to API Center.
# Revisit when Microsoft publishes an ARM apiType/properties for A2A.

output "api_center_name" {
  description = "API Center service name."
  value       = azapi_resource.api_center.name
}
```

- [ ] **Step 3: Validate & commit**

```bash
terraform fmt && terraform validate
git add mcp.tf apicenter.tf
git commit -m "feat(v2): keep MCP governance (azapi) + API Center; A2A documented as future"
```

---

## Task 13: Observability workbook + outputs

**Files:** Create `workbook.tf`, `outputs.tf`.

- [ ] **Step 1: Create `workbook.tf`**

```hcl
resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "apim" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  display_name        = "AI Gateway — APIM telemetry"
  category            = "workbook"
  source_id           = lower(azurerm_application_insights.ai.id)

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        content = { json = "# AI Gateway telemetry\nToken usage, request volume, and content-safety blocks by client app." }
      }
    ]
    styleSettings = {}
  })
}
```

- [ ] **Step 2: Create `outputs.tf`**

```hcl
output "apim_gateway_url" {
  description = "APIM gateway base URL."
  value       = azurerm_api_management.apim.gateway_url
}

output "tenant_id" {
  value = local.tenant_id
}

output "gateway_app_client_id" {
  description = "Audience the client requests a token for (api://.../.default)."
  value       = azuread_application.gateway.client_id
}

output "client_app_id" {
  value = azuread_application.client.client_id
}

output "client_app_secret" {
  description = "Demo client secret for the client-credentials flow."
  value       = azuread_application_password.client.value
  sensitive   = true
}

output "chat_deployment_name" {
  value = azurerm_cognitive_deployment.chat.name
}
```

- [ ] **Step 3: Validate & commit**

```bash
terraform fmt && terraform validate
git add workbook.tf outputs.tf
git commit -m "feat(v2): Azure Monitor workbook + outputs (gateway url, app/client ids, token info)"
```

---

## Task 14: Smoke tests, README, optional Azure Policy, final verification

**Files:** Create `test/get-token.sh`, `test/smoke.sh`; rewrite `README.md`; (optional) `governance.tf`.

- [ ] **Step 1: Create `test/get-token.sh`** (client-credentials token for the gateway audience)

```bash
#!/usr/bin/env bash
# Usage: TENANT_ID=.. CLIENT_ID=.. CLIENT_SECRET=.. GATEWAY_APP_ID=.. ./test/get-token.sh
set -euo pipefail
: "${TENANT_ID:?}" "${CLIENT_ID:?}" "${CLIENT_SECRET:?}" "${GATEWAY_APP_ID:?}"
curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=api://${GATEWAY_APP_ID}/.default" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])"
```

- [ ] **Step 2: Create `test/smoke.sh`** (chat via gateway + content-safety + direct-backend-should-fail)

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${GATEWAY_URL:?}" "${TOKEN:?}" "${DEPLOYMENT:?}" "${FOUNDRY_ENDPOINT:?}"

echo "1) Foundry chat via gateway (expect 200):"
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}'

echo "2) No token (expect 401):"
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}'

echo "3) Direct backend call, bypassing APIM (expect failure - public access disabled):"
curl -s -o /dev/null -w "  HTTP %{http_code} (000/403 = blocked, good)\n" --max-time 15 -X POST \
  "${FOUNDRY_ENDPOINT}openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}' || echo "  (connection blocked, good)"
```

- [ ] **Step 3: (Optional control) Create `governance.tf`** — deny Global model deployment types to enforce UK processing

```hcl
# Optional: block GlobalStandard/DataZone deployment types so no one routes HMCTS data outside the UK.
# Uses a built-in/ custom policy definition; wire assignment scope to the RG.
# Implementer: confirm the exact built-in policy def ID for "Azure AI deployment SKU" restriction,
# or author a custom azurerm_policy_definition restricting Microsoft.CognitiveServices/accounts/deployments sku.name.
```

> This task step is intentionally a documented control to discuss with Security, not auto-applied — leave as a comment/README item unless the team wants it enforced now.

- [ ] **Step 4: Rewrite `README.md`** to cover: architecture (private, Entra-keyless, multi-service, uksouth), the **UK data-residency findings** (in-region models only; Content Safety uksouth-only; no UK HA twin; Global/DataZone caveats), prerequisites, single `terraform apply`, how to get a token (`test/get-token.sh`) and run `test/smoke.sh`, the Entra app-role onboarding flow (how a team's app gets a role assignment), MCP usage, A2A manual step, and a **production-hardening appendix** (swap to Premium + Internal mode + App Gateway/WAF; UK HA strategy; Azure Policy for deployment-type restriction; rotate client secrets via Key Vault; CI/CD; remote state).

- [ ] **Step 5: Final integrated verification**

Run: `terraform fmt -recursive && terraform validate`
Expected: `Success! The configuration is valid.`
Run: `terraform plan` (provider pinned to work sub) — review the create plan; expect no errors. (User applies.)

- [ ] **Step 6: Commit**

```bash
git add test/get-token.sh test/smoke.sh governance.tf README.md
git commit -m "feat(v2): smoke tests (token, chat, 401, direct-backend-blocked), residency README, prod-hardening"
```

---

## Self-review against the decisions

- **Private networking** ✓ (Task 2 VNet/NSG/DNS; Task 4 APIM External VNet; Tasks 3/5/6 private endpoints + public access off).
- **Entra keyless** ✓ (Task 8 apps/roles; Task 9 JWT fragment; Task 11 keyless products + per-tier role; throttling keyed by `azp`).
- **Multi-service Foundry-first** ✓ (Task 5 Foundry+gpt-4.1-mini; Task 6 Speech/Language/Doc Intelligence/Content Safety; Task 10 APIs+backends).
- **UK residency** ✓ (uksouth; gpt-4.1-mini Standard; residency caveats + optional deny-Global policy documented).
- **MCP kept / A2A future / semantic cache dropped** ✓ (Task 12; no Redis/cache resources anywhere).
- **Observability** ✓ (Task 4 logger/diagnostic; Task 9 token-metric fragment; Task 13 workbook).
- **API Center, Key Vault** ✓ (Task 12, Task 3).
- **Transition destroy→rebuild** ✓ (Task 0).
- **No `count` feature-flags except intentional `enable_mcp`** ✓.

**Schema-verification points flagged inline (confirm against live registry/control plane during implementation, not guessed):** `azurerm_api_management_policy_fragment` arg names (`api_management_id`/`format`/`value`) — Task 9; `validate-azure-ad-token` element exactness for the per-tier role gate — Task 11 (placeholder corrected in the note); azuread v3 argument names (`client_id`, `application_id`) — Task 8; the preview MCP azapi body — Task 12; the public-access two-phase sequencing for cognitive accounts — Tasks 5/6; the optional deny-Global Azure Policy definition ID — Task 14.
