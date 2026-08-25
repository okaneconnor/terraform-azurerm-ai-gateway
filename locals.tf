data "azurerm_location" "current" {
  location = var.location
}

locals {
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

  # ── Naming ──────────────────────────────────────────────────────────────────
  # Azure CAF convention, one fixed token order for every resource:
  #
  #     <type>-<name_prefix>[-<environment>][-<region>][-<instance>]
  #
  # `type` is the CAF resource abbreviation and always comes FIRST
  # (learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations).
  # Optional tokens drop out cleanly when null, so a minimal deployment reads
  # `apim-aigw-uks` and a full one `apim-aigw-prod-uks-002`.
  #
  # This block is the ONLY place a resource name is constructed. Anything that needs
  # a name takes it from here — a name built inline elsewhere is a bug, because it
  # escapes both the convention and the length checks below.
  #
  # Names are fully deterministic: the module generates no random component, so the
  # caller owns uniqueness for globally-scoped names. See docs/naming.md.
  name_base = join("-", compact([
    var.name_prefix,
    var.environment,
    local.region_short,
    var.instance,
  ]))

  # Resources whose scope is a parent (subnets, NSG rules, PE connections, DNS links,
  # diagnostic settings, APIM child resources) are named short and descriptively
  # instead — they are already unique within that parent, so repeating the base is
  # noise. Documented as a deliberate exception in docs/naming.md.
  rg_name      = coalesce(var.custom_names.resource_group, "rg-${local.name_base}")
  apim_name    = coalesce(var.custom_names.apim, "apim-${local.name_base}")
  law_name     = coalesce(var.custom_names.log_analytics, "log-${local.name_base}")
  ai_name      = coalesce(var.custom_names.app_insights, "appi-${local.name_base}")
  foundry_name = coalesce(var.custom_names.foundry, "aif-${local.name_base}")
  apic_name    = coalesce(var.custom_names.api_center, "apic-${local.name_base}")
  redis_name   = coalesce(var.custom_names.redis, "amr-${local.name_base}")
  vnet_name    = coalesce(var.custom_names.vnet, "vnet-${local.name_base}")

  # Key Vault takes hyphens but caps at 24 chars, which the composed name can exceed
  # once environment/instance are set. Truncating silently would risk two deployments
  # colliding on the same clipped name, so the cap is asserted at plan time instead
  # (see check "name_lengths" below) and the caller shortens name_prefix or sets
  # custom_names.key_vault.
  kv_name = coalesce(var.custom_names.key_vault, "kv-${local.name_base}")

  # Every generated name that Azure length-caps, checked before anything is created.
  name_length_caps = {
    "key_vault (custom_names.key_vault)"   = { name = local.kv_name, max = 24 }
    "apim (custom_names.apim)"             = { name = local.apim_name, max = 50 }
    "foundry (custom_names.foundry)"       = { name = local.foundry_name, max = 64 }
    "redis (custom_names.redis)"           = { name = local.redis_name, max = 60 }
    "api_center (custom_names.api_center)" = { name = local.apic_name, max = 90 }
    "resource_group"                       = { name = local.rg_name, max = 90 }
  }

  tenant_id = data.azurerm_client_config.current.tenant_id

  resource_group_name     = var.existing_resource_group_name != null ? var.existing_resource_group_name : azurerm_resource_group.rg["this"].name
  resource_group_id       = var.existing_resource_group_name != null ? data.azurerm_resource_group.existing["this"].id : azurerm_resource_group.rg["this"].id
  resource_group_location = var.existing_resource_group_name != null ? data.azurerm_resource_group.existing["this"].location : azurerm_resource_group.rg["this"].location

  create_network = var.existing_network == null
  vnet_id        = var.existing_network != null ? var.existing_network.vnet_id : azurerm_virtual_network.main["this"].id
  apim_subnet_id = var.existing_network != null ? var.existing_network.apim_subnet_id : azurerm_subnet.apim["this"].id
  pe_subnet_id   = var.existing_network != null ? var.existing_network.pe_subnet_id : azurerm_subnet.pe["this"].id

  create_dns_zones = length(var.existing_private_dns_zone_ids) == 0
  private_dns_zone_ids = local.create_dns_zones ? {
    for k in keys(local.private_dns_zones) : k => azurerm_private_dns_zone.zone[k].id
  } : var.existing_private_dns_zone_ids

  create_law                     = var.existing_log_analytics_workspace_id == null
  log_analytics_workspace_id     = var.existing_log_analytics_workspace_id != null ? var.existing_log_analytics_workspace_id : azurerm_log_analytics_workspace.law["this"].id
  create_app_insights            = var.existing_application_insights == null
  app_insights_id                = var.existing_application_insights != null ? var.existing_application_insights.id : azurerm_application_insights.ai["this"].id
  app_insights_connection_string = var.existing_application_insights != null ? var.existing_application_insights.connection_string : azurerm_application_insights.ai["this"].connection_string

  gateway_client_id = var.existing_gateway_app != null ? var.existing_gateway_app.client_id : azuread_application.gateway["this"].client_id

  # The preset applied to every admitted caller: var.default_tier, or the single
  # entry when only one preset is defined (the default_tier validation guarantees
  # one of the two holds).
  default_tier_key  = var.default_tier != null ? var.default_tier : keys(var.tiers)[0]
  default_tier_spec = var.tiers[local.default_tier_key]

  content_safety_keys        = [for k, v in var.ai_services : k if v.kind == "ContentSafety"]
  content_safety_backend_key = length(local.content_safety_keys) > 0 ? local.content_safety_keys[0] : null

  # Facade model indirection: empty model_map means every deployment maps to
  # itself, so the facade works with zero configuration.
  effective_model_map = length(var.model_map) > 0 ? var.model_map : { for k, _ in var.model_deployments : k => k }

  llm_apis = merge(
    { facade = azurerm_api_management_api.facade.id },
    var.enable_legacy_openai_path ? { foundry = azurerm_api_management_api.foundry["this"].id } : {}
  )

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

  member_cb = { for k, m in local.pool_members : k => {
    enabled            = coalesce(try(m.circuit_breaker.enabled, null), var.circuit_breaker.enabled)
    failure_count      = coalesce(try(m.circuit_breaker.failure_count, null), var.circuit_breaker.failure_count)
    interval           = coalesce(try(m.circuit_breaker.interval, null), var.circuit_breaker.interval)
    trip_duration      = coalesce(try(m.circuit_breaker.trip_duration, null), var.circuit_breaker.trip_duration)
    trip_on_429        = coalesce(try(m.circuit_breaker.trip_on_429, null), var.circuit_breaker.trip_on_429)
    accept_retry_after = coalesce(try(m.circuit_breaker.accept_retry_after, null), var.circuit_breaker.accept_retry_after)
  } }

  member_endpoint = { for k, m in local.pool_members : k =>
    m.create_account != null
    ? "${azurerm_cognitive_account.member[k].endpoint}openai"
    : "${trimsuffix(m.endpoint_url, "/")}/openai"
  }

  # Pool members are siblings of the platform Foundry account, so the member key is
  # the discriminator: aif-<member>-<base>.
  member_account_name = { for k, m in local.created_members : k =>
    substr(lower("aif-${k}-${local.name_base}"), 0, 63)
  }
}

# Length caps are asserted rather than silently truncated: a clipped name can collide
# with another deployment's clipped name, which surfaces as a confusing "already
# exists" at apply instead of a clear message here.
check "name_lengths" {
  assert {
    condition = alltrue([
      for _, v in local.name_length_caps : length(v.name) <= v.max
    ])
    error_message = "Generated resource names exceed their Azure length limit: ${join("; ", [
      for k, v in local.name_length_caps :
      "${k} is ${length(v.name)} chars (max ${v.max}): \"${v.name}\""
      if length(v.name) > v.max
    ])}. Shorten name_prefix/environment/instance, or set the matching custom_names entry."
  }
}
