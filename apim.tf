resource "azurerm_api_management" "apim" {
  #checkov:skip=CKV_AZURE_174:External VNet injection intentionally exposes a public gateway IP (the front door), gated by mandatory Entra JWT validation + IP filter. Set apim_virtual_network_type="Internal" and front with App Gateway/WAF for a fully private ingress.
  name                = local.apim_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.apim_sku_name
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }

  virtual_network_type = var.apim_virtual_network_type
  virtual_network_configuration {
    subnet_id = local.apim_subnet_id
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
  resource_group_name = local.resource_group_name
  resource_id         = local.app_insights_id

  application_insights {
    connection_string = local.app_insights_connection_string
  }
}

# GOTCHA: emit-metric / llm-emit-token-metric policies only emit when the App
# Insights diagnostic has metrics=true (the portal's "Enable custom metrics"
# toggle). azurerm doesn't expose that property (verified against 4.77), so patch
# it via azapi — without this, token metrics (per-app chargeback) silently never
# reach customMetrics while everything else looks healthy.
resource "azapi_update_resource" "appinsights_custom_metrics" {
  type        = "Microsoft.ApiManagement/service/diagnostics@2024-06-01-preview"
  resource_id = azurerm_api_management_diagnostic.apim.id

  body = {
    properties = {
      metrics  = true
      loggerId = azurerm_api_management_logger.appinsights.id
    }
  }
}

resource "azurerm_api_management_diagnostic" "apim" {
  identifier                = "applicationinsights"
  api_management_name       = azurerm_api_management.apim.name
  resource_group_name       = local.resource_group_name
  api_management_logger_id  = azurerm_api_management_logger.appinsights.id
  sampling_percentage       = var.apim_diagnostic.sampling_percentage
  verbosity                 = var.apim_diagnostic.verbosity
  always_log_errors         = true
  log_client_ip             = true
  http_correlation_protocol = "W3C"

  backend_request {
    headers_to_log = ["content-type", "apim-request-id"]
  }
  backend_response {
    headers_to_log = ["content-type", "x-ms-region", "x-ratelimit-remaining-tokens", "retry-after"]
  }
  frontend_response {
    headers_to_log = ["content-type"]
  }
}
