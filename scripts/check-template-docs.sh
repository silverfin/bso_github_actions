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

# $1 = template dir (e.g. reconciliation_texts/vol_1), $2 = optional repo_root.
# Prints the path of its template-specific md, as written by
# silverfin-uni-create-template-specific-md: <dir>/template_info/<handle>.md.
# A reconciliation text's handle comes from its config.json (the folder can
# differ, e.g. nl_market's model_condensed); an account template's is its
# folder name, verbatim (spaces, accents, trailing space and all).
doc_path_for_dir() {
  local dir="$1" repo_root="${2:-}" name="${1#*/}"
  if [[ "$dir" == reconciliation_texts/* && -n "$repo_root" && -f "$repo_root/$dir/config.json" ]]; then
    local handle
    handle=$(jq -r '.handle | strings' "$repo_root/$dir/config.json" 2>/dev/null) || handle=""
    if [[ -n "$handle" && "$handle" != */* ]]; then
      name="$handle"
    fi
  fi
  printf '%s/template_info/%s.md\n' "$dir" "$name"
}

# $1 = reconciliation text handle, $2 = repo_root. Prints its folder
# (reconciliation_texts/<x>). Usually the folder is the handle; otherwise it
# is found by config.json. Prints nothing when no folder (or several) match.
resolve_rt_dir() {
  local handle="$1" repo_root="$2"
  if [[ -f "$repo_root/reconciliation_texts/$handle/config.json" ]]; then
    printf 'reconciliation_texts/%s\n' "$handle"
    return 0
  fi
  local matches
  matches=$(cd "$repo_root" && jq -r --arg h "$handle" 'select(.handle == $h) | input_filename' reconciliation_texts/*/config.json 2>/dev/null) || matches=""
  if [[ -n "$matches" && "$matches" != *$'\n'* ]]; then
    printf '%s\n' "${matches%/config.json}"
  fi
  return 0
}

# $1 = shared part dir (e.g. shared_parts/be_legal), relative to $2 = repo_root.
# Prints consumer dirs (relative to repo_root) whose template-specific md
# already exists. Skips any used_in entry with a null/empty handle, warning on
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
  # A top-level `used_in` that's neither null/absent nor an array (e.g.
  # "used_in": "bad") is a case `.used_in[]?` swallows completely: `?`
  # suppresses jq's "cannot iterate over string" error, so it exits 0 with
  # empty output - indistinguishable from "no consumers", with no WARN at
  # all (worse than the malformed-JSON case above, which at least warns).
  # Only the array branch iterates; anything else hits error(...), making
  # it a real jq failure the exit-status check above can catch.
  local jq_output
  if ! jq_output=$(jq -r '
    if .used_in == null then empty
    elif (.used_in | type) == "array" then
      .used_in[] | [.type, (.handle // "null")] | @tsv
    else
      error("used_in must be an array")
    end
  ' "$config_path" 2>&1); then
    # A gate must not pass because it could not work out what to check.
    echo "ERROR: $shared_part_dir has an unparseable config.json (jq failed: $jq_output) - cannot tell which consumer docs are required" >&2
    return 1
  fi

  local results=()
  if [[ -n "$jq_output" ]]; then
    local type handle
    while IFS=$'\t' read -r type handle; do
      if [[ "$handle" == "null" || -z "$handle" || "$handle" == */* ]]; then
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
        reconciliationText|reconciliation|reconciliation_text)
          dir=$(resolve_rt_dir "$handle" "$repo_root")
          if [[ -z "$dir" ]]; then
            echo "WARN: $shared_part_dir used_in names reconciliation text '$handle', which matches no single folder, skipping" >&2
            continue
          fi
          ;;
        accountTemplate|account_detail_template|account_template) dir="account_templates/$handle" ;;
        *)
          echo "WARN: $shared_part_dir used_in has unknown type '$type', skipping" >&2
          continue
          ;;
      esac
      local doc
      doc=$(doc_path_for_dir "$dir" "$repo_root")
      if [[ -f "$repo_root/$doc" ]]; then
        results+=("$dir")
      fi
    done <<< "$jq_output"
  fi

  (( ${#results[@]} )) && printf '%s\n' "${results[@]}" | sort -u
  return 0
}

# $1 = path to file of changed files (newline-separated), or process substitution.
# $2 = repo_root.
compute_expected_docs() {
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
    results+=("$(doc_path_for_dir "$dir" "$repo_root")")
  done <<< "$template_dirs"

  local consumers
  while IFS= read -r sp_dir; do
    [[ -z "$sp_dir" ]] && continue
    # Captured, not `< <(...)`: a process substitution hides the failure.
    consumers=$(resolve_fanout_consumers "$sp_dir" "$repo_root") || return 1
    while IFS= read -r consumer_dir; do
      [[ -z "$consumer_dir" ]] && continue
      results+=("$(doc_path_for_dir "$consumer_dir" "$repo_root")")
    done <<< "$consumers"
  done <<< "$shared_part_dirs"

  (( ${#results[@]} )) && printf '%s\n' "${results[@]}" | sort -u
  return 0
}

# $1 = path to file of expected doc paths. $2 = path to file of changed files.
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

# $1 = path to a template-specific md. Prints one ERROR: line per problem to
# stdout, nothing on success. Returns 0 if valid, 1 otherwise.
validate_doc_structure() {
  local readme_path="$1"
  local ok=0

  if [[ ! -s "$readme_path" ]]; then
    echo "ERROR: file is empty or missing"
    return 1
  fi

  for heading in "${REQUIRED_HEADINGS[@]}"; do
    # -x (whole-line match): plain -F does a substring search, so
    # "### Metadata" (wrong heading level) would silently pass a check
    # for "## Metadata" - "###" + " Metadata" contains "## Metadata" as
    # a substring starting at its second character.
    if ! grep -qxF "$heading" "$readme_path"; then
      echo "ERROR: missing required section: $heading"
      ok=1
    fi
  done

  # Unresolved skeleton placeholders: backtick-quoted {word} left as-is,
  # e.g. `{handle}`, `{situation}`. A filled-in doc should have none.
  # Character class includes digits/hyphen/comma/period, not just letters
  # and spaces: the skill's own skeleton examples include placeholder text
  # like `{plain-language answer}` and a hyphen-free class misses it
  # silently (verified: `{plain-language answer}` does not match
  # `[a-zA-Z_ /]+`, only the fixture's other, letters-only placeholders
  # do - masking the gap behind an otherwise-passing test).
  if grep -qE '`\{[a-zA-Z0-9_ /,.-]+\}`' "$readme_path"; then
    echo "ERROR: unresolved placeholder(s) still present - the skeleton was not filled in:"
    grep -nE '`\{[a-zA-Z0-9_ /,.-]+\}`' "$readme_path" | sed 's/^/  /'
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

# $1 = template dir, $2 = repo_root. Prints one line per .md file under
# <dir>/template_info/ other than the expected one: a misnamed doc
# (`{handle}_v2.md`, a `.MD` casing variant, a `README.md`), a second doc, or
# one nested deeper. The skill allows exactly one doc per template.
find_stray_docs() {
  local dir="$1"
  local repo_root="$2"
  local info_dir="$repo_root/$dir/template_info"
  [[ -d "$info_dir" ]] || return 0

  local expected found
  expected="$repo_root/$(doc_path_for_dir "$dir" "$repo_root")"
  if ! found=$(find "$info_dir" -type f -iname '*.md' -print); then
    echo "ERROR: could not list $dir/template_info" >&2
    return 1
  fi
  local path
  while IFS= read -r path; do
    [[ -z "$path" || "$path" == "$expected" ]] && continue
    echo "${path#"$repo_root"/}"
  done <<< "$found"
}

# CLI entrypoint - only runs when this file is executed directly, not when sourced.
main() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <changed_files_path> <repo_root> [deleted_files_path]" >&2
    return 1
  fi

  local changed_files_path="$1"
  local repo_root="$2"
  local deleted_files_path="${3:-}"

  if [[ ! -r "$changed_files_path" ]]; then
    echo "ERROR: changed-files list '$changed_files_path' is missing or unreadable" >&2
    return 1
  fi
  if [[ ! -d "$repo_root" ]]; then
    echo "ERROR: repo root '$repo_root' is not a directory" >&2
    return 1
  fi

  if [[ -n "$deleted_files_path" && ! -r "$deleted_files_path" ]]; then
    echo "ERROR: deleted-files list '$deleted_files_path' is unreadable" >&2
    return 1
  fi

  # Templates touched = changed files, plus deletions inside a template that
  # still exists (deleting only the doc must not pass). Deletions never count
  # as updating a doc: find_missing compares against changed files only.
  local touched_path expected_path
  touched_path=$(mktemp)
  expected_path=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$touched_path' '$expected_path'" RETURN
  cat "$changed_files_path" > "$touched_path"
  if [[ -n "$deleted_files_path" ]]; then
    local deleted deleted_dir
    while IFS= read -r deleted; do
      deleted_dir=$(extract_template_dirs <<< "$deleted")
      [[ -n "$deleted_dir" && -d "$repo_root/$deleted_dir" ]] && printf '%s\n' "$deleted" >> "$touched_path"
    done < "$deleted_files_path"
  fi
  compute_expected_docs "$touched_path" "$repo_root" > "$expected_path"

  local missing
  missing=$(find_missing "$expected_path" "$changed_files_path")

  local not_created=() not_updated=()
  local doc
  while IFS= read -r doc; do
    [[ -z "$doc" ]] && continue
    if [[ -f "$repo_root/$doc" ]]; then
      not_updated+=("$doc")
    else
      not_created+=("$doc")
    fi
  done <<< "$missing"

  local invalid=()
  local changed dir errors
  while IFS= read -r changed; do
    # Only the exact <dir>/template_info/<handle>.md is validated. Misnamed
    # files are reported by find_stray_docs below; tests/README.md and a
    # template-root README.md (developer notes) are not template docs at all.
    [[ "$changed" =~ ^((reconciliation_texts|account_templates)/[^/]+)/template_info/ ]] || continue
    dir="${BASH_REMATCH[1]}"
    [[ "$changed" == "$(doc_path_for_dir "$dir" "$repo_root")" ]] || continue
    [[ -f "$repo_root/$changed" ]] || continue
    errors=$(validate_doc_structure "$repo_root/$changed") || invalid+=("$changed: $errors")
  done < "$changed_files_path"

  local stray=()
  local template_dirs stray_out
  template_dirs=$(extract_template_dirs < "$touched_path")
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    if ! stray_out=$(find_stray_docs "$dir" "$repo_root"); then
      invalid+=("$dir/template_info: could not be listed")
      continue
    fi
    [[ -z "$stray_out" ]] && continue
    while IFS= read -r doc; do
      stray+=("$doc (expected only $(doc_path_for_dir "$dir" "$repo_root"))")
    done <<< "$stray_out"
  done <<< "$template_dirs"

  local missing_report="" invalid_report=""
  if (( ${#not_created[@]} )); then
    missing_report+="These templates changed but have no template-specific md yet - create it with silverfin-uni-create-template-specific-md:"$'\n'
    missing_report+=$(printf '  - %s\n' "${not_created[@]}")$'\n'
  fi
  if (( ${#not_updated[@]} )); then
    missing_report+="These templates changed but their template-specific md was not updated in this PR:"$'\n'
    missing_report+=$(printf '  - %s\n' "${not_updated[@]}")$'\n'
  fi
  if (( ${#invalid[@]} )); then
    invalid_report+="These template-specific mds have structural problems:"$'\n'
    invalid_report+=$(printf '%s\n' "${invalid[@]}" | sed 's/^/  - /')$'\n'
  fi
  if (( ${#stray[@]} )); then
    invalid_report+="These files in template_info/ are misnamed or extra - one <handle>.md per template (an account template's handle is its folder name):"$'\n'
    invalid_report+=$(printf '  - %s\n' "${stray[@]}")$'\n'
  fi

  [[ -n "$missing_report" ]] && printf '%s' "$missing_report"
  [[ -n "$invalid_report" ]] && printf '%s' "$invalid_report"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    local delim
    delim="EOF_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$missing_report$invalid_report" == *"$delim"* ]]; then
      echo "ERROR: GITHUB_OUTPUT delimiter collided with the report" >&2
      return 1
    fi
    {
      printf 'missing_docs<<%s\n%s\n%s\n' "$delim" "$missing_report" "$delim"
      printf 'invalid_docs<<%s\n%s\n%s\n' "$delim" "$invalid_report" "$delim"
    } >> "$GITHUB_OUTPUT"
  fi

  if [[ -n "$missing_report$invalid_report" ]]; then
    return 1
  fi
  echo "All changed templates have an up-to-date, structurally valid template-specific md."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
