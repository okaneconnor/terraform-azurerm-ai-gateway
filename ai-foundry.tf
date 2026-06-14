# Two-phase workaround: if apply locks Terraform out, set public_network_access_enabled = true,
# apply, attach the private endpoint, then flip back to false in a second apply.

resource "azurerm_cognitive_account" "foundry" {
  name                  = local.foundry_name
  location              = local.resource_group_location
  resource_group_name   = local.resource_group_name
  kind                  = "AIServices" # unified Foundry account (OpenAI + multi-service); required for the model + embeddings deployments
  sku_name              = var.foundry_account_sku
  custom_subdomain_name = local.foundry_name
  tags                  = var.tags

  # Entra-only: the gateway authenticates with its managed identity, so account
  # keys are an unused second credential plane — keep them disabled.
  local_auth_enabled = false

  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

# Consumer-chosen model deployments (any model/SKU/capacity the region offers).
# Concurrent deployments to one account can 409 transiently; re-apply or use
# -parallelism=1 if that occurs.
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
