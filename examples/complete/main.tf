# examples/complete — deploy the full private, keyless Azure AI gateway.
#
# With just the required inputs (location, publisher, model_deployments) plus a
# couple of overrides, this stands up the ENTIRE stack: a VNet-injected APIM gateway
# with mandatory Entra (keyless) auth, an Azure AI Foundry account with your model
# deployments, per-tier rate/token limits (two Entra app roles), four Cognitive
# Services exposed as authenticated passthrough APIs, inbound content safety (Prompt
# Shield), a private RBAC Key Vault, a data-residency policy, and Log Analytics +
# Application Insights + workbook. Anything not set below uses a sensible module
# default — see the module README "Inputs" for the full list.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.74" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    azapi   = { source = "azure/azapi", version = "~> 2.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

# The caller owns provider configuration — the module only pins required_providers.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
provider "azuread" {}
provider "azapi" {}

module "ai_gateway" {
  # Local path for this in-repo example. When consuming the published module use:
  #   source = "github.com/okaneconnor/ai-gateway?ref=v1.0.0"
  source = "../.."

  location        = "uksouth"
  publisher_name  = "Contoso AI Platform"
  publisher_email = "ai-platform@contoso.com"

  # REQUIRED — the module ships no default model (Azure deprecates versions over
  # time). Pin current models + versions you hold quota for. gpt-5.4-mini is only
  # offered on GlobalStandard, so the residency allowlist below must permit it.
  model_deployments = {
    "gpt-5.4-mini" = {
      model_name    = "gpt-5.4-mini"
      model_version = "2026-03-17"
      sku_name      = "GlobalStandard"
      capacity      = 50
    }
    "text-embedding-3-small" = {
      model_name    = "text-embedding-3-small"
      model_version = "1"
      sku_name      = "Standard"
      capacity      = 50
    }
  }

  # Allow GlobalStandard (required by current chat models); Standard keeps embeddings
  # in-region. Every model_deployments SKU is validated against this list at plan time.
  deployment_sku_policy = { allowed_sku_names = ["Standard", "GlobalStandard"] }

  # Point the (opt-in) semantic cache at the embeddings deployment above.
  semantic_cache = { embeddings_deployment = "text-embedding-3-small" }

  # One ready-made test client per tier (with a secret) so you can run the end-to-end
  # smoke tests immediately. Set false for real deployments.
  create_demo_clients = true

  tags = { environment = "example", workload = "ai-gateway" }

  # Everything else is a sensible default and deploys the full gateway:
  #   tiers                     → AI Sandbox (30 req/min) + AI Production (120 req/min)
  #   ai_services               → Content Safety, Speech, Language, Document Intelligence
  #   content_safety            → enabled (Prompt Shield screens every prompt)
  #   apim_sku_name             → Developer_1 (use Premium_N + apim_zones for production)
  #   apim_virtual_network_type → External   (set "Internal" for a fully private gateway)
  #   key_vault / monitoring / governance / circuit_breaker → on
  #   semantic_cache.enabled    → false (opt-in; see this example's README)
}
