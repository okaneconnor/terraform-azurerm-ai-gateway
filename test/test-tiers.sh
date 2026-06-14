#!/usr/bin/env bash
# Tier-separation test. Prereqs (export):
#   GATEWAY_URL DEPLOYMENT TENANT_ID GATEWAY_APP_ID
#   SANDBOX_CLIENT_ID SANDBOX_CLIENT_SECRET PROD_CLIENT_ID PROD_CLIENT_SECRET
# With the module's demo clients (create_demo_clients = true), read them from the
# example deployment:  terraform -chdir=examples/complete output -json demo_clients
set -uo pipefail
: "${GATEWAY_URL:?}" "${DEPLOYMENT:?}" "${TENANT_ID:?}" "${GATEWAY_APP_ID:?}"
: "${SANDBOX_CLIENT_ID:?}" "${SANDBOX_CLIENT_SECRET:?}" "${PROD_CLIENT_ID:?}" "${PROD_CLIENT_SECRET:?}"
here="$(cd "$(dirname "$0")" && pwd)"
chat_url="${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21"
body='{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
pass=0; fail=0

tok() { # $1=client_id $2=secret — delegates to get-token.sh (single source of truth
        # for the scope format + Entra error reporting)
  TENANT_ID="$TENANT_ID" CLIENT_ID="$1" CLIENT_SECRET="$2" GATEWAY_APP_ID="$GATEWAY_APP_ID" \
    "$here/get-token.sh"
}

# Fire $2 calls CONCURRENTLY so the whole burst lands inside one rate window
# (serial LLM calls can outlast the 60s renewal period and never see a 429).
# Prints the number of 429s observed.
burst429s() { # $1=token $2=ncalls
  seq 1 "$2" | xargs -P 10 -I{} curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST "$chat_url" -H "Content-Type: application/json" \
    -H "Authorization: Bearer $1" -d "$body" | grep -c '^429$' || true
}

echo "== Sandbox token: expect 429s within 40 calls (limit 30/min) =="
st=$(tok "$SANDBOX_CLIENT_ID" "$SANDBOX_CLIENT_SECRET") || exit 1
s_429s=$(burst429s "$st" 40)
if [ "$s_429s" -gt 0 ]; then echo "  PASS  sandbox throttled ($s_429s of 40 calls got 429)"; pass=$((pass+1));
else echo "  FAIL  sandbox saw no 429 in 40 calls"; fail=$((fail+1)); fi

# No wait needed: rate counters are keyed per client app (azp claim), so the
# production client starts with a fresh window regardless of the sandbox burst.

echo "== Production token: expect NO 429 within 40 calls (limit is 120/min) =="
pt=$(tok "$PROD_CLIENT_ID" "$PROD_CLIENT_SECRET") || exit 1
p_429s=$(burst429s "$pt" 40)
if [ "$p_429s" -eq 0 ]; then echo "  PASS  production survived 40 calls (no 429)"; pass=$((pass+1));
else echo "  FAIL  production got $p_429s 429s (should be 0 within 40 calls)"; fail=$((fail+1)); fi

echo; echo "RESULT: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
