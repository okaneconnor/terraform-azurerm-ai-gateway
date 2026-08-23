# Unit tests for modules/onboarding — plan-mode against a mocked azuread provider.
# Run from the submodule: terraform -chdir=modules/onboarding test
#
# Every validation rule has a failing-case run: a rule without a failing test is
# a rule that can silently stop working.

mock_provider "azuread" {}

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

  # 2 teams, 3 services -> 3 assignments keyed <team>-<service>.
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

# team "acme" + service "pay-api" and team "acme-pay" + service "api" both derive
# the key "acme-pay-api"; a for_each would silently collapse them into one
# resource — one team quietly receiving another's assignment.
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

run "rejects_non_guid_gateway_inputs" {
  command = plan
  variables {
    registry_file         = "tests/fixtures/valid.yaml"
    gateway_app_object_id = "not-a-guid"
  }
  expect_failures = [var.gateway_app_object_id]
}
