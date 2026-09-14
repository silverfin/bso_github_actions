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

# $1 = path to file of changed files (newline-separated), or process substitution.
# $2 = repo_root.
compute_expected_readmes() {
  local changed_files_path="$1"
  local repo_root="$2"
  local changed
  changed=$(cat "$changed_files_path")

  local template_dirs shared_part_dirs
  template_dirs=$(extract_template_dirs <<< "$changed")
  shared_part_dirs=$(extract_shared_part_dirs <<< "$changed")

  local results=()
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    results+=("$dir/README.md")
  done <<< "$template_dirs"

  while IFS= read -r sp_dir; do
    [[ -z "$sp_dir" ]] && continue
    while IFS= read -r consumer_dir; do
      [[ -z "$consumer_dir" ]] && continue
      results+=("$consumer_dir/README.md")
    done < <(resolve_fanout_consumers "$sp_dir" "$repo_root")
  done <<< "$shared_part_dirs"

  (( ${#results[@]} )) && printf '%s\n' "${results[@]}" | sort -u
  return 0
}

# $1 = path to file of expected README paths. $2 = path to file of changed files.
find_missing() {
  local expected_path="$1"
  local changed_path="$2"

  # `-r` (a permission check, not a read) rather than pre-reading each path
  # via `sort`: reading a process-substitution path twice returns empty on
  # the second read, which would silently break this function's own tests
  # (they pass <(...) paths). `-r` catches missing/unreadable input before
  # the real sort/comm below, whose exit status a process substitution
  # would otherwise hide from set -e - the same failure mode already
  # documented and worked around in resolve_fanout_consumers above.
  if [[ ! -r "$expected_path" ]]; then
    echo "ERROR: find_missing could not read $expected_path" >&2
    return 1
  fi
  if [[ ! -r "$changed_path" ]]; then
    echo "ERROR: find_missing could not read $changed_path" >&2
    return 1
  fi

  comm -23 <(sort -u "$expected_path") <(sort -u "$changed_path")
}

REQUIRED_HEADINGS=(
  "## Metadata"
  "## Functional overview"
  "## Scenarios & edge cases"
  "## FAQ / support answers"
)

# $1 = path to a README.md. Prints one ERROR: line per problem to stdout,
# nothing on success. Returns 0 if valid, 1 otherwise.
validate_readme_structure() {
  local readme_path="$1"
  local ok=0

  if [[ ! -s "$readme_path" ]]; then
    echo "ERROR: file is empty or missing"
    return 1
  fi

  for heading in "${REQUIRED_HEADINGS[@]}"; do
    if ! grep -qF "$heading" "$readme_path"; then
      echo "ERROR: missing required section: $heading"
      ok=1
    fi
  done

  # Unresolved skeleton placeholders: backtick-quoted {word} left as-is,
  # e.g. `{handle}`, `{situation}`. A filled-in README should have none.
  if grep -qE '`\{[a-zA-Z_ /]+\}`' "$readme_path"; then
    echo "ERROR: unresolved placeholder(s) still present - the skeleton was not filled in:"
    grep -nE '`\{[a-zA-Z_ /]+\}`' "$readme_path" | sed 's/^/  /'
    ok=1
  fi

  # PII backstop: BE-shaped VAT/company numbers and email addresses.
  # This is a mechanical net under the skill's own PII rule, not a
  # replacement for it - false positives are expected and acceptable.
  local pii_matches
  pii_matches=$(grep -nE '(BE[0-9]{10}|BE0[0-9]{3}\.[0-9]{3}\.[0-9]{3}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})' "$readme_path" || true)
  if [[ -n "$pii_matches" ]]; then
    echo "ERROR: possible PII (VAT/company number or email) found - generalize per the skill's PII rule:"
    echo "$pii_matches" | sed 's/^/  /'
    ok=1
  fi

  return $ok
}
