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
curl -s -o /dev/null -w "  HTTP %{http_code} (000/403 = blocked, good)\n" --max-time 15 -X POST \
  "${FOUNDRY_ENDPOINT}openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}' || echo "  (connection blocked, good)"
