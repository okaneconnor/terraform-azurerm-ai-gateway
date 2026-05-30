resource "azapi_resource" "api_center" {
  type      = "Microsoft.ApiCenter/services@2024-03-01"
  name      = local.apic_name
  parent_id = azurerm_resource_group.rg.id
  location  = var.location

  identity { type = "SystemAssigned" }
  body = { properties = {} }
}

# --- A2A agent API: FUTURE ---
# No stable ARM/azapi apiType for A2A agent import as of 2026-05-30 (portal-only).
# Register manually (APIM -> APIs -> + Add API -> A2A Agent); it auto-syncs to API Center.
# Revisit when Microsoft publishes an ARM apiType/properties for A2A.

output "api_center_name" {
  description = "API Center service name."
  value       = azapi_resource.api_center.name
}
