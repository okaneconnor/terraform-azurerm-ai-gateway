# Versioned facade: /v1/chat/completions — canonical model names (model_map),
# gateway-pinned api-version, stable error taxonomy. See docs/usage.md.

resource "azurerm_api_management_api" "facade" {
  name                  = "ai-gateway-v1"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = local.resource_group_name
  revision              = "1"
  display_name          = "AI Gateway v1"
  path                  = "v1"
  protocols             = ["https"]
  subscription_required = false

  import {
    content_format = "openapi"
    content_value  = file("${path.module}/specs/ai-gateway-v1.yaml")
  }
}

resource "azurerm_api_management_api_policy" "facade" {
  api_name            = azurerm_api_management_api.facade.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = local.resource_group_name
  xml_content = templatefile("${path.module}/policies/api-facade.xml", {
    model_map              = local.effective_model_map
    api_version            = var.aoai_api_version
    content_safety_enabled = var.content_safety.enabled
    semantic_cache_enabled = var.semantic_cache.enabled
    score_threshold        = var.semantic_cache.score_threshold
    cache_duration         = var.semantic_cache.duration_seconds
  })

  depends_on = [
    azurerm_api_management_policy_fragment.ip_allow,
    azurerm_api_management_policy_fragment.entra_jwt,
    azurerm_api_management_policy_fragment.tier_rate,
    azurerm_api_management_policy_fragment.tier_tokens,
    azurerm_api_management_policy_fragment.backend_mi,
    azurerm_api_management_policy_fragment.content_safety,
    azurerm_api_management_policy_fragment.token_metric,
    azurerm_api_management_policy_fragment.error_taxonomy,
    azapi_resource.foundry_pool,
    azurerm_api_management_backend.embeddings,
    azurerm_api_management_redis_cache.cache,
  ]
}
