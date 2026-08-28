resource "azurerm_api_management_api_operation" "svc_wildcard" {
  for_each = local.svc_wildcard_ops

  operation_id        = "wildcard-${lower(each.value.method)}"
  api_name            = azurerm_api_management_api.svc[each.value.api].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = local.resource_group_name
  display_name        = "${each.value.method} (wildcard)"
  method              = each.value.method
  url_template        = "/*"
  description         = "Passthrough wildcard; client appends the real service path."
}
