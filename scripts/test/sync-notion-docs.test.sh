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
  # Single-quoted so the expansion is deferred to when the trap fires, not
  # frozen into the trap text at set time (SC2064) - and it now also cleans up
  # the .exit sidecar written below, which the double-quoted version leaked.
  # Self-clearing (`trap - RETURN` first): a RETURN trap set inside a function
  # stays armed afterwards and would otherwise fire a second time when the
  # *calling* test function returns, at which point $tempfile is out of scope
  # and, under set -u, an unbound-variable abort. The old double-quoted form
  # hid that: it had the path baked in, so the stray second fire was a silent
  # no-op rm of an already-deleted file.
  trap 'trap - RETURN; rm -f "$tempfile" "$tempfile.exit"' RETURN

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
  export STUB_SLEEP_LOG="$SCRIPT_DIR/fixtures/notion-sync/sleep.log"
  : > "$STUB_CURL_LOG"
  : > "$STUB_SLEEP_LOG"
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
# multiple lines if its body is pretty-printed JSON), or nothing if there
# is no such call.
curl_call_block() {
  local n="$1"
  local starts start_line next_start
  # grep exits 1 on zero matches (e.g. a test expecting fewer calls than
  # were actually made) - guarded so that case degrades to an empty
  # $starts and a normal `assert_*` FAIL line, not a raw abort now that
  # inherit_errexit is active in this sourcing test file too.
  starts=$(grep -n -- '^-sS -w' "$STUB_CURL_LOG" | cut -d: -f1) || true
  start_line=$(echo "$starts" | sed -n "${n}p")
  if [[ -z "$start_line" ]]; then
    return 0
  fi
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
  local out
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc")
  assert_eq "notion_request success body" '{"ok":true}' "$out"
  assert_eq "notion_request success: exactly 1 call" "1" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
  assert_contains "notion_request success: sends Authorization header" \
    "Authorization: Bearer fake-token" "$(cat "$STUB_CURL_LOG")"
  assert_contains "notion_request success: sends Notion-Version header" \
    "Notion-Version: 2026-03-11" "$(cat "$STUB_CURL_LOG")"
  assert_contains "notion_request success: sets a connect timeout" \
    "--connect-timeout 10" "$(cat "$STUB_CURL_LOG")"
  assert_contains "notion_request success: sets a max transfer time" \
    "--max-time 120" "$(cat "$STUB_CURL_LOG")"
}

test_notion_request_retries_on_429() {
  setup_stub_curl
  printf '429\t-\t{"code":"rate_limited"}\n200\t-\t{"ok":true}\n' > "$STUB_CURL_RESPONSES"
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
    printf '429\t-\t{"code":"rate_limited"}\n' >> "$STUB_CURL_RESPONSES"
  done
  local out rc
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc" 2>&1) && rc=0 || rc=$?

  assert_eq "notion_request exhausted: exit 1" "1" "$rc"
  assert_contains "notion_request exhausted: sensible error message" \
    "failed after $NOTION_MAX_ATTEMPTS attempts" "$out"
  assert_eq "notion_request exhausted: exactly $NOTION_MAX_ATTEMPTS calls, not $((NOTION_MAX_ATTEMPTS + 1))" \
    "$NOTION_MAX_ATTEMPTS" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"

  # Regression guard for the wasted-final-sleep fix, against the exact
  # recorded backoff sequence rather than inferring it from wall-clock
  # elapsed time: with the bug, the loop sleeps out a backoff even on the
  # last, already-doomed attempt (1 2 4 8 16 32); fixed, the pointless final
  # 32s sleep never happens (1 2 4 8 16). The stubbed `sleep` (same
  # directory as the stubbed `curl`, already on PATH via setup_stub_curl)
  # makes this instant and exact instead of a ~31s real-time assertion.
  assert_eq "notion_request exhausted: skips the pointless final backoff sleep" \
    "1
2
4
8
16" "$(cat "$STUB_SLEEP_LOG")"
}

test_notion_request_honors_retry_after() {
  setup_stub_curl
  printf '429\t3\t{"code":"rate_limited"}\n200\t-\t{"ok":true}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc" 2>&1)
  assert_contains "notion_request retries then succeeds (with Retry-After)" '{"ok":true}' "$out"
  assert_eq "notion_request Retry-After: exactly 2 calls" "2" "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')"
  assert_contains "notion_request Retry-After: logs that it's honoring the header" \
    "honoring Retry-After: 3s" "$out"
  # The header value (3), not the fixed schedule's first backoff (1) -
  # proves the header is actually driving the sleep, not just being logged.
  assert_eq "notion_request Retry-After: sleeps the header's value, not the fixed schedule" \
    "3" "$(cat "$STUB_SLEEP_LOG")"
}

test_notion_request_ignores_invalid_retry_after() {
  setup_stub_curl
  # "soon" is not a plain non-negative integer (nor is a HTTP-date, which
  # this script also doesn't parse) - falls back to the fixed schedule
  # exactly like "-" (absent) does, rather than guessing or crashing.
  printf '429\tsoon\t{"code":"rate_limited"}\n200\t-\t{"ok":true}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc" 2>&1)
  assert_contains "notion_request invalid Retry-After: retries then succeeds" '{"ok":true}' "$out"
  assert_contains "notion_request invalid Retry-After: falls back to fixed backoff" \
    "backing off 1s" "$out"
  assert_eq "notion_request invalid Retry-After: sleeps the fixed schedule's value" \
    "1" "$(cat "$STUB_SLEEP_LOG")"
}

test_notion_request_caps_excessive_retry_after() {
  setup_stub_curl
  # A value beyond NOTION_RETRY_AFTER_MAX_SECONDS (120) is not "trust the
  # header a little less" - it's rejected outright and treated exactly like
  # an absent/invalid header, falling back to the fixed schedule. Guards
  # against a malformed proxy response or a compromised intermediary
  # stalling this loop (and the whole post-merge job) far longer than the
  # bounded ~31s the fixed schedule would ever take.
  # 121 passes the four-digit format check but exceeds
  # NOTION_RETRY_AFTER_MAX_SECONDS (120), so the numeric cap is what rejects
  # it — not the regex alone (99999 would fail the format check first).
  printf '429\t121\t{"code":"rate_limited"}\n200\t-\t{"ok":true}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" notion_request GET "/v1/pages/abc" 2>&1)
  assert_contains "notion_request excessive Retry-After: retries then succeeds" '{"ok":true}' "$out"
  assert_contains "notion_request excessive Retry-After: falls back to fixed backoff" \
    "backing off 1s" "$out"
  assert_eq "notion_request excessive Retry-After: sleeps the fixed schedule's value, not 121" \
    "1" "$(cat "$STUB_SLEEP_LOG")"
}

test_notion_request_succeeds_first_try
test_notion_request_retries_on_429
test_notion_request_fails_on_non_retryable_error
test_notion_request_curl_hard_failure
test_notion_request_fails_after_max_attempts
test_notion_request_honors_retry_after
test_notion_request_ignores_invalid_retry_after
test_notion_request_caps_excessive_retry_after

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

test_find_page_by_handle_missing_results_field() {
  setup_stub_curl
  # Valid JSON, 2xx, but missing `.results` entirely - the kind of
  # malformed-but-parseable response `.results | length` alone would
  # silently treat as "0 matches" (jq's `length` on a missing/null field is
  # 0, not an error), letting sync_readme create a duplicate page instead of
  # failing loudly. Must be caught as a real error, same as unparseable JSON.
  printf '200\t-\t{"object":"list"}\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" find_page_by_handle "ds-abc" "vol_1_fixture" 2>&1) && rc=0 || rc=$?
  assert_eq "find_page_by_handle: missing .results field exit 1" "1" "$rc"
  assert_contains "find_page_by_handle: missing .results field sensible error message" \
    "unparseable response" "$out"
}

test_find_page_by_handle_null_results_field() {
  setup_stub_curl
  printf '200\t-\t{"results":null}\n' > "$STUB_CURL_RESPONSES"
  local out rc
  out=$(NOTION_TOKEN="fake-token" find_page_by_handle "ds-abc" "vol_1_fixture" 2>&1) && rc=0 || rc=$?
  assert_eq "find_page_by_handle: null .results field exit 1" "1" "$rc"
  assert_contains "find_page_by_handle: null .results field sensible error message" \
    "unparseable response" "$out"
}

test_find_page_by_handle_one_match
test_find_page_by_handle_no_match
test_find_page_by_handle_duplicate
test_find_page_by_handle_malformed_response
test_find_page_by_handle_missing_results_field
test_find_page_by_handle_null_results_field

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

test_sync_readme_stamp_failure_names_result_and_page() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1 fixture content" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  # lookup: no existing page (CREATE path) -> create succeeds -> stamp fails.
  # A plain "FAILED: metadata stamp failed" here would drop this page from
  # created_handles with no trace that a page WAS created and now sits
  # unstamped - the result ($result) and the page id must ride along in the
  # message so a human reading the job log/Slack alert can find it.
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n500\t-\t{"code":"error"}\n' > "$STUB_CURL_RESPONSES"
  local out
  out=$(NOTION_TOKEN="fake-token" sync_readme \
    "$root/reconciliation_texts/vol_1_fixture/README.md" \
    "reconciliation_texts/vol_1_fixture" "$root" "ds-abc" "BE" "abcdef1234567")
  assert_contains "sync_readme stamp failure: still reports FAILED" "FAILED:" "$out"
  assert_contains "sync_readme stamp failure: names the already-known result (CREATED)" "CREATED" "$out"
  assert_contains "sync_readme stamp failure: names the orphaned page id" "new-page-1" "$out"
}

test_sync_readme_creates_when_missing
test_sync_readme_updates_when_present
test_sync_readme_skips_on_duplicate
test_sync_readme_reports_failed_without_crashing
test_sync_readme_create_response_missing_id
test_sync_readme_stamp_failure_names_result_and_page

test_cli_reports_failed_handles_via_github_output() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  # one success (create), one duplicate
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n200\t-\t{"id":"new-page-1"}\n200\t-\t{"results":[{"id":"p1"},{"id":"p2"}]}\n' > "$STUB_CURL_RESPONSES"

  local changed_file github_output
  changed_file="$SCRIPT_DIR/fixtures/notion-sync/changed-readmes.txt"
  printf '%s\n' \
    "reconciliation_texts/vol_1_fixture/README.md" \
    "account_templates/AT_fixture/README.md" > "$changed_file"
  echo "# AT" > "$root/account_templates/AT_fixture/README.md"

  github_output="$SCRIPT_DIR/fixtures/notion-sync/github_output.txt"
  : > "$github_output"

  local test_config="$SCRIPT_DIR/fixtures/notion-sync/notion-config.json"
  cat > "$test_config" << 'JSON'
{"BE": {"reconciliation_texts": "ds-rt", "account_templates": "ds-at"}}
JSON

  NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" > /dev/null 2>&1

  if grep -q "^failed_handles=.*AT_fixture" "$github_output"; then
    echo "PASS: CLI reports the duplicate handle in GITHUB_OUTPUT"
  else
    echo "FAIL: CLI should have reported AT_fixture as failed, got:"
    cat "$github_output"
    failures=$((failures + 1))
  fi

  # The brief's one given test only exercises CREATED and DUPLICATE - also
  # cover created_handles itself, and that a DUPLICATE handle never leaks
  # into created_handles.
  assert_contains "CLI reports the created handle in GITHUB_OUTPUT" \
    "created_handles=vol_1_fixture" "$(cat "$github_output")"
  assert_not_contains "CLI never reports the duplicate handle as created" \
    "AT_fixture" "$(grep '^created_handles=' "$github_output" || true)"
}

test_cli_classifies_updated_and_failed_results() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  echo "# AT" > "$root/account_templates/AT_fixture/README.md"
  # vol_1_fixture: lookup finds an existing page -> UPDATED (3 calls: lookup,
  # update, stamp). AT_fixture: lookup itself errors -> FAILED:* (1 call).
  printf '200\t-\t{"results":[{"id":"page-existing"}]}\n200\t-\t{"id":"page-existing"}\n200\t-\t{"id":"page-existing"}\n500\t-\t{"code":"error"}\n' > "$STUB_CURL_RESPONSES"

  local changed_file github_output test_config
  changed_file="$SCRIPT_DIR/fixtures/notion-sync/changed-readmes.txt"
  printf '%s\n' \
    "reconciliation_texts/vol_1_fixture/README.md" \
    "account_templates/AT_fixture/README.md" > "$changed_file"

  github_output="$SCRIPT_DIR/fixtures/notion-sync/github_output.txt"
  : > "$github_output"

  test_config="$SCRIPT_DIR/fixtures/notion-sync/notion-config.json"
  cat > "$test_config" << 'JSON'
{"BE": {"reconciliation_texts": "ds-rt", "account_templates": "ds-at"}}
JSON

  NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" > /dev/null 2>&1

  assert_not_contains "CLI: an UPDATED handle is not reported as failed" \
    "vol_1_fixture" "$(grep '^failed_handles=' "$github_output" || true)"
  assert_not_contains "CLI: an UPDATED handle is not reported as created" \
    "vol_1_fixture" "$(grep '^created_handles=' "$github_output" || true)"
  assert_contains "CLI: a FAILED:* result is reported as failed" \
    "AT_fixture" "$(grep '^failed_handles=' "$github_output" || true)"
}

test_cli_stamp_failure_reports_both_failed_and_created() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  echo "# Vol 1" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  # lookup: no existing page -> create succeeds -> stamp fails.
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n500\t-\t{"code":"error"}\n' > "$STUB_CURL_RESPONSES"

  local changed_file github_output test_config
  changed_file="$SCRIPT_DIR/fixtures/notion-sync/changed-readmes.txt"
  printf '%s\n' "reconciliation_texts/vol_1_fixture/README.md" > "$changed_file"

  github_output="$SCRIPT_DIR/fixtures/notion-sync/github_output.txt"
  : > "$github_output"

  test_config="$SCRIPT_DIR/fixtures/notion-sync/notion-config.json"
  cat > "$test_config" << 'JSON'
{"BE": {"reconciliation_texts": "ds-rt", "account_templates": "ds-at"}}
JSON

  NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" > /dev/null 2>&1

  assert_contains "CLI stamp failure after CREATED: reports failed handle" \
    "failed_handles=vol_1_fixture" "$(cat "$github_output")"
  assert_contains "CLI stamp failure after CREATED: also reports created handle" \
    "created_handles=vol_1_fixture" "$(cat "$github_output")"
}

test_cli_reports_resolved_handle_not_dir_basename() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  # config.json's .handle can differ from the directory name for
  # reconciliation_texts - reporting the directory basename here would
  # undermine the created-page alert's own "check for a handle mismatch in
  # config.json" guidance, since a real mismatch is exactly what the
  # basename would hide instead of reveal.
  mkdir -p "$root/reconciliation_texts/dir_name_fixture"
  echo '{"handle": "actual_handle_value"}' > "$root/reconciliation_texts/dir_name_fixture/config.json"
  echo "# Mismatched dir name" > "$root/reconciliation_texts/dir_name_fixture/README.md"
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n200\t-\t{"id":"new-page-1"}\n' > "$STUB_CURL_RESPONSES"

  local changed_file github_output test_config
  changed_file="$SCRIPT_DIR/fixtures/notion-sync/changed-readmes.txt"
  printf '%s\n' "reconciliation_texts/dir_name_fixture/README.md" > "$changed_file"

  github_output="$SCRIPT_DIR/fixtures/notion-sync/github_output.txt"
  : > "$github_output"

  test_config="$SCRIPT_DIR/fixtures/notion-sync/notion-config.json"
  cat > "$test_config" << 'JSON'
{"BE": {"reconciliation_texts": "ds-rt", "account_templates": "ds-at"}}
JSON

  NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" > /dev/null 2>&1

  assert_contains "CLI reports the resolved .handle, not the directory name" \
    "created_handles=actual_handle_value" "$(cat "$github_output")"
  assert_not_contains "CLI does not report the directory basename instead" \
    "dir_name_fixture" "$(cat "$github_output")"
}

# --- CLI exit-0 safety contract -------------------------------------------
# main() is a post-merge job with nothing left to block: it must always exit 0
# and report problems through stderr/$GITHUB_OUTPUT, never by failing the job.
# Each of the four tests below covers a hole where it previously did fail hard
# (or, for the unconfigured market, "succeeded" while doing the wrong thing).

# Writes the standard single-market config used by the tests below and echoes
# its path. $1 = the market key to write (default BE).
write_cli_test_config() {
  local market="${1:-BE}"
  local test_config="$SCRIPT_DIR/fixtures/notion-sync/notion-config.json"
  jq -n --arg m "$market" \
    '{($m): {reconciliation_texts: "ds-rt", account_templates: "ds-at"}}' > "$test_config"
  printf '%s' "$test_config"
}

test_cli_missing_changed_readmes_file() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  local test_config github_output missing_list out rc
  test_config=$(write_cli_test_config BE)
  github_output="$root/github_output.txt"
  : > "$github_output"
  missing_list="$root/no-such-changed-readmes.txt"
  rm -f "$missing_list"

  out=$(NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" \
    "$missing_list" "$root" "BE" "abcdef1234567" "$test_config" 2>&1) && rc=0 || rc=$?

  assert_eq "CLI with a missing changed-readmes list: still exits 0" "0" "$rc"
  assert_contains "CLI with a missing changed-readmes list: names the missing file" \
    "no-such-changed-readmes.txt" "$out"
  assert_contains "CLI with a missing changed-readmes list: clear stderr message" \
    "does not exist or is not readable" "$out"
  assert_eq "CLI with a missing changed-readmes list: makes no curl calls" \
    "0" "$(curl_call_count)"
  assert_contains "CLI with a missing changed-readmes list: alerts via GITHUB_OUTPUT" \
    "failed_handles=config-error:missing-list" "$(cat "$github_output")"
}

test_cli_malformed_config() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  local test_config="$root/notion-config.json"
  echo '{ this is not json' > "$test_config"

  local changed_file github_output out rc
  changed_file="$root/changed-readmes.txt"
  printf '%s\n' "reconciliation_texts/vol_1_fixture/README.md" > "$changed_file"
  echo "# Vol 1" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  github_output="$root/github_output.txt"
  : > "$github_output"

  out=$(NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" \
    "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" 2>&1) && rc=0 || rc=$?

  assert_eq "CLI with a malformed notion-config.json: still exits 0" "0" "$rc"
  assert_contains "CLI with a malformed notion-config.json: clear stderr message" \
    "could not read" "$out"
  assert_eq "CLI with a malformed notion-config.json: makes no curl calls" \
    "0" "$(curl_call_count)"
  assert_contains "CLI with a malformed notion-config.json: alerts via GITHUB_OUTPUT" \
    "failed_handles=config-error:config-read:BE" "$(cat "$github_output")"
}

# A market key that is simply absent is NOT a jq error - `jq -r` prints the
# literal string "null" and exits 0. Without the explicit guard, that "null"
# was used as a data source id and the run made three real, authenticated
# Notion calls per changed template before "succeeding".
test_cli_market_not_in_config() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  local test_config
  test_config=$(write_cli_test_config BE)
  # Enough queued responses that an unguarded run would happily complete a
  # full create+stamp cycle against the bogus "null" data source.
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n200\t-\t{"id":"new-page-1"}\n' > "$STUB_CURL_RESPONSES"

  local changed_file github_output out rc
  changed_file="$root/changed-readmes.txt"
  printf '%s\n' "reconciliation_texts/vol_1_fixture/README.md" > "$changed_file"
  echo "# Vol 1" > "$root/reconciliation_texts/vol_1_fixture/README.md"
  github_output="$root/github_output.txt"
  : > "$github_output"

  out=$(NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" \
    "$changed_file" "$root" "NL" "abcdef1234567" "$test_config" 2>&1) && rc=0 || rc=$?

  assert_eq "CLI with an unconfigured market: still exits 0" "0" "$rc"
  assert_contains "CLI with an unconfigured market: names the market and the config" \
    "market 'NL' has no entry in $test_config" "$out"
  assert_eq "CLI with an unconfigured market: makes no curl calls at all" \
    "0" "$(curl_call_count)"
  assert_contains "CLI with an unconfigured market: alerts via GITHUB_OUTPUT" \
    "failed_handles=config-error:unconfigured:NL" "$(cat "$github_output")"
  assert_not_contains "CLI with an unconfigured market: never blames the template" \
    "vol_1_fixture:" "$out"
}

# The $GITHUB_OUTPUT appends run AFTER every sync has already happened, so an
# unwritable path must not abort the run - that would both fail the job and
# discard the outputs the Slack steps depend on.
test_cli_unwritable_github_output() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  local test_config
  test_config=$(write_cli_test_config BE)
  # One clean create: lookup (no match), create, metadata stamp.
  printf '200\t-\t{"results":[]}\n200\t-\t{"id":"new-page-1"}\n200\t-\t{"id":"new-page-1"}\n' > "$STUB_CURL_RESPONSES"

  local changed_file out rc
  changed_file="$root/changed-readmes.txt"
  printf '%s\n' "reconciliation_texts/vol_1_fixture/README.md" > "$changed_file"
  echo "# Vol 1" > "$root/reconciliation_texts/vol_1_fixture/README.md"

  # A directory can never be appended to, which is the simplest portable way
  # to make the `>>` redirection fail (running as root makes a chmod 000 file
  # writable again, so this shape is more reliable in CI too).
  local github_output_dir="$root/github_output_dir"
  rm -rf "$github_output_dir"
  mkdir -p "$github_output_dir"

  out=$(NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output_dir" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" \
    "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" 2>&1) && rc=0 || rc=$?

  assert_eq "CLI with an unwritable GITHUB_OUTPUT: still exits 0" "0" "$rc"
  assert_contains "CLI with an unwritable GITHUB_OUTPUT: warns instead of aborting" \
    "WARN: could not write created_handles" "$out"
  assert_contains "CLI with an unwritable GITHUB_OUTPUT: the sync work itself still ran" \
    "reconciliation_texts/vol_1_fixture: CREATED" "$out"
  assert_eq "CLI with an unwritable GITHUB_OUTPUT: all 3 calls were made before the failed append" \
    "3" "$(curl_call_count)"
  rm -rf "$github_output_dir"
}

# Account template "handles" are directory basenames, which contain spaces -
# joining them on a plain space produced one unparseable run-together string
# in $GITHUB_OUTPUT and in the Slack message built from it.
test_cli_joins_multiple_handles_readably() {
  setup_stub_curl
  setup_resolve_fixture
  local root="$SCRIPT_DIR/fixtures/notion-sync"
  local test_config
  test_config=$(write_cli_test_config BE)

  mkdir -p "$root/account_templates/Dubieuze debiteuren"
  echo '{"id": {"542": 123}}' > "$root/account_templates/Dubieuze debiteuren/config.json"
  echo "# AT one" > "$root/account_templates/Dubieuze debiteuren/README.md"
  mkdir -p "$root/account_templates/Te ontvangen facturen"
  echo '{"id": {"542": 124}}' > "$root/account_templates/Te ontvangen facturen/config.json"
  echo "# AT two" > "$root/account_templates/Te ontvangen facturen/README.md"

  # Both templates are duplicates -> both land in failed_handles.
  printf '200\t-\t{"results":[{"id":"p1"},{"id":"p2"}]}\n200\t-\t{"results":[{"id":"p3"},{"id":"p4"}]}\n' \
    > "$STUB_CURL_RESPONSES"

  local changed_file github_output
  changed_file="$root/changed-readmes.txt"
  printf '%s\n' \
    "account_templates/Dubieuze debiteuren/README.md" \
    "account_templates/Te ontvangen facturen/README.md" > "$changed_file"
  github_output="$root/github_output.txt"
  : > "$github_output"

  NOTION_TOKEN="fake-token" GITHUB_OUTPUT="$github_output" \
    bash "$SCRIPT_DIR/../sync-notion-docs.sh" \
    "$changed_file" "$root" "BE" "abcdef1234567" "$test_config" > /dev/null 2>&1

  assert_eq "CLI joins multiple space-containing handles with a visible separator" \
    "failed_handles=Dubieuze debiteuren, Te ontvangen facturen" "$(cat "$github_output")"
  rm -rf "$root/account_templates/Dubieuze debiteuren" \
    "$root/account_templates/Te ontvangen facturen"
}

test_cli_reports_failed_handles_via_github_output
test_cli_classifies_updated_and_failed_results
test_cli_stamp_failure_reports_both_failed_and_created
test_cli_reports_resolved_handle_not_dir_basename
test_cli_missing_changed_readmes_file
test_cli_malformed_config
test_cli_market_not_in_config
test_cli_unwritable_github_output
test_cli_joins_multiple_handles_readably

if [[ $failures -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
