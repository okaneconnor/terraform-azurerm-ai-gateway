resource "random_string" "suffix" {
  for_each = var.name_suffix == null ? { this = {} } : {}
  length   = 5
  special  = false
  upper    = false
  numeric  = true
}

data "azurerm_location" "current" {
  location = var.location
}

locals {
  suffix = var.name_suffix != null ? var.name_suffix : one(values(random_string.suffix)[*].result)

  region_short_map = {
    uksouth            = "uks"
    ukwest             = "ukw"
    northeurope        = "neu"
    westeurope         = "weu"
    swedencentral      = "sdc"
    francecentral      = "frc"
    germanywestcentral = "gwc"
    switzerlandnorth   = "szn"
    eastus             = "eus"
    eastus2            = "eus2"
    centralus          = "cus"
    westus2            = "wus2"
    westus3            = "wus3"
    canadacentral      = "cac"
    brazilsouth        = "brs"
    australiaeast      = "aue"
    japaneast          = "jpe"
    koreacentral       = "krc"
    southeastasia      = "sea"
    centralindia       = "inc"
    southafricanorth   = "san"
    uaenorth           = "uan"
  }
  region_short = lookup(local.region_short_map, var.location, var.location)

  rg_name   = "${var.name_prefix}-${local.region_short}-rg"
  apim_name = "${var.name_prefix}-apim-${local.suffix}"
  law_name  = "${var.name_prefix}-law-${local.suffix}"
  ai_name   = "${var.name_prefix}-appi-${local.suffix}"
  kv_name   = substr(replace("${var.name_prefix}kv${local.suffix}", "-", ""), 0, 24) # <=24 chars, alnum

  foundry_name = "${var.name_prefix}-fdry-${local.suffix}"
  apic_name    = "${var.name_prefix}-apic-${local.suffix}"
  redis_name   = "${var.name_prefix}-redis-${local.suffix}"

  tenant_id = data.azurerm_client_config.current.tenant_id

  # ── Effective resource-group / location (module-created vs bring-your-own) ──
  resource_group_name     = var.existing_resource_group_name != null ? var.existing_resource_group_name : azurerm_resource_group.rg["this"].name
  resource_group_id       = var.existing_resource_group_name != null ? data.azurerm_resource_group.existing["this"].id : azurerm_resource_group.rg["this"].id
  resource_group_location = var.existing_resource_group_name != null ? data.azurerm_resource_group.existing["this"].location : azurerm_resource_group.rg["this"].location

  # ── Effective network (module-created vs bring-your-own) ──
  create_network = var.existing_network == null
  vnet_id        = var.existing_network != null ? var.existing_network.vnet_id : azurerm_virtual_network.main["this"].id
  apim_subnet_id = var.existing_network != null ? var.existing_network.apim_subnet_id : azurerm_subnet.apim["this"].id
  pe_subnet_id   = var.existing_network != null ? var.existing_network.pe_subnet_id : azurerm_subnet.pe["this"].id

  # ── Effective private DNS zones (module-created vs bring-your-own) ──
  create_dns_zones = length(var.existing_private_dns_zone_ids) == 0
  private_dns_zone_ids = local.create_dns_zones ? {
    for k in keys(local.private_dns_zones) : k => azurerm_private_dns_zone.zone[k].id
  } : var.existing_private_dns_zone_ids

  # ── Effective observability (module-created vs bring-your-own) ──
  create_law                     = var.existing_log_analytics_workspace_id == null
  log_analytics_workspace_id     = var.existing_log_analytics_workspace_id != null ? var.existing_log_analytics_workspace_id : azurerm_log_analytics_workspace.law["this"].id
  create_app_insights            = var.existing_application_insights == null
  app_insights_id                = var.existing_application_insights != null ? var.existing_application_insights.id : azurerm_application_insights.ai["this"].id
  app_insights_connection_string = var.existing_application_insights != null ? var.existing_application_insights.connection_string : azurerm_application_insights.ai["this"].connection_string

  # Gateway app identity — module-created unless the consumer brings their own.
  gateway_client_id = var.existing_gateway_app != null ? var.existing_gateway_app.client_id : azuread_application.gateway["this"].client_id

  # Tiers ordered by tokens_per_minute DESC. Policy <choose> branches evaluate in
  # order, so a client holding several roles lands on its highest tier.
  tiers_sorted = [
    for s in reverse(sort([
      for k, t in var.tiers : format("%020d|%s", t.tokens_per_minute, k)
    ])) : merge(var.tiers[split("|", s)[1]], { key = split("|", s)[1] })
  ]

  # The ContentSafety entry in ai_services backs the llm-content-safety policy.
  content_safety_keys        = [for k, v in var.ai_services : k if v.kind == "ContentSafety"]
  content_safety_backend_key = length(local.content_safety_keys) > 0 ? local.content_safety_keys[0] : null

  llm_apis = {
    foundry = azurerm_api_management_api.foundry.id
  }

  # ── Multi-member backend pool (#15) ──
  pool_members    = var.backend_pool.members
  created_members = { for k, m in local.pool_members : k => m if m.create_account != null }
  byo_members     = { for k, m in local.pool_members : k => m if m.endpoint_url != null }

  member_deployments = merge([
    for k, m in local.created_members : {
      for dname, d in m.create_account.model_deployments : "${k}/${dname}" => {
        member     = k
        deployment = dname
        spec       = d
      }
    }
  ]...)

  # Effective per-member circuit breaker: member override merged over var.circuit_breaker.
  member_cb = { for k, m in local.pool_members : k => {
    enabled            = coalesce(try(m.circuit_breaker.enabled, null), var.circuit_breaker.enabled)
    failure_count      = coalesce(try(m.circuit_breaker.failure_count, null), var.circuit_breaker.failure_count)
    interval           = coalesce(try(m.circuit_breaker.interval, null), var.circuit_breaker.interval)
    trip_duration      = coalesce(try(m.circuit_breaker.trip_duration, null), var.circuit_breaker.trip_duration)
    trip_on_429        = coalesce(try(m.circuit_breaker.trip_on_429, null), var.circuit_breaker.trip_on_429)
    accept_retry_after = coalesce(try(m.circuit_breaker.accept_retry_after, null), var.circuit_breaker.accept_retry_after)
  } }

  # Backend URL per pool member: module-created accounts derive it from the
  # created azurerm_cognitive_account; BYO members use the consumer-supplied endpoint_url.
  member_endpoint = { for k, m in local.pool_members : k =>
    m.create_account != null
    ? "${azurerm_cognitive_account.member[k].endpoint}openai"
    : "${trimsuffix(m.endpoint_url, "/")}/openai"
  }

  # Member Cognitive account names mirror local.foundry_name's convention
  # ("${var.name_prefix}-fdry-${local.suffix}"): same prefix source and same
  # local.suffix, with the member key inserted for uniqueness across members.
  # lower() + substr(...,0,63) are defensive (foundry_name needs neither since
  # var.name_prefix is length-validated and has no member key appended) because
  # member keys are consumer-chosen map keys with no length/case constraint.
  member_account_name = { for k, m in local.created_members : k =>
    substr(lower("${var.name_prefix}-fdry-${k}-${local.suffix}"), 0, 63)
  }
}
