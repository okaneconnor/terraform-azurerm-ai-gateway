locals {
  # Key the for_each off var.ai_services (always known) rather than
  # keys(azurerm_api_management_api.svc) — the latter is a resource attribute that's
  # unknown until apply, which breaks `terraform import` and targeted plans. The keys
  # are identical (one svc API per ai_services entry), so resource addresses are unchanged.
  svc_wildcard_ops = {
    for pair in setproduct(keys(var.ai_services), ["GET", "POST"]) :
    "${pair[0]}|${pair[1]}" => { api = pair[0], method = pair[1] }
  }
}

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
