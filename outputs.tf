# ── Gateway ──────────────────────────────────────────────────────────────────

output "apim_gateway_url" {
  description = "APIM gateway base URL."
  value       = azurerm_api_management.apim.gateway_url
}

output "apim_name" {
  description = "APIM service name."
  value       = azurerm_api_management.apim.name
}

output "apim_id" {
  description = "APIM service resource ID."
  value       = azurerm_api_management.apim.id
}

output "apim_principal_id" {
  description = "APIM system-assigned managed identity principal ID — grant it roles on your own resources (e.g. additional Cognitive accounts) to extend the gateway."
  value       = azurerm_api_management.apim.identity[0].principal_id
}

# ── Identity / auth ──────────────────────────────────────────────────────────

output "tenant_id" {
  description = "Entra tenant the gateway app lives in."
  value       = local.tenant_id
}

output "gateway_app_client_id" {
  description = "Audience clients request tokens for (scope: <client_id>/.default)."
  value       = local.gateway_client_id
}

output "demo_clients" {
  description = "Demo client credentials per tier (only when create_demo_clients = true). Map of tier key -> { client_id, client_secret }."
  value = {
    for k in keys(var.create_demo_clients ? var.tiers : {}) : k => {
      client_id     = azuread_application.demo[k].client_id
      client_secret = azuread_application_password.demo[k].value
    }
  }
  sensitive = true
}

# ── Models / backends ────────────────────────────────────────────────────────

output "model_deployment_names" {
  description = "Deployment names exposed at /openai/deployments/<name>/... on the gateway."
  value       = keys(var.model_deployments)
}

output "foundry_account_name" {
  description = "Foundry (AIServices) account name — needed by test/test-residency.sh."
  value       = azurerm_cognitive_account.foundry.name
}

output "foundry_id" {
  description = "Foundry (AIServices) account resource ID."
  value       = azurerm_cognitive_account.foundry.id
}

output "foundry_endpoint" {
  description = "Foundry account endpoint (private; resolvable only inside the VNet)."
  value       = azurerm_cognitive_account.foundry.endpoint
}

# ── Resource group / network (peering & integration) ─────────────────────────

output "resource_group_name" {
  description = "Resource group containing the gateway stack."
  value       = local.resource_group_name
}

output "resource_group_id" {
  description = "Resource group resource ID."
  value       = local.resource_group_id
}

output "vnet_id" {
  description = "VNet the gateway is injected into (module-created or bring-your-own) — use for peering."
  value       = local.vnet_id
}

output "apim_subnet_id" {
  description = "Subnet APIM is injected into."
  value       = local.apim_subnet_id
}

output "pe_subnet_id" {
  description = "Subnet holding the private endpoints."
  value       = local.pe_subnet_id
}

output "private_dns_zone_ids" {
  description = "Map of private DNS zone role -> resource ID (module-created or bring-your-own). Link these from a hub if you run hub-and-spoke DNS."
  value       = local.private_dns_zone_ids
}

# ── Observability ────────────────────────────────────────────────────────────

output "log_analytics_workspace_resource_id" {
  description = "Log Analytics workspace ARM resource ID (module-created or bring-your-own)."
  value       = local.log_analytics_workspace_id
}

output "log_analytics_workspace_guid" {
  description = "Log Analytics customer/workspace GUID for KQL queries (ApiManagementGatewayLogs / ApiManagementGatewayLlmLog). Null when bringing your own workspace."
  value       = local.create_law ? azurerm_log_analytics_workspace.law[0].workspace_id : null
}

output "application_insights_id" {
  description = "Application Insights resource ID (module-created or bring-your-own)."
  value       = local.app_insights_id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string for consumer apps that want to correlate telemetry."
  value       = local.app_insights_connection_string
  sensitive   = true
}

# ── Optional components ──────────────────────────────────────────────────────

output "key_vault_id" {
  description = "Key Vault resource ID (null when key_vault.enabled = false)."
  value       = var.key_vault.enabled ? azurerm_key_vault.main[0].id : null
}

output "key_vault_uri" {
  description = "Key Vault URI for consumer workloads (null when key_vault.enabled = false)."
  value       = var.key_vault.enabled ? azurerm_key_vault.main[0].vault_uri : null
}

output "api_center_id" {
  description = "API Center service resource ID (null when enable_api_center = false)."
  value       = var.enable_api_center ? azapi_resource.api_center[0].id : null
}

output "api_center_name" {
  description = "API Center service name (null when enable_api_center = false)."
  value       = var.enable_api_center ? azapi_resource.api_center[0].name : null
}
