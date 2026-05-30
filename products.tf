resource "azurerm_api_management_product" "tier" {
  for_each              = var.products
  product_id            = each.key
  display_name          = each.value.display_name
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  published             = true
  subscription_required = false # keyless; access gated by Entra JWT + IP
}

locals {
  all_api_names = concat(
    [azurerm_api_management_api.foundry.name],
    [for k, a in azurerm_api_management_api.svc : a.name]
  )
  product_api_pairs = {
    for pair in setproduct(keys(var.products), local.all_api_names) :
    "${pair[0]}|${pair[1]}" => { product = pair[0], api = pair[1] }
  }
}

resource "azurerm_api_management_product_api" "pa" {
  for_each            = local.product_api_pairs
  product_id          = azurerm_api_management_product.tier[each.value.product].product_id
  api_name            = each.value.api
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_api_management_product_policy" "tier" {
  for_each            = var.products
  product_id          = azurerm_api_management_product.tier[each.key].product_id
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = templatefile("${path.module}/policies/product-limits.xml", {
    tenant_id = local.tenant_id
    role      = each.value.app_role
    tpm       = each.value.tokens_per_minute
    calls     = each.value.rate_limit_calls
    renewal   = var.rate_limit_renewal_seconds
  })
}
