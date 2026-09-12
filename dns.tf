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
