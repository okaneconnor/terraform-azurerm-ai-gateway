resource "azurerm_role_assignment" "apim_foundry_openai" {
  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apim_svc" {
  for_each             = var.ai_services
  scope                = azurerm_cognitive_account.svc[each.key].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "member_openai" {
  for_each = merge(
    { for k, m in local.created_members : k => azurerm_cognitive_account.member[k].id },
    { for k, m in local.byo_members : k => m.managed_identity_scope_id if m.managed_identity_scope_id != null },
  )
  scope                = each.value
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
