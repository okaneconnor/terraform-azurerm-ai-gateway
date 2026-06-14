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
}

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_resource_group.rg[0].name == "aigw-uks-rg"
    error_message = "RG name should derive the region shortcode from var.location."
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.local_auth_enabled == false
    error_message = "Foundry account must be Entra-only (no API keys)."
  }

  assert {
    condition     = alltrue([for k, a in azurerm_cognitive_account.svc : a.local_auth_enabled == false])
    error_message = "All AI service accounts must be Entra-only (no API keys)."
  }

  # Tier branches render highest tokens_per_minute first (multi-role clients get
  # their best tier) and key counters off the validated caller identity.
  assert {
    condition     = strcontains(split("</when>", azurerm_api_management_policy_fragment.tier_rate.value)[0], "AI.Gateway.Production")
    error_message = "First tier branch must be the highest tier (production outranks sandbox)."
  }

  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.tier_rate.value, "caller-app-id")
    error_message = "Tier rate limiting must key off the caller-app-id variable."
  }

  # Content safety must screen BEFORE the semantic cache (cache hits stay screened).
  assert {
    condition     = strcontains(split("llm-semantic-cache-lookup", azurerm_api_management_api_policy.foundry.xml_content)[0], "ai-content-safety")
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
    condition     = strcontains(azurerm_policy_definition.allowed_deployment_skus[0].policy_rule, "notIn")
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

  # With a known client_id the JWT fragment is fully known at plan: assert the
  # audience, every tier role, and the caller-app-id set-variable.
  assert {
    condition = alltrue([
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "11111111-1111-1111-1111-111111111111"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "AI.Gateway.Sandbox"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "AI.Gateway.Production"),
      strcontains(azurerm_api_management_policy_fragment.entra_jwt.value, "caller-app-id"),
    ])
    error_message = "JWT fragment must pin the BYO audience, list every tier role, and set caller-app-id."
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
    condition     = !strcontains(azurerm_api_management_api_policy.foundry.xml_content, "llm-semantic-cache-lookup")
    error_message = "Foundry policy must not reference the cache when disabled."
  }

  assert {
    condition     = !strcontains(azurerm_api_management_api_policy.foundry.xml_content, "ai-content-safety")
    error_message = "Foundry policy must not include content safety when disabled."
  }
}

run "extra_tier_and_demo_clients" {
  command = plan

  variables {
    create_demo_clients = true
    tiers = {
      "ai-sandbox" = {
        display_name      = "AI Sandbox"
        app_role          = "AI.Gateway.Sandbox"
        tokens_per_minute = 20000
        rate_limit_calls  = 30
      }
      "ai-production-standard" = {
        display_name      = "AI Production Standard"
        app_role          = "AI.Gateway.Production"
        tokens_per_minute = 150000
        rate_limit_calls  = 120
      }
      "ai-premium" = {
        display_name      = "AI Premium"
        app_role          = "AI.Gateway.Premium"
        tokens_per_minute = 500000
        rate_limit_calls  = 300
      }
    }
  }

  # Adding a tier is the COMPLETE change: branch rendered (highest first), limit
  # applied, demo client created.
  assert {
    condition     = strcontains(split("</when>", azurerm_api_management_policy_fragment.tier_tokens.value)[0], "500000")
    error_message = "Premium (highest tpm) must be the first token-limit branch."
  }

  assert {
    condition     = strcontains(azurerm_api_management_policy_fragment.tier_rate.value, "AI.Gateway.Premium")
    error_message = "New tier's role must appear in the rate-limit branches."
  }

  assert {
    condition     = length(azuread_application.demo) == 3
    error_message = "One demo client per tier."
  }
}

# Full-stack shape: every feature on, three tiers, demo clients. Asserts
# the FULL gateway resource graph materializes from the module — the strongest
# offline proof that a complete deployment renders correctly.
run "full_stack_shape" {
  command = plan

  variables {
    create_demo_clients = true
    tiers = {
      "ai-sandbox" = {
        display_name      = "AI Sandbox"
        app_role          = "AI.Gateway.Sandbox"
        tokens_per_minute = 20000
        rate_limit_calls  = 30
      }
      "ai-production-standard" = {
        display_name      = "AI Production Standard"
        app_role          = "AI.Gateway.Production"
        tokens_per_minute = 150000
        rate_limit_calls  = 120
      }
      "ai-premium" = {
        display_name      = "AI Premium"
        app_role          = "AI.Gateway.Premium"
        tokens_per_minute = 500000
        rate_limit_calls  = 300
      }
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
      length(azapi_resource.llm_diagnostic) == 1,
    ])
    error_message = "Every optional component must be present in the full stack."
  }

  # Per-tier objects: 3 demo clients, secrets, and role assignments.
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

run "rejects_substring_roles" {
  command = plan

  variables {
    tiers = {
      a = { display_name = "A", app_role = "AI.Premium", tokens_per_minute = 1000, rate_limit_calls = 10 }
      b = { display_name = "B", app_role = "AI.Premium2", tokens_per_minute = 2000, rate_limit_calls = 20 }
    }
  }

  expect_failures = [var.tiers]
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
    semantic_cache = { embeddings_deployment = "nope" }
  }

  expect_failures = [var.semantic_cache]
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

run "name_suffix_override" {
  command = plan

  variables {
    name_suffix = "prod01"
  }

  assert {
    condition = alltrue([
      length(random_string.suffix) == 0,
      azurerm_api_management.apim.name == "aigw-apim-prod01",
    ])
    error_message = "name_suffix must replace the random suffix deterministically."
  }
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
    condition     = azurerm_key_vault.main[0].sku_name == "premium"
    error_message = "key_vault.sku_name must flow to the vault (premium = HSM-backed)."
  }
}

run "rejects_bad_app_role_charset" {
  command = plan

  variables {
    tiers = {
      a = { display_name = "A", app_role = "AI Gateway Sandbox", tokens_per_minute = 1000, rate_limit_calls = 10 }
    }
  }

  expect_failures = [var.tiers]
}

run "rejects_non_https_mcp_url" {
  command = plan

  variables {
    mcp_server_url = "http://insecure.example.com/mcp"
  }

  expect_failures = [var.mcp_server_url]
}

run "rejects_invalid_internal_mode" {
  command = plan

  variables {
    apim_virtual_network_type = "None"
  }

  expect_failures = [var.apim_virtual_network_type]
}
