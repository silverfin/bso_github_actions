#!/usr/bin/env bash
set -euo pipefail

# $1 = template dir (e.g. reconciliation_texts/vol_1), $2 = repo_root.
resolve_handle() {
  local template_dir="$1"
  local repo_root="$2"
  local config_path="$repo_root/$template_dir/config.json"

  if [[ "$template_dir" == account_templates/* ]]; then
    basename "$template_dir"
    return 0
  fi

  if [[ ! -f "$config_path" ]]; then
    echo "ERROR: $template_dir has no config.json" >&2
    return 1
  fi

  local jq_output
  if ! jq_output=$(jq -r '.handle // empty' "$config_path" 2>&1); then
    echo "ERROR: $template_dir has an unparseable config.json (jq failed: $jq_output)" >&2
    return 1
  fi

  if [[ -z "$jq_output" ]]; then
    echo "ERROR: $template_dir has no .handle in config.json" >&2
    return 1
  fi

  echo "$jq_output"
}

# $1 = template dir, $2 = repo_root.
resolve_name() {
  local template_dir="$1"
  local repo_root="$2"
  local config_path="$repo_root/$template_dir/config.json"

  local name
  name=$(jq -r '.name_en // empty' "$config_path" 2>/dev/null || true)
  if [[ -n "$name" ]]; then
    echo "$name"
    return 0
  fi

  basename "$template_dir" | tr '_' ' '
}

NOTION_API_BASE="https://api.notion.com"
NOTION_VERSION="2026-03-11"
NOTION_MAX_ATTEMPTS=6

# $1 = HTTP method, $2 = path (e.g. /v1/pages/abc), $3 = optional JSON body.
# Retries on 429/529 honouring Retry-After (falls back to exponential
# backoff if the header is absent), up to NOTION_MAX_ATTEMPTS. Any other
# non-2xx is a hard failure - printed to stderr, returns 1.
notion_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local attempt=1
  local backoff=1

  while (( attempt <= NOTION_MAX_ATTEMPTS )); do
    local response status response_body
    local -a curl_args=(
      -sS -w '\n%{http_code}'
      -X "$method" "$NOTION_API_BASE$path"
      -H "Authorization: Bearer $NOTION_TOKEN"
      -H "Notion-Version: $NOTION_VERSION"
    )
    if [[ -n "$body" ]]; then
      curl_args+=(-H "Content-Type: application/json" -d "$body")
    fi

    # Guard explicitly against curl itself failing (DNS/connection/TLS - no
    # HTTP response at all), as opposed to a non-2xx HTTP status. A bare
    # `response=$(curl ...)` here would trip `set -e` deep inside this
    # function on that failure and could kill the calling script before it
    # ever sees a return value - same hazard class as the jq fix in
    # resolve_handle. Capturing curl's own exit status explicitly keeps the
    # failure inside this function's normal, reportable return-1 path.
    if ! response=$(curl "${curl_args[@]}" 2>&1); then
      echo "ERROR: Notion API $method $path: curl itself failed (network/DNS/TLS, no HTTP response): $response" >&2
      return 1
    fi

    status=$(echo "$response" | tail -n 1)
    response_body=$(echo "$response" | sed '$d')

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
      echo "$response_body"
      return 0
    fi

    if [[ "$status" == "429" || "$status" == "529" ]]; then
      # Only sleep/back off when another attempt will actually follow -
      # there's no point waiting out a backoff right before giving up.
      if (( attempt < NOTION_MAX_ATTEMPTS )); then
        echo "WARN: Notion API returned $status (attempt $attempt/$NOTION_MAX_ATTEMPTS), backing off ${backoff}s" >&2
        sleep "$backoff"
        backoff=$((backoff * 2))
      else
        echo "WARN: Notion API returned $status (attempt $attempt/$NOTION_MAX_ATTEMPTS), no attempts left" >&2
      fi
      attempt=$((attempt + 1))
      continue
    fi

    echo "ERROR: Notion API $method $path failed with $status: $response_body" >&2
    return 1
  done

  echo "ERROR: Notion API $method $path failed after $NOTION_MAX_ATTEMPTS attempts" >&2
  return 1
}
