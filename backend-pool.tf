# Additional load-balanced pool members that the module provisions (create_account).
# BYO members (endpoint_url) don't create accounts here — only backends (resilience.tf).

resource "azurerm_cognitive_account" "member" {
  #checkov:skip=CKV2_AZURE_22:Microsoft-managed keys by design; CMK is a consumer/org choice, not forced by this generic module.
  for_each              = local.created_members
  name                  = local.member_account_name[each.key]
  location              = coalesce(each.value.create_account.location, local.resource_group_location)
  resource_group_name   = local.resource_group_name
  kind                  = "AIServices"
  sku_name              = each.value.create_account.sku_name
  custom_subdomain_name = local.member_account_name[each.key]
  tags                  = var.tags

  local_auth_enabled            = false
  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "member_model" {
  for_each             = local.member_deployments
  name                 = each.value.deployment
  cognitive_account_id = azurerm_cognitive_account.member[each.value.member].id

  model {
    format  = each.value.spec.model_format
    name    = each.value.spec.model_name
    version = each.value.spec.model_version
  }

  sku {
    name     = each.value.spec.sku_name
    capacity = each.value.spec.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}
