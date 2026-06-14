# Foundry/OpenAI inference -> Cognitive Services OpenAI User (least privilege for model calls)
resource "azurerm_role_assignment" "apim_foundry_openai" {
  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# The other AI services (Speech/Language/Doc Intelligence/Content Safety/...) -> Cognitive Services User
resource "azurerm_role_assignment" "apim_svc" {
  for_each             = var.ai_services
  scope                = azurerm_cognitive_account.svc[each.key].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
