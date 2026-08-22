resource "azurerm_cognitive_account" "svc" {
  #checkov:skip=CKV2_AZURE_22:Uses Microsoft-managed keys by design; customer-managed key encryption (a KV key + identity wiring) is a consumer/org choice, not forced by this generic module.
  for_each              = var.ai_services
  name                  = "${each.value.short_name}-${local.name_base}"
  location              = local.resource_group_location
  resource_group_name   = local.resource_group_name
  kind                  = each.value.kind
  sku_name              = each.value.sku_name
  custom_subdomain_name = "${each.value.short_name}-${local.name_base}"
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
