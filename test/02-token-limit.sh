#!/usr/bin/env bash
# Fires rapid requests to trip the per-minute token limit; expect a 429 once exceeded.
set -euo pipefail
: "${GATEWAY_URL:?}" "${SUB_KEY:?}" "${DEPLOYMENT:?}"
for i in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21" \
    -H "Content-Type: application/json" \
    -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
    -d '{"messages":[{"role":"user","content":"Write a 200 word story."}],"max_tokens":400}')
  echo "request $i -> HTTP $code"
  [ "$code" = "429" ] && { echo "Token limit hit (429) as expected."; exit 0; }
done
echo "Did not hit 429 — lower tokens-per-minute or raise max_tokens."
