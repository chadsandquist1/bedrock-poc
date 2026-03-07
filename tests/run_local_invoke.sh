#!/usr/bin/env bash
set -euo pipefail

# Skip automatically in GitHub Actions and other CI environments
if [ "${CI:-}" = "true" ]; then
  echo "CI detected — skipping SAM local invoke tests"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/tests/env.json"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing tests/env.json — copy tests/env.json.example and fill in your account ID"
  exit 1
fi

cd "$REPO_ROOT"
sam build

EVENT='{"query": "What is photosynthesis?"}'
FAIL=0

for FUNCTION in CitationsV1 CitationsV2; do
  echo -n "Invoking $FUNCTION ... "
  RESPONSE=$(echo "$EVENT" | sam local invoke "$FUNCTION" \
    --env-vars "$ENV_FILE" --event - 2>/dev/null)
  STATUS=$(echo "$RESPONSE" | jq -r '.statusCode // empty')
  if [ "$STATUS" = "200" ]; then
    echo "OK (200)"
  else
    echo "FAILED — response: $RESPONSE"
    FAIL=$((FAIL + 1))
  fi
done

[ "$FAIL" -eq 0 ]
