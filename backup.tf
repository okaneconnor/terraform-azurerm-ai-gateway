# Opt-in supporting resources for APIM configuration backup (var.apim_backup, default
# off). APIM keeps APIs, policies, named values, products and subscriptions in its own
# control plane; a region loss or accidental delete loses all of it and Terraform only
# restores what Terraform created. Backup itself is an imperative operation (`az apim
# backup`), so this provisions the target: a storage account + container and the role
# assignment that lets APIM's managed identity write to it. See docs/operations.md.

resource "azurerm_storage_account" "backup" {
  #checkov:skip=CKV2_AZURE_33:No private endpoint in this pass — APIM reaches it over the Storage service tag (the module's APIM NSG has out-storage-443). Add a PE / network_rules for a fully private backup target.
  #checkov:skip=CKV2_AZURE_47:Public network access stays enabled so APIM can reach the account for backup; access is gated by managed-identity RBAC (shared keys are disabled). Restrict with network_rules for production.
  #checkov:skip=CKV_AZURE_59:Anonymous blob access is disabled (allow_nested_items_to_be_public=false); public *network* access is retained only so the in-VNet APIM identity can write backups.
  #checkov:skip=CKV_AZURE_33:Queue-service logging is inapplicable — this is a blob-only backup target with no queue service.
  #checkov:skip=CKV_AZURE_206:Replication is caller-configurable (var.apim_backup.replication_type); default GRS already gives cross-region durability for a DR target.
  #checkov:skip=CKV2_AZURE_40:Shared keys stay enabled so the module doesn't force `storage_use_azuread` on the caller's provider (azurerm reads queue/blob properties via keys). Backup itself uses the APIM managed identity (role assignment + --access-type SystemAssignedManagedIdentity).
  #checkov:skip=CKV2_AZURE_41:No SAS is issued for this account — backup writes use the APIM managed identity, so a SAS expiration policy is inapplicable.
  #checkov:skip=CKV2_AZURE_1:Uses Microsoft-managed keys by design; a customer-managed key (KV key + identity wiring) is a consumer/org choice, not forced by this generic module (same stance as the Cognitive accounts).
  for_each                        = var.apim_backup.enabled ? { this = {} } : {}
  name                            = substr(lower(replace("${var.name_prefix}bkp${local.suffix}", "-", "")), 0, 24)
  resource_group_name             = local.resource_group_name
  location                        = local.resource_group_location
  account_tier                    = "Standard"
  account_replication_type        = var.apim_backup.replication_type
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "backup" {
  #checkov:skip=CKV2_AZURE_21:Blob read-access logging isn't needed for a write-only APIM backup target; enable storage analytics logging if your org requires it.
  for_each              = var.apim_backup.enabled ? { this = {} } : {}
  name                  = "apim-backups"
  storage_account_id    = azurerm_storage_account.backup["this"].id
  container_access_type = "private"
}

# APIM's managed identity writes backups to the account (access-type
# SystemAssignedManagedIdentity on `az apim backup`).
resource "azurerm_role_assignment" "apim_backup" {
  for_each             = var.apim_backup.enabled ? { this = {} } : {}
  scope                = azurerm_storage_account.backup["this"].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_api_management.apim.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
