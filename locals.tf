resource "random_string" "suffix" {
  count   = var.name_suffix == null ? 1 : 0
  length  = 5
  special = false
  upper   = false
  numeric = true
}

# Display-name form of var.location ("uksouth" -> "UK South"). APIM reports its
# gateway region as the display name, and the external-cache binding must match
# it exactly (see redis.tf).
data "azurerm_location" "current" {
  location = var.location
}

locals {
  suffix = var.name_suffix != null ? var.name_suffix : one(random_string.suffix[*].result)

  # CAF-style region shortcode for the resource-group name; falls back to the
  # raw region string for regions not in the map.
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
  resource_group_name     = var.existing_resource_group_name != null ? var.existing_resource_group_name : azurerm_resource_group.rg[0].name
  resource_group_id       = var.existing_resource_group_name != null ? data.azurerm_resource_group.existing[0].id : azurerm_resource_group.rg[0].id
  resource_group_location = var.existing_resource_group_name != null ? data.azurerm_resource_group.existing[0].location : azurerm_resource_group.rg[0].location

  # ── Effective network (module-created vs bring-your-own) ──
  create_network = var.existing_network == null
  vnet_id        = var.existing_network != null ? var.existing_network.vnet_id : azurerm_virtual_network.main[0].id
  apim_subnet_id = var.existing_network != null ? var.existing_network.apim_subnet_id : azurerm_subnet.apim[0].id
  pe_subnet_id   = var.existing_network != null ? var.existing_network.pe_subnet_id : azurerm_subnet.pe[0].id

  # ── Effective private DNS zones (module-created vs bring-your-own) ──
  create_dns_zones = length(var.existing_private_dns_zone_ids) == 0
  private_dns_zone_ids = local.create_dns_zones ? {
    for k in keys(local.private_dns_zones) : k => azurerm_private_dns_zone.zone[k].id
  } : var.existing_private_dns_zone_ids

  # ── Effective observability (module-created vs bring-your-own) ──
  create_law                     = var.existing_log_analytics_workspace_id == null
  log_analytics_workspace_id     = var.existing_log_analytics_workspace_id != null ? var.existing_log_analytics_workspace_id : azurerm_log_analytics_workspace.law[0].id
  create_app_insights            = var.existing_application_insights == null
  app_insights_id                = var.existing_application_insights != null ? var.existing_application_insights.id : azurerm_application_insights.ai[0].id
  app_insights_connection_string = var.existing_application_insights != null ? var.existing_application_insights.connection_string : azurerm_application_insights.ai[0].connection_string

  # Gateway app identity — module-created unless the consumer brings their own.
  gateway_client_id = var.existing_gateway_app != null ? var.existing_gateway_app.client_id : azuread_application.gateway[0].client_id

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

  # APIs that should emit per-request LLM token logs (ApiManagementGatewayLlmLog).
  # Any future LLM-shaped API added to the gateway belongs in this map so it gets
  # the largeLanguageModel diagnostic automatically.
  llm_apis = {
    foundry = azurerm_api_management_api.foundry.id
  }
}
