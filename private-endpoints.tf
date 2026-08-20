locals {
  private_endpoints = merge(
    {
      for k, v in var.ai_services : k => {
        resource_id = azurerm_cognitive_account.svc[k].id
        subresource = "account"
        dns_zones   = ["cognitive", "aiservices"]
      }
    },
    {
      foundry = {
        resource_id = azurerm_cognitive_account.foundry.id
        subresource = "account"
        dns_zones   = ["cognitive", "openai", "aiservices"]
      }
    },
    {
      for k, m in local.created_members : "member-${k}" => {
        resource_id = azurerm_cognitive_account.member[k].id
        subresource = "account"
        dns_zones   = ["cognitive", "openai", "aiservices"]
      }
    },
    var.key_vault.enabled ? {
      kv = {
        resource_id = azurerm_key_vault.main["this"].id
        subresource = "vault"
        dns_zones   = ["keyvault"]
      }
    } : {},
    var.semantic_cache.enabled ? {
      redis = {
        resource_id = azurerm_managed_redis.cache["this"].id
        subresource = "redisEnterprise"
        dns_zones   = ["redis"]
      }
    } : {}
  )
}

resource "azurerm_private_endpoint" "pe" {
  for_each            = local.private_endpoints
  name                = "pe-${each.key}-${local.suffix}"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  subnet_id           = local.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = each.value.resource_id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdnszg-${each.key}"
    private_dns_zone_ids = [for z in each.value.dns_zones : local.private_dns_zone_ids[z]]
  }
}
