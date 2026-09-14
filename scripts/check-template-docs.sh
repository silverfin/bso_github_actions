#!/usr/bin/env bash
# Pure functions for the check-template-docs CI check. Sourced by both the
# test script and this file's own CLI entrypoint (see bottom of file).
set -euo pipefail

# Reads newline-separated changed file paths on stdin. Prints unique sorted
# reconciliation_texts/<x> and account_templates/<x> directory paths.
#
# NOTE: the leading `(grep ... || true)` matters. Under `set -e` + pipefail,
# a `grep` with zero matches exits 1 and would otherwise kill the whole
# script the first time a PR touches no templates at all - a completely
# normal case (e.g. a shared-part-only PR touching no AT/RT directly).
# Parenthesize it: `grep X || true | sed Y` is NOT `(grep X || true) | sed Y`
# - `|` binds tighter than `||` in bash, so the unparenthesized form skips
#   the whole downstream pipe whenever grep succeeds, leaking grep's raw
#   unsedded output as the function's result instead.
extract_template_dirs() {
  (grep -E '^(reconciliation_texts|account_templates)/[^/]+/' || true) \
    | sed -E 's#^((reconciliation_texts|account_templates)/[^/]+)/.*#\1#' \
    | sort -u
}

# Same shape, for shared_parts/<x>. Same `(grep ... || true)` reasoning.
extract_shared_part_dirs() {
  (grep -E '^shared_parts/[^/]+/' || true) \
    | sed -E 's#^(shared_parts/[^/]+)/.*#\1#' \
    | sort -u
}

# $1 = shared part dir (e.g. shared_parts/be_legal), relative to $2 = repo_root.
# Prints consumer dirs (relative to repo_root) whose README.md already
# exists. Skips accountTemplate entries with a null handle, warning on stderr.
resolve_fanout_consumers() {
  local shared_part_dir="$1"
  local repo_root="$2"
  local config_path="$repo_root/$shared_part_dir/config.json"

  if [[ ! -f "$config_path" ]]; then
    echo "WARN: $shared_part_dir has no config.json, skipping fan-out" >&2
    return 0
  fi

  local results=()
  local type handle
  while IFS=$'\t' read -r type handle; do
    if [[ "$handle" == "null" || -z "$handle" ]]; then
      echo "WARN: $shared_part_dir used_in has a $type entry with no handle (common for account templates) - cannot resolve automatically, skipping" >&2
      continue
    fi
    local dir=""
    case "$type" in
      reconciliationText) dir="reconciliation_texts/$handle" ;;
      accountTemplate)    dir="account_templates/$handle" ;;
      *)
        echo "WARN: $shared_part_dir used_in has unknown type '$type', skipping" >&2
        continue
        ;;
    esac
    if [[ -f "$repo_root/$dir/README.md" ]]; then
      results+=("$dir")
    fi
  done < <(jq -r '.used_in[]? | [.type, (.handle // "null")] | @tsv' "$config_path")

  printf '%s\n' "${results[@]}" | sort -u
}
