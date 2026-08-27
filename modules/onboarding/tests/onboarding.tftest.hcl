# Run from the submodule: terraform -chdir=modules/onboarding test.
# Every validation rule has a failing-case run.

mock_provider "azuread" {}
mock_provider "azapi" {}

variables {
  gateway_app_object_id = "b1b2c3d4-0001-4aaa-9bbb-1234567890ab"
  gateway_app_role_id   = "b1b2c3d4-0002-4aaa-9bbb-1234567890ab"
  tier_names            = ["standard", "premium"]
}

run "valid_registry_onboards_every_service" {
  command = plan

  variables {
    registry_file = "tests/fixtures/valid.yaml"
  }

  assert {
    condition = alltrue([
      length(azuread_app_role_assignment.service) == 3,
      contains(keys(azuread_app_role_assignment.service), "team-alpha-chat"),
      contains(keys(azuread_app_role_assignment.service), "team-alpha-summariser"),
      contains(keys(azuread_app_role_assignment.service), "team-beta-chat"),
    ])
    error_message = "One admission-role assignment per service, keyed <team>-<service>."
  }

  assert {
    condition = alltrue([
      for k, a in azuread_app_role_assignment.service :
      a.app_role_id == var.gateway_app_role_id && a.resource_object_id == var.gateway_app_object_id
    ])
    error_message = "Every assignment must bind the gateway outputs verbatim."
  }

  assert {
    condition     = [for t in output.teams : t.tier if t.team == "team-beta"][0] == "premium"
    error_message = "The teams output must carry each team's tier for downstream config."
  }
}

run "rejects_wrong_version" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-version.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_unknown_team_key" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-unknown-team-key.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_unknown_service_key" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-unknown-service-key.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_missing_required_fields" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-missing-fields.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_non_kebab_names" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-name-case.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_malformed_guid" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-guid-shape.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_placeholder_guid" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-placeholder-guid.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_duplicate_team" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-duplicate-team.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_hyphen_ambiguous_derived_keys" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-derived-collision.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_principal_shared_across_teams" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-shared-principal.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_unknown_tier" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-tier.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_unknown_top_level_key" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-top-level-key.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_service_missing_fields" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-service-missing-fields.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_service_name_case" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-service-name-case.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_client_id_shared_across_services" {
  command = plan
  variables { registry_file = "tests/fixtures/bad-shared-client-id.yaml" }
  expect_failures = [terraform_data.registry_guard]
}

run "rejects_non_guid_gateway_inputs" {
  command = plan
  variables {
    registry_file         = "tests/fixtures/valid.yaml"
    gateway_app_object_id = "not-a-guid"
  }
  expect_failures = [var.gateway_app_object_id]
}

# ---- Overrides seam ----

run "overrides_merge_semantics" {
  command = plan

  variables {
    registry_file    = "tests/fixtures/overrides.yaml"
    defaults_file    = "tests/fixtures/defaults.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 }, premium = { tokens_per_minute = 150000, rate_limit_calls = 120, token_quota = 5000000, token_quota_period = "Daily" } }
    canonical_models = ["gpt-test", "embed-test", "extra-model"]
    content_safety   = { backend_name = "cs-backend" }
  }

  # service > team > defaults > tier preset, maps per-key, lists wholesale.
  assert {
    condition = alltrue([
      output.effective_policies["team-beta-chat"].limits.rate_limit_calls == 5,
      output.effective_policies["team-beta-chat"].limits.tokens_per_minute == 50000,
      output.effective_policies["team-beta-chat"].limits.token_quota == null,
      output.effective_policies["team-alpha-chat"].limits.rate_limit_calls == 30,
      output.effective_policies["team-alpha-chat"].limits.tokens_per_minute == 20000,
      output.effective_policies["team-beta-batch"].limits.rate_limit_calls == 30,
      output.effective_policies["team-beta-batch"].limits.tokens_per_minute == 50000,
    ])
    error_message = "Limits must merge per key: service over team over tier preset."
  }

  assert {
    condition = alltrue([
      tolist(output.effective_policies["team-alpha-chat"].allowed_models) == tolist(["embed-test", "gpt-test"]),
      tolist(output.effective_policies["team-beta-chat"].allowed_models) == tolist(["gpt-test"]),
      tolist(output.effective_policies["team-beta-batch"].allowed_models) == tolist(["embed-test"]),
    ])
    error_message = "allowed_models must replace wholesale: service over team over defaults."
  }

  assert {
    condition = alltrue([
      [for c in output.effective_policies["team-beta-chat"].content_safety.categories : c.threshold if c.name == "Violence"][0] == 2,
      [for c in output.effective_policies["team-beta-chat"].content_safety.categories : c.threshold if c.name == "Hate"][0] == 3,
      [for c in output.effective_policies["team-beta-chat"].content_safety.categories : c.threshold if c.name == "Sexual"][0] == 4,
      [for c in output.effective_policies["team-alpha-chat"].content_safety.categories : c.threshold if c.name == "Hate"][0] == 3,
      output.effective_policies["team-alpha-chat"].content_safety.overridden,
    ])
    error_message = "content_safety must deep-merge per category: service threshold wins, siblings inherit defaults then platform."
  }

  assert {
    condition = alltrue([
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "a1b2c3d4-0005-4aaa-9bbb-1234567890ab"),
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "calls=\"5\""),
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "tokens-per-minute=\"50000\""),
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "value=\"embed-test,gpt-test\""),
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "team-policied"),
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "not_onboarded"),
    ])
    error_message = "Rendered overrides fragment must carry per-service branches, inline numbers and the fail-closed otherwise."
  }

  assert {
    condition = alltrue([
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "<category name=\"Violence\" threshold=\"2\" />"),
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "<category name=\"Hate\" threshold=\"3\" />"),
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "backend-id=\"cs-backend\""),
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "team-cs-policied"),
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "shield-prompt=\"true\""),
    ])
    error_message = "Rendered CS fragment must carry per-service categories with merged thresholds and platform shield settings."
  }
}

run "overrides_registry_without_overrides_uses_tier_presets" {
  command = plan

  variables {
    registry_file    = "tests/fixtures/valid.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 }, premium = { tokens_per_minute = 150000, rate_limit_calls = 120, token_quota = 5000000, token_quota_period = "Daily" } }
    canonical_models = ["gpt-test", "embed-test", "extra-model"]
  }

  assert {
    condition = alltrue([
      output.effective_policies["team-beta-chat"].limits.rate_limit_calls == 120,
      output.effective_policies["team-beta-chat"].limits.token_quota == 5000000,
      output.effective_policies["team-beta-chat"].limits.token_quota_period == "Daily",
      tolist(output.effective_policies["team-alpha-chat"].allowed_models) == tolist(["embed-test", "extra-model", "gpt-test"]),
      !output.effective_policies["team-alpha-chat"].content_safety.overridden,
    ])
    error_message = "Plain registry entries must inherit their tier preset and the full canonical model list."
  }

  assert {
    condition = alltrue([
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "token-quota=\"5000000\""),
      strcontains(azapi_resource_action.team_overrides_write["this"].body.properties.value, "token-quota-period=\"Daily\""),
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "team-cs-active"),
    ])
    error_message = "Tier quota must render inline; with no CS overrides the CS fragment stays inert."
  }
}

run "overrides_disabled_without_apim_id" {
  command = plan
  variables {
    registry_file = "tests/fixtures/valid.yaml"
  }

  assert {
    condition = alltrue([
      length(azapi_resource_action.team_overrides_write) == 0,
      length(azapi_resource_action.team_content_safety_write) == 0,
      output.effective_policies == null,
    ])
    error_message = "Without apim_id the module must stay azuread-only (v1 behaviour)."
  }
}

run "cs_opt_out_renders_no_screening" {
  command = plan

  variables {
    registry_file                     = "tests/fixtures/cs-optout.yaml"
    apim_id                           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits                       = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models                  = ["gpt-test"]
    content_safety                    = { backend_name = "cs-backend" }
    allow_team_content_safety_opt_out = true
  }

  assert {
    condition = alltrue([
      strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "team-cs-policied"),
      !strcontains(azapi_resource_action.team_content_safety_write["this"].body.properties.value, "llm-content-safety"),
    ])
    error_message = "A permitted opt-out must set team-cs-policied and render no llm-content-safety element."
  }
}

run "rejects_defaults_unknown_key" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/valid.yaml"
    defaults_file    = "tests/fixtures/bad-defaults-unknown-key.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 }, premium = { tokens_per_minute = 150000, rate_limit_calls = 120 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_overrides_without_apim_id" {
  command = plan
  variables {
    registry_file = "tests/fixtures/overrides-minimal.yaml"
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_apim_id_without_contract_inputs" {
  command = plan
  variables {
    registry_file = "tests/fixtures/valid.yaml"
    apim_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_limits_unknown_key" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-limits-unknown-key.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_limits_bad_value" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-limits-value.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_bad_quota_period" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-quota-period.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_empty_allowlist" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-models-empty.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_unknown_model" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-models-unknown.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_cs_unknown_category" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-cs-unknown-key.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
    content_safety   = { backend_name = "cs-backend" }
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_cs_bad_threshold" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-cs-threshold.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
    content_safety   = { backend_name = "cs-backend" }
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_cs_enabled_non_bool" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/bad-cs-enabled-type.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
    content_safety   = { backend_name = "cs-backend" }
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_cs_opt_out_when_not_allowed" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/cs-optout.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
    content_safety   = { backend_name = "cs-backend" }
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_cs_override_without_contract" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/overrides.yaml"
    defaults_file    = "tests/fixtures/defaults.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test", "embed-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_tier_absent_from_tier_limits" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/valid.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
  }
  expect_failures = [terraform_data.overrides_guard]
}

run "rejects_limits_above_maxima" {
  command = plan
  variables {
    registry_file    = "tests/fixtures/overrides-minimal.yaml"
    apim_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock-rg/providers/Microsoft.ApiManagement/service/mock-apim"
    tier_limits      = { standard = { tokens_per_minute = 20000, rate_limit_calls = 30 } }
    canonical_models = ["gpt-test"]
    limit_maxima     = { tokens_per_minute = 4000 }
  }
  expect_failures = [terraform_data.overrides_guard]
}
