# Service-side diagnostics for the model + backend layer. The APIM diagnostic
# (monitoring.tf) captures the gateway's view; these route what the Cognitive
# accounts, Key Vault and Managed Redis themselves emit (audit, request/response,
# metrics) to the same Log Analytics workspace, so a model-layer failure has a
# service-side trace and not just what APIM saw. Toggle off (enable_backend_diagnostics
# = false) when diagnostics are managed centrally by Azure Policy.

resource "azurerm_monitor_diagnostic_setting" "foundry" {
  for_each                   = var.enable_backend_diagnostics ? { this = {} } : {}
  name                       = "diag-to-law"
  target_resource_id         = azurerm_cognitive_account.foundry.id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }
  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "svc" {
  for_each                   = var.enable_backend_diagnostics ? var.ai_services : {}
  name                       = "diag-to-law"
  target_resource_id         = azurerm_cognitive_account.svc[each.key].id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }
  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  for_each                   = var.enable_backend_diagnostics && var.key_vault.enabled ? { this = {} } : {}
  name                       = "diag-to-law"
  target_resource_id         = azurerm_key_vault.main["this"].id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }
  enabled_metric { category = "AllMetrics" }
}

resource "azurerm_monitor_diagnostic_setting" "redis" {
  for_each                   = var.enable_backend_diagnostics && var.semantic_cache.enabled ? { this = {} } : {}
  name                       = "diag-to-law"
  target_resource_id         = azurerm_managed_redis.cache["this"].id
  log_analytics_workspace_id = local.log_analytics_workspace_id

  # Azure Managed Redis (redisEnterprise) exposes no diagnostic LOG categories —
  # metrics only. Setting category_group="allLogs" here 400s "not supported".
  enabled_metric { category = "AllMetrics" }
}
