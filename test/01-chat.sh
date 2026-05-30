#!/usr/bin/env bash
# Usage: GATEWAY_URL=... SUB_KEY=... DEPLOYMENT=gpt-4o ./test/01-chat.sh
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}" "${DEPLOYMENT:?}"
curl -sS -X POST \
  "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
  -d '{"messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":20}'
echo
