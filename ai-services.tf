# One Cognitive Services account per ai_services entry — private, Entra-only.
# Two-phase note: provision with public_network_access_enabled = true, attach PE,
# then flip to false if an apply ever locks Terraform out mid-run.

resource "azurerm_cognitive_account" "svc" {
  #checkov:skip=CKV2_AZURE_22:Uses Microsoft-managed keys by design; customer-managed key encryption (a KV key + identity wiring) is a consumer/org choice, not forced by this generic module.
  for_each              = var.ai_services
  name                  = "${var.name_prefix}-${each.value.short_name}-${local.suffix}"
  location              = local.resource_group_location
  resource_group_name   = local.resource_group_name
  kind                  = each.value.kind
  sku_name              = each.value.sku_name
  custom_subdomain_name = "${var.name_prefix}-${each.value.short_name}-${local.suffix}"
  tags                  = var.tags

  # Entra-only: APIM reaches these via managed identity; account keys stay off.
  local_auth_enabled = false

  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}
