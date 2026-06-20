resource "azapi_resource" "api_center" {
  for_each  = var.enable_api_center ? { this = {} } : {}
  type      = "Microsoft.ApiCenter/services@2024-03-01"
  name      = local.apic_name
  parent_id = local.resource_group_id
  location  = var.location
  tags      = var.tags

  identity { type = "SystemAssigned" }
  body = { properties = {} }
}

# Grant the API Center's system-assigned identity read access to the APIM instance,
# so it can continuously synchronise the API inventory.
resource "azurerm_role_assignment" "apic_apim_reader" {
  for_each             = var.enable_api_center ? { this = {} } : {}
  scope                = azurerm_api_management.apim.id
  role_definition_name = "API Management Service Reader Role"
  principal_id         = azapi_resource.api_center["this"].identity[0].principal_id
}

# Continuous one-way sync of APIM APIs into the API
# Center catalog. This is the documented, codifiable integration
# (Microsoft.ApiCenter/services/workspaces/apiSources). Sync can take minutes-to-hours.
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

# --- A2A agent API: FUTURE (not codifiable) ---
# No stable ARM/azapi apiType for A2A agent import (portal-only as of 2026-06).
# Register manually (APIM -> APIs -> + Add API -> A2A Agent); it auto-syncs to API Center
# via the apiSource integration above. Revisit when MS publishes an ARM apiType for A2A.
