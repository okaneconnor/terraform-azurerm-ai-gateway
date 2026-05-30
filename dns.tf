locals {
  private_dns_zones = {
    cognitive  = "privatelink.cognitiveservices.azure.com"
    openai     = "privatelink.openai.azure.com"
    aiservices = "privatelink.services.ai.azure.com"
    keyvault   = "privatelink.vaultcore.azure.net"
  }
}

resource "azurerm_private_dns_zone" "zone" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "link" {
  for_each              = local.private_dns_zones
  name                  = "link-${each.key}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.zone[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}
