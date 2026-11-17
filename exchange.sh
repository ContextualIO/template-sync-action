#!/usr/bin/env bash
set -eo pipefail

if [ -z "$ACTIONS_ID_TOKEN_REQUEST_URL" ]; then
  echo "::error::Getting a sync token from $ORGANIZATION needs the id-token: write permission on this job"
  exit 1
fi

silo=${CONTEXTUAL_SILO:-prod}
if [ "$silo" = prod ]; then
  url=${CONTEXTUAL_CONNECTIONS_URL:-https://connections.$ORGANIZATION.my.contextual.io}
else
  url=${CONTEXTUAL_CONNECTIONS_URL:-https://connections.$ORGANIZATION.my.$silo.contextual.io}
fi

oidc=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=contextual" | jq -re .value)
echo "::add-mask::$oidc"
if ! response=$(curl -sS --fail-with-body -X POST -H "authorization: Bearer $oidc" -H "x-org-id: $ORGANIZATION" "$url/api/v1/github-apps/exchange"); then
  echo "::error::Getting a sync token from $ORGANIZATION at $url failed: $response"
  exit 1
fi
token=$(jq -re .token <<< "$response") || { echo "::error::Getting a sync token from $ORGANIZATION at $url returned no token"; exit 1; }
echo "::add-mask::$token"
echo "token=$token" >> "$GITHUB_OUTPUT"
