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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected to contain: $needle"
    echo "  actual:   $haystack"
    failures=$((failures + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected NOT to contain: $needle"
    echo "  actual:   $haystack"
    failures=$((failures + 1))
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

setup_stub_curl() {
  local stub_dir="$SCRIPT_DIR/fixtures/notion-sync/stub-curl"
  mkdir -p "$stub_dir"
  export PATH="$stub_dir:$PATH"
  export STUB_CURL_LOG="$SCRIPT_DIR/fixtures/notion-sync/curl.log"
  export STUB_CURL_RESPONSES="$SCRIPT_DIR/fixtures/notion-sync/curl-responses.tsv"
  : > "$STUB_CURL_LOG"
}

# $STUB_CURL_LOG holds one call's full argv per entry, but a call whose
# body is pretty-printed JSON (the default `jq -n` output, no -c) spans
# multiple lines - so `wc -l` does not count calls, and a plain sed -n
# 'Np' does not select call N. Every call's argv always starts with the
# fixed `-sS -w ...` prefix (see notion_request's curl_args), which never
# appears inside a JSON body value, so it's a reliable per-call delimiter.
curl_call_count() {
  grep -c -- '^-sS -w' "$STUB_CURL_LOG"
}

# $1 = 1-based call index. Prints that call's full argv block (spanning
# multiple lines if its body is pretty-printed JSON).
curl_call_block() {
  local n="$1"
  local starts start_line next_start
  starts=$(grep -n -- '^-sS -w' "$STUB_CURL_LOG" | cut -d: -f1)
  start_line=$(echo "$starts" | sed -n "${n}p")
  next_start=$(echo "$starts" | sed -n "$((n + 1))p")
  if [[ -z "$next_start" ]]; then
    sed -n "${start_line},\$p" "$STUB_CURL_LOG"
  else
    sed -n "${start_line},$((next_start - 1))p" "$STUB_CURL_LOG"
  fi
}

test_notion_request_succeeds_first_try() {
  setup_stub_curl
  printf '200\t-\t{"ok":true}\n' > "$STUB_CURL_RESPONSES"
  NOTION_TOKEN="fake-token" local out
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc")
  assert_eq "notion_request success body" '{"ok":true}' "$out"
  assert_eq "notion_request success: exactly 1 call" "1" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
  assert_contains "notion_request success: sends Authorization header" \
    "Authorization: Bearer fake-token" "$(cat "$STUB_CURL_LOG")"
  assert_contains "notion_request success: sends Notion-Version header" \
    "Notion-Version: 2026-03-11" "$(cat "$STUB_CURL_LOG")"
}

test_notion_request_retries_on_429() {
  setup_stub_curl
  printf '429\t0\t{"code":"rate_limited"}\n200\t-\t{"ok":true}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc")
  assert_eq "notion_request retries then succeeds" '{"ok":true}' "$out"
  assert_eq "notion_request retries: exactly 2 calls" "2" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
}

test_notion_request_fails_on_non_retryable_error() {
  setup_stub_curl
  printf '404\t-\t{"code":"object_not_found"}\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/missing" 2>&1) && rc=0 || rc=$?
  assert_eq "notion_request 404: exit 1" "1" "$rc"
  assert_eq "notion_request 404: exactly 1 call, no retry" "1" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
}

test_notion_request_curl_hard_failure() {
  setup_stub_curl
  printf 'CURLFAIL\t-\t-\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc" 2>&1) && rc=0 || rc=$?
  assert_eq "notion_request curl hard failure: exit 1" "1" "$rc"
  assert_contains "notion_request curl hard failure: sensible error message" "curl itself failed" "$out"
  assert_eq "notion_request curl hard failure: exactly 1 call, no retry" "1" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
}

test_notion_request_fails_after_max_attempts() {
  setup_stub_curl
  local i
  for ((i = 0; i < NOTION_MAX_ATTEMPTS; i++)); do
    printf '429\t0\t{"code":"rate_limited"}\n' >> "$STUB_CURL_RESPONSES"
  done
  local out rc start_ts end_ts elapsed
  start_ts=$(date +%s)
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc" 2>&1) && rc=0 || rc=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  assert_eq "notion_request exhausted: exit 1" "1" "$rc"
  assert_contains "notion_request exhausted: sensible error message" \
    "failed after $NOTION_MAX_ATTEMPTS attempts" "$out"
  assert_eq "notion_request exhausted: exactly $NOTION_MAX_ATTEMPTS calls, not $((NOTION_MAX_ATTEMPTS + 1))" \
    "$NOTION_MAX_ATTEMPTS" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"

  # Regression guard for the wasted-final-sleep fix: with the bug, the loop
  # sleeps out a backoff even on the last, already-doomed attempt, so 6
  # straight 429s take 1+2+4+8+16+32=63s. Fixed, the pointless final 32s
  # sleep is skipped, so this takes 1+2+4+8+16=31s. 45s leaves generous
  # slack for scheduling jitter while still catching a reintroduced sleep.
  if (( elapsed < 45 )); then
    echo "PASS: notion_request exhausted: skips the pointless final backoff sleep (${elapsed}s elapsed)"
  else
    echo "FAIL: notion_request exhausted: skips the pointless final backoff sleep (${elapsed}s elapsed, expected < 45s)"
    failures=$((failures + 1))
  fi
}

test_notion_request_succeeds_first_try
test_notion_request_retries_on_429
test_notion_request_fails_on_non_retryable_error
test_notion_request_curl_hard_failure
test_notion_request_fails_after_max_attempts

# Proof that a hard curl failure inside notion_request doesn't trip set -e
# and kill this whole test script (the bug being guarded against): if it
# did, we would never reach this line, and the run's final exit code would
# come from curl's own failure rather than from the failures counter below.
echo "PASS: test script continued past the hard curl failure"

test_find_page_by_handle_one_match() {
  setup_stub_curl
  printf '200\t-\t{"results":[{"id":"page-123"}]}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" find_page_by_handle "ds-abc" "vol_1_fixture")
  assert_eq "find_page_by_handle: one match returns its id" "page-123" "$out"
}

test_find_page_by_handle_no_match() {
  setup_stub_curl
  printf '200\t-\t{"results":[]}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" find_page_by_handle "ds-abc" "nonexistent")
  assert_eq "find_page_by_handle: no match returns empty" "" "$out"
}

test_find_page_by_handle_duplicate() {
  setup_stub_curl
  printf '200\t-\t{"results":[{"id":"page-1"},{"id":"page-2"}]}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" find_page_by_handle "ds-abc" "dup_handle" 2>/dev/null)
  assert_eq "find_page_by_handle: 2 matches returns DUPLICATE" "DUPLICATE" "$out"
}

test_find_page_by_handle_malformed_response() {
  setup_stub_curl
  printf '200\t-\tnot-json\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" find_page_by_handle "ds-abc" "vol_1_fixture" 2>&1) && rc=0 || rc=$?
  assert_eq "find_page_by_handle: malformed response exit 1" "1" "$rc"
  assert_contains "find_page_by_handle: malformed response sensible error message" \
    "unparseable response" "$out"
}

test_find_page_by_handle_one_match
test_find_page_by_handle_no_match
test_find_page_by_handle_duplicate
test_find_page_by_handle_malformed_response

# Proof that a malformed-JSON response inside find_page_by_handle's jq call
# doesn't trip set -e and kill this whole test script (the bug the jq guard
# above is protecting against): if it did, we would never reach this line.
echo "PASS: test script continued past the malformed jq response"

test_sync_readme_creates_when_missing() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1 fixture content" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n200\t-\t{"id":"new-page-1"}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" sync_readme \
    "$root/reconciliation_texts/vol_1_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture" "$root" "ds-abc" "BE" "abcdef1234567")
  assert_eq "sync_readme creates when no existing page" "CREATED" "$out"

  # Proves the metadata-stamp PATCH actually fired: the stub queues 3
  # responses (lookup, create, stamp) and only consumes one line per real
  # curl call, so if the stamp block were ever deleted this would see 2
  # calls, not 3, and fail.
  assert_eq "sync_readme create path: makes exactly 3 calls (lookup, create, stamp)" \
    "3" "$(curl_call_count)"

  local create_call stamp_call
  create_call=$(curl_call_block 2)
  stamp_call=$(curl_call_block 3)
  assert_contains "sync_readme create call: targets /v1/pages" "/v1/pages" "$create_call"
  assert_contains "sync_readme stamp call: targets PATCH /v1/pages/<id>" "PATCH" "$stamp_call"
  assert_contains "sync_readme stamp call: targets the new page id" "/v1/pages/new-page-1" "$stamp_call"
  assert_not_contains "sync_readme create body: never writes Package" "Package" "$create_call"
  assert_not_contains "sync_readme stamp body: never writes Package" "Package" "$stamp_call"
  assert_contains "sync_readme stamp body: Repo path matches template_dir" \
    "reconciliation_texts/vol_1_fixture" "$stamp_call"
  assert_contains "sync_readme stamp body: Source commit truncated to 7 chars" "abcdef1" "$stamp_call"
  assert_not_contains "sync_readme stamp body: Source commit not longer than 7 chars" "abcdef12" "$stamp_call"
}

test_sync_readme_updates_when_present() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1 fixture content" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  printf '200\t-\t{"results":[{"id":"page-existing"}]}\n200\t-\t{"id":"page-existing"}\n200\t-\t{"id":"page-existing"}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" sync_readme \
    "$root/reconciliation_texts/vol_1_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture" "$root" "ds-abc" "BE" "abcdef1234567")
  assert_eq "sync_readme updates when a page already exists" "UPDATED" "$out"

  assert_eq "sync_readme update path: makes exactly 3 calls (lookup, update, stamp)" \
    "3" "$(curl_call_count)"

  local stamp_call
  stamp_call=$(curl_call_block 3)
  assert_not_contains "sync_readme update-path stamp body: never writes Package" "Package" "$stamp_call"
  # Global Constraint says the script owns Name/Handle/Market on every page
  # it manages, with no update-time carve-out - so a name_en or Market
  # change must reach an already-existing page too, not just a newly
  # created one. Verifies Name/Market ride along on the same stamp PATCH
  # that already runs on the update path.
  assert_contains "sync_readme update-path stamp body: refreshes Name" \
    "Postponement of the general meeting" "$stamp_call"
  assert_contains "sync_readme update-path stamp body: refreshes Market" '"Market"' "$stamp_call"
  assert_contains "sync_readme update-path stamp body: Market value is BE" "BE" "$stamp_call"
}

test_sync_readme_skips_on_duplicate() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1 fixture content" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  printf '200\t-\t{"results":[{"id":"page-1"},{"id":"page-2"}]}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" sync_readme \
    "$root/reconciliation_texts/vol_1_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture" "$root" "ds-abc" "BE" "abcdef1234567" 2>/dev/null)
  assert_eq "sync_readme skips on duplicate Handle" "DUPLICATE" "$out"
}

test_sync_readme_reports_failed_without_crashing() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1 fixture content" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  printf '500\t-\t{"code":"error"}\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" sync_readme \
    "$root/reconciliation_texts/vol_1_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture" "$root" "ds-abc" "BE" "abcdef1234567" 2>/dev/null) && rc=0 || rc=$?
  assert_eq "sync_readme FAILED path: exits 0, doesn't crash the caller" "0" "$rc"
  assert_contains "sync_readme FAILED path: result line starts with FAILED:" "FAILED:" "$out"
}

test_sync_readme_create_response_missing_id() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1 fixture content" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  # The create response is syntactically valid JSON (unlike the malformed-
  # response case already covered for find_page_by_handle) but simply has
  # no .id - a plain `jq -r '.id'` would print the literal string "null"
  # and exit 0 here, letting a bogus page_id of "null" slip through to the
  # stamp PATCH (.../v1/pages/null) undetected. Guards against that.
  printf '200\t-\t{"results":[]}\n200\t-\t{"object":"page"}\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" sync_readme \
    "$root/reconciliation_texts/vol_1_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture" "$root" "ds-abc" "BE" "abcdef1234567" 2>/dev/null) && rc=0 || rc=$?
  assert_eq "sync_readme create response missing id: exits 0, doesn't crash" "0" "$rc"
  assert_contains "sync_readme create response missing id: reports FAILED" "FAILED:" "$out"
  assert_eq "sync_readme create response missing id: never reaches the stamp PATCH" \
    "2" "$(curl_call_count)"
}

test_sync_readme_creates_when_missing
test_sync_readme_updates_when_present
test_sync_readme_skips_on_duplicate
test_sync_readme_reports_failed_without_crashing
test_sync_readme_create_response_missing_id

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
