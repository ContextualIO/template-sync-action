#!/usr/bin/env bash
set -eo pipefail

# Read through the API, since the checkout needs this step's token.
file_organization () {
  local directory=${DIRECTORY#./} path file line organization=""
  directory=${directory%/}
  if [ -z "$directory" ] || [ "$directory" = . ]; then path=contextual-deploy.env; else path=$directory/contextual-deploy.env; fi
  file=$(curl -sSf -H "Authorization: Bearer $READ_TOKEN" -H "Accept: application/vnd.github.raw" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/contents/$path?ref=$DEFAULT_BRANCH" 2>/dev/null) || return 0
  while IFS= read -r line; do
    line=${line%$'\r'}
    case $line in CONTEXTUAL_ORGANIZATION=*) organization=${line#*=} ;; esac
  done <<< "$file"
  case $organization in \"*\" | \'*\') organization=${organization:1:${#organization}-2} ;; esac
  echo "$organization"
}

ORGANIZATION=${ORGANIZATION:-$(file_organization)}
[ -n "$ORGANIZATION" ] || exit 0

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
