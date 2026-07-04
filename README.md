# terraform-azurerm-ai-gateway

A reusable Terraform module for a **private, keyless, multi-service Azure AI gateway**
built on Azure API Management. Clients authenticate with an Entra ID token
(client-credentials, app-role gated) — no subscription keys, no API keys anywhere. All
AI backends are private-endpoint only.

Licensed under the [MIT License](LICENSE).

## Features

- **APIM (VNet-injected, External or Internal)** fronting Azure AI Foundry (OpenAI)
  plus any set of Cognitive Services you choose — all reached over private endpoints
  with the gateway's managed identity.
- **Keyless tiering** — consumption tiers are Entra app roles; rate and token limits
  render from one `tiers` map. Adding a tier is one map entry.
- **AI gateway policies** — prompt screening (Content Safety + Prompt Shield) on
  *every* prompt, semantic caching (Azure Managed Redis + RediSearch) partitioned per
  client, per-client token metrics for chargeback, circuit-broken backend pool.
- **Governance** — Azure Policy allowlist for model-deployment SKUs (data-residency
  guardrail), API Center cataloguing, full Log Analytics / App Insights observability
  including per-request LLM token logs.
- **Nothing hardcoded** — every SKU, size, capacity, region, name, threshold, and
  toggle is a variable; most carry a sensible default. Set `location`, publisher info,
  and your `model_deployments` (the module ships no default model — you choose current,
  non-deprecating models for your region); override anything else as needed.
- **Composable for landing zones** — bring your own resource group, VNet/subnets,
  private DNS zones, Log Analytics workspace, App Insights, or Entra gateway app, or
  let the module create them. Every optional component toggles independently.

## Usage

As a consumer you write a small root module that **configures the providers** (the
module only pins `required_providers` — the caller owns provider config) and calls
`ai_gateway` by `source`:

```hcl
# versions.tf
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.74" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    azapi   = { source = "azure/azapi", version = "~> 2.0" }
  }
}

# providers.tf
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
provider "azuread" {}
provider "azapi" {}

# main.tf
module "ai_gateway" {
  source = "github.com/okaneconnor/ai-gateway" # pin to a release for production: ?ref=v1.0.0

  location        = "uksouth"
  publisher_name  = "AI Platform Team"
  publisher_email = "platform@example.com"

  # Required — the module ships no default model. Choose current, non-deprecating
  # models for your region. gpt-5.4-mini is only offered on GlobalStandard, so the
  # SKU allowlist below must permit it (GlobalStandard leaves the deployment region;
  # use a Standard-SKU model to keep inference in-region).
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
  semantic_cache        = { embeddings_deployment = "text-embedding-3-small" }
  deployment_sku_policy = { allowed_sku_names = ["Standard", "GlobalStandard"] }
}
```

```bash
terraform init
terraform apply -var subscription_id=<sub-id>   # APIM VNet provisioning takes ~30-45 min
```

`location`, publisher info, and `model_deployments` are the required inputs — every
other knob is optional with a sensible default (see [Inputs](#inputs)), so this deploys
the full secure stack. Once it is up, a client requests an Entra token
(client-credentials, app-role gated) and calls the gateway. For getting a token,
onboarding a team, and the end-to-end tests, see the **[usage guide](docs/usage.md)**.

> You need Entra permissions to create app registrations (or set `existing_gateway_app`
> to bring your own). Terraform >= 1.9.

### Complete example

A fuller configuration exercising the common knobs. Apart from `model_deployments`
(required), every argument below is optional with a sensible default — set only what
you need to override. See the
[Inputs](#inputs) reference for the full list (including bring-your-own / landing-zone
inputs such as `existing_network`, `existing_resource_group_name`, and
`existing_private_dns_zone_ids`).

```hcl
module "ai_gateway" {
  source = "github.com/okaneconnor/ai-gateway"

  location        = var.location
  name_prefix     = var.name_prefix
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email
  tags            = var.tags

  # API Management
  apim_sku_name             = var.apim_sku_name
  apim_virtual_network_type = var.apim_virtual_network_type
  apim_diagnostic = {
    sampling_percentage = var.apim_sampling_percentage
  }
  allowed_client_cidrs = var.allowed_client_cidrs

  # Models
  foundry_account_sku = var.foundry_account_sku
  model_deployments   = var.model_deployments

  # Tiers
  tiers = var.tiers

  # AI gateway policies
  semantic_cache = {
    enabled           = var.semantic_cache_enabled
    redis_sku_name    = var.redis_sku_name
    high_availability = var.redis_high_availability
    score_threshold   = var.semantic_cache_score_threshold
    duration_seconds  = var.semantic_cache_duration_seconds
  }

  content_safety = {
    enabled            = var.content_safety_enabled
    category_threshold = var.content_safety_category_threshold
  }

  circuit_breaker = {
    trip_on_429 = var.circuit_breaker_trip_on_429
  }

  deployment_sku_policy = {
    allowed_sku_names = var.allowed_deployment_skus
  }

  # Key Vault
  key_vault = {
    enabled                    = var.key_vault_enabled
    sku_name                   = var.key_vault_sku_name
    soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  }

  # Observability
  log_analytics_sku  = var.log_analytics_sku
  log_retention_days = var.log_retention_days

  # Toggles
  enable_api_center   = var.enable_api_center
  enable_workbook     = var.enable_workbook
  create_demo_clients = var.create_demo_clients
}
```

## Documentation

| Page | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture diagram, keyless/tiering model, policy chain, data residency, resilience & caching |
| [docs/usage.md](docs/usage.md) | Deploy, bring-your-own / landing-zone adoption, get a token, onboard a team, live tests |
| [docs/operations.md](docs/operations.md) | Deployment gotchas, A2A agents, production hardening, cost, linting & scanning |

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9.0 |
| azapi | ~> 2.0 |
| azuread | ~> 3.0 |
| azurerm | ~> 4.74 |
| random | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| azapi | ~> 2.0 |
| azuread | ~> 3.0 |
| azurerm | ~> 4.74 |
| random | ~> 3.6 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azapi_resource.api_center](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.apic_apim_source](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.apim_azuremonitor_logger](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.foundry_member](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.foundry_pool](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.llm_diagnostic](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_update_resource.appinsights_custom_metrics](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/update_resource) | resource |
| [azuread_app_role_assignment.demo](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/app_role_assignment) | resource |
| [azuread_application.demo](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application) | resource |
| [azuread_application.gateway](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application) | resource |
| [azuread_application_password.demo](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application_password) | resource |
| [azuread_service_principal.demo](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/service_principal) | resource |
| [azuread_service_principal.gateway](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/service_principal) | resource |
| [azurerm_api_management.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management) | resource |
| [azurerm_api_management_api.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_api) | resource |
| [azurerm_api_management_api.svc](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_api) | resource |
| [azurerm_api_management_api_operation.svc_wildcard](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_api_operation) | resource |
| [azurerm_api_management_api_policy.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_api_policy) | resource |
| [azurerm_api_management_api_policy.svc](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_api_policy) | resource |
| [azurerm_api_management_backend.embeddings](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_backend) | resource |
| [azurerm_api_management_backend.svc](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_backend) | resource |
| [azurerm_api_management_diagnostic.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_diagnostic) | resource |
| [azurerm_api_management_logger.appinsights](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_logger) | resource |
| [azurerm_api_management_policy_fragment.backend_mi](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_policy_fragment.content_safety](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_policy_fragment.entra_jwt](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_policy_fragment.ip_allow](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_policy_fragment.tier_rate](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_policy_fragment.tier_tokens](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_policy_fragment.token_metric](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_policy_fragment) | resource |
| [azurerm_api_management_redis_cache.cache](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/api_management_redis_cache) | resource |
| [azurerm_application_insights.ai](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights) | resource |
| [azurerm_application_insights_workbook.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights_workbook) | resource |
| [azurerm_cognitive_account.foundry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_account) | resource |
| [azurerm_cognitive_account.svc](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_account) | resource |
| [azurerm_cognitive_deployment.model](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cognitive_deployment) | resource |
| [azurerm_key_vault.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault) | resource |
| [azurerm_log_analytics_workspace.law](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace) | resource |
| [azurerm_managed_redis.cache](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/managed_redis) | resource |
| [azurerm_monitor_diagnostic_setting.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_network_security_group.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_policy_definition.allowed_deployment_skus](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/policy_definition) | resource |
| [azurerm_private_dns_zone.zone](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone) | resource |
| [azurerm_private_dns_zone_virtual_network_link.link](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_endpoint.pe](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_resource_group.rg](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group_policy_assignment.allowed_deployment_skus](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_policy_assignment) | resource |
| [azurerm_role_assignment.apic_apim_reader](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.apim_foundry_openai](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.apim_kv_secrets](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.apim_svc](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_subnet.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet.pe](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) | resource |
| [azurerm_subnet_network_security_group_association.apim](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) | resource |
| [azurerm_virtual_network.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network) | resource |
| [random_string.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [random_uuid.role](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/uuid) | resource |
| [random_uuid.workbook](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/uuid) | resource |
| [azuread_client_config.current](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/data-sources/client_config) | data source |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_location.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/location) | data source |
| [azurerm_resource_group.existing](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| location | Azure region for all resources. Choose a region where your chat + embeddings models are available with the deployment SKUs you allow (see deployment\_sku\_policy). | `string` | n/a | yes |
| model\_deployments | Model deployments created on the Foundry (AIServices) account, keyed by<br/>deployment name (the key becomes the /openai/deployments/<name> path segment).<br/>REQUIRED — the module ships no default model: Azure deprecates model versions<br/>over time and SKU/region availability varies, so choosing current models is the<br/>consumer's responsibility. If semantic\_cache is enabled, include the embeddings<br/>model named by semantic\_cache.embeddings\_deployment. model\_format defaults to<br/>OpenAI (set e.g. "Meta"/"Mistral" for those). Each sku\_name must be in<br/>deployment\_sku\_policy.allowed\_sku\_names while that policy is enabled. Concurrent<br/>deployments to one account can 409 transiently — re-apply or use -parallelism=1. | <pre>map(object({<br/>    model_name    = string<br/>    model_version = string<br/>    sku_name      = optional(string, "Standard")<br/>    capacity      = optional(number, 10)<br/>    model_format  = optional(string, "OpenAI")<br/>  }))</pre> | n/a | yes |
| publisher\_email | APIM publisher email. | `string` | n/a | yes |
| publisher\_name | APIM publisher name (shown in the developer portal). | `string` | n/a | yes |
| ai\_services | Cognitive Services exposed as passthrough APIs through the gateway, keyed by a<br/>short identifier. Add/remove/resize services freely — each entry creates the<br/>account (private, Entra-only), a private endpoint, an APIM backend + API with<br/>the standard policy chain (IP filter -> JWT -> rate limit -> managed identity).<br/>NOTE: content\_safety.enabled requires an entry whose kind is "ContentSafety". | <pre>map(object({<br/>    kind         = string<br/>    sku_name     = string<br/>    display_name = string<br/>    api_path     = string<br/>    short_name   = string # used in resource names; keep it brief<br/>  }))</pre> | <pre>{<br/>  "docintel": {<br/>    "api_path": "docintel",<br/>    "display_name": "Document Intelligence",<br/>    "kind": "FormRecognizer",<br/>    "short_name": "doci",<br/>    "sku_name": "S0"<br/>  },<br/>  "language": {<br/>    "api_path": "language",<br/>    "display_name": "Language",<br/>    "kind": "TextAnalytics",<br/>    "short_name": "lang",<br/>    "sku_name": "S"<br/>  },<br/>  "safety": {<br/>    "api_path": "contentsafety",<br/>    "display_name": "Content Safety",<br/>    "kind": "ContentSafety",<br/>    "short_name": "cs",<br/>    "sku_name": "S0"<br/>  },<br/>  "speech": {<br/>    "api_path": "speech",<br/>    "display_name": "Speech",<br/>    "kind": "SpeechServices",<br/>    "short_name": "spch",<br/>    "sku_name": "S0"<br/>  }<br/>}</pre> | no |
| allowed\_client\_cidrs | Client CIDRs allowed through the gateway's IP filter (e.g. office egress ranges). The default allows all — tighten before real use; Entra JWT auth remains mandatory regardless. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| apim\_diagnostic | APIM Application Insights diagnostic tuning. sampling\_percentage 100 captures every request (lower it to cut cost/volume at scale); verbosity is information \| verbose \| error. | <pre>object({<br/>    sampling_percentage = optional(number, 100)<br/>    verbosity           = optional(string, "information")<br/>  })</pre> | `{}` | no |
| apim\_sku\_name | APIM SKU (name\_capacity). Default Developer\_1 (cheap, no SLA, no zones).<br/>VNet INJECTION (this module's private model) is supported ONLY on classic<br/>Developer and Premium — NOT on classic Basic/Standard.<br/>For production use Premium\_1+ (SLA, zone redundancy, multi-region). | `string` | `"Developer_1"` | no |
| apim\_virtual\_network\_type | APIM VNet injection mode. "External" (default) gives APIM a public gateway IP<br/>inside the VNet. "Internal" removes the public endpoint entirely (no public<br/>gateway IP) — front it with Application Gateway / WAF for ingress and make sure<br/>your DNS resolves the internal gateway and the APIM subnet NSG permits it. | `string` | `"External"` | no |
| circuit\_breaker | Circuit breaker on the Foundry backend. Default trips on 5xx only: with a<br/>single-member pool, tripping on 429 lets one bursty client 503 the whole<br/>gateway for trip\_duration (Microsoft's sample pattern does include 429 —<br/>set trip\_on\_429 = true if you run a multi-member pool where failover helps). | <pre>object({<br/>    enabled            = optional(bool, true)<br/>    failure_count      = optional(number, 3)<br/>    interval           = optional(string, "PT1M")<br/>    trip_duration      = optional(string, "PT1M")<br/>    trip_on_429        = optional(bool, false)<br/>    accept_retry_after = optional(bool, true)<br/>  })</pre> | `{}` | no |
| content\_safety | Prompt screening via llm-content-safety (+ Prompt Shield). Runs BEFORE the semantic cache so every prompt is screened, including ones answered from cache. Requires an ai\_services entry of kind ContentSafety. | <pre>object({<br/>    enabled            = optional(bool, true)<br/>    shield_prompt      = optional(bool, true)<br/>    category_threshold = optional(number, 4) # 0-7; blocks at >= threshold severity<br/>  })</pre> | `{}` | no |
| create\_demo\_clients | Create one demo client app (with secret) per tier, role-assigned to that tier — handy for testing the gateway end-to-end. Off by default so real deployments don't ship unused credentials. Requires the module-created gateway app (not BYO). | `bool` | `false` | no |
| deployment\_sku\_policy | Azure Policy guardrail denying model-deployment SKUs outside the allowlist.<br/>The default ["Standard"] keeps inference in-region (data residency): Global*/<br/>DataZone* SKUs process data outside the deployment region and are denied.<br/>Extend the list (e.g. "ProvisionedManaged", "Batch") if regional processing<br/>under those SKUs fits your residency requirements. | <pre>object({<br/>    enabled           = optional(bool, true)<br/>    allowed_sku_names = optional(list(string), ["Standard"])<br/>  })</pre> | `{}` | no |
| enable\_api\_center | Deploy an API Center service that continuously catalogues the gateway's APIs. | `bool` | `true` | no |
| enable\_workbook | Deploy the Azure Monitor workbook (token usage by client app, request volume). | `bool` | `true` | no |
| existing\_application\_insights | Bring-your-own Application Insights for APIM request/token telemetry. When set the module uses it instead of creating one (needs both the resource id and its connection string). Leave null to create one wired to the workspace. | <pre>object({<br/>    id                = string<br/>    connection_string = string<br/>  })</pre> | `null` | no |
| existing\_gateway\_app | Bring-your-own gateway app registration for tenants where Entra app creation<br/>is restricted. The app must: be single-tenant, request v2 access tokens, and<br/>define one Application app role per tier whose `value` matches tiers[*].app\_role.<br/>Leave null (default) and the module creates and wires the app itself. | <pre>object({<br/>    client_id = string<br/>  })</pre> | `null` | no |
| existing\_log\_analytics\_workspace\_id | Bring-your-own Log Analytics workspace (Azure resource ID) for diagnostics — common when an org centralises logs. Leave null to create one. | `string` | `null` | no |
| existing\_network | Bring-your-own VNet and subnets (landing-zone / hub-spoke adoption). When set,<br/>the module does NOT create the VNet, subnets, or NSG — it injects APIM into<br/>apim\_subnet\_id and places private endpoints in pe\_subnet\_id. You are then<br/>responsible for the APIM subnet's NSG rules (see README) and for the subnets<br/>being adequately sized and delegated. Leave null to create an isolated VNet<br/>from var.network. | <pre>object({<br/>    vnet_id        = string<br/>    apim_subnet_id = string<br/>    pe_subnet_id   = string<br/>  })</pre> | `null` | no |
| existing\_private\_dns\_zone\_ids | Bring-your-own private DNS zones (hub-managed DNS). Map keyed by zone role —<br/>keys: cognitive, openai, aiservices, keyvault, redis — each a private DNS zone<br/>resource ID. When non-empty the module does NOT create any private DNS zones or<br/>VNet links and uses these IDs for private-endpoint DNS groups; provide every key<br/>for the backends you deploy. Leave empty to create + link them. | `map(string)` | `{}` | no |
| existing\_resource\_group\_name | Deploy into an existing resource group (landing-zone pattern) instead of creating one. The RG must already exist and be in var.location. Leave null to create one named <name\_prefix>-<region>-rg. | `string` | `null` | no |
| foundry\_account\_sku | SKU for the Foundry (AIServices) Cognitive account that hosts your model deployments. | `string` | `"S0"` | no |
| key\_vault | Optional private Key Vault (RBAC, purge protection, private endpoint) for<br/>consumer workloads' secrets — the gateway itself stores nothing in it. Set<br/>enabled=false to skip. SKU / retention / purge-protection are tunable for org<br/>policy (e.g. premium for HSM-backed keys). | <pre>object({<br/>    enabled                    = optional(bool, true)<br/>    sku_name                   = optional(string, "standard")<br/>    soft_delete_retention_days = optional(number, 90)<br/>    purge_protection_enabled   = optional(bool, true)<br/>  })</pre> | `{}` | no |
| log\_analytics\_sku | SKU for the module-created Log Analytics workspace (ignored when existing\_log\_analytics\_workspace\_id is set). | `string` | `"PerGB2018"` | no |
| log\_retention\_days | Retention for the module-created Log Analytics workspace. | `number` | `30` | no |
| name\_prefix | Short lowercase prefix for resource names (e.g. "aigw", "contoso-ai"). | `string` | `"aigw"` | no |
| name\_suffix | Override the random 5-char suffix appended to most resource names. Set this for deterministic / standards-compliant names (some orgs forbid randomness in names). Leave null to generate one. | `string` | `null` | no |
| network | VNet and subnet CIDRs for the module-created network. Ignored when existing\_network is set. APIM is injected into the apim subnet; all backends are reached via private endpoints in the pe subnet. | <pre>object({<br/>    vnet_cidr        = optional(string, "10.90.0.0/16")<br/>    apim_subnet_cidr = optional(string, "10.90.1.0/24")<br/>    pe_subnet_cidr   = optional(string, "10.90.2.0/24")<br/>  })</pre> | `{}` | no |
| rate\_limit\_renewal\_seconds | Fixed-window length for the per-tier request rate limit. | `number` | `60` | no |
| semantic\_cache | Semantic caching of LLM completions in Azure Managed Redis (RediSearch),<br/>partitioned per client app. score\_threshold: lower = stricter similarity.<br/>embeddings\_deployment must name a key in model\_deployments (an embeddings<br/>model used to vectorise prompts). Set enabled=false to skip Redis entirely;<br/>set high\_availability=true for a production (replicated) cache. | <pre>object({<br/>    enabled               = optional(bool, true)<br/>    redis_sku_name        = optional(string, "Balanced_B0")<br/>    high_availability     = optional(bool, false)<br/>    score_threshold       = optional(number, 0.05)<br/>    duration_seconds      = optional(number, 120)<br/>    embeddings_deployment = optional(string, "text-embedding-ada-002")<br/>  })</pre> | `{}` | no |
| tags | Tags applied to all taggable resources. | `map(string)` | `{}` | no |
| tiers | Self-service consumption tiers (keyless model: limits keyed by the caller's<br/>Entra client app id). Each tier becomes an Entra app role on the gateway app<br/>AND a branch in the rate/token-limit policies, so adding an entry here is the<br/>complete change. Tokens-per-minute also bounds spend per client.<br/>The JWT policy admits only tokens carrying one of these app roles; when a<br/>client holds several, the highest tokens\_per\_minute tier wins. | <pre>map(object({<br/>    display_name      = string<br/>    app_role          = string<br/>    tokens_per_minute = number<br/>    rate_limit_calls  = number<br/>  }))</pre> | <pre>{<br/>  "ai-production-standard": {<br/>    "app_role": "AI.Gateway.Production",<br/>    "display_name": "AI Production Standard",<br/>    "rate_limit_calls": 120,<br/>    "tokens_per_minute": 150000<br/>  },<br/>  "ai-sandbox": {<br/>    "app_role": "AI.Gateway.Sandbox",<br/>    "display_name": "AI Sandbox",<br/>    "rate_limit_calls": 30,<br/>    "tokens_per_minute": 20000<br/>  }<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| api\_center\_id | API Center service resource ID (null when enable\_api\_center = false). |
| api\_center\_name | API Center service name (null when enable\_api\_center = false). |
| apim\_gateway\_url | APIM gateway base URL. |
| apim\_id | APIM service resource ID. |
| apim\_name | APIM service name. |
| apim\_principal\_id | APIM system-assigned managed identity principal ID — grant it roles on your own resources (e.g. additional Cognitive accounts) to extend the gateway. |
| apim\_subnet\_id | Subnet APIM is injected into. |
| application\_insights\_connection\_string | Application Insights connection string for consumer apps that want to correlate telemetry. |
| application\_insights\_id | Application Insights resource ID (module-created or bring-your-own). |
| demo\_clients | Demo client credentials per tier (only when create\_demo\_clients = true). Map of tier key -> { client\_id, client\_secret }. |
| foundry\_account\_name | Foundry (AIServices) account name. |
| foundry\_endpoint | Foundry account endpoint (private; resolvable only inside the VNet). |
| foundry\_id | Foundry (AIServices) account resource ID. |
| gateway\_app\_client\_id | Audience clients request tokens for (scope: <client\_id>/.default). |
| key\_vault\_id | Key Vault resource ID (null when key\_vault.enabled = false). |
| key\_vault\_uri | Key Vault URI for consumer workloads (null when key\_vault.enabled = false). |
| log\_analytics\_workspace\_guid | Log Analytics customer/workspace GUID for KQL queries (ApiManagementGatewayLogs / ApiManagementGatewayLlmLog). Null when bringing your own workspace. |
| log\_analytics\_workspace\_resource\_id | Log Analytics workspace ARM resource ID (module-created or bring-your-own). |
| model\_deployment\_names | Deployment names exposed at /openai/deployments/<name>/... on the gateway. |
| pe\_subnet\_id | Subnet holding the private endpoints. |
| private\_dns\_zone\_ids | Map of private DNS zone role -> resource ID (module-created or bring-your-own). Link these from a hub if you run hub-and-spoke DNS. |
| resource\_group\_id | Resource group resource ID. |
| resource\_group\_name | Resource group containing the gateway stack. |
| tenant\_id | Entra tenant the gateway app lives in. |
| vnet\_id | VNet the gateway is injected into (module-created or bring-your-own) — use for peering. |
<!-- END_TF_DOCS -->

## Testing

```bash
terraform init -backend=false && terraform test   # 20 plan-mode unit tests, mocked providers, no Azure creds
```

Live end-to-end tests (auth, content safety, cache, tiers, residency) run against a
live deployment of the module with `create_demo_clients = true` — see
[docs/usage.md](docs/usage.md#tests).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local checks (fmt / validate / test /
scan), the pre-commit hooks, and how to regenerate the docs block. Changes are tracked
in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE).
