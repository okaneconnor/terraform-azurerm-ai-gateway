#!/usr/bin/env bash
# Cache correctness. Prereqs (export):
#   GATEWAY_URL DEPLOYMENT TENANT_ID GATEWAY_APP_ID
#   SANDBOX_CLIENT_ID SANDBOX_CLIENT_SECRET PROD_CLIENT_ID PROD_CLIENT_SECRET
set -uo pipefail
: "${GATEWAY_URL:?}" "${DEPLOYMENT:?}" "${TENANT_ID:?}" "${GATEWAY_APP_ID:?}"
: "${SANDBOX_CLIENT_ID:?}" "${SANDBOX_CLIENT_SECRET:?}" "${PROD_CLIENT_ID:?}" "${PROD_CLIENT_SECRET:?}"
here="$(cd "$(dirname "$0")" && pwd)"
chat_url="${GATEWAY_URL}/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=2024-10-21"
pass=0; fail=0
tok() { # delegates to get-token.sh (single source of truth for scope + error reporting)
  TENANT_ID="$TENANT_ID" CLIENT_ID="$1" CLIENT_SECRET="$2" GATEWAY_APP_ID="$GATEWAY_APP_ID" \
    "$here/get-token.sh"
}
ask() { # $1=token $2=prompt-text  -> prints completion id
  curl -s -X POST "$chat_url" -H "Content-Type: application/json" -H "Authorization: Bearer $1" \
    -d "{\"messages\":[{\"role\":\"user\",\"content\":\"$2\"}],\"max_tokens\":8,\"temperature\":0}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))"; }

st=$(tok "$SANDBOX_CLIENT_ID" "$SANDBOX_CLIENT_SECRET")
pt=$(tok "$PROD_CLIENT_ID" "$PROD_CLIENT_SECRET")

echo "== False-hit: two DIFFERENT prompts must NOT share a cached answer =="
a=$(ask "$st" "Name a fruit in one word."); sleep 3
b=$(ask "$st" "Explain quantum entanglement in one sentence.")
if [ -n "$a" ] && [ "$a" != "$b" ]; then echo "  PASS  distinct prompts -> distinct ids"; pass=$((pass+1));
else echo "  FAIL  false cache hit (a=$a b=$b)"; fail=$((fail+1)); fi

echo "== Isolation: a prompt cached by sandbox must NOT be served to prod =="
p="Tenant isolation probe: a country in one word."
s1=$(ask "$st" "$p"); sleep 3      # sandbox caches it (miss -> store)
s2=$(ask "$st" "$p")               # sandbox hit (same id)
pr=$(ask "$pt" "$p")               # prod: different azp -> must MISS -> different id
if [ "$s1" = "$s2" ] && [ -n "$pr" ] && [ "$pr" != "$s1" ]; then
  echo "  PASS  sandbox hit ($s1) isolated from prod ($pr)"; pass=$((pass+1));
else echo "  FAIL  s1=$s1 s2=$s2 prod=$pr (expect s1==s2 and prod!=s1)"; fail=$((fail+1)); fi

echo; echo "RESULT: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
