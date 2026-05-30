output "apim_gateway_url" {
  description = "APIM gateway base URL."
  value       = azurerm_api_management.apim.gateway_url
}

output "tenant_id" {
  value = local.tenant_id
}

output "gateway_app_client_id" {
  description = "Audience the client requests a token for (api://.../.default)."
  value       = azuread_application.gateway.client_id
}

output "client_app_id" {
  value = azuread_application.client.client_id
}

output "client_app_secret" {
  description = "Demo client secret for the client-credentials flow."
  value       = azuread_application_password.client.value
  sensitive   = true
}

output "chat_deployment_name" {
  value = azurerm_cognitive_deployment.chat.name
}
