module "ai_gateway" {
  #checkov:skip=CKV_TF_1:Registry source pinned by version constraint; commit hashes apply to git sources.

  source  = "okaneconnor/ai-gateway/azurerm"
  version = "~> 2.0"

  location        = "uksouth"
  publisher_name  = "Contoso AI Platform"
  publisher_email = "ai-platform@contoso.com"

  # REQUIRED — the module ships no default model
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

  deployment_sku_policy = { allowed_sku_names = ["Standard", "GlobalStandard"] }
  semantic_cache        = { embeddings_deployment = "text-embedding-3-small" }
  create_demo_clients   = true

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
