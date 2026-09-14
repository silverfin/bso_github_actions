#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../check-template-docs.sh"

failures=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    failures=$((failures + 1))
  else
    echo "PASS: $desc"
  fi
}

test_extract_template_dirs() {
  local input
  input=$(printf '%s\n' \
    "reconciliation_texts/foo/main.liquid" \
    "reconciliation_texts/foo/README.md" \
    "reconciliation_texts/bar/config.json" \
    "account_templates/Baz/main.liquid" \
    "shared_parts/qux/qux.liquid" \
    "some_other_dir/file.txt")
  local actual
  actual=$(extract_template_dirs <<< "$input")
  local expected
  expected=$(printf '%s\n' \
    "account_templates/Baz" \
    "reconciliation_texts/bar" \
    "reconciliation_texts/foo")
  assert_eq "extract_template_dirs" "$expected" "$actual"
}

test_extract_shared_part_dirs() {
  local input
  input=$(printf '%s\n' \
    "shared_parts/be_legal/be_legal.liquid" \
    "shared_parts/be_legal/config.json" \
    "reconciliation_texts/foo/main.liquid")
  local actual
  actual=$(extract_shared_part_dirs <<< "$input")
  assert_eq "extract_shared_part_dirs" "shared_parts/be_legal" "$actual"
}

# Regression case: a PR that touches NO templates and NO shared parts at
# all (e.g. only docs/CI files) must produce clean empty output, not crash
# the whole script. Under `set -e` + pipefail, a `grep` with zero matches
# exits 1 - easy to get wrong (see the implementation note in Step 3).
test_extract_dirs_with_no_matches_at_all() {
  local input
  input=$(printf '%s\n' "docs/README.md" ".github/workflows/foo.yml")
  local actual rc
  actual=$(extract_template_dirs <<< "$input") && rc=0 || rc=$?
  assert_eq "extract_template_dirs with zero matches: exit 0" "0" "$rc"
  assert_eq "extract_template_dirs with zero matches: empty output" "" "$actual"
  actual=$(extract_shared_part_dirs <<< "$input") && rc=0 || rc=$?
  assert_eq "extract_shared_part_dirs with zero matches: exit 0" "0" "$rc"
  assert_eq "extract_shared_part_dirs with zero matches: empty output" "" "$actual"
}

setup_shared_part_consumers_fixture() {
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  rm -rf "$root"
  mkdir -p "$root/shared_parts/be_legal_fixture"
  mkdir -p "$root/reconciliation_texts/vol_1_fixture"
  mkdir -p "$root/reconciliation_texts/vol_2_fixture"
  mkdir -p "$root/account_templates/AT_fixture"

  cat > "$root/shared_parts/be_legal_fixture/config.json" << 'JSON'
{
  "name": "be_legal_fixture",
  "used_in": [
    {"type": "reconciliationText", "handle": "vol_1_fixture"},
    {"type": "reconciliationText", "handle": "vol_2_fixture"},
    {"type": "accountTemplate", "handle": "AT_fixture"},
    {"type": "accountTemplate", "handle": null}
  ]
}
JSON

  echo '{}' > "$root/reconciliation_texts/vol_1_fixture/config.json"
  echo '# Vol 1' > "$root/reconciliation_texts/vol_1_fixture/README.md"
  echo '{}' > "$root/reconciliation_texts/vol_2_fixture/config.json"
  # vol_2_fixture deliberately has no README.md

  echo '{}' > "$root/account_templates/AT_fixture/config.json"
  echo '# AT Fixture' > "$root/account_templates/AT_fixture/README.md"
}

# Regression case: a changed path with a space AND a shell metacharacter
# (e.g. an account template named "Foo Bar & Baz", a real shape in
# be_market) must survive extract_template_dirs whole - the dir extraction
# uses [^/]+ and never word-splits, so this locks that invariant in. The
# actual space-mangling bug this guards against lives in the workflow's own
# changed-files extraction step (tr ' ' '\n'), not in this function - but
# nothing previously exercised a space-containing path through this
# function to prove it was never at risk here too.
test_extract_template_dirs_with_spaces_and_metacharacters() {
  local input
  input=$(printf '%s\n' "account_templates/Foo Bar & Baz/main.liquid")
  local actual
  actual=$(extract_template_dirs <<< "$input")
  assert_eq "extract_template_dirs preserves spaces/metacharacters in dir names" "account_templates/Foo Bar & Baz" "$actual"
}

test_resolve_fanout_consumers() {
  setup_shared_part_consumers_fixture
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  local actual
  actual=$(resolve_fanout_consumers "shared_parts/be_legal_fixture" "$root" 2>/dev/null)
  local expected
  expected=$(printf '%s\n' \
    "account_templates/AT_fixture" \
    "reconciliation_texts/vol_1_fixture")
  assert_eq "resolve_fanout_consumers (existing-README only, null handle skipped)" "$expected" "$actual"
}

test_resolve_fanout_consumers_empty_result() {
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  rm -rf "$root"
  mkdir -p "$root/shared_parts/only_null_handles"

  cat > "$root/shared_parts/only_null_handles/config.json" << 'JSON'
{
  "name": "only_null_handles",
  "used_in": [
    {"type": "accountTemplate", "handle": null},
    {"type": "accountTemplate", "handle": null}
  ]
}
JSON

  local actual
  actual=$(resolve_fanout_consumers "shared_parts/only_null_handles" "$root" 2>/dev/null)
  assert_eq "resolve_fanout_consumers (empty result, all null handles skipped)" "" "$actual"
}

test_resolve_fanout_consumers_malformed_config() {
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  rm -rf "$root"
  mkdir -p "$root/shared_parts/broken_fixture"
  printf '{ this is not valid json' > "$root/shared_parts/broken_fixture/config.json"

  local actual rc stderr_out
  stderr_out=$(mktemp)
  actual=$(resolve_fanout_consumers "shared_parts/broken_fixture" "$root" 2>"$stderr_out") && rc=0 || rc=$?
  assert_eq "resolve_fanout_consumers (malformed config.json): exit 0, non-blocking" "0" "$rc"
  assert_eq "resolve_fanout_consumers (malformed config.json): empty output" "" "$actual"
  if grep -q "WARN:.*unparseable config.json" "$stderr_out"; then
    echo "PASS: resolve_fanout_consumers (malformed config.json) warns on stderr"
  else
    echo "FAIL: resolve_fanout_consumers (malformed config.json) should warn on stderr, got: $(cat "$stderr_out")"
    failures=$((failures + 1))
  fi
  rm -f "$stderr_out"
}

# Regression case: used_in itself is a scalar, not an array (e.g. bad data
# from a hand-edit or a partial write). `.used_in[]?` alone swallows this
# completely - the `?` suppresses jq's own "cannot iterate over string"
# error, so it exits 0 with empty output and no warning at all, unlike
# every other malformed-input case this function already handles.
test_resolve_fanout_consumers_scalar_used_in() {
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  rm -rf "$root"
  mkdir -p "$root/shared_parts/scalar_used_in_fixture"

  cat > "$root/shared_parts/scalar_used_in_fixture/config.json" << 'JSON'
{
  "name": "scalar_used_in_fixture",
  "used_in": "bad"
}
JSON

  local actual rc stderr_out
  stderr_out=$(mktemp)
  actual=$(resolve_fanout_consumers "shared_parts/scalar_used_in_fixture" "$root" 2>"$stderr_out") && rc=0 || rc=$?
  assert_eq "resolve_fanout_consumers (scalar used_in): exit 0, non-blocking" "0" "$rc"
  assert_eq "resolve_fanout_consumers (scalar used_in): empty output" "" "$actual"
  if grep -q "WARN:.*unparseable config.json" "$stderr_out"; then
    echo "PASS: resolve_fanout_consumers (scalar used_in) warns on stderr"
  else
    echo "FAIL: resolve_fanout_consumers (scalar used_in) should warn on stderr, got: $(cat "$stderr_out")"
    failures=$((failures + 1))
  fi
  rm -f "$stderr_out"
}

test_resolve_fanout_consumers_legacy_type_aliases() {
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  rm -rf "$root"
  mkdir -p "$root/shared_parts/legacy_types_fixture"
  mkdir -p "$root/reconciliation_texts/legacy_rt_fixture"
  mkdir -p "$root/reconciliation_texts/legacy_rt2_fixture"
  mkdir -p "$root/account_templates/legacy_at_fixture"
  mkdir -p "$root/account_templates/legacy_at2_fixture"

  cat > "$root/shared_parts/legacy_types_fixture/config.json" << 'JSON'
{
  "name": "legacy_types_fixture",
  "used_in": [
    {"type": "reconciliation", "handle": "legacy_rt_fixture"},
    {"type": "reconciliation_text", "handle": "legacy_rt2_fixture"},
    {"type": "account_detail_template", "handle": "legacy_at_fixture"},
    {"type": "account_template", "handle": "legacy_at2_fixture"}
  ]
}
JSON

  echo '{}' > "$root/reconciliation_texts/legacy_rt_fixture/config.json"
  echo '# Legacy RT' > "$root/reconciliation_texts/legacy_rt_fixture/README.md"
  echo '{}' > "$root/reconciliation_texts/legacy_rt2_fixture/config.json"
  echo '# Legacy RT 2' > "$root/reconciliation_texts/legacy_rt2_fixture/README.md"
  echo '{}' > "$root/account_templates/legacy_at_fixture/config.json"
  echo '# Legacy AT' > "$root/account_templates/legacy_at_fixture/README.md"
  echo '{}' > "$root/account_templates/legacy_at2_fixture/config.json"
  echo '# Legacy AT 2' > "$root/account_templates/legacy_at2_fixture/README.md"

  local actual
  actual=$(resolve_fanout_consumers "shared_parts/legacy_types_fixture" "$root" 2>/dev/null)
  local expected
  expected=$(printf '%s\n' \
    "account_templates/legacy_at2_fixture" \
    "account_templates/legacy_at_fixture" \
    "reconciliation_texts/legacy_rt2_fixture" \
    "reconciliation_texts/legacy_rt_fixture")
  assert_eq "resolve_fanout_consumers (pre-migration type aliases: reconciliation, reconciliation_text, account_detail_template, account_template)" "$expected" "$actual"
}

test_compute_expected_readmes() {
  setup_shared_part_consumers_fixture
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  local changed
  changed=$(printf '%s\n' \
    "shared_parts/be_legal_fixture/be_legal_fixture.liquid" \
    "reconciliation_texts/vol_1_fixture/main.liquid")
  local actual
  actual=$(compute_expected_readmes <(echo "$changed") "$root" 2>/dev/null)
  local expected
  expected=$(printf '%s\n' \
    "account_templates/AT_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture/README.md")
  assert_eq "compute_expected_readmes" "$expected" "$actual"
}

test_compute_expected_readmes_empty_input() {
  setup_shared_part_consumers_fixture
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  local changed
  changed=$(printf '%s\n' "docs/README.md" ".github/workflows/foo.yml")
  local actual rc
  actual=$(compute_expected_readmes <(echo "$changed") "$root" 2>/dev/null) && rc=0 || rc=$?
  assert_eq "compute_expected_readmes (empty input): exit 0" "0" "$rc"
  assert_eq "compute_expected_readmes (empty input): empty output" "" "$actual"
}

test_find_missing() {
  local expected changed actual
  expected=$(printf '%s\n' "account_templates/AT_fixture/README.md" "reconciliation_texts/vol_1_fixture/README.md")
  changed=$(printf '%s\n' "reconciliation_texts/vol_1_fixture/README.md" "reconciliation_texts/vol_1_fixture/main.liquid")
  actual=$(find_missing <(echo "$expected") <(echo "$changed"))
  assert_eq "find_missing" "account_templates/AT_fixture/README.md" "$actual"
}

test_find_missing_unreadable_input() {
  local actual rc stderr_out
  stderr_out=$(mktemp)
  actual=$(find_missing "/tmp/check-template-docs-test-does-not-exist.txt" "/tmp/check-template-docs-test-also-does-not-exist.txt" 2>"$stderr_out") && rc=0 || rc=$?
  assert_eq "find_missing (unreadable expected_path): nonzero exit, not a silent pass" "1" "$rc"
  assert_eq "find_missing (unreadable expected_path): empty output" "" "$actual"
  if grep -q "ERROR:.*could not read" "$stderr_out"; then
    echo "PASS: find_missing (unreadable expected_path) warns on stderr"
  else
    echo "FAIL: find_missing (unreadable expected_path) should warn on stderr, got: $(cat "$stderr_out")"
    failures=$((failures + 1))
  fi
  rm -f "$stderr_out"
}

test_validate_readme_structure_valid() {
  local out rc
  out=$(validate_readme_structure "$SCRIPT_DIR/fixtures/readmes/valid.README.md") && rc=0 || rc=$?
  assert_eq "valid README: no errors" "" "$out"
  assert_eq "valid README: exit 0" "0" "$rc"
}

test_validate_readme_structure_missing_heading() {
  local out rc
  out=$(validate_readme_structure "$SCRIPT_DIR/fixtures/readmes/missing-heading.README.md") && rc=0 || rc=$?
  assert_eq "missing heading: exit 1" "1" "$rc"
  if [[ "$out" != *"## FAQ / support answers"* ]]; then
    echo "FAIL: missing-heading output should name the missing heading, got: $out"
    failures=$((failures + 1))
  else
    echo "PASS: missing-heading output names the missing heading"
  fi
}

test_validate_readme_structure_unresolved_placeholder() {
  local out rc
  out=$(validate_readme_structure "$SCRIPT_DIR/fixtures/readmes/unresolved-placeholder.README.md") && rc=0 || rc=$?
  assert_eq "unresolved placeholder: exit 1" "1" "$rc"
  if [[ "$out" != *"unresolved placeholder"* ]]; then
    echo "FAIL: unresolved-placeholder output should mention it, got: $out"
    failures=$((failures + 1))
  else
    echo "PASS: unresolved-placeholder output mentions it"
  fi
}

test_validate_readme_structure_pii_leak() {
  local out rc
  out=$(validate_readme_structure "$SCRIPT_DIR/fixtures/readmes/pii-leak.README.md") && rc=0 || rc=$?
  assert_eq "pii leak: exit 1" "1" "$rc"
  if [[ "$out" != *"possible PII"* ]]; then
    echo "FAIL: pii-leak output should flag possible PII, got: $out"
    failures=$((failures + 1))
  else
    echo "PASS: pii-leak output flags possible PII"
  fi
}

test_cli_passes_when_nothing_missing_and_all_valid() {
  setup_shared_part_consumers_fixture
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  cp "$SCRIPT_DIR/fixtures/readmes/valid.README.md" "$root/reconciliation_texts/vol_1_fixture/README.md"
  cp "$SCRIPT_DIR/fixtures/readmes/valid.README.md" "$root/account_templates/AT_fixture/README.md"
  local changed
  changed=$(printf '%s\n' \
    "reconciliation_texts/vol_1_fixture/main.liquid" \
    "reconciliation_texts/vol_1_fixture/README.md" \
    "account_templates/AT_fixture/README.md")
  local changed_file rc
  changed_file="$SCRIPT_DIR/fixtures/changed-files.txt"
  echo "$changed" > "$changed_file"
  bash "$SCRIPT_DIR/../check-template-docs.sh" "$changed_file" "$root" > /dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "CLI passes when nothing missing and all valid" "0" "$rc"
}

test_cli_fails_when_readme_missing() {
  setup_shared_part_consumers_fixture
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  local changed changed_file rc
  changed="reconciliation_texts/vol_1_fixture/main.liquid"
  changed_file="$SCRIPT_DIR/fixtures/changed-files-missing.txt"
  echo "$changed" > "$changed_file"
  bash "$SCRIPT_DIR/../check-template-docs.sh" "$changed_file" "$root" > /dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "CLI fails when a required README is missing from the diff" "1" "$rc"
}

# Regression case: main()'s structural-validation loop used to match any
# CHANGED path ending in "README.md" (a substring/suffix match), which also
# hits nested liquid-test docs like reconciliation_texts/<x>/tests/README.md
# - a completely different, unrelated file that happens to share a
# basename with the real template-root README. This test's nested README
# is deliberately invalid (missing all four required headings): if main()
# still matched it, the CLI would fail with "missing required section"
# errors for a file that was never supposed to be validated at all. The
# template-root README is included in the diff too, valid, so the only way
# this test can pass is if the nested one is correctly ignored.
test_cli_ignores_nested_tests_readme_for_structural_validation() {
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  rm -rf "$root"
  mkdir -p "$root/reconciliation_texts/some_fixture/tests"

  cp "$SCRIPT_DIR/fixtures/readmes/valid.README.md" "$root/reconciliation_texts/some_fixture/README.md"
  cat > "$root/reconciliation_texts/some_fixture/tests/README.md" << 'MD'
# Liquid Testing

## 274 APT-8 - some scenario
MD

  local changed changed_file rc out
  changed=$(printf '%s\n' \
    "reconciliation_texts/some_fixture/main.liquid" \
    "reconciliation_texts/some_fixture/README.md" \
    "reconciliation_texts/some_fixture/tests/README.md")
  changed_file="$SCRIPT_DIR/fixtures/changed-files-nested-readme.txt"
  echo "$changed" > "$changed_file"
  out=$(bash "$SCRIPT_DIR/../check-template-docs.sh" "$changed_file" "$root" 2>&1) && rc=0 || rc=$?
  assert_eq "CLI ignores nested tests/README.md for structural validation: exit 0" "0" "$rc"
  if [[ "$out" == *"missing required section"* ]]; then
    echo "FAIL: nested tests/README.md should not be structurally validated, got: $out"
    failures=$((failures + 1))
  else
    echo "PASS: nested tests/README.md is not structurally validated"
  fi
}

test_cli_github_output_all_valid() {
  setup_shared_part_consumers_fixture
  local root="$SCRIPT_DIR/fixtures/shared-part-consumers"
  cp "$SCRIPT_DIR/fixtures/readmes/valid.README.md" "$root/reconciliation_texts/vol_1_fixture/README.md"
  cp "$SCRIPT_DIR/fixtures/readmes/valid.README.md" "$root/account_templates/AT_fixture/README.md"
  local changed
  changed=$(printf '%s\n' \
    "reconciliation_texts/vol_1_fixture/main.liquid" \
    "reconciliation_texts/vol_1_fixture/README.md" \
    "account_templates/AT_fixture/README.md")
  local changed_file rc github_output
  changed_file="$SCRIPT_DIR/fixtures/changed-files-all-valid.txt"
  echo "$changed" > "$changed_file"
  github_output=$(mktemp)
  GITHUB_OUTPUT="$github_output" bash "$SCRIPT_DIR/../check-template-docs.sh" "$changed_file" "$root" > /dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "CLI with GITHUB_OUTPUT set and all valid: exit 0" "0" "$rc"
  if [[ ! -f "$github_output" ]]; then
    echo "FAIL: GITHUB_OUTPUT file should exist"
    failures=$((failures + 1))
  else
    echo "PASS: GITHUB_OUTPUT file created"
    rm -f "$github_output"
  fi
}

# Isolated regression case: a placeholder whose text contains a hyphen or a
# digit, with no OTHER placeholder present to mask a regex gap. The
# fixtures/readmes/unresolved-placeholder.README.md fixture has several
# placeholders at once (`{handle}`, `{one paragraph}`, etc.) - a class that
# only matches letters-and-spaces still passes that whole-file test because
# the other, letters-only placeholders are caught, even if
# `{plain-language answer}` itself is silently missed. This test isolates
# a single hyphen/digit placeholder so that masking can't happen.
test_validate_readme_structure_unresolved_placeholder_with_hyphen_and_digit() {
  local tmpfile
  tmpfile=$(mktemp)
  cat > "$tmpfile" << 'MD'
## Metadata

## Functional overview

**Purpose:**
Something.

## Scenarios & edge cases

### Happy path
- Something happens -> something else happens.

## FAQ / support answers

**Q:** `{step 1}`
**A:** `{plain-language answer}`
MD
  local out rc
  out=$(validate_readme_structure "$tmpfile") && rc=0 || rc=$?
  rm -f "$tmpfile"
  assert_eq "unresolved placeholder with hyphen/digit: exit 1" "1" "$rc"
  if [[ "$out" == *"unresolved placeholder"* ]]; then
    echo "PASS: hyphen/digit-only placeholder is still detected"
  else
    echo "FAIL: hyphen/digit-only placeholder should be detected, got: $out"
    failures=$((failures + 1))
  fi
}

# Regression case: a wrong heading level (### instead of the required ##)
# must not be accepted. Plain -F is a substring search, and "### Metadata"
# contains "## Metadata" as a substring (starting at its second character),
# so this fails without -x (whole-line match).
test_validate_readme_structure_wrong_heading_level() {
  local tmpfile
  tmpfile=$(mktemp)
  cat > "$tmpfile" << 'MD'
### Metadata

## Functional overview

**Purpose:**
Something.

## Scenarios & edge cases

### Happy path
- Something happens -> something else happens.

## FAQ / support answers

**Q:** Why?
**A:** Because.
MD
  local out rc
  out=$(validate_readme_structure "$tmpfile") && rc=0 || rc=$?
  rm -f "$tmpfile"
  assert_eq "wrong heading level (### instead of ##): exit 1" "1" "$rc"
  if [[ "$out" == *"missing required section: ## Metadata"* ]]; then
    echo "PASS: wrong heading level is not accepted as the required section"
  else
    echo "FAIL: wrong heading level should be flagged as a missing section, got: $out"
    failures=$((failures + 1))
  fi
}

# Regression case: main() previously had no arity guard, so calling the CLI
# with fewer than 2 args died with a bare "$1: unbound variable" under
# `set -u` instead of a legible usage message. Cover both 0 and 1 args.
test_cli_usage_message_on_missing_args() {
  local out rc

  out=$(bash "$SCRIPT_DIR/../check-template-docs.sh" 2>&1) && rc=0 || rc=$?
  assert_eq "CLI with 0 args: nonzero exit" "1" "$rc"
  if [[ "$out" == *"Usage:"* ]]; then
    echo "PASS: CLI with 0 args prints a Usage message"
  else
    echo "FAIL: CLI with 0 args should print a Usage message, got: $out"
    failures=$((failures + 1))
  fi

  out=$(bash "$SCRIPT_DIR/../check-template-docs.sh" "/tmp/some-changed-files.txt" 2>&1) && rc=0 || rc=$?
  assert_eq "CLI with 1 arg: nonzero exit" "1" "$rc"
  if [[ "$out" == *"Usage:"* ]]; then
    echo "PASS: CLI with 1 arg prints a Usage message"
  else
    echo "FAIL: CLI with 1 arg should print a Usage message, got: $out"
    failures=$((failures + 1))
  fi
}

test_extract_template_dirs
test_extract_template_dirs_with_spaces_and_metacharacters
test_extract_shared_part_dirs
test_extract_dirs_with_no_matches_at_all
test_resolve_fanout_consumers
test_resolve_fanout_consumers_empty_result
test_resolve_fanout_consumers_malformed_config
test_resolve_fanout_consumers_scalar_used_in
test_resolve_fanout_consumers_legacy_type_aliases
test_compute_expected_readmes
test_compute_expected_readmes_empty_input
test_find_missing
test_find_missing_unreadable_input
test_validate_readme_structure_valid
test_validate_readme_structure_missing_heading
test_validate_readme_structure_unresolved_placeholder
test_validate_readme_structure_unresolved_placeholder_with_hyphen_and_digit
test_validate_readme_structure_wrong_heading_level
test_validate_readme_structure_pii_leak
test_cli_passes_when_nothing_missing_and_all_valid
test_cli_fails_when_readme_missing
test_cli_ignores_nested_tests_readme_for_structural_validation
test_cli_github_output_all_valid
test_cli_usage_message_on_missing_args

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
