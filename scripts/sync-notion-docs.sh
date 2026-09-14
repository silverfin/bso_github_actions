#!/usr/bin/env bash
set -euo pipefail
# Without this, bash does NOT propagate errexit into command-substitution
# subshells (pre-4.4 behavior, or simply without this shopt) - a command
# deep inside a `x=$(fn ...)` call chain can fail and the subshell can
# silently continue past it instead of aborting, which would undermine
# every "guard fires, function returns cleanly" assumption this script
# relies on throughout resolve_handle/notion_request/find_page_by_handle/
# sync_readme.
# inherit_errexit is a bash 4.4+ option; macOS's stock /bin/bash is 3.2
# (Apple never shipped a GPLv3 bash), where `shopt -s <unknown option>`
# itself fails and - with `set -e` above - would kill this script before
# a single function gets defined. Version-guarded rather than piping
# stderr to /dev/null, so an unrelated future shopt typo still surfaces.
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
  shopt -s inherit_errexit
fi

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

# $1 = data_source_id, $2 = handle to search for.
# stdout: the page ID on exactly one match; empty string on zero matches;
# the literal string DUPLICATE (plus a stderr warning) on 2+ matches - the
# caller must treat DUPLICATE as skip-and-alert, never guess which page.
find_page_by_handle() {
  local data_source_id="$1"
  local handle="$2"
  local body
  body=$(jq -n --arg h "$handle" '{filter: {property: "Handle", rich_text: {equals: $h}}}')

  local response
  response=$(notion_request POST "/v1/data_sources/$data_source_id/query" "$body") || return 1

  # Guard explicitly against jq failing (e.g. a malformed/unexpected
  # response body) - a bare `count=$(echo ... | jq ...)` would trip
  # `set -e` deep inside this function and kill the calling script before
  # it ever sees a return value, same hazard class as the fixes already
  # applied in resolve_handle and notion_request.
  local count
  if ! count=$(echo "$response" | jq '.results | length' 2>&1); then
    echo "ERROR: find_page_by_handle: unparseable response from Notion for handle '$handle' (jq failed: $count)" >&2
    return 1
  fi

  if [[ "$count" == "0" ]]; then
    echo ""
    return 0
  elif [[ "$count" == "1" ]]; then
    echo "$response" | jq -r '.results[0].id'
    return 0
  else
    echo "WARN: Handle '$handle' matches $count pages in data source $data_source_id - skipping, needs manual dedup" >&2
    echo "DUPLICATE"
    return 0
  fi
}

SYNC_CALLOUT='<callout icon="🤖">This page is generated from the repo and will be overwritten on the next merge. Leave feedback as a comment - comments survive the sync.</callout>

'

# $1 = readme_path, $2 = template_dir, $3 = repo_root, $4 = data_source_id,
# $5 = market, $6 = commit_sha.
sync_readme() {
  local readme_path="$1" template_dir="$2" repo_root="$3"
  local data_source_id="$4" market="$5" commit_sha="$6"

  local handle
  handle=$(resolve_handle "$template_dir" "$repo_root") || { echo "FAILED: could not resolve handle"; return 0; }

  local existing_page_id
  existing_page_id=$(find_page_by_handle "$data_source_id" "$handle") || { echo "FAILED: lookup error"; return 0; }

  if [[ "$existing_page_id" == "DUPLICATE" ]]; then
    echo "DUPLICATE"
    return 0
  fi

  local markdown_body readme_content
  if ! readme_content=$(cat "$readme_path"); then
    echo "FAILED: could not read $readme_path"
    return 0
  fi
  markdown_body="$SYNC_CALLOUT$readme_content"

  # Name/Market are resolved unconditionally (not just on create) so the
  # follow-up metadata-stamp PATCH below can refresh them on the update
  # path too - the script owns these properties on every page it manages,
  # not just the ones it creates.
  local name
  name=$(resolve_name "$template_dir" "$repo_root") || { echo "FAILED: could not resolve name"; return 0; }

  local page_id result
  if [[ -z "$existing_page_id" ]]; then
    # Name/Market are deliberately not set here - the metadata-stamp PATCH
    # below is their single owner and runs on every successful path
    # (create and update alike), so setting them here too would just be
    # duplicated, driftable state.
    local create_body
    if ! create_body=$(jq -n \
      --arg ds "$data_source_id" \
      --arg handle "$handle" --arg md "$markdown_body" \
      '{parent: {data_source_id: $ds}, properties: {Handle: {rich_text: [{text: {content: $handle}}]}}, markdown: $md}'); then
      echo "FAILED: could not build create request body"
      return 0
    fi
    local response
    response=$(notion_request POST "/v1/pages" "$create_body") || { echo "FAILED: create request failed"; return 0; }
    # jq -r alone would print the literal string "null" (exit 0) for a
    # syntactically-valid 2xx body that simply lacks .id, letting a bogus
    # page_id of "null" slip through to the stamp PATCH below (PATCH
    # /v1/pages/null). -e makes jq exit non-zero on a null/false result so
    # that case is caught here, same hazard class as the guards elsewhere
    # in this file - a non-JSON response alone isn't the only failure mode.
    if ! page_id=$(echo "$response" | jq -er '.id'); then
      echo "FAILED: create response missing id"
      return 0
    fi
    result="CREATED"
  else
    page_id="$existing_page_id"
    local update_body
    if ! update_body=$(jq -n --arg md "$markdown_body" '{type: "replace_content", replace_content: {new_str: $md}}'); then
      echo "FAILED: could not build update request body"
      return 0
    fi
    notion_request PATCH "/v1/pages/$page_id/markdown" "$update_body" > /dev/null || { echo "FAILED: update request failed"; return 0; }
    result="UPDATED"
  fi

  local today
  if ! today=$(date -u +%Y-%m-%d); then
    echo "FAILED: could not compute today's date"
    return 0
  fi
  local short_sha="${commit_sha:0:7}"
  local stamp_body
  if ! stamp_body=$(jq -n \
    --arg date "$today" --arg sha "$short_sha" --arg path "$template_dir" \
    --arg name "$name" --arg market "$market" \
    '{properties: {"Last synced": {date: {start: $date}}, "Source commit": {rich_text: [{text: {content: $sha}}]}, "Repo path": {rich_text: [{text: {content: $path}}]}, Name: {title: [{text: {content: $name}}]}, Market: {select: {name: $market}}}}'); then
    echo "FAILED: could not build metadata stamp body"
    return 0
  fi
  notion_request PATCH "/v1/pages/$page_id" "$stamp_body" > /dev/null || { echo "FAILED: metadata stamp failed"; return 0; }

  echo "$result"
}

# CLI entrypoint. $1 = path to a newline-separated list of changed README
# paths (relative to repo_root), $2 = repo_root, $3 = market (e.g. BE),
# $4 = commit_sha, $5 = optional path to the market -> data-source-id config
# (defaults to repo_root/scripts/notion-config.json). This is a post-merge
# job with nothing left to block, so it always exits 0; failures are
# reported via $GITHUB_OUTPUT instead, for the workflow's Slack step.
main() {
  local changed_readmes_path="$1"
  local repo_root="$2"
  local market="$3"
  local commit_sha="$4"
  local config_path="${5:-$repo_root/scripts/notion-config.json}"

  # Guarded like every other jq call in this file: a missing or unparseable
  # config_path exits non-zero (unlike a merely-missing market key, which jq
  # resolves to "null" without erroring) and would otherwise trip set -e/
  # inherit_errexit and kill this CLI run before it reports anything - this
  # function must always exit 0 per its contract above.
  local rt_ds at_ds
  if ! rt_ds=$(jq -r --arg m "$market" '.[$m].reconciliation_texts' "$config_path" 2>&1); then
    echo "ERROR: could not read $config_path for market '$market' (jq failed: $rt_ds)" >&2
    return 0
  fi
  if ! at_ds=$(jq -r --arg m "$market" '.[$m].account_templates' "$config_path" 2>&1); then
    echo "ERROR: could not read $config_path for market '$market' (jq failed: $at_ds)" >&2
    return 0
  fi

  local failed=()
  local created=()

  while IFS= read -r readme_path; do
    [[ -z "$readme_path" ]] && continue
    local template_dir
    template_dir=$(dirname "$readme_path")

    local data_source_id
    if [[ "$template_dir" == reconciliation_texts/* ]]; then
      data_source_id="$rt_ds"
    elif [[ "$template_dir" == account_templates/* ]]; then
      data_source_id="$at_ds"
    else
      continue
    fi

    local full_readme_path="$repo_root/$readme_path"
    [[ -f "$full_readme_path" ]] || continue

    local result
    result=$(sync_readme "$full_readme_path" "$template_dir" "$repo_root" "$data_source_id" "$market" "$commit_sha")
    echo "$template_dir: $result"

    if [[ "$result" == "DUPLICATE" || "$result" == FAILED:* ]]; then
      failed+=("$(basename "$template_dir")")
    elif [[ "$result" == "CREATED" ]]; then
      created+=("$(basename "$template_dir")")
    fi
  done < "$changed_readmes_path"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    if [[ ${#failed[@]} -gt 0 ]]; then
      echo "failed_handles=${failed[*]}" >> "$GITHUB_OUTPUT"
    fi
    if [[ ${#created[@]} -gt 0 ]]; then
      echo "created_handles=${created[*]}" >> "$GITHUB_OUTPUT"
    fi
  fi

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
