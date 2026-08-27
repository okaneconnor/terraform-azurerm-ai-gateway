# Unit tests: plan-mode against mocked providers — no Azure credentials needed.
# Run with: terraform test
#
# Notes for maintainers:
# - mock_data defaults must be UUID-shaped where provider validators run on them
#   (data sources are read at plan, unlike resource computed attributes).
# - Assertions must avoid values that are unknown at plan (anything derived from a
#   computed attribute, e.g. the module-created gateway app's client_id) — the
#   byo_gateway_app run exists to make the JWT fragment fully known and assertable.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000001"
      client_id       = "00000000-0000-0000-0000-000000000003"
    }
  }
  # azapi parent_id / resource_group_id parsers require a real ARM ID (leading "/"),
  # so the mock must return a valid RG id rather than a random short string.
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg"
    }
  }
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-existing-rg"
      location = "uksouth"
    }
  }
}

mock_provider "azuread" {
  mock_data "azuread_service_principal" {
    defaults = {
      object_id    = "00000000-0000-0000-0000-000000000010"
      app_role_ids = { "AI.Gateway.Standard" = "00000000-0000-0000-0000-000000000011" }
    }
  }
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000002"
      object_id = "00000000-0000-0000-0000-000000000001"
      client_id = "00000000-0000-0000-0000-000000000003"
    }
  }
}

mock_provider "azapi" {}

variables {
  location        = "uksouth"
  publisher_name  = "Test"
  publisher_email = "test@example.com"

  # model_deployments has no default (consumer must choose current models). A
  # chat + embeddings pair on Standard SKUs satisfies the non-empty check, the
  # semantic_cache embeddings-deployment default, and the SKU-allowlist default.
  model_deployments = {
    "chat" = {
      model_name    = "chat-model"
      model_version = "1"
      sku_name      = "Standard"
    }
    "text-embedding-ada-002" = {
      model_name    = "text-embedding-ada-002"
      model_version = "2"
      sku_name      = "Standard"
    }
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_resource_group.rg["this"].name == "rg-aigw-uks"
    error_message = "RG name must follow the CAF convention <type>-<prefix>-<region>."
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.local_auth_enabled == false
    error_message = "Foundry account must be Entra-only (no API keys)."
  }

  assert {
    condition     = alltrue([for k, a in azurerm_cognitive_account.svc : a.local_auth_enabled == false])
    error_message = "All AI service accounts must be Entra-only (no API keys)."
  }

  # Default preset keyed per caller, guarded so the registry seam can supersede it.
  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.tier_rate.value, "calls=\"30\""),
      strcontains(azurerm_api_management_policy_fragment.tier_rate.value, "!context.Variables.ContainsKey(&quot;team-policied&quot;)"),
      strcontains(azurerm_api_management_policy_fragment.tier_tokens.value, "!context.Variables.ContainsKey(&quot;team-policied&quot;)"),
    ])
    error_message = "Tier fragments must render the default preset's limits behind the team-policied guard."
  }

  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.tier_rate.value, "caller-app-id")
    error_message = "Tier rate limiting must key off the caller-app-id variable."
  }

  # Content safety must screen BEFORE the semantic cache (cache hits stay screened).
  assert {
    condition     = strcontains(split("llm-semantic-cache-lookup", azurerm_api_management_api_policy.foundry["this"].xml_content)[0], "ai-content-safety")
    error_message = "ai-content-safety must precede llm-semantic-cache-lookup in the foundry policy."
  }

  # Token metrics must not re-parse the Authorization header (MI overwrites it).
  assert {
    condition = alltrue([
      !strcontains(azurerm_api_management_policy_fragment.token_metric.value, "AsJwt"),
      strcontains(azurerm_api_management_policy_fragment.token_metric.value, "caller-app-id"),
    ])
    error_message = "Token-metric fragment must read caller-app-id, not re-parse the Authorization header."
  }

  # Residency guardrail is an allowlist (fails closed for future non-regional SKUs).
  assert {
    condition     = strcontains(azurerm_policy_definition.allowed_deployment_skus["this"].policy_rule, "notIn")
    error_message = "Deployment-SKU policy must be an allowlist (notIn), not a denylist."
  }

  # Default circuit breaker trips on 5xx only.
  assert {
    condition     = !contains([for r in azapi_resource.foundry_member.body.properties.circuitBreaker.rules[0].failureCondition.statusCodeRanges : r.min], 429)
    error_message = "Default breaker must not trip on 429 (single-member pool blast radius)."
  }

  assert {
    condition     = length(azuread_application.demo) == 0
    error_message = "Demo clients must be off by default."
  }

  # Custom metrics must be enabled on the App Insights diagnostic or the
  # emit-token-metric policy silently no-ops (found in live testing).
  assert {
    condition     = azapi_update_resource.appinsights_custom_metrics.body.properties.metrics == true
    error_message = "App Insights diagnostic must enable custom metrics."
  }
}

run "byo_gateway_app" {
  command = plan

  variables {
    existing_gateway_app = { client_id = "11111111-1111-1111-1111-111111111111" }
  }

  assert {
    condition     = length(azuread_application.gateway) == 0
    error_message = "BYO gateway app must skip the module-created app registration."
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "11111111-1111-1111-1111-111111111111"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "AI.Gateway.Standard"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "caller-app-id"),
    ])
    error_message = "JWT fragment must pin the BYO audience, require the admission role, and set caller-app-id."
  }

  assert {
    condition = alltrue([
      output.gateway_app_object_id == "00000000-0000-0000-0000-000000000010",
      output.gateway_app_role_id == "00000000-0000-0000-0000-000000000011",
      output.admission_app_role == "AI.Gateway.Standard",
    ])
    error_message = "gateway_app_object_id / gateway_app_role_id must resolve via the BYO service-principal data source."
  }
}

run "byo_missing_admission_role_fails" {
  command = plan

  variables {
    existing_gateway_app = { client_id = "11111111-1111-1111-1111-111111111111" }
    admission_app_role   = "AI.Gateway.Other"
  }

  expect_failures = [check.byo_admission_role, output.gateway_app_role_id]
}

# caller-app-id is the counter-key for the rate limit and the token limit/quota, and
# the vary-by for the semantic cache. It must resolve for every caller shape, and must
# never resolve to "" — an empty key pools unrelated callers into one shared bucket.
run "caller_app_id_reads_appid_and_fails_closed" {
  command = plan

  variables {
    existing_gateway_app = { client_id = "11111111-1111-1111-1111-111111111111" }
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "GetValueOrDefault(&quot;azp&quot;"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "GetValueOrDefault(&quot;appid&quot;"),
    ])
    error_message = "caller-app-id must read azp (v2 tokens) with an appid fallback (v1 tokens) so every caller keys to its own identity."
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "IsNullOrEmpty"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "403"),
    ])
    error_message = "The fragment must fail closed with 403 when neither azp nor appid is present, so no caller can occupy the shared empty-key bucket."
  }
}

run "cache_and_safety_disabled" {
  command = plan

  variables {
    semantic_cache = { enabled = false }
    content_safety = { enabled = false }
  }

  assert {
    condition     = length(azurerm_managed_redis.cache) == 0
    error_message = "Disabling semantic_cache must skip Redis entirely."
  }

  assert {
    condition     = length(azurerm_api_management_policy_fragment.content_safety) == 0
    error_message = "Disabling content_safety must skip the fragment."
  }

  assert {
    condition     = !strcontains(azurerm_api_management_api_policy.foundry["this"].xml_content, "llm-semantic-cache-lookup")
    error_message = "Foundry policy must not reference the cache when disabled."
  }

  assert {
    condition     = !strcontains(azurerm_api_management_api_policy.foundry["this"].xml_content, "ai-content-safety")
    error_message = "Foundry policy must not include content safety when disabled."
  }
}

run "extra_tier_and_demo_clients" {
  command = plan

  variables {
    create_demo_clients = true
    default_tier        = "ai-premium"
    tiers = {
      "ai-sandbox"             = { tokens_per_minute = 20000, rate_limit_calls = 30 }
      "ai-production-standard" = { tokens_per_minute = 150000, rate_limit_calls = 120 }
      "ai-premium"             = { tokens_per_minute = 500000, rate_limit_calls = 300 }
    }
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.tier_tokens.value, "tokens-per-minute=\"500000\""),
      strcontains(azurerm_api_management_policy_fragment.tier_rate.value, "calls=\"300\""),
    ])
    error_message = "The default_tier preset's numbers must render into both limit fragments."
  }

  assert {
    condition     = length(azuread_application.demo) == 3
    error_message = "One demo client per tier preset."
  }

  assert {
    condition     = length(output.tier_names) == 3
    error_message = "tier_names must list every preset for the onboarding registry to reference."
  }
}

# Full-stack shape: every feature on, three tiers, demo clients. Asserts
# the FULL gateway resource graph materializes from the module — the strongest
# offline proof that a complete deployment renders correctly.
run "full_stack_shape" {
  command = plan

  variables {
    create_demo_clients = true
    semantic_cache      = { enabled = true }
    default_tier        = "ai-production-standard"
    tiers = {
      "ai-sandbox"             = { tokens_per_minute = 20000, rate_limit_calls = 30 }
      "ai-production-standard" = { tokens_per_minute = 150000, rate_limit_calls = 120 }
      "ai-premium"             = { tokens_per_minute = 500000, rate_limit_calls = 300 }
    }
  }

  assert {
    condition     = length(azurerm_cognitive_account.svc) == 4
    error_message = "All four default AI services must deploy."
  }

  assert {
    condition     = length(azurerm_cognitive_deployment.model) == 2
    error_message = "Both default model deployments (chat + embeddings) must deploy."
  }

  # 4 AI services + foundry + key vault + redis = 7 private endpoints.
  assert {
    condition     = length(azurerm_private_endpoint.pe) == 7
    error_message = "Full stack must wire 7 private endpoints (4 services, foundry, key vault, redis)."
  }

  # foundry API + 4 service APIs, each service with GET/POST wildcard ops.
  assert {
    condition     = length(azurerm_api_management_api.svc) == 4 && length(azurerm_api_management_api_operation.svc_wildcard) == 8
    error_message = "All passthrough APIs and wildcard operations must deploy."
  }

  assert {
    condition     = length(azurerm_api_management_backend.svc) == 4 && length(azurerm_api_management_backend.embeddings) == 1
    error_message = "One backend per service plus the embeddings backend."
  }

  assert {
    condition = alltrue([
      length(azurerm_managed_redis.cache) == 1,
      length(azurerm_api_management_redis_cache.cache) == 1,
      length(azurerm_api_management_policy_fragment.content_safety) == 1,
      length(azurerm_policy_definition.allowed_deployment_skus) == 1,
      length(azapi_resource.api_center) == 1,
      length(azurerm_key_vault.main) == 1,
      length(azurerm_application_insights_workbook.apim) == 1,
      length(azapi_resource.llm_diagnostic) == 2, # facade + legacy foundry
    ])
    error_message = "Every optional component must be present in the full stack."
  }

  assert {
    condition = alltrue([
      length(azuread_application.demo) == 3,
      length(azuread_application_password.demo) == 3,
      length(azuread_app_role_assignment.demo) == 3,
    ])
    error_message = "One demo client (app + secret + role assignment) per tier."
  }

  # RBAC: managed identity gets a role on foundry and on each service.
  assert {
    condition     = length(azurerm_role_assignment.apim_svc) == 4
    error_message = "APIM's managed identity must get Cognitive Services User on each service."
  }
}

# Semantic caching is opt-in: at defaults the Redis cache is never provisioned
# (Azure Managed Redis failed to provision in live testing, so a default apply
# must not depend on it).
run "semantic_cache_default_off" {
  command = plan

  assert {
    condition     = length(azurerm_managed_redis.cache) == 0
    error_message = "semantic_cache must default off (no Redis at defaults)."
  }
}

run "rejects_multiple_tiers_without_default" {
  command = plan

  variables {
    tiers = {
      a = { tokens_per_minute = 1000, rate_limit_calls = 10 }
      b = { tokens_per_minute = 2000, rate_limit_calls = 20 }
    }
  }

  expect_failures = [var.default_tier]
}

run "rejects_default_tier_not_in_tiers" {
  command = plan

  variables {
    default_tier = "missing"
    tiers = {
      a = { tokens_per_minute = 1000, rate_limit_calls = 10 }
    }
  }

  expect_failures = [var.default_tier]
}

run "rejects_vnet_incompatible_apim_sku" {
  command = plan

  variables {
    apim_sku_name = "Standard_1"
  }

  expect_failures = [var.apim_sku_name]
}

run "rejects_demo_clients_with_byo_app" {
  command = plan

  variables {
    create_demo_clients  = true
    existing_gateway_app = { client_id = "00000000-0000-0000-0000-000000000000" }
  }

  expect_failures = [var.create_demo_clients]
}

run "rejects_unknown_embeddings_deployment" {
  command = plan

  variables {
    semantic_cache = { enabled = true, embeddings_deployment = "nope" }
  }

  expect_failures = [var.semantic_cache]
}

run "rejects_empty_model_deployments" {
  command = plan

  variables {
    model_deployments = {}
  }

  expect_failures = [var.model_deployments]
}

# A model SKU outside the enabled allowlist is caught at plan (no more silent
# apply-time Azure Policy denial). Embeddings key present so only the SKU check trips.
run "rejects_model_sku_outside_allowlist" {
  command = plan

  variables {
    model_deployments = {
      "chat"                   = { model_name = "chat", model_version = "1", sku_name = "GlobalStandard" }
      "text-embedding-ada-002" = { model_name = "text-embedding-ada-002", model_version = "2", sku_name = "Standard" }
    }
    # deployment_sku_policy default allows only "Standard".
  }

  expect_failures = [var.model_deployments]
}

# The real consumer case: a current model only offered on GlobalStandard, allow-listed.
run "accepts_globalstandard_when_allowlisted" {
  command = plan

  variables {
    model_deployments = {
      "chat"                   = { model_name = "chat", model_version = "1", sku_name = "GlobalStandard" }
      "text-embedding-ada-002" = { model_name = "text-embedding-ada-002", model_version = "2", sku_name = "Standard" }
    }
    deployment_sku_policy = { enabled = true, allowed_sku_names = ["Standard", "GlobalStandard"] }
  }

  assert {
    condition     = length(azurerm_cognitive_deployment.model) == 2
    error_message = "A GlobalStandard model must plan cleanly when its SKU is allow-listed."
  }
}

# With the SKU policy off, the cross-validation is skipped (any SKU permitted).
run "sku_policy_disabled_allows_any_sku" {
  command = plan

  variables {
    model_deployments = {
      "chat"                   = { model_name = "chat", model_version = "1", sku_name = "GlobalStandard" }
      "text-embedding-ada-002" = { model_name = "text-embedding-ada-002", model_version = "2", sku_name = "Standard" }
    }
    deployment_sku_policy = { enabled = false }
  }

  assert {
    condition     = length(azurerm_policy_definition.allowed_deployment_skus) == 0
    error_message = "Disabling the SKU policy must skip the definition and its cross-validation."
  }
}

# ── Bring-your-own / optionality ─────────────────────────────────────────────

run "byo_resource_group" {
  command = plan

  variables {
    existing_resource_group_name = "platform-shared-rg"
  }

  assert {
    condition     = length(azurerm_resource_group.rg) == 0
    error_message = "existing_resource_group_name must skip creating the RG."
  }
}

run "byo_network" {
  command = plan

  variables {
    existing_network = {
      vnet_id        = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/virtualNetworks/spoke"
      apim_subnet_id = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/virtualNetworks/spoke/subnets/apim"
      pe_subnet_id   = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/virtualNetworks/spoke/subnets/pe"
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_virtual_network.main) == 0,
      length(azurerm_subnet.apim) == 0,
      length(azurerm_subnet.pe) == 0,
      length(azurerm_network_security_group.apim) == 0,
    ])
    error_message = "existing_network must skip creating the VNet, subnets, and NSG."
  }

  assert {
    condition     = endswith(azurerm_api_management.apim.virtual_network_configuration[0].subnet_id, "/subnets/apim")
    error_message = "APIM must be injected into the bring-your-own apim subnet."
  }
}

run "byo_private_dns_zones" {
  command = plan

  variables {
    existing_private_dns_zone_ids = {
      cognitive  = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com"
      openai     = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
      aiservices = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.services.ai.azure.com"
      keyvault   = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
      redis      = "/subscriptions/x/resourceGroups/hub/providers/Microsoft.Network/privateDnsZones/privatelink.redis.azure.net"
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_private_dns_zone.zone) == 0,
      length(azurerm_private_dns_zone_virtual_network_link.link) == 0,
    ])
    error_message = "existing_private_dns_zone_ids must skip creating zones and VNet links."
  }
}

run "byo_observability" {
  command = plan

  variables {
    existing_log_analytics_workspace_id = "/subscriptions/x/resourceGroups/obs/providers/Microsoft.OperationalInsights/workspaces/central"
    existing_application_insights = {
      id                = "/subscriptions/x/resourceGroups/obs/providers/Microsoft.Insights/components/central"
      connection_string = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_log_analytics_workspace.law) == 0,
      length(azurerm_application_insights.ai) == 0,
    ])
    error_message = "Bring-your-own LAW + App Insights must skip creating them."
  }
}

run "internal_vnet_mode" {
  command = plan

  variables {
    apim_virtual_network_type = "Internal"
  }

  assert {
    condition     = azurerm_api_management.apim.virtual_network_type == "Internal"
    error_message = "apim_virtual_network_type must flow to the APIM resource."
  }
}

# ── Versioned facade (#38): /v1, model indirection, error taxonomy ────────────

run "facade_default_identity_map" {
  command = plan

  assert {
    condition     = azurerm_api_management_api.facade.path == "v1"
    error_message = "The facade must live at path v1."
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_api_policy.facade.xml_content, "case &quot;chat&quot;: return &quot;chat&quot;;"),
      strcontains(azurerm_api_management_api_policy.facade.xml_content, "case &quot;text-embedding-ada-002&quot;: return &quot;text-embedding-ada-002&quot;;"),
    ])
    error_message = "Default model_map must be the identity map over model_deployments."
  }

  assert {
    condition     = strcontains(azurerm_api_management_api_policy.facade.xml_content, "model_not_found")
    error_message = "The facade must return model_not_found for unknown canonical names."
  }

  assert {
    condition     = strcontains(azurerm_api_management_api_policy.facade.xml_content, "api-version=2024-10-21")
    error_message = "The facade must pin the backend api-version."
  }

  assert {
    condition     = !strcontains(azurerm_api_management_api_policy.facade.xml_content, "streaming_not_supported")
    error_message = "Streaming is supported in v1 — no rejection branch may exist."
  }
}

run "facade_content_safety_precedes_cache" {
  command = plan

  variables {
    semantic_cache = { enabled = true }
  }

  assert {
    condition     = strcontains(split("llm-semantic-cache-lookup", azurerm_api_management_api_policy.facade.xml_content)[0], "ai-content-safety")
    error_message = "ai-content-safety must precede llm-semantic-cache-lookup in the facade policy."
  }

  assert {
    condition     = strcontains(azurerm_api_management_api_policy.facade.xml_content, "llm-semantic-cache-store")
    error_message = "The facade must store completions in the semantic cache when enabled."
  }
}

run "facade_custom_model_map_replaces_identity" {
  command = plan

  variables {
    model_map        = { fast = "chat" }
    aoai_api_version = "2025-01-01"
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_api_policy.facade.xml_content, "case &quot;fast&quot;: return &quot;chat&quot;;"),
      !strcontains(azurerm_api_management_api_policy.facade.xml_content, "case &quot;text-embedding-ada-002&quot;"),
      strcontains(azurerm_api_management_api_policy.facade.xml_content, "api-version=2025-01-01"),
    ])
    error_message = "A custom model_map must replace the identity map wholesale, and aoai_api_version must flow into the rewrite."
  }
}

run "rejects_model_map_unknown_deployment" {
  command = plan

  variables {
    model_map = { fast = "not-a-deployment" }
  }

  expect_failures = [var.model_map]
}

run "error_taxonomy_wired_into_both_surfaces" {
  command = plan

  variables {
    existing_gateway_app = { client_id = "11111111-1111-1111-1111-111111111111" }
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.error_taxonomy.value, "invalid_token"),
      strcontains(azurerm_api_management_policy_fragment.error_taxonomy.value, "rate_limit_exceeded"),
      strcontains(azurerm_api_management_policy_fragment.error_taxonomy.value, "token_quota_exceeded"),
      strcontains(azurerm_api_management_policy_fragment.error_taxonomy.value, "content_filtered"),
      strcontains(azurerm_api_management_policy_fragment.error_taxonomy.value, "Retry-After"),
      strcontains(azurerm_api_management_api_policy.facade.xml_content, "ai-error-taxonomy"),
      strcontains(azurerm_api_management_api_policy.foundry["this"].xml_content, "ai-error-taxonomy"),
    ])
    error_message = "The taxonomy fragment must carry every error code and be included in on-error of both LLM surfaces."
  }

  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "missing_caller_id")
    error_message = "The caller-app-id 403 must return the machine-readable missing_caller_id code."
  }
}

run "legacy_path_disabled_leaves_facade_only" {
  command = plan

  variables {
    enable_legacy_openai_path = false
  }

  assert {
    condition = alltrue([
      length(azurerm_api_management_api.foundry) == 0,
      length(azurerm_api_management_api_policy.foundry) == 0,
      azurerm_api_management_api.facade.path == "v1",
    ])
    error_message = "Disabling the legacy path must remove the raw /openai API and leave the facade standing."
  }
}

# ── Naming convention (CAF): <type>-<name_prefix>[-<env>][-<region>][-<instance>] ──

run "naming_minimal_omits_optional_tokens" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_resource_group.rg["this"].name == "rg-aigw-uks",
      azurerm_api_management.apim.name == "apim-aigw-uks",
      azurerm_log_analytics_workspace.law["this"].name == "log-aigw-uks",
      azurerm_application_insights.ai["this"].name == "appi-aigw-uks",
      azurerm_key_vault.main["this"].name == "kv-aigw-uks",
      azurerm_virtual_network.main["this"].name == "vnet-aigw-uks",
    ])
    error_message = "With environment and instance unset, names must be <type>-<prefix>-<region> with the optional tokens dropped entirely."
  }
}

run "naming_full_token_order" {
  command = plan

  variables {
    name_prefix = "contoso"
    environment = "prod"
    instance    = "002"
  }

  assert {
    condition = alltrue([
      azurerm_resource_group.rg["this"].name == "rg-contoso-prod-uks-002",
      azurerm_api_management.apim.name == "apim-contoso-prod-uks-002",
      azurerm_cognitive_account.foundry.name == "aif-contoso-prod-uks-002",
      azurerm_key_vault.main["this"].name == "kv-contoso-prod-uks-002",
    ])
    error_message = "Token order must be <type>-<prefix>-<env>-<region>-<instance> for every resource, with the CAF type abbreviation first."
  }
}

# The instance token is how two deployments coexist in one subscription now that no
# random component is generated. If it failed to reach the globally-scoped names,
# the second deployment would collide at apply.
run "naming_instance_disambiguates_global_names" {
  command = plan

  variables {
    instance = "002"
  }

  assert {
    condition = alltrue([
      azurerm_api_management.apim.name == "apim-aigw-uks-002",
      azurerm_key_vault.main["this"].name == "kv-aigw-uks-002",
      azurerm_cognitive_account.foundry.name == "aif-aigw-uks-002",
    ])
    error_message = "The instance token must reach every globally-scoped name, or side-by-side deployments collide."
  }
}

run "naming_custom_names_override" {
  command = plan

  variables {
    custom_names = {
      apim      = "legacy-apim-name"
      key_vault = "legacy-kv"
    }
  }

  assert {
    condition = alltrue([
      azurerm_api_management.apim.name == "legacy-apim-name",
      azurerm_key_vault.main["this"].name == "legacy-kv",
      # Untouched keys still follow the convention.
      azurerm_log_analytics_workspace.law["this"].name == "log-aigw-uks",
    ])
    error_message = "custom_names must override per resource without affecting the rest — this is the v1 adoption path."
  }
}

# Names are asserted against their Azure length cap rather than silently truncated:
# a clipped name can collide with another deployment's clipped name, which surfaces
# as a confusing "already exists" at apply.
#
# Key Vault is disabled here deliberately. Its name is still composed and still
# length-checked, but with no vault resource to plan, the azurerm provider's own
# schema validator does not run — so this proves the module's check fires on its own,
# with a message naming the exact knob to turn. (When the vault IS enabled the
# provider rejects the name first, with a far less actionable error.)
run "naming_length_cap_fails_closed" {
  command = plan

  variables {
    name_prefix = "contoso-ai-gate" # 15, the maximum
    environment = "production"      # 10, the maximum
    instance    = "0002"            # 4, the maximum
    key_vault   = { enabled = false }
  }

  expect_failures = [check.name_lengths]
}

run "key_vault_disabled" {
  command = plan

  variables {
    key_vault = { enabled = false }
  }

  assert {
    condition = alltrue([
      length(azurerm_key_vault.main) == 0,
      length(azurerm_role_assignment.apim_kv_secrets) == 0,
    ])
    error_message = "key_vault.enabled = false must skip the vault and its role assignment."
  }
}

run "key_vault_premium_sku" {
  command = plan

  variables {
    key_vault = { enabled = true, sku_name = "premium" }
  }

  assert {
    condition     = azurerm_key_vault.main["this"].sku_name == "premium"
    error_message = "key_vault.sku_name must flow to the vault (premium = HSM-backed)."
  }
}

run "rejects_bad_admission_role_charset" {
  command = plan

  variables {
    admission_app_role = "AI Gateway Standard"
  }

  expect_failures = [var.admission_app_role]
}

run "rejects_invalid_internal_mode" {
  command = plan

  variables {
    apim_virtual_network_type = "None"
  }

  expect_failures = [var.apim_virtual_network_type]
}

# ── Production hardening: output content safety, token quota, TLS floor ───────

run "content_safety_completions_default_off" {
  command = plan

  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.content_safety["this"].value, "enforce-on-completions=\"false\"")
    error_message = "By default content safety must NOT enforce on completions (enforce-on-completions=\"false\")."
  }
}

run "content_safety_completions_enabled" {
  command = plan

  variables {
    content_safety = { enforce_on_completions = true }
  }

  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.content_safety["this"].value, "enforce-on-completions=\"true\"")
    error_message = "content_safety.enforce_on_completions=true must render enforce-on-completions=\"true\"."
  }
}

run "tier_token_quota_rendered" {
  command = plan

  variables {
    tiers = {
      "ai-sandbox" = {
        tokens_per_minute  = 20000
        rate_limit_calls   = 30
        token_quota        = 500000
        token_quota_period = "Daily"
      }
    }
  }

  # Rendered attributes AND their spacing must be correct (the ~} trim-marker bug
  # that stripped inter-attribute spaces would produce malformed policy XML here).
  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.tier_tokens.value, "tokens-per-minute=\"20000\" token-quota=\"500000\" token-quota-period=\"Daily\" estimate-prompt-tokens=")
    error_message = "A tier with token_quota must render well-formed token-quota / token-quota-period with correct attribute spacing."
  }
}

run "default_tiers_no_token_quota" {
  command = plan

  assert {
    condition = alltrue([
      !strcontains(azurerm_api_management_policy_fragment.tier_tokens.value, "token-quota"),
      # default render keeps the single space between tokens-per-minute and estimate-prompt-tokens
      strcontains(azurerm_api_management_policy_fragment.tier_tokens.value, "tokens-per-minute=\"20000\" estimate-prompt-tokens="),
    ])
    error_message = "Default tiers (no token_quota) must render no token-quota attribute and preserve attribute spacing."
  }
}

run "rejects_invalid_token_quota_period" {
  command = plan

  variables {
    tiers = {
      a = { tokens_per_minute = 1000, rate_limit_calls = 10, token_quota = 1000, token_quota_period = "Minutely" }
    }
  }

  expect_failures = [var.tiers]
}

run "apim_tls_hardened" {
  command = plan

  assert {
    condition = alltrue([
      azurerm_api_management.apim.security[0].frontend_tls10_enabled == false,
      azurerm_api_management.apim.security[0].frontend_tls11_enabled == false,
      azurerm_api_management.apim.security[0].backend_tls10_enabled == false,
      azurerm_api_management.apim.security[0].backend_tls11_enabled == false,
      azurerm_api_management.apim.security[0].triple_des_ciphers_enabled == false,
    ])
    error_message = "APIM must reject TLS 1.0/1.1 and 3DES on both frontend and backend."
  }
}

run "apim_zones_premium" {
  command = plan

  variables {
    apim_sku_name = "Premium_2"
    apim_zones    = ["1", "2"]
  }

  assert {
    condition = length(azurerm_api_management.apim.zones) == 2 && alltrue([
      for z in ["1", "2"] : contains(tolist(azurerm_api_management.apim.zones), z)
    ])
    error_message = "apim_zones must be passed through to the APIM resource for zonal deployment."
  }

  # External VNet + zones must auto-provision a zone-redundant Standard public IP
  # (its id wires into public_ip_address_id, unassertable here as it's unknown at plan).
  assert {
    condition     = azurerm_public_ip.apim["this"].sku == "Standard" && length(azurerm_public_ip.apim["this"].zones) == 2
    error_message = "zonal External APIM must get a zone-redundant Standard public IP across both zones."
  }
}

run "rejects_zones_on_developer" {
  command = plan

  variables {
    apim_zones = ["1", "2"]
  }

  expect_failures = [var.apim_zones]
}

run "rejects_zones_exceeding_units" {
  command = plan

  variables {
    apim_sku_name = "Premium_1"
    apim_zones    = ["1", "2", "3"]
  }

  expect_failures = [var.apim_zones]
}

# ── Observability & cost add-ons (#9, #10, #11, #21) ──────────────────────────

run "backend_diagnostics_default_on" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.foundry) == 1 && length(azurerm_monitor_diagnostic_setting.svc) == length(var.ai_services)
    error_message = "Backend diagnostics default to on: foundry + one per ai_service."
  }
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.keyvault) == 1 && length(azurerm_monitor_diagnostic_setting.redis) == 0
    error_message = "KV diagnostics on (KV default enabled); Redis off (cache default disabled)."
  }
}

run "backend_diagnostics_disabled" {
  command = plan

  variables {
    enable_backend_diagnostics = false
  }

  assert {
    condition = alltrue([
      length(azurerm_monitor_diagnostic_setting.foundry) == 0,
      length(azurerm_monitor_diagnostic_setting.svc) == 0,
      length(azurerm_monitor_diagnostic_setting.keyvault) == 0,
    ])
    error_message = "enable_backend_diagnostics=false must create no backend diagnostic settings."
  }
}

run "alerts_disabled_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_monitor_action_group.main) == 0 && length(azurerm_monitor_metric_alert.apim_capacity) == 0 && length(azurerm_monitor_scheduled_query_rules_alert_v2.throttle_429) == 0
    error_message = "Alerts must be off by default (no action group, no alerts)."
  }
}

run "alerts_enabled" {
  command = plan

  variables {
    alerts = {
      enabled                        = true
      email_receivers                = ["ops@example.com"]
      model_tokens_per_min_threshold = 100000
    }
  }

  assert {
    condition = alltrue([
      length(azurerm_monitor_action_group.main) == 1,
      length(azurerm_monitor_metric_alert.apim_capacity) == 1,
      length(azurerm_monitor_metric_alert.gateway_5xx) == 1,
      length(azurerm_monitor_metric_alert.model_tokens) == 1,
      length(azurerm_monitor_scheduled_query_rules_alert_v2.throttle_429) == 1,
      length(azurerm_monitor_scheduled_query_rules_alert_v2.backend_failures) == 1,
    ])
    error_message = "alerts.enabled must create the action group + all five alerts (model_tokens when threshold set)."
  }
}

run "alerts_byo_action_group" {
  command = plan

  variables {
    alerts = {
      enabled                  = true
      existing_action_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/existing"
    }
  }

  assert {
    condition     = length(azurerm_monitor_action_group.main) == 0 && length(azurerm_monitor_metric_alert.apim_capacity) == 1
    error_message = "A supplied action group id must skip creating one but still wire the alerts."
  }
}

run "rejects_alerts_without_destination" {
  command = plan

  variables {
    alerts = { enabled = true }
  }

  expect_failures = [var.alerts]
}

run "budget_disabled_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_consumption_budget_resource_group.budget) == 0
    error_message = "Budget must be off by default."
  }
}

run "budget_enabled" {
  command = plan

  variables {
    budget = {
      enabled        = true
      amount         = 500
      start_date     = "2026-07-01T00:00:00Z"
      contact_emails = ["finops@example.com"]
    }
  }

  assert {
    condition     = length(azurerm_consumption_budget_resource_group.budget) == 1
    error_message = "budget.enabled with a start_date + destination must create the budget."
  }
}

run "rejects_budget_without_start_date" {
  command = plan

  variables {
    budget = {
      enabled        = true
      contact_emails = ["finops@example.com"]
    }
  }

  expect_failures = [var.budget]
}


# Regression guards for two bugs behavioral testing caught (both passed plan+CI):
run "redis_diagnostic_is_metrics_only" {
  command = plan

  variables {
    semantic_cache = { enabled = true }
  }

  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.redis["this"].enabled_log) == 0
    error_message = "Azure Managed Redis (redisEnterprise) supports no diagnostic log categories — the setting must be metrics-only (no enabled_log; category_group=allLogs 400s)."
  }
}

run "backend_failures_kql_matches_real_reasons" {
  command = plan

  variables {
    alerts = { enabled = true, email_receivers = ["ops@example.com"] }
  }

  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.backend_failures["this"].criteria[0].query, "PoolIsInactive")
    error_message = "backend_failures KQL must match APIM's real LastErrorReason values (e.g. PoolIsInactive when the breaker opens), not an unmatched 'has \"Backend\"'."
  }
}

# ── Multi-member backend pool (#15) ───────────────────────────────────────────

run "backend_pool_default_single_member" {
  command = plan
  assert {
    condition     = length(output.backend_pool_members) == 1
    error_message = "Default backend_pool must yield a single (primary) member."
  }
  assert {
    condition     = output.backend_pool_members["primary"].priority == 1
    error_message = "Primary member must default to priority 1."
  }
}

run "backend_pool_two_members_shape" {
  command = plan
  variables {
    backend_pool = {
      primary_priority = 2
      members = {
        ptu = {
          endpoint_url              = "https://my-ptu.openai.azure.com/"
          managed_identity_scope_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.CognitiveServices/accounts/ptu"
          priority                  = 1
          circuit_breaker           = { trip_on_429 = true }
        }
      }
    }
  }
  assert {
    condition     = length(output.backend_pool_members) == 2
    error_message = "Primary + one member must yield two pool members."
  }
  assert {
    condition     = output.backend_pool_members["ptu"].kind == "byo"
    error_message = "endpoint_url member must be classified byo."
  }
  assert {
    condition     = output.backend_pool_members["ptu"].trip_on_429 == true
    error_message = "Per-member circuit_breaker override must surface trip_on_429=true."
  }
  assert {
    condition     = output.backend_pool_members["primary"].priority == 2
    error_message = "primary_priority override must apply."
  }
  assert {
    condition     = length(azapi_resource.foundry_pool.body.properties.pool.services) == 2
    error_message = "Pool must contain the primary + one member."
  }
  assert {
    condition     = [for s in azapi_resource.foundry_pool.body.properties.pool.services : s.priority] == [2, 1]
    error_message = "Pool services must be [primary(priority 2), ptu(priority 1)] in order."
  }
}

run "rejects_member_without_account_or_url" {
  command = plan
  variables {
    backend_pool = { members = { bad = { priority = 2 } } }
  }
  expect_failures = [var.backend_pool]
}

run "rejects_member_with_both_account_and_url" {
  command = plan
  variables {
    backend_pool = { members = { bad = {
      endpoint_url   = "https://x.openai.azure.com/"
      create_account = { model_deployments = { chat = { model_name = "chat-model", model_version = "1", sku_name = "Standard" } } }
    } } }
  }
  expect_failures = [var.backend_pool]
}

run "rejects_weight_over_100" {
  command = plan
  variables {
    backend_pool = { members = { ptu = {
      endpoint_url = "https://x.openai.azure.com/"
      priority     = 1
      weight       = 300
    } } }
  }
  expect_failures = [var.backend_pool]
}

run "rejects_priority_over_100" {
  command = plan
  variables {
    backend_pool = { members = { ptu = {
      endpoint_url = "https://x.openai.azure.com/"
      priority     = 200
    } } }
  }
  expect_failures = [var.backend_pool]
}

run "rejects_primary_weight_over_100" {
  command = plan
  variables {
    backend_pool = { primary_weight = 300 }
  }
  expect_failures = [var.backend_pool]
}

run "created_member_provisions_account_and_role" {
  command = plan
  variables {
    # Scoped to just "chat" so the member's create_account deployments satisfy
    # the parity validation (module model_deployments has 2 keys globally).
    model_deployments = {
      chat = { model_name = "chat-model", model_version = "1", sku_name = "Standard" }
    }
    backend_pool = {
      members = {
        payg = {
          priority = 2
          create_account = {
            model_deployments = {
              chat = { model_name = "chat-model", model_version = "1", sku_name = "Standard" }
            }
          }
        }
      }
    }
  }
  assert {
    condition     = azurerm_cognitive_account.member["payg"].kind == "AIServices"
    error_message = "create_account member must provision an AIServices account."
  }
  assert {
    condition     = azurerm_cognitive_account.member["payg"].public_network_access_enabled == false
    error_message = "Member accounts must be private (public network access disabled)."
  }
  assert {
    condition     = azurerm_role_assignment.member_openai["payg"].role_definition_name == "Cognitive Services OpenAI User"
    error_message = "Member account must grant the APIM MI Cognitive Services OpenAI User."
  }
}

run "created_member_gets_backend_diagnostics" {
  command = plan
  variables {
    model_deployments = {
      chat = { model_name = "chat-model", model_version = "1", sku_name = "Standard" }
    }
    backend_pool = {
      members = {
        payg = {
          priority = 2
          create_account = {
            model_deployments = {
              chat = { model_name = "chat-model", model_version = "1", sku_name = "Standard" }
            }
          }
        }
      }
    }
  }
  # log_analytics_workspace_id itself is unknown at plan (module-created LAW's .id
  # is computed), so - mirroring backend_diagnostics_default_on above - assert on
  # for_each existence rather than the unknown attribute value.
  assert {
    condition     = length(azurerm_monitor_diagnostic_setting.member) == 1
    error_message = "Created member accounts must get a backend diagnostic setting when enable_backend_diagnostics is on."
  }
  assert {
    condition     = contains(keys(azurerm_monitor_diagnostic_setting.member), "payg")
    error_message = "Created member accounts must route backend diagnostics to Log Analytics."
  }
}

run "rejects_member_missing_deployment_parity" {
  command = plan
  variables {
    # module var.model_deployments has "chat" + "text-embedding-ada-002" (global
    # variables block); member omits "text-embedding-ada-002" -> parity failure.
    backend_pool = {
      members = { payg = {
        priority       = 2
        create_account = { model_deployments = { chat = { model_name = "chat-model", model_version = "1", sku_name = "Standard" } } }
      } }
    }
  }
  expect_failures = [var.backend_pool]
}

run "rejects_invalid_member_key" {
  command = plan
  variables {
    backend_pool = { members = { "Bad.Key_1" = { priority = 2, endpoint_url = "https://x.openai.azure.com/" } } }
  }
  expect_failures = [var.backend_pool]
}

run "byo_member_backend_created" {
  command = plan
  variables {
    backend_pool = {
      members = {
        ptu = {
          endpoint_url = "https://my-ptu.openai.azure.com/"
          priority     = 1
        }
      }
    }
  }
  assert {
    condition     = azapi_resource.member_backend["ptu"].name == "foundry-member-ptu"
    error_message = "Each pool member must produce a Single backend named foundry-member-<key>."
  }
}

run "member_cleanup_twin_created_per_member" {
  command = plan
  variables {
    backend_pool = {
      members = {
        ptu = { endpoint_url = "https://my-ptu.openai.azure.com/", priority = 1 }
      }
    }
  }
  assert {
    condition     = length(azapi_resource_action.pool_member_cleanup) == 1
    error_message = "Each pool member must get a destroy-time cleanup twin."
  }
  assert {
    condition     = azapi_resource_action.pool_member_cleanup["ptu"].when == "destroy"
    error_message = "The pool-member cleanup action must run at destroy time."
  }
  assert {
    condition     = azapi_resource_action.pool_member_cleanup["ptu"].method == "PATCH"
    error_message = "The pool-member cleanup action must PATCH the pool to detach the member."
  }
}

run "team_seam_wiring" {
  command = plan

  # Onboarding-owned fragments are created inert; allowlist enforces 403.
  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.team_overrides.value, "team-overrides-active"),
      strcontains(azurerm_api_management_policy_fragment.team_content_safety.value, "team-cs-active"),
      strcontains(azurerm_api_management_policy_fragment.model_allowlist.value, "model_not_permitted"),
      azurerm_api_management_policy_fragment.team_overrides.name == "ai-team-overrides",
      azurerm_api_management_policy_fragment.team_content_safety.name == "ai-team-content-safety",
      azurerm_api_management_policy_fragment.model_allowlist.name == "ai-model-allowlist",
    ])
    error_message = "Seam fragments must exist inert under their contract names."
  }

  # Platform CS is guarded so a team rendering can replace it.
  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.content_safety["this"].value, "!context.Variables.ContainsKey(&quot;team-cs-policied&quot;)")
    error_message = "Platform content-safety must skip when a team rendering policied the caller."
  }

  # Facade chain order: overrides before tier fragments; allowlist after the
  # model map (unknown -> 404 wins) and before the rewrite; team CS before platform CS.
  assert {
    condition = alltrue([
      strcontains(split("ai-tier-rate", azurerm_api_management_api_policy.facade.xml_content)[0], "ai-team-overrides"),
      strcontains(split("ai-model-allowlist", azurerm_api_management_api_policy.facade.xml_content)[0], "model_not_found"),
      strcontains(split("rewrite-uri", azurerm_api_management_api_policy.facade.xml_content)[0], "ai-model-allowlist"),
      strcontains(split("ai-content-safety", azurerm_api_management_api_policy.facade.xml_content)[0], "ai-team-content-safety"),
    ])
    error_message = "Facade policy chain must order the seam correctly."
  }

  assert {
    condition = alltrue([
      strcontains(split("ai-tier-rate", azurerm_api_management_api_policy.foundry["this"].xml_content)[0], "ai-team-overrides"),
      strcontains(split("ai-content-safety", azurerm_api_management_api_policy.foundry["this"].xml_content)[0], "ai-team-content-safety"),
    ])
    error_message = "Legacy foundry policy chain must carry the seam too."
  }

  # The onboarding contract outputs.
  assert {
    condition = alltrue([
      contains(output.canonical_models, "chat"),
      contains(output.canonical_models, "text-embedding-ada-002"),
      output.tiers["standard"].rate_limit_calls == 30,
      output.rate_limit_renewal_seconds == 60,
      output.content_safety_contract.category_threshold == 4,
      output.content_safety_contract.shield_prompt == true,
    ])
    error_message = "Onboarding contract outputs must mirror the gateway's presets and CS settings."
  }
}

run "team_seam_when_content_safety_disabled" {
  command = plan

  variables {
    content_safety = { enabled = false }
  }

  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.team_content_safety.value, "team-cs-active"),
      !strcontains(azurerm_api_management_api_policy.facade.xml_content, "ai-team-content-safety"),
      output.content_safety_contract == null,
    ])
    error_message = "With CS disabled the seam fragment still exists (inert) but is not included, and the contract output is null."
  }
}
