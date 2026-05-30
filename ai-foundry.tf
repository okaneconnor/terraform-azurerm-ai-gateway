# Two-phase workaround: if apply locks Terraform out, set public_network_access_enabled = true,
# apply, attach the private endpoint, then flip back to false in a second apply.

resource "azurerm_cognitive_account" "foundry" {
  name                  = local.foundry_name
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = local.foundry_name

  public_network_access_enabled = false

  network_acls {
    default_action = "Deny"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model.name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.chat_model.name
    version = var.chat_model.version
  }

  sku {
    name     = var.chat_model.sku_name
    capacity = var.chat_model.capacity
  }

  version_upgrade_option = "NoAutoUpgrade"
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "pe-foundry-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-foundry"
    private_connection_resource_id = azurerm_cognitive_account.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "pdnszg-foundry"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.zone["cognitive"].id,
      azurerm_private_dns_zone.zone["openai"].id,
      azurerm_private_dns_zone.zone["aiservices"].id,
    ]
  }
}
