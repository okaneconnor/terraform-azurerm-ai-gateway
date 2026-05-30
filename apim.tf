resource "azurerm_api_management" "apim" {
  name                = local.apim_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"

  identity {
    type = "SystemAssigned"
  }

  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  # VNet changes on APIM are slow; give it room.
  timeouts {
    create = "3h"
    update = "3h"
  }

  depends_on = [azurerm_subnet_network_security_group_association.apim]
}

resource "azurerm_api_management_logger" "appinsights" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  resource_id         = azurerm_application_insights.ai.id

  application_insights {
    connection_string = azurerm_application_insights.ai.connection_string
  }
}

resource "azurerm_api_management_diagnostic" "apim" {
  identifier                = "applicationinsights"
  api_management_name       = azurerm_api_management.apim.name
  resource_group_name       = azurerm_resource_group.rg.name
  api_management_logger_id  = azurerm_api_management_logger.appinsights.id
  sampling_percentage       = 100.0
  verbosity                 = "information"
  always_log_errors         = true
  log_client_ip             = true
  http_correlation_protocol = "W3C"
}
