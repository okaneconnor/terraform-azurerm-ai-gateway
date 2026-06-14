resource "azurerm_cognitive_account" "foundry" {
  #checkov:skip=CKV2_AZURE_22:Uses Microsoft-managed keys by design; customer-managed key encryption (a KV key + identity wiring) is a consumer/org choice, not forced by this generic module.
  name                  = local.foundry_name
  location              = local.resource_group_location
  resource_group_name   = local.resource_group_name
  kind                  = "AIServices"
  sku_name              = var.foundry_account_sku
  custom_subdomain_name = local.foundry_name
  tags                  = var.tags

  local_auth_enabled = false

  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "model" {
  for_each             = var.model_deployments
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = each.value.model_format
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

# Embeddings backend used by llm-semantic-cache-lookup to vectorise prompts.
resource "azurerm_api_management_backend" "embeddings" {
  #checkov:skip=CKV_AZURE_215:"protocol" is the APIM backend type (http|soap), not the wire scheme — the url is the private HTTPS Foundry endpoint reached over TLS.
  count               = var.semantic_cache.enabled ? 1 : 0
  name                = "embeddings-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = local.resource_group_name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.foundry.endpoint}openai/deployments/${var.semantic_cache.embeddings_deployment}/embeddings"

  depends_on = [azurerm_cognitive_deployment.model]
}
