#!/usr/bin/env bash
# Usage: TENANT_ID=.. CLIENT_ID=.. CLIENT_SECRET=.. GATEWAY_APP_ID=.. ./test/get-token.sh
set -euo pipefail
: "${TENANT_ID:?}" "${CLIENT_ID:?}" "${CLIENT_SECRET:?}" "${GATEWAY_APP_ID:?}"
curl -s -X POST "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&scope=api://${GATEWAY_APP_ID}/.default" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])"
