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

test_extract_template_dirs
test_extract_shared_part_dirs
test_extract_dirs_with_no_matches_at_all

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
