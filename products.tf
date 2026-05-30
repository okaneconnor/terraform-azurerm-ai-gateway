resource "azurerm_api_management_product" "team" {
  for_each = var.teams

  product_id            = each.key
  display_name          = each.value.display_name
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  published             = true
  subscription_required = true
  approval_required     = false
  subscriptions_limit   = 10
}

resource "azurerm_api_management_product_api" "team_openai" {
  for_each = var.teams

  product_id          = azurerm_api_management_product.team[each.key].product_id
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_api_management_subscription" "team" {
  for_each = var.teams

  display_name        = "${each.value.display_name} subscription"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  product_id          = azurerm_api_management_product.team[each.key].id
  state               = "active"
  allow_tracing       = true
}
