output "gateway_url" {
  description = "Base URL of the APIM gateway (call /openai/deployments/<name>/chat/completions)."
  value       = module.ai_gateway.apim_gateway_url
}

output "gateway_app_client_id" {
  description = "Entra app that clients request tokens for (the token audience)."
  value       = module.ai_gateway.gateway_app_client_id
}

output "tenant_id" {
  description = "Entra tenant issuing the client-credentials tokens."
  value       = module.ai_gateway.tenant_id
}

output "demo_clients" {
  description = "Per-tier demo client_id + client_secret (create_demo_clients = true). Sensitive."
  value       = module.ai_gateway.demo_clients
  sensitive   = true
}
