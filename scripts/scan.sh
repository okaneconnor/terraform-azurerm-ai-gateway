#!/usr/bin/env bash
# Local static analysis for the Terraform module. Install: brew install tfsec checkov
# Fails CLOSED: exits non-zero if no scanner is installed (a pipeline gating on this
# script must not report clean when nothing actually ran).
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
ran=0
if command -v tfsec >/dev/null 2>&1; then
  echo "== tfsec =="
  tfsec . || rc=1
  ran=1
else
  echo "tfsec not installed (brew install tfsec)"
fi
if command -v checkov >/dev/null 2>&1; then
  echo "== checkov =="
  checkov -d . --quiet --compact || rc=1
  ran=1
else
  echo "checkov not installed (brew install checkov)"
fi
if [ "$ran" -eq 0 ]; then
  echo "ERROR: no scanner ran — install tfsec and/or checkov before trusting this result." >&2
  exit 2
fi
exit $rc
