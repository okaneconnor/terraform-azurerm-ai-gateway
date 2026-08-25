#!/usr/bin/env bash
#
# Per-rule live sweep: real plan per failing fixture, asserting each rule's
# SPECIFIC message (unit expect_failures can't tell which precondition fired).
# Required env: GATEWAY_APP_OBJECT_ID, GATEWAY_APP_ROLE_ID.
# Output: case names and PASS/FAIL only.

set -uo pipefail

: "${GATEWAY_APP_OBJECT_ID:?required}"
: "${GATEWAY_APP_ROLE_ID:?required}"

MODULE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$MODULE_DIR/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.tf" <<EOF
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
}
provider "azuread" {}
variable "tier_names" { type = list(string) }
module "onboarding" {
  source                = "$MODULE_DIR"
  registry_file         = "\${path.module}/teams.yaml"
  gateway_app_object_id = "$GATEWAY_APP_OBJECT_ID"
  gateway_app_role_id   = "$GATEWAY_APP_ROLE_ID"
  tier_names            = var.tier_names
}
EOF

(cd "$WORK" && terraform init -no-color >/dev/null 2>&1) || { echo "init failed"; exit 2; }

passed=0
failed=0

# fixture|expected message substring
CASES='bad-version.yaml|Registry version must be "v1"
bad-top-level-key.yaml|Unknown top-level registry key(s): enviroment
bad-unknown-team-key.yaml|Unknown key(s) on team entries: team team-alpha: groupId
bad-unknown-service-key.yaml|Unknown key(s) on service entries: team-alpha-chat: clientid
bad-missing-fields.yaml|Team entries missing required fields
bad-service-missing-fields.yaml|Service entries missing required fields
bad-name-case.yaml|Team names must be lowercase kebab-case
bad-service-name-case.yaml|Service names must be lowercase kebab-case
bad-guid-shape.yaml|Identity ids must be GUIDs
bad-placeholder-guid.yaml|Placeholder GUIDs found
bad-duplicate-team.yaml|Duplicate team entries: team-alpha
bad-derived-collision.yaml|Colliding team/service keys: acme-pay-api
bad-shared-principal.yaml|principal_object_id claimed more than once
bad-shared-client-id.yaml|client_id claimed by more than one service
bad-tier.yaml|Unknown tier(s): team team-alpha: platinum'

run_case() { # $1 fixture, $2 expected substring, $3 tier_names json
  cp "$FIXTURES/$1" "$WORK/teams.yaml"
  local out
  out=$(cd "$WORK" && terraform plan -no-color -var "tier_names=$3" 2>&1)
  if [ $? -eq 0 ]; then
    printf '  FAIL  %s: plan succeeded but must fail\n' "$1"; failed=$((failed+1)); return
  fi
  if printf '%s' "$out" | grep -qF "$2"; then
    printf '  PASS  %s\n' "$1"; passed=$((passed+1))
  else
    printf '  FAIL  %s: failed, but not with the expected message (%s)\n' "$1" "$2"
    failed=$((failed+1))
  fi
}

while IFS='|' read -r fixture expected; do
  [ -z "$fixture" ] && continue
  run_case "$fixture" "$expected" '["standard","premium"]'
done <<< "$CASES"

cp "$FIXTURES/valid.yaml" "$WORK/teams.yaml"
out=$(cd "$WORK" && terraform plan -no-color -var 'tier_names=["standard","premium"]' 2>&1)
if [ $? -ne 0 ]; then
  printf '  FAIL  valid.yaml: plan errored\n'; failed=$((failed+1))
elif printf '%s' "$out" | grep -q "4 to add, 0 to change, 0 to destroy" \
  && [ "$(printf '%s' "$out" | grep -c 'azuread_app_role_assignment.service\[')" -eq 3 ]; then
  printf '  PASS  valid.yaml -> plans 3 assignments + guard\n'; passed=$((passed+1))
else
  printf '  FAIL  valid.yaml: unexpected plan summary\n'; failed=$((failed+1))
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
