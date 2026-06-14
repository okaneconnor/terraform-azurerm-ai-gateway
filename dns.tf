locals {
  private_dns_zones = {
    cognitive  = "privatelink.cognitiveservices.azure.com"
    openai     = "privatelink.openai.azure.com"
    aiservices = "privatelink.services.ai.azure.com"
    keyvault   = "privatelink.vaultcore.azure.net"
    redis      = "privatelink.redis.azure.net"
  }
}

# Private DNS zones — created + linked by default, or skipped entirely when
# var.existing_private_dns_zone_ids is supplied (hub-managed DNS). The effective
# IDs are resolved in locals.private_dns_zone_ids.
resource "azurerm_private_dns_zone" "zone" {
  for_each            = local.create_dns_zones ? local.private_dns_zones : {}
  name                = each.value
  resource_group_name = local.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  for_each              = local.create_dns_zones ? local.private_dns_zones : {}
  name                  = "link-${each.key}"
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.zone[each.key].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
}
