#!/usr/bin/env bash
set -euo pipefail
: "${GATEWAY_URL:?}" "${TOKEN:?}" "${DEPLOYMENT:?}" "${FOUNDRY_ENDPOINT:?}"

echo "1) Foundry chat via gateway (expect 200):"
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}'

echo "2) No token (expect 401):"
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
  "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}'

echo "3) Direct backend call, bypassing APIM (expect failure - public access disabled):"
# 000 = connection blocked; 403 = PublicNetworkAccess denied; 401 = the public
# front-end rejected the missing key BEFORE the network check — equally blocked,
# since local (key) auth is disabled on the account, no key exists that could pass
# that gate, and Entra-authenticated requests from outside the VNet get the PNA 403.
curl -s -o /dev/null -w "  HTTP %{http_code} (000/401/403 = blocked, good)\n" --max-time 15 -X POST \
  "${FOUNDRY_ENDPOINT}openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}' || echo "  (connection blocked, good)"
