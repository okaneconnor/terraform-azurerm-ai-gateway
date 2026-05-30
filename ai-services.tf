locals {
  ai_services = {
    speech   = { name = local.speech_name, kind = "SpeechServices", sku = "S0" }
    language = { name = local.language_name, kind = "TextAnalytics", sku = "S" }
    docintel = { name = local.docintel_name, kind = "FormRecognizer", sku = "S0" }
    safety   = { name = local.cs_name, kind = "ContentSafety", sku = "S0" }
  }
}

resource "azurerm_cognitive_account" "svc" {
  for_each              = local.ai_services
  name                  = each.value.name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = each.value.kind
  sku_name              = each.value.sku
  custom_subdomain_name = each.value.name

  # Two-phase note: provision with public_network_access_enabled = true, attach PE,
  # then flip to false. Doing both in one shot can lock Terraform out mid-apply.
  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_private_endpoint" "svc" {
  for_each            = local.ai_services
  name                = "pe-${each.key}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_cognitive_account.svc[each.key].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "pdnszg-${each.key}"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.zone["cognitive"].id,
      azurerm_private_dns_zone.zone["aiservices"].id,
    ]
  }
}
