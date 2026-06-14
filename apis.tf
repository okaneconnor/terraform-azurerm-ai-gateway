# One APIM backend per AI service. The API policy references the backend by this
# resource's name, so adding an ai_services entry wires account -> backend -> API
# -> policy in one change with real dependency edges (no free-text coupling).
resource "azurerm_api_management_backend" "svc" {
  #checkov:skip=CKV_AZURE_215:"protocol" is the APIM backend type (http|soap), not the wire scheme — the url is the private HTTPS Cognitive Services endpoint reached over TLS.
  for_each            = var.ai_services
  name                = "${each.key}-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = local.resource_group_name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc[each.key].endpoint, "/")
}

resource "azurerm_api_management_api" "foundry" {
  name                  = "foundry-openai"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = local.resource_group_name
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
  resource_group_name = local.resource_group_name
  xml_content = templatefile("${path.module}/policies/api-foundry.xml", {
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
    azapi_resource.foundry_pool,
    azurerm_api_management_backend.embeddings,
    azurerm_api_management_redis_cache.cache,
  ]
}

resource "azurerm_api_management_api" "svc" {
  for_each              = var.ai_services
  name                  = "ai-${each.key}"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = local.resource_group_name
  revision              = "1"
  display_name          = each.value.display_name
  path                  = each.value.api_path
  protocols             = ["https"]
  subscription_required = false
}

resource "azurerm_api_management_api_policy" "svc" {
  for_each            = var.ai_services
  api_name            = azurerm_api_management_api.svc[each.key].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = local.resource_group_name
  xml_content = templatefile("${path.module}/policies/api-aiservice.xml", {
    backend_id = azurerm_api_management_backend.svc[each.key].name
  })

  depends_on = [
    azurerm_api_management_policy_fragment.ip_allow,
    azurerm_api_management_policy_fragment.entra_jwt,
    azurerm_api_management_policy_fragment.tier_rate,
    azurerm_api_management_policy_fragment.backend_mi,
  ]
}
