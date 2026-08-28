resource "azurerm_private_endpoint" "pe" {
  for_each            = local.private_endpoints
  name                = "pep-${each.key}-${local.name_base}"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  subnet_id           = local.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = each.value.resource_id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnszg-${each.key}"
    private_dns_zone_ids = [for z in each.value.dns_zones : local.private_dns_zone_ids[z]]
  }
}
