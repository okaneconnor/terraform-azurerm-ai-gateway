#!/usr/bin/env bash
#
# Per-rule live sweep: real plan per failing fixture, asserting each rule's
# SPECIFIC message (unit expect_failures can't tell which precondition fired).
# Required env: GATEWAY_APP_OBJECT_ID, GATEWAY_APP_ROLE_ID.
# Overrides cases need az CLI auth (azapi provider configure) but never touch Azure.
# Output: case names and PASS/FAIL only.

set -uo pipefail

: "${GATEWAY_APP_OBJECT_ID:?required}"
: "${GATEWAY_APP_ROLE_ID:?required}"

MODULE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$MODULE_DIR/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APIM_ID="/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/sweep-rg/providers/Microsoft.ApiManagement/service/sweep-apim"
TIERS='{standard={tokens_per_minute=20000,rate_limit_calls=30},premium={tokens_per_minute=150000,rate_limit_calls=120}}'
MODELS='["gpt-test","embed-test"]'

cat > "$WORK/main.tf" <<EOF
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    azapi   = { source = "azure/azapi", version = "~> 2.0" }
  }
}
provider "azuread" {}
provider "azapi" {}
variable "tier_names" { type = list(string) }
variable "apim_id" {
  type    = string
  default = null
}
variable "defaults_file" {
  type    = string
  default = null
}
variable "tier_limits" {
  type    = any
  default = null
}
variable "canonical_models" {
  type    = list(string)
  default = null
}
variable "content_safety" {
  type    = any
  default = null
}
variable "allow_opt_out" {
  type    = bool
  default = false
}
variable "limit_maxima" {
  type    = any
  default = null
}
module "onboarding" {
  source                            = "$MODULE_DIR"
  registry_file                     = "\${path.module}/teams.yaml"
  gateway_app_object_id             = "$GATEWAY_APP_OBJECT_ID"
  gateway_app_role_id               = "$GATEWAY_APP_ROLE_ID"
  tier_names                        = var.tier_names
  apim_id                           = var.apim_id
  defaults_file                     = var.defaults_file
  tier_limits                       = var.tier_limits
  canonical_models                  = var.canonical_models
  content_safety                    = var.content_safety
  allow_team_content_safety_opt_out = var.allow_opt_out
  limit_maxima                      = var.limit_maxima
}
EOF

(cd "$WORK" && terraform init -no-color >/dev/null 2>&1) || { echo "init failed"; exit 2; }

passed=0
failed=0

plan_out() { # $1 fixture; rest: extra -var args. Echoes plan output; exit code preserved.
  local fixture="$1"; shift
  cp "$FIXTURES/$fixture" "$WORK/teams.yaml"
  (cd "$WORK" && terraform plan -no-color -var 'tier_names=["standard","premium"]' "$@" 2>&1)
}

expect_fail() { # $1 fixture, $2 expected substring, rest: extra -var args
  local fixture="$1" expected="$2"; shift 2
  local out
  out=$(plan_out "$fixture" "$@")
  if [ $? -eq 0 ]; then
    printf '  FAIL  %s: plan succeeded but must fail\n' "$fixture"; failed=$((failed+1)); return
  fi
  # Unwrap terraform's hard-wrapped, frame-prefixed error text before matching.
  out=$(printf '%s' "$out" | sed 's/^[│╷╵ ]*//' | tr '\n' ' ' | tr -s ' ')
  if printf '%s' "$out" | grep -qF "$expected"; then
    printf '  PASS  %s\n' "$fixture"; passed=$((passed+1))
  else
    printf '  FAIL  %s: failed, but not with the expected message (%s)\n' "$fixture" "$expected"
    failed=$((failed+1))
  fi
}

# ---- Registry rules (no overrides inputs) ----
expect_fail bad-version.yaml            'Registry version must be "v1"'
expect_fail bad-top-level-key.yaml      'Unknown top-level registry key(s): enviroment'
expect_fail bad-unknown-team-key.yaml   'Unknown key(s) on team entries: team team-alpha: groupId'
expect_fail bad-unknown-service-key.yaml 'Unknown key(s) on service entries: team-alpha-chat: clientid'
expect_fail bad-missing-fields.yaml     'Team entries missing required fields'
expect_fail bad-service-missing-fields.yaml 'Service entries missing required fields'
expect_fail bad-name-case.yaml          'Team names must be lowercase kebab-case'
expect_fail bad-service-name-case.yaml  'Service names must be lowercase kebab-case'
expect_fail bad-guid-shape.yaml         'Identity ids must be GUIDs'
expect_fail bad-placeholder-guid.yaml   'Placeholder GUIDs found'
expect_fail bad-duplicate-team.yaml     'Duplicate team entries: team-alpha'
expect_fail bad-derived-collision.yaml  'Colliding team/service keys: acme-pay-api'
expect_fail bad-shared-principal.yaml   'principal_object_id claimed more than once'
expect_fail bad-shared-client-id.yaml   'client_id claimed by more than one service'
expect_fail bad-tier.yaml               'Unknown tier(s): team team-alpha: platinum'

# ---- Overrides rules ----
OV=(-var "apim_id=$APIM_ID" -var "tier_limits=$TIERS" -var "canonical_models=$MODELS")
CS=(-var 'content_safety={backend_name="cs-backend"}')

expect_fail valid.yaml 'Unknown key(s) in the defaults file: models' "${OV[@]}" -var "defaults_file=$FIXTURES/bad-defaults-unknown-key.yaml"
expect_fail overrides-minimal.yaml 'but apim_id is not set'
expect_fail valid.yaml 'apim_id is set but tier_limits and canonical_models missing' -var "apim_id=$APIM_ID"
expect_fail bad-limits-unknown-key.yaml 'Unknown key(s) in limits: team team-alpha: requests_per_minute' "${OV[@]}"
expect_fail bad-limits-value.yaml 'Limit values must be positive integers' "${OV[@]}"
expect_fail bad-quota-period.yaml 'token_quota_period must be one of Hourly, Daily, Weekly, Monthly, Yearly: team team-alpha' "${OV[@]}"
expect_fail bad-models-empty.yaml 'allowed_models must be a non-empty list' "${OV[@]}"
expect_fail bad-models-unknown.yaml 'allowed_models name(s) the gateway does not serve: team team-alpha: gpt-imaginary' "${OV[@]}"
expect_fail bad-cs-unknown-key.yaml 'Unknown key(s) in content_safety: team team-alpha: selfharm' "${OV[@]}" "${CS[@]}"
expect_fail bad-cs-threshold.yaml 'content_safety thresholds must be integers 0-7' "${OV[@]}" "${CS[@]}"
expect_fail bad-cs-enabled-type.yaml 'content_safety enabled flags must be booleans: team team-alpha' "${OV[@]}" "${CS[@]}"
expect_fail cs-optout.yaml 'the platform does not allow opt-out' "${OV[@]}" "${CS[@]}"
expect_fail overrides.yaml "pass the gateway module's content_safety_contract output" "${OV[@]}" -var "defaults_file=$FIXTURES/defaults.yaml"
expect_fail valid.yaml 'tier_limits has no entry for tier(s): premium' -var "apim_id=$APIM_ID" -var 'tier_limits={standard={tokens_per_minute=20000,rate_limit_calls=30}}' -var "canonical_models=$MODELS"
expect_fail overrides-minimal.yaml 'Effective limits exceed the platform maxima (limit_maxima): team-alpha-chat' "${OV[@]}" -var 'limit_maxima={tokens_per_minute=4000}'

# ---- Happy paths ----
out=$(plan_out valid.yaml)
if [ $? -ne 0 ]; then
  printf '  FAIL  valid.yaml: plan errored\n'; failed=$((failed+1))
elif printf '%s' "$out" | grep -q "5 to add, 0 to change, 0 to destroy" \
  && [ "$(printf '%s' "$out" | grep -c 'azuread_app_role_assignment.service\[')" -eq 3 ]; then
  printf '  PASS  valid.yaml -> plans 3 assignments + guards, no azapi\n'; passed=$((passed+1))
else
  printf '  FAIL  valid.yaml: unexpected plan summary\n'; failed=$((failed+1))
fi

out=$(plan_out overrides.yaml "${OV[@]}" "${CS[@]}" -var "defaults_file=$FIXTURES/defaults.yaml")
if [ $? -ne 0 ]; then
  printf '  FAIL  overrides.yaml: plan errored\n'; failed=$((failed+1))
elif printf '%s' "$out" | grep -q "9 to add, 0 to change, 0 to destroy" \
  && printf '%s' "$out" | grep -q 'azapi_update_resource.team_overrides' \
  && printf '%s' "$out" | grep -q 'azapi_update_resource.team_content_safety' \
  && printf '%s' "$out" | grep -q 'calls="5"'; then
  printf '  PASS  overrides.yaml -> plans assignments + both fragments with merged numbers\n'; passed=$((passed+1))
else
  printf '  FAIL  overrides.yaml: unexpected plan summary\n'; failed=$((failed+1))
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
