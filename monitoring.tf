resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                           = "apim-to-law"
  target_resource_id             = azurerm_api_management.apim.id
  log_analytics_workspace_id     = local.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "GatewayLogs" }
  enabled_log { category = "GatewayLlmLogs" }
  enabled_log { category = "WebSocketConnectionLogs" }
  enabled_log { category = "DeveloperPortalAuditLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azapi_resource" "apim_azuremonitor_logger" {
  type      = "Microsoft.ApiManagement/service/loggers@2024-06-01-preview"
  name      = "azuremonitor"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      loggerType = "azureMonitor"
      isBuffered = true
    }
  }
}

resource "azapi_resource" "llm_diagnostic" {
  for_each  = local.llm_apis
  type      = "Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview"
  name      = "azuremonitor"
  parent_id = each.value

  body = {
    properties = {
      loggerId = azapi_resource.apim_azuremonitor_logger.id
      largeLanguageModel = {
        logs = "enabled"
      }
    }
  }

  schema_validation_enabled = false
  depends_on                = [azurerm_monitor_diagnostic_setting.apim]
}
