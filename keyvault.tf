# Optional private Key Vault for consumer workloads (the gateway itself stores no
# secrets here). Two-phase workaround: if apply locks Terraform out mid-run, set
# public_network_access_enabled = true, apply, attach the PE, then flip back.
#
# NOTE — human/app secret access is not wired up yet. This vault is RBAC-mode +
# private, so as shipped nobody can add/view secrets:
#   * RBAC mode grants NO data-plane access from management-plane roles — Owner /
#     Contributor do not let you read or write secrets (that separation is the best
#     practice). The only data-plane grant today is APIM's MI = Secrets User (below),
#     so admins get "not allowed by RBAC" in the portal.
#   * It is private (public access off + Deny ACLs + private endpoint), so even with
#     a role you must reach it from the VNet (bastion/jumpbox) or an allow-listed IP.
#
# TO HANDLE PROPERLY (least-privilege + explicit; mirrors the Azure Verified Modules
# role_assignments pattern):
#   1. Data-plane role assignments on the key_vault object:
#        - secrets_officer_object_ids -> "Key Vault Secrets Officer" (create/rotate
#          secrets; for admins / CI)
#        - secrets_user_object_ids    -> "Key Vault Secrets User" (read; for the
#          consumer's app managed identities)
#        - grant_deployer = true (optional, default false) -> grant the deploying
#          identity (data.azurerm_client_config.current.object_id) "Key Vault
#          Administrator", so whoever runs `terraform apply` can manage secrets on
#          day one. Off by default — explicit is safer.
#   2. Management network path: an optional key_vault.allowed_ip_ranges feeding
#      network_acls.ip_rules (default empty = stays fully private), so an admin can
#      allow-list their egress IP; otherwise manage from inside the VNet via the
#      private endpoint. Keep default_action = "Deny".
# (Also revisit the APIM-MI "Secrets User" grant below: the gateway stores nothing
#  here, so it is likely vestigial.)

resource "azurerm_key_vault" "main" {
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
