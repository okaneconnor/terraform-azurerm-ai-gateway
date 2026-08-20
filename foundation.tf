resource "azurerm_resource_group" "rg" {
  for_each = var.existing_resource_group_name == null ? { this = {} } : {}
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  for_each = var.existing_resource_group_name != null ? { this = {} } : {}
  name     = var.existing_resource_group_name
}

resource "azurerm_log_analytics_workspace" "law" {
  for_each            = local.create_law ? { this = {} } : {}
  name                = local.law_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_application_insights" "ai" {
  for_each            = local.create_app_insights ? { this = {} } : {}
  name                = local.ai_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  workspace_id        = local.log_analytics_workspace_id
  application_type    = "web"
  tags                = var.tags
}
