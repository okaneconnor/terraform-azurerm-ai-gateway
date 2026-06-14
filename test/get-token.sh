#!/usr/bin/env bash
# Usage: TENANT_ID=.. CLIENT_ID=.. CLIENT_SECRET=.. GATEWAY_APP_ID=.. ./test/get-token.sh
# Prints the access token on success; prints the full Entra error JSON on failure.
set -euo pipefail
: "${TENANT_ID:?}" "${CLIENT_ID:?}" "${CLIENT_SECRET:?}" "${GATEWAY_APP_ID:?}"

# Scope uses the resource app's client-ID GUID + /.default. This form is valid
# regardless of the app's identifier URI (api://<guid>/.default would require
# api://<guid> to be a registered identifier URI, which it is not).
# The secret is fed to curl via a config on stdin so it never appears in argv
# (process command lines are world-readable).
resp=$(printf 'data-urlencode = "client_secret=%s"\n' "$CLIENT_SECRET" | curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "scope=${GATEWAY_APP_ID}/.default" \
  --config -)

token=$(printf '%s' "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
if [ -n "$token" ]; then
  printf '%s\n' "$token"
else
  echo "ERROR: no access_token returned. Full response:" >&2
  printf '%s\n' "$resp" >&2
  exit 1
fi
