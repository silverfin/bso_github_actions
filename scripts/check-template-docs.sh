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
# exists. Skips any used_in entry with a null/empty handle, warning on
# stderr.
resolve_fanout_consumers() {
  local shared_part_dir="$1"
  local repo_root="$2"
  local config_path="$repo_root/$shared_part_dir/config.json"

  if [[ ! -f "$config_path" ]]; then
    echo "WARN: $shared_part_dir has no config.json, skipping fan-out" >&2
    return 0
  fi

  # Captured via command substitution, not `< <(jq ...)`: a process
  # substitution's exit status is invisible to the shell (even under
  # `set -e`), so a malformed config.json would otherwise make jq fail
  # silently - the while loop just sees zero lines, `results` stays
  # empty, and this function reports success indistinguishable from "no
  # consumers to fan out to". Command substitution's status IS checkable.
  local jq_output
  if ! jq_output=$(jq -r '.used_in[]? | [.type, (.handle // "null")] | @tsv' "$config_path" 2>&1); then
    echo "WARN: $shared_part_dir has an unparseable config.json (jq failed: $jq_output), skipping fan-out" >&2
    return 0
  fi

  local results=()
  if [[ -n "$jq_output" ]]; then
    local type handle
    while IFS=$'\t' read -r type handle; do
      if [[ "$handle" == "null" || -z "$handle" ]]; then
        echo "WARN: $shared_part_dir used_in has a $type entry with no handle (common for account templates) - cannot resolve automatically, skipping" >&2
        continue
      fi
      local dir=""
      # reconciliation/reconciliation_text and account_detail_template/
      # account_template are pre-migration values still present in real
      # config.json files - silverfin-cli's own TEMPLATE_MAP_TYPES
      # (lib/utils/templateUtils.js) normalizes them the same way on read.
      # Not a rare case: reconciliation outnumbers reconciliationText in
      # be_market's committed shared_parts/*/config.json (495 vs 268).
      case "$type" in
        reconciliationText|reconciliation|reconciliation_text) dir="reconciliation_texts/$handle" ;;
        accountTemplate|account_detail_template|account_template) dir="account_templates/$handle" ;;
        *)
          echo "WARN: $shared_part_dir used_in has unknown type '$type', skipping" >&2
          continue
          ;;
      esac
      if [[ -f "$repo_root/$dir/README.md" ]]; then
        results+=("$dir")
      fi
    done <<< "$jq_output"
  fi

  (( ${#results[@]} )) && printf '%s\n' "${results[@]}" | sort -u
  return 0
}
