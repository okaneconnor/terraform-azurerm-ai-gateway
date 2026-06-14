# APIM resource (platform) logs -> Log Analytics.
#
# Without this, the ApiManagementGatewayLogs / ApiManagementGatewayLlmLog tables are
# empty, so backend response codes, errors, and per-request LLM token usage aren't
# queryable in KQL. GatewayLlmLogs is the AI-gateway-specific category: by default
# it records request metadata + token counts (NOT prompt/completion text, which is
# a separate opt-in we intentionally leave off for data residency).
#
# GOTCHA: the resource-specific table for the GatewayLlmLogs *category* is named
# ApiManagementGatewayLlmLog (SINGULAR "Log"), while the gateway table is
# ApiManagementGatewayLogs (plural). Querying the plural LLM name returns
# SEM0100 "Failed to resolve table" and looks like "logs aren't flowing" when they are.
# Verify with: ApiManagementGatewayLlmLog | where TimeGenerated > ago(1h)
# A NEW Log Analytics workspace can take up to ~2h to start ingesting.
resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "apim-to-law"
  target_resource_id         = azurerm_api_management.apim.id
  log_analytics_workspace_id = local.log_analytics_workspace_id
  # REQUIRED for the resource-specific tables to populate. Without "Dedicated",
  # logs land in the generic AzureDiagnostics table and those tables stay empty.
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "GatewayLogs" }
  enabled_log { category = "GatewayLlmLogs" }
  enabled_log { category = "GatewayMCPLogs" }
  enabled_log { category = "WebSocketConnectionLogs" }
  enabled_log { category = "DeveloperPortalAuditLogs" }

  enabled_metric {
    category = "AllMetrics"
  }
}

# The singleton `azuremonitor` APIM logger the per-API diagnostics below point at.
# GOTCHA: the platform creates this logger LAZILY on instances that already have
# Azure Monitor logs flowing — it is NOT created synchronously when the diagnostic
# setting above is PUT. On a fresh deployment the per-API diagnostic then fails with
# ValidationError "Logger Id 'azuremonitor' does not exist", so create it explicitly
# (loggerType "azureMonitor" is a supported value; same pattern as Microsoft's
# Bicep samples). The name MUST be "azuremonitor".
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

# Enable LLM logging on every LLM-shaped API (local.llm_apis) so the
# ApiManagementGatewayLlmLog table + the "Language models" analytics dashboard
# populate. This is the per-API "Log LLM messages" toggle, which azurerm doesn't
# expose, so it's done via azapi against the `azuremonitor` logger above.
# Only `logs = "enabled"` (token usage + model) is set; `requests`/`responses`
# (prompt/completion BODIES) are intentionally omitted so no prompt/completion text
# is logged — preserving data residency.
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
