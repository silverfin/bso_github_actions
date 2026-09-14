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
