#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../sync-notion-docs.sh"

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

assert_error() {
  local desc="$1" template_dir="$2" repo_root="$3" expected_msg="$4"
  local tempfile output exit_code
  tempfile=$(mktemp)
  trap "rm -f $tempfile" RETURN

  # Run in a subshell that doesn't inherit set -e to properly capture exit codes
  (
    set +e
    resolve_handle "$template_dir" "$repo_root" > "$tempfile" 2>&1
    echo $? > "${tempfile}.exit"
  )

  exit_code=$(cat "${tempfile}.exit")
  output=$(cat "$tempfile")

  if [[ $exit_code -eq 0 ]]; then
    echo "FAIL: $desc (expected non-zero exit code, got 0)"
    failures=$((failures + 1))
    return
  fi

  if [[ "$output" != *"$expected_msg"* ]]; then
    echo "FAIL: $desc (error message mismatch)"
    echo "  expected to contain: $expected_msg"
    echo "  actual:   $output"
    failures=$((failures + 1))
  else
    echo "PASS: $desc"
  fi
}

setup_resolve_fixture() {
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  # Clear only the template dirs, NOT $root itself - $root also holds
  # stub-curl/curl, which every later test depends on being on PATH.
  rm -rf "$root/reconciliation_texts" "$root/account_templates"
  mkdir -p "$root/reconciliation_texts/vol_1_fixture" "$root/account_templates/AT_fixture"
  cat > "$root/reconciliation_texts/vol_1_fixture/config.json" << 'JSON'
{"handle": "vol_1_fixture", "name_en": "Postponement of the general meeting"}
JSON
  echo '{"id": {"542": 123}}' > "$root/account_templates/AT_fixture/config.json"
}

test_resolve_handle() {
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  assert_eq "resolve_handle RT" "vol_1_fixture" "$(resolve_handle reconciliation_texts/vol_1_fixture "$root")"
  assert_eq "resolve_handle AT falls back to dir basename" "AT_fixture" "$(resolve_handle account_templates/AT_fixture "$root")"
}

test_resolve_name() {
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  assert_eq "resolve_name RT uses name_en" "Postponement of the general meeting" "$(resolve_name reconciliation_texts/vol_1_fixture "$root")"
  assert_eq "resolve_name AT falls back to prettified dir name" "AT fixture" "$(resolve_name account_templates/AT_fixture "$root")"
}

test_resolve_handle_errors() {
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"

  # Test missing config.json
  assert_error "resolve_handle RT with missing config.json" \
    "reconciliation_texts/missing_fixture" \
    "$root" \
    "has no config.json"

  # Test malformed JSON
  mkdir -p "$root/reconciliation_texts/malformed_fixture"
  echo "{ invalid json" > "$root/reconciliation_texts/malformed_fixture/config.json"
  assert_error "resolve_handle RT with malformed JSON" \
    "reconciliation_texts/malformed_fixture" \
    "$root" \
    "unparseable config.json"

  # Test missing .handle key
  mkdir -p "$root/reconciliation_texts/no_handle_fixture"
  echo '{"name_en": "Test"}' > "$root/reconciliation_texts/no_handle_fixture/config.json"
  assert_error "resolve_handle RT with missing .handle key" \
    "reconciliation_texts/no_handle_fixture" \
    "$root" \
    "has no .handle in config.json"
}

test_resolve_handle
test_resolve_name
test_resolve_handle_errors

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
