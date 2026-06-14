# Semantic-cache store: Azure Managed Redis with RediSearch (required by APIM's
# llm-semantic-cache policies). Entirely skipped when semantic_cache.enabled = false.

resource "azurerm_managed_redis" "cache" {
  count               = var.semantic_cache.enabled ? 1 : 0
  name                = local.redis_name
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  sku_name            = var.semantic_cache.redis_sku_name
  tags                = var.tags

  high_availability_enabled = var.semantic_cache.high_availability
  # NOTE: this azurerm argument is a no-op on the current provider (publicNetworkAccess
  # requires the Microsoft.Cache redisEnterprise 2025-07-01 API, which azurerm_managed_redis
  # doesn't use yet). With a private endpoint attached, the cache is private-only regardless.
  # To actually toggle it, PATCH publicNetworkAccess via the 2025-07-01 API directly.
  public_network_access = "Disabled"

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
  count             = var.semantic_cache.enabled ? 1 : 0
  name              = "${var.name_prefix}-semantic-cache"
  api_management_id = azurerm_api_management.apim.id
  description       = "Semantic cache for LLM responses (RediSearch)."
  # Bind the cache to the gateway's specific region. Registering as "default" (the
  # implicit value) leaves the semantic-cache policy unable to match a cache to the
  # gateway -> trace shows "No appropriate cache found for provided policy
  # configuration. Policy execution will be skipped."
  # APIM reports the region as a DISPLAY name ("UK South"), so derive it from
  # var.location via the azurerm_location data source rather than hardcoding.
  cache_location = data.azurerm_location.current.display_name
  connection_string = format(
    "%s:%d,password=%s,ssl=True,abortConnect=False",
    azurerm_managed_redis.cache[0].hostname,
    azurerm_managed_redis.cache[0].default_database[0].port,
    azurerm_managed_redis.cache[0].default_database[0].primary_access_key,
  )

  depends_on = [azurerm_private_endpoint.pe]
}
