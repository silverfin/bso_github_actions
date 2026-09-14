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

test_extract_template_dirs
test_extract_shared_part_dirs
test_extract_dirs_with_no_matches_at_all
test_resolve_fanout_consumers
test_resolve_fanout_consumers_empty_result
test_resolve_fanout_consumers_malformed_config
test_resolve_fanout_consumers_legacy_type_aliases
test_compute_expected_readmes
test_compute_expected_readmes_empty_input
test_find_missing
test_find_missing_unreadable_input

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
