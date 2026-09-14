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
