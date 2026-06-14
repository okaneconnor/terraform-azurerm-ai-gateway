#!/usr/bin/env bash
# Verifies the deployment-SKU Azure Policy denies non-allowlisted (non-regional) SKUs.
# Prereqs: az login; RG + FOUNDRY exported — both are module outputs:
#   RG=$(terraform -chdir=examples/complete output -raw resource_group_name)
#   FOUNDRY=$(terraform -chdir=examples/complete output -raw foundry_account_name)
# Optional: MODEL_NAME / MODEL_VERSION override the probe model.
set -uo pipefail
: "${RG:?set RG to the resource group}" "${FOUNDRY:?set FOUNDRY to the AIServices account name}"
MODEL_NAME="${MODEL_NAME:-gpt-4.1-mini}"
MODEL_VERSION="${MODEL_VERSION:-2025-04-14}"
echo "Attempting a GlobalStandard deployment (should be DENIED by policy)..."
out=$(az cognitiveservices account deployment create \
  -g "$RG" -n "$FOUNDRY" --deployment-name residency-probe \
  --model-name "$MODEL_NAME" --model-version "$MODEL_VERSION" --model-format OpenAI \
  --sku-name GlobalStandard --sku-capacity 1 2>&1 || true)
if echo "$out" | grep -qiE "disallowed by policy|RequestDisallowedByPolicy|denied"; then
  echo "  PASS  GlobalStandard deployment was denied by policy"
  exit 0
else
  echo "  FAIL  deployment was NOT denied. Output:"; echo "$out" | head -5
  echo "  (Cleanup if it was created: az cognitiveservices account deployment delete -g $RG -n $FOUNDRY --deployment-name residency-probe)"
  exit 1
fi
