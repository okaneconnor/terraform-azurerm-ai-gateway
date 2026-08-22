resource "azurerm_managed_redis" "cache" {
  for_each            = var.semantic_cache.enabled ? { this = {} } : {}
  name                = local.redis_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  sku_name            = var.semantic_cache.redis_sku_name
  tags                = var.tags

  high_availability_enabled = var.semantic_cache.high_availability
  public_network_access     = "Disabled"

  default_database {
    clustering_policy                  = "EnterpriseCluster"
    eviction_policy                    = "NoEviction" # required by RediSearch
    access_keys_authentication_enabled = true

    module {
      name = "RediSearch"
    }
  }
}

resource "azurerm_api_management_redis_cache" "cache" {
  for_each          = var.semantic_cache.enabled ? { this = {} } : {}
  name              = "semantic-cache"
  api_management_id = azurerm_api_management.apim.id
  description       = "Semantic cache for LLM responses (RediSearch)."
  cache_location    = data.azurerm_location.current.display_name
  connection_string = format(
    "%s:%d,password=%s,ssl=True,abortConnect=False",
    azurerm_managed_redis.cache["this"].hostname,
    azurerm_managed_redis.cache["this"].default_database[0].port,
    azurerm_managed_redis.cache["this"].default_database[0].primary_access_key,
  )

  depends_on = [azurerm_private_endpoint.pe]
}
