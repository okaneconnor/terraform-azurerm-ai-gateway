# Resource group: created by default, or a pre-existing one (landing-zone pattern)
# via var.existing_resource_group_name. Everything else references local.resource_group_*.
resource "azurerm_resource_group" "rg" {
  count    = var.existing_resource_group_name == null ? 1 : 0
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.existing_resource_group_name != null ? 1 : 0
  name  = var.existing_resource_group_name
}

# Log Analytics — created by default, or bring-your-own via
# var.existing_log_analytics_workspace_id (central-logging pattern).
resource "azurerm_log_analytics_workspace" "law" {
  count               = local.create_law ? 1 : 0
  name                = local.law_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

# Application Insights — created by default, or bring-your-own via
# var.existing_application_insights.
resource "azurerm_application_insights" "ai" {
  count               = local.create_app_insights ? 1 : 0
  name                = local.ai_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  workspace_id        = local.log_analytics_workspace_id
  application_type    = "web"
  tags                = var.tags
}
