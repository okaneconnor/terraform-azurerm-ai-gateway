resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "apim" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  display_name        = "AI Gateway — APIM telemetry"
  category            = "workbook"
  source_id           = lower(azurerm_application_insights.ai.id)

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type    = 1
        content = { json = "# AI Gateway telemetry\nToken usage, request volume, and content-safety blocks by client app." }
      }
    ]
    styleSettings = {}
  })
}
