resource "random_uuid" "workbook" {
  count = var.enable_workbook ? 1 : 0
}

# Operational dashboard over the App Insights telemetry the gateway emits:
# llm-emit-token-metric lands in customMetrics (namespace llm-metrics) with the
# App ID dimension set from the validated caller identity.
resource "azurerm_application_insights_workbook" "apim" {
  count               = var.enable_workbook ? 1 : 0
  name                = random_uuid.workbook[0].result
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  display_name        = "AI Gateway — APIM telemetry"
  category            = "workbook"
  source_id           = lower(local.app_insights_id)
  tags                = var.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type    = 1
        content = { json = "# AI Gateway telemetry\nToken usage, request volume, and per-client attribution. Token metrics come from `llm-emit-token-metric` (App Insights customMetrics, namespace `llm-metrics`)." }
      },
      {
        type = 3
        content = {
          version      = "KqlItem/1.0"
          query        = "customMetrics | where name in ('Total Tokens', 'Prompt Tokens', 'Completion Tokens') | summarize tokens = sum(valueSum) by name, bin(timestamp, 15m) | render timechart"
          size         = 0
          title        = "LLM token usage over time"
          queryType    = 0
          resourceType = "microsoft.insights/components"
        }
      },
      {
        type = 3
        content = {
          version      = "KqlItem/1.0"
          query        = "customMetrics | where name == 'Total Tokens' | extend appId = tostring(customDimensions['App ID']) | summarize tokens = sum(valueSum) by appId | order by tokens desc | render barchart"
          size         = 0
          title        = "Total tokens by client app (chargeback)"
          queryType    = 0
          resourceType = "microsoft.insights/components"
        }
      },
      {
        type = 3
        content = {
          version      = "KqlItem/1.0"
          query        = "requests | summarize requests = count() by resultCode, bin(timestamp, 15m) | render timechart"
          size         = 0
          title        = "Gateway requests by result code"
          queryType    = 0
          resourceType = "microsoft.insights/components"
        }
      },
    ]
    styleSettings = {}
  })
}
