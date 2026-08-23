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

output "tenant_id" {
  description = "Entra tenant the gateway app lives in."
  value       = local.tenant_id
}

output "gateway_app_client_id" {
  description = "Audience clients request tokens for (scope: <client_id>/.default)."
  value       = local.gateway_client_id
}

output "gateway_app_object_id" {
  description = <<-EOT
    Object id of the gateway's service principal — the resource_object_id an
    external azuread_app_role_assignment binds to. Resolved in both modes
    (module-created and existing_gateway_app), so team onboarding can live in its
    own Terraform state and never plan the gateway.
  EOT
  value       = local.gateway_sp_object_id
}

output "gateway_app_role_id" {
  description = <<-EOT
    Id of the single admission app role (var.admission_app_role) — the app_role_id
    for an external azuread_app_role_assignment. With gateway_app_object_id, this
    is everything an out-of-state onboarding needs.
  EOT
  value       = local.gateway_admission_role_id
}

output "admission_app_role" {
  description = "Value of the admission app role callers must carry (mirrors var.admission_app_role)."
  value       = var.admission_app_role
}

output "tier_names" {
  description = "Names of the configured tier presets — the values an onboarding registry may reference as a team's tier."
  value       = keys(var.tiers)
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

output "model_deployment_names" {
  description = "Deployment names exposed at /openai/deployments/<name>/... on the gateway."
  value       = keys(var.model_deployments)
}

output "foundry_account_name" {
  description = "Foundry (AIServices) account name."
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

output "log_analytics_workspace_resource_id" {
  description = "Log Analytics workspace ARM resource ID (module-created or bring-your-own)."
  value       = local.log_analytics_workspace_id
}

output "log_analytics_workspace_guid" {
  description = "Log Analytics customer/workspace GUID for KQL queries (ApiManagementGatewayLogs / ApiManagementGatewayLlmLog). Null when bringing your own workspace."
  value       = local.create_law ? azurerm_log_analytics_workspace.law["this"].workspace_id : null
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

output "key_vault_id" {
  description = "Key Vault resource ID (null when key_vault.enabled = false)."
  value       = var.key_vault.enabled ? azurerm_key_vault.main["this"].id : null
}

output "key_vault_uri" {
  description = "Key Vault URI for consumer workloads (null when key_vault.enabled = false)."
  value       = var.key_vault.enabled ? azurerm_key_vault.main["this"].vault_uri : null
}

output "api_center_id" {
  description = "API Center service resource ID (null when enable_api_center = false)."
  value       = var.enable_api_center ? azapi_resource.api_center["this"].id : null
}

output "api_center_name" {
  description = "API Center service name (null when enable_api_center = false)."
  value       = var.enable_api_center ? azapi_resource.api_center["this"].name : null
}

output "alerts_action_group_id" {
  description = "Action group used by alerts/budget notifications (created or bring-your-own); null when alerting is off."
  value       = local.action_group_id
}

output "backend_pool_members" {
  description = "Backend pool members and their priority/weight/kind (includes the module's Foundry account as 'primary')."
  value = merge(
    { primary = {
      priority    = var.backend_pool.primary_priority
      weight      = var.backend_pool.primary_weight
      kind        = "created"
      trip_on_429 = var.circuit_breaker.trip_on_429
    } },
    { for k, m in var.backend_pool.members : k => {
      priority    = m.priority
      weight      = m.weight
      kind        = m.create_account != null ? "created" : "byo"
      trip_on_429 = local.member_cb[k].trip_on_429
    } }
  )
}
