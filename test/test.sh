export SUBSCRIPTION_ID="04109105-f3ca-44ac-a3a7-66b4936112c3"
export PUBLISHER_EMAIL="thomasthornton1@live.co.uk"
export PUBLISHER_NAME="AI Gateway PoC"

# Optional but recommended
export HOME_IP_CIDR="31.126.40.64/32"

export DOCINTEL_SAMPLE_URL="https://www.orimi.com/pdf-test.pdf"

# That keeps token/model logging enabled but avoids centrally logging prompts and completions.
export ENABLE_LLM_MESSAGE_LOGGING=false

export APIM_SKU="Premium"

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Azure AI Gateway PoC v6 - Foundry-first APIM AI Gateway + keyless Entra ID Model B
# =============================================================================
#
# What this deploys:
# - Resource group
# - VNet with APIM subnet + Private Endpoint subnet
# - Log Analytics Workspace
# - Workspace-based Application Insights
# - Azure Monitor Workbook dashboard for APIM AI Gateway telemetry
# - Key Vault with APIM managed identity access
# - API Management Standard tier in EXTERNAL VNet mode
# - APIM as the only public API endpoint for consumers
# - APIM products:
#     - ai-sandbox: lower rate/token limits, no subscription key required
#     - ai-production-standard: higher rate/token limits, no subscription key required
# - Entra ID app registrations for keyless client-authenticated access
# - APIM policy fragments:
#     - ai-ip-allow-home
#     - ai-auth-entra-jwt
#     - ai-observability
#     - ai-token-limit-sandbox
#     - ai-token-limit-production
#     - ai-content-safety
#     - ai-backend-managed-identity
#     - ai-token-metrics
# - Azure AI resources with public network access disabled:
#     - Microsoft Foundry Models
#     - Content Safety
#     - Speech
#     - Language
#     - Document Intelligence
# - Private Endpoints + Private DNS for Azure AI services and Key Vault
# - APIM APIs for concrete shared Azure AI service contracts
# - API Center catalog registration for the shared AI APIs
# - Smoke tests:
#     - Foundry model call through APIM
#     - Content Safety analyze text through APIM
#     - Language key phrase extraction through APIM
#     - optional Document Intelligence prebuilt-read through APIM
#     - direct backend call expected to fail because public network access is disabled
#
# Notes:
# - APIM Standard tier with External VNet mode.
# - External VNet mode means APIM gateway remains publicly reachable, while APIM
#   can access private backends from the VNet.
# - API calls require all three controls:
#     1. source IP matches HOME_IP_CIDR
#     2. valid Entra ID bearer token
#     3. approved Entra client application identity/app role
# - No APIM subscription key is required. Rate/token limits are keyed by client ID.
#
# =============================================================================

# -----------------------------
# User-configurable values
# -----------------------------

: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID, e.g. export SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000}"
: "${PUBLISHER_EMAIL:?Set PUBLISHER_EMAIL, e.g. export PUBLISHER_EMAIL=you@example.com}"
: "${PUBLISHER_NAME:=AI Gateway PoC}"

# Optional. If not set, the script attempts to detect your current public IP.
# For the PoC policy this should be a single IPv4 /32, e.g. 1.2.3.4/32.
: "${HOME_IP_CIDR:=}"

# Region. Pick a region where your subscription has Microsoft Foundry Models quota.
: "${LOCATION:=swedencentral}"

# Naming.
: "${PREFIX:=tamops-aigw-poc}"
: "${UNIQUE_SUFFIX:=v7}"

RG_NAME="${RG_NAME:-rg-${PREFIX}-${UNIQUE_SUFFIX}}"
VNET_NAME="${VNET_NAME:-vnet-${PREFIX}-${UNIQUE_SUFFIX}}"
APIM_SUBNET_NAME="${APIM_SUBNET_NAME:-snet-apim}"
APIM_NSG_NAME="${APIM_NSG_NAME:-nsg-apim-${PREFIX}-${UNIQUE_SUFFIX}}"
PE_SUBNET_NAME="${PE_SUBNET_NAME:-snet-private-endpoints}"

LAW_NAME="${LAW_NAME:-law${PREFIX//-/}${UNIQUE_SUFFIX}}"
APPINSIGHTS_NAME="${APPINSIGHTS_NAME:-appi${PREFIX//-/}${UNIQUE_SUFFIX}}"
WORKBOOK_NAME="${WORKBOOK_NAME:-wb-${PREFIX}-${UNIQUE_SUFFIX}}"
# Azure Monitor Workbooks require a GUID as the resource name; derive one deterministically.
WORKBOOK_GUID="$(python3 -c "import uuid; print(str(uuid.uuid5(uuid.NAMESPACE_URL, 'apim-ai-gateway-workbook-${PREFIX}-${UNIQUE_SUFFIX}')))")"
APIM_NAME="${APIM_NAME:-apim-${PREFIX}-${UNIQUE_SUFFIX}}"
APIM_SKU="${APIM_SKU:-Standard}"
API_CENTER_NAME="${API_CENTER_NAME:-apic-${PREFIX}-${UNIQUE_SUFFIX}}"
KEYVAULT_NAME="${KEYVAULT_NAME:-kv${PREFIX//-/}${UNIQUE_SUFFIX}}"

FOUNDRY_NAME="${FOUNDRY_NAME:-fdry-${PREFIX}-${UNIQUE_SUFFIX}}"
CONTENT_SAFETY_NAME="${CONTENT_SAFETY_NAME:-cs-${PREFIX}-${UNIQUE_SUFFIX}}"
SPEECH_NAME="${SPEECH_NAME:-spch-${PREFIX}-${UNIQUE_SUFFIX}}"
LANGUAGE_NAME="${LANGUAGE_NAME:-lang-${PREFIX}-${UNIQUE_SUFFIX}}"
DOCINTEL_NAME="${DOCINTEL_NAME:-docint-${PREFIX}-${UNIQUE_SUFFIX}}"

FOUNDRY_DEPLOYMENT_NAME="${FOUNDRY_DEPLOYMENT_NAME:-gpt-4.1-mini}"
FOUNDRY_MODEL_NAME="${FOUNDRY_MODEL_NAME:-gpt-4.1-mini}"
FOUNDRY_MODEL_VERSION="${FOUNDRY_MODEL_VERSION:-2025-04-14}"
FOUNDRY_MODEL_FORMAT="${FOUNDRY_MODEL_FORMAT:-OpenAI}"
FOUNDRY_MODEL_SKU_NAME="${FOUNDRY_MODEL_SKU_NAME:-Standard}"
FOUNDRY_MODEL_SKU_CAPACITY="${FOUNDRY_MODEL_SKU_CAPACITY:-10}"
FOUNDRY_MODELS_API_VERSION="${FOUNDRY_MODELS_API_VERSION:-2024-05-01-preview}"
# Compatibility path APIM exposes to consumers.
# azure-ai-model-inference = /models/chat/completions with model deployment in the body.
# azure-openai-compatible = /openai/deployments/{deployment}/chat/completions.
FOUNDRY_CLIENT_COMPAT="${FOUNDRY_CLIENT_COMPAT:-azure-ai-model-inference}"

SANDBOX_PRODUCT_ID="${SANDBOX_PRODUCT_ID:-ai-sandbox}"
PROD_PRODUCT_ID="${PROD_PRODUCT_ID:-ai-production-standard}"
# Model B uses APIM products without subscription keys.
# Access and usage control is based on Entra ID client identity/app roles.
KEYLESS_PRODUCT_ID="${KEYLESS_PRODUCT_ID:-ai-entra-keyless}"
AI_GATEWAY_APP_NAME="${AI_GATEWAY_APP_NAME:-app-${PREFIX}-gateway-${UNIQUE_SUFFIX}}"
AI_GATEWAY_APP_ID="${AI_GATEWAY_APP_ID:-}"
AI_GATEWAY_APP_OBJECT_ID="${AI_GATEWAY_APP_OBJECT_ID:-}"
AI_GATEWAY_APP_ID_URI="${AI_GATEWAY_APP_ID_URI:-}"

AI_GATEWAY_CLIENT_APP_NAME="${AI_GATEWAY_CLIENT_APP_NAME:-app-${PREFIX}-client-${UNIQUE_SUFFIX}}"
AI_GATEWAY_CLIENT_APP_ID="${AI_GATEWAY_CLIENT_APP_ID:-}"
AI_GATEWAY_CLIENT_SP_OBJECT_ID="${AI_GATEWAY_CLIENT_SP_OBJECT_ID:-}"
AI_GATEWAY_CLIENT_SECRET="${AI_GATEWAY_CLIENT_SECRET:-}"

SANDBOX_APP_ROLE_VALUE="${SANDBOX_APP_ROLE_VALUE:-AI.Gateway.Sandbox}"
PROD_APP_ROLE_VALUE="${PROD_APP_ROLE_VALUE:-AI.Gateway.Production}"
ASSIGN_CLIENT_APP_ROLE="${ASSIGN_CLIENT_APP_ROLE:-sandbox}"        # sandbox|production|both
ASSIGN_CURRENT_USER_APP_ROLE="${ASSIGN_CURRENT_USER_APP_ROLE:-sandbox}" # sandbox|production|both|none

# Network CIDRs.
VNET_CIDR="${VNET_CIDR:-10.90.0.0/16}"
APIM_SUBNET_CIDR="${APIM_SUBNET_CIDR:-10.90.1.0/24}"
PE_SUBNET_CIDR="${PE_SUBNET_CIDR:-10.90.2.0/24}"

# Product limits.
SANDBOX_RATE_LIMIT_CALLS="${SANDBOX_RATE_LIMIT_CALLS:-30}"
SANDBOX_TOKENS_PER_MINUTE="${SANDBOX_TOKENS_PER_MINUTE:-20000}"
SANDBOX_MONTHLY_TOKEN_QUOTA="${SANDBOX_MONTHLY_TOKEN_QUOTA:-1000000}"
PROD_RATE_LIMIT_CALLS="${PROD_RATE_LIMIT_CALLS:-120}"
PROD_TOKENS_PER_MINUTE="${PROD_TOKENS_PER_MINUTE:-150000}"
PROD_MONTHLY_TOKEN_QUOTA="${PROD_MONTHLY_TOKEN_QUOTA:-50000000}"
RATE_LIMIT_RENEWAL_SECONDS="${RATE_LIMIT_RENEWAL_SECONDS:-60}"

# Entra ID JWT validation.
# Model B uses a dedicated Entra app registration as the APIM AI Gateway audience.
ENABLE_ENTRA_JWT="${ENABLE_ENTRA_JWT:-true}"
CREATE_ENTRA_APPS="${CREATE_ENTRA_APPS:-true}"
AUTH_AUDIENCE="${AUTH_AUDIENCE:-}"

# Optional platform features.
ENABLE_LLM_POLICIES="${ENABLE_LLM_POLICIES:-true}"
ENABLE_CONTENT_SAFETY_POLICY="${ENABLE_CONTENT_SAFETY_POLICY:-true}"
ENABLE_API_CENTER="${ENABLE_API_CENTER:-true}"
ENABLE_WORKBOOK="${ENABLE_WORKBOOK:-true}"
# Enables APIM Azure Monitor-based Analytics > Language models dashboard support.
# This turns on GatewayLlmLogs and API-level LLM logging for the Foundry model API.
ENABLE_APIM_GENAI_DASHBOARD="${ENABLE_APIM_GENAI_DASHBOARD:-true}"
# Logs prompts/completions for the demo Foundry API. Keep false for sensitive data.
ENABLE_LLM_MESSAGE_LOGGING="${ENABLE_LLM_MESSAGE_LOGGING:-true}"
LLM_LOG_MESSAGE_BYTES="${LLM_LOG_MESSAGE_BYTES:-32768}"
RUN_SMOKE_TESTS="${RUN_SMOKE_TESTS:-true}"

# -----------------------------
# Helpers
# -----------------------------

log() { echo; echo "==> $*"; }
warn() { echo; echo "WARNING: $*" >&2; }
require_command() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

safe_name() {
  # Cognitive Services account names: 2-64 chars, lowercase alphanumeric + hyphen.
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-60
}

safe_kv_name() {
  # Key Vault names: 3-24 chars, alphanumeric + hyphen, globally unique.
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-24
}

cidr_ip_only() {
  echo "$1" | cut -d/ -f1
}

resource_provider_state() {
  local ns="$1"
  az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered"
}

register_provider_if_needed() {
  local ns="$1"
  local state
  state="$(resource_provider_state "$ns")"
  if [[ "$state" != "Registered" ]]; then
    log "Registering resource provider: $ns"
    az provider register --namespace "$ns" -o none
    for i in {1..60}; do
      state="$(resource_provider_state "$ns")"
      [[ "$state" == "Registered" ]] && return 0
      sleep 5
    done
    warn "Provider $ns did not report Registered within wait period. Continuing; Azure may still finish registration in the background."
  fi
}

check_apim_name_available() {
  # Skip the global name check if APIM already exists in our RG — the name is
  # "taken" by us, so checkNameAvailability would return false incorrectly.
  if az apim show -g "$RG_NAME" -n "$APIM_NAME" >/dev/null 2>&1; then
    echo "APIM already exists in $RG_NAME, skipping name availability check."
    return 0
  fi
  local result
  result="$(az rest --method post \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.ApiManagement/checkNameAvailability?api-version=2022-08-01" \
    --body "{\"name\":\"${APIM_NAME}\"}" \
    --query nameAvailable -o tsv 2>/dev/null || echo "unknown")"
  if [[ "$result" == "false" ]]; then
    echo "APIM name is not available: $APIM_NAME" >&2
    exit 1
  fi
}

create_private_dns_zone_if_missing() {
  local zone_name="$1"
  local link_name="$2"
  if ! az network private-dns zone show -g "$RG_NAME" -n "$zone_name" >/dev/null 2>&1; then
    az network private-dns zone create -g "$RG_NAME" -n "$zone_name" -o none
  fi
  if ! az network private-dns link vnet show -g "$RG_NAME" -z "$zone_name" -n "$link_name" >/dev/null 2>&1; then
    az network private-dns link vnet create -g "$RG_NAME" -z "$zone_name" -n "$link_name" -v "$VNET_ID" -e false -o none
  fi
}

create_ai_account() {
  local name="$1" kind="$2" sku="$3"
  log "Creating Azure AI resource: $name ($kind)"
  if az cognitiveservices account show -g "$RG_NAME" -n "$name" >/dev/null 2>&1; then
    echo "Resource already exists: $name"
  else
    az cognitiveservices account ...
 