resource "azapi_resource" "api_center" {
  for_each  = var.enable_api_center ? { this = {} } : {}
  type      = "Microsoft.ApiCenter/services@2024-03-01"
  name      = local.apic_name
  parent_id = local.resource_group_id
  location  = var.location
  tags      = var.tags

  identity { type = "SystemAssigned" }
  schema_validation_enabled = false
  body                      = { sku = { name = "Free" }, properties = {} }
}

resource "azurerm_role_assignment" "apic_apim_reader" {
  for_each             = var.enable_api_center ? { this = {} } : {}
  scope                = azurerm_api_management.apim.id
  role_definition_name = "API Management Service Reader Role"
  principal_id         = azapi_resource.api_center["this"].identity[0].principal_id
}

resource "azapi_resource" "apic_apim_source" {
  for_each  = var.enable_api_center ? { this = {} } : {}
  type      = "Microsoft.ApiCenter/services/workspaces/apiSources@2024-06-01-preview"
  name      = "apim-source"
  parent_id = "${azapi_resource.api_center["this"].id}/workspaces/default"

  body = {
    properties = {
      azureApiManagementSource = {
        resourceId = azurerm_api_management.apim.id
      }
      importSpecification = "always"
    }
  }

  schema_validation_enabled = false
  depends_on                = [azurerm_role_assignment.apic_apim_reader]
}

