resource "azurerm_key_vault" "main" {
  #checkov:skip=CKV_AZURE_110:purge protection is enabled by default via var.key_vault.purge_protection_enabled (checkov cannot resolve the object optional() default).
  #checkov:skip=CKV_AZURE_42:soft-delete (90d) + purge protection are on by default via var.key_vault (checkov cannot resolve the object optional() default).
  #checkov:skip=CKV2_AZURE_32:Reached via a private endpoint (azurerm_private_endpoint.pe["kv"], subresource "vault"); checkov's graph does not link the for_each PE resource to the vault.
  for_each                      = var.key_vault.enabled ? { this = {} } : {}
  name                          = local.kv_name
  location                      = local.resource_group_location
  resource_group_name           = local.resource_group_name
  tenant_id                     = local.tenant_id
  sku_name                      = var.key_vault.sku_name
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.key_vault.purge_protection_enabled
  soft_delete_retention_days    = var.key_vault.soft_delete_retention_days
  public_network_access_enabled = false
  tags                          = var.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_role_assignment" "apim_kv_secrets" {
  for_each             = var.key_vault.enabled ? { this = {} } : {}
  scope                = azurerm_key_vault.main["this"].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
