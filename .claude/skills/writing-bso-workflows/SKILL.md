---
name: writing-bso-workflows
description: Use when creating or editing a .github/workflows/*.yml file (or scripts/*.sh it calls) in bso_github_actions - distilled from repeated /review-pr findings, so the same mistakes don't get re-flagged on every new workflow.
---

# Writing bso_github_actions workflows

## Overview

This repo's `/review-pr` history (`.cursor/review-learnings/`) shows the same ~8 mistakes
getting introduced in new workflow files, then caught in review, over and over - often in a
file that gets the pattern right in one step and wrong in the next step of the *same* diff.
This skill is the checklist to apply BEFORE writing, so the reviewer doesn't have to.

**Also read `.cursor/review-learnings/_syntax.md` in full** - it holds the platform-mechanics
facts (GITHUB_OUTPUT limits, workflow_call boundaries, etc.) this skill builds on, kept there
instead of duplicated here. If you're editing a workflow that already has its own topic file
under `.cursor/review-learnings/` (check `INDEX.md`), read that file too - it has the specific
history for that exact file.

## The checklist

1. **Never splice `${{ }}` directly into a `run:` script body.** Always pass through `env:`
   and reference `$VAR`. This is the single most-repeated finding in this repo's history -
   check EVERY `${{ }}` in the step, not just the obvious one (a step can fix 4 of 5
   occurrences and miss the 5th, e.g. the right side of a comparison).
   ```yaml
   # Wrong: a filename/title with backticks or $(...) executes as shell code
   run: echo "Changed: ${{ steps.x.outputs.all_changed_files }}"
   # Right
   env:
     CHANGED: ${{ steps.x.outputs.all_changed_files }}
   run: echo "Changed: ${CHANGED}"
   ```

2. **Repo-tree/PR-derived names (handles, template dirs, filenames) need three guards:**
   - Split newline-separated, never space-separated (`mapfile -t`, not `arr=($(cmd))`) -
     account template names contain spaces.
   - Reject a name starting with `-` before passing it to a variadic CLI flag (`-h`/`-at`/
     `--handle`) - commander reads it as a flag, not a value. `run_sampler.yml`'s
     `reject_option_like_names` is the reference implementation.
   - Before embedding in a markdown PR comment: CommonMark-safe backtick fencing (one more
     backtick than the longest run in the name, space-pad if it starts/ends with a backtick) -
     NOT backslash-escaping (a backslash is literal inside a code span, doesn't escape
     anything). Inside a markdown *table cell*, also strip `|` (breaks the column structure) -
     `tr -d '\`|'` is simpler and acceptable there since exact fidelity doesn't matter as much
     as in a comment body.

3. **Know which of the two default shells you're getting - they are NOT the same.** An
   **unspecified** `run:` (no `shell:` key anywhere) runs as plain `bash -e {0}` - no
   `pipefail`. Only an **explicit** `shell: bash` gets `bash --noprofile --norc -eo pipefail
   {0}`. Verified directly against GitHub's own docs; every workflow this skill was written
   from has no explicit `shell:` on its steps, so treat `pipefail` as ABSENT unless you've
   confirmed otherwise for the specific step.
   - **With `-e` alone (the common case here):** `VAR=$(cmd | grep ...)` still aborts the step
     when `grep` finds no match (that part doesn't need pipefail - `grep`/`sort`/etc failing is
     what aborts, and the pipeline's own reported status is its LAST command's either way) -
     add `|| true` whenever zero-match is a valid outcome. Process substitution
     (`done < <(cmd)`) hides a failing command's exit status entirely regardless of pipefail -
     only use it for best-effort/warn-and-skip logic.
   - **The dangerous mistake this causes:** `RC=$?` right after `X=$(cmd1 | cmd2)` captures
     `cmd2`'s exit status, not `cmd1`'s, whenever pipefail is absent - a real bug shipped in
     this repo's own `run_sampler.yml` (`node ... | tr -d '\r'`, `RC=$?` silently reading
     `tr`'s always-zero status instead of the CLI's). If you need `cmd1`'s exit code and the
     step has no explicit `shell: bash`, capture it BEFORE piping - and note a bare
     `X=$(cmd1)` on its own line still aborts the step under plain `-e` the instant `cmd1`
     fails, before a following `RC=$?` ever runs, so wrap the capture so `-e` can't fire:
     ```bash
     set +e
     X=$(cmd1)
     RC=$?
     set -e
     X=$(tr ... <<< "$X")
     ```
     (a single capture can use `RC=0; X=$(cmd1) || RC=$?` instead of the `set +e`/`set -e`
     pair - reach for `set +e ... set -e` once more than one command in the block can fail).
     Don't rely on pipefail unless you've added `shell: bash` yourself.

4. **`$GITHUB_OUTPUT` multiline values need a `key<<DELIMITER` heredoc** - `echo "key=$val"`
   truncates at the first newline. If the value can contain arbitrary/untrusted content
   (template output, PR text), don't use a fixed delimiter string - generate one and verify
   it doesn't collide with the content first.

5. **Repository/organization `secrets.*` are snapshotted at queue time** (environment secrets
   are read when a job referencing that environment starts, not queue time - this repo doesn't
   use environments, so queue-time is what applies here). A job that `gh secret set`s a
   refreshed value does NOT change what a later job in the *same run* reads via
   `${{ secrets.X }}`. **Merge the writer and the consumer into one job** - this repo's actual
   fix for this exact problem (`push_to_review_firm.yml`'s refresh-then-push). Don't hand off a
   secret value via a job output or artifact instead: GitHub can redact/omit an output
   containing a recognized secret value, and artifacts are plaintext-persisted, readable by
   anyone with run access - neither is a safe substitute for same-job handling. Being in the
   same job isn't the whole fix either: `push_to_review_firm.yml`'s refresh action writes the
   refreshed value to `$HOME/.silverfin/config.json`, and the consumer step reads *that local
   file* - it never re-reads `${{ secrets.CONFIG_JSON }}`, which is still the queue-time
   snapshot even within the same job. The secret context itself doesn't update mid-run; only a
   local write-back does. `needs: some-refresher-job` does NOT imply your job reads the
   refreshed value either, even if that job runs first - `run_tests.yml`'s `test-templates`
   job `needs: check-auth` but is a genuinely separate job, and still loads
   `${{ secrets.CONFIG_JSON }}` (the queue-time snapshot) directly, not a same-run refresh.
   Whether that's actually safe depends on whether the consumer can tolerate a secret that's
   at most as stale as the queue-time snapshot (e.g. an access token still well inside its
   normal validity window) - know which case you're in before assuming `needs:` bought you
   freshness.

6. **`tj-actions/changed-files` needs `safe_output: false` and `quotepath: false`** when
   piping its output through `jq`. The default `safe_output: true` backslash-escapes shell
   metacharacters *inside* the JSON string values (`\&`, `\(`, `\)` are invalid JSON, jq
   aborts). Git's default `core.quotepath` double-quotes and octal-escapes non-ASCII paths
   (e.g. a curly apostrophe) - `quotepath: false` on the action's own input is the fix; a
   global git-config attempt does not override the action's default.

7. **CLI install stays unpinned (`npm install https://github.com/silverfin/silverfin-cli.git`)
   by default** - unpinned-from-`main` is the deliberate, repo-wide convention; don't "fix" it
   on an unrelated PR. Pin to an exact commit only for a specific, time-boxed reason, always
   with a comment saying when to revert:
   - **This workflow needs a flag not yet on `main`** - revert once that CLI PR merges.
   - **A currently-open, unmerged CLI PR touches credential-handling code this workflow relies
     on**, so an ordinary `@main` merge elsewhere could change how secrets are handled here
     with zero visible diff in *this* repo. `push_to_review_firm.yml` pins for this reason
     (against open silverfin-cli#273), reverting once it merges. This is NOT "every
     secret-writing workflow must always pin" - `check_auth.yml` also writes a secret
     (`CONFIG_JSON`) and stays deliberately unpinned, because at the time of writing there's
     no open CLI PR whose unmerged state it needs shielding from. Pin against a specific named
     risk, not against the general category of "handles credentials."
   - **This file's design is itself mid-migration** (e.g. the CI-auth pilot currently piloted
     in `be_market` is expected to become the standard auth flow repo-wide) - treat any
     specific-file example in this skill about auth/credential workflows as time-bound. Verify
     against the current file rather than assuming `check_auth.yml`'s shape described here
     still matches once that migration lands.

8. **A new reusable workflow needs a README.md entry** (Individual Action Documentation
   section) - repo convention since #24, and README drift on this file is treated as a real
   regression here, not a nit.

9. **A market repo consumes this repo's workflows one of three ways - know which before
   assuming a merge here reaches it:**
   - **`uses: .../X.yml@main`** - the default. Confirmed across all 4 market repos (be/nl/lu/uk)
     for every wrapper except the two cases below. **A merge to `main` reaches this caller on
     its very next run** - no gradual rollout, no opt-out short of the caller pinning itself.
   - **`uses: .../X.yml@<sha>`** - pinned. Only be_market's `check_auth.yml`/
     `refresh-config-json`, deliberately isolating the CI-auth pilot (see silverfin-cli's
     `CI_AUTH_SAMPLER_PLAN.md`). A merge here does NOT reach that caller until its pin is
     bumped.
   - **Fully forked/inlined - no `uses:` reference at all.** be_market's own `run_tests.yml` is
     a complete local reimplementation, not a call to this repo's `run_tests.yml`. A merge here
     never reaches it automatically, under any circumstances - only a human manually re-syncing
     the fork does. Check for an actual `uses: silverfin/bso_github_actions` line before
     assuming a market repo's same-named file tracks this one.

   Design changes to an *existing* `uses:`-consumed workflow to be backward-compatible for
   `@main` callers, or coordinate the merge explicitly; this is why this repo's own merge
   policy restricts changes to "non-breaking for the non-pilot markets."

## Common mistakes (from review history, don't re-litigate)

| Symptom | Cause | Fix |
|---|---|---|
| CI green but a template was silently skipped | `jq` failure inside `<( )` process substitution swallowed by `set -e` | Capture via `x=$(jq ...)`, check exit status explicitly |
| Job fails on an empty match, not a real failure | `VAR=$(cmd \| grep pattern)` with no match | Append `\|\| true` to the assignment |
| Later job doesn't see a secret another job just wrote | `secrets.*` queue-time snapshot | Merge writer and consumer into one job |
| `actionlint` flags `concurrency.queue: max` as an unknown key | actionlint's schema predates this real GitHub Actions beta feature | Known false positive - don't "fix" it, don't downgrade to `queue: single`. `queue: max` and `cancel-in-progress: true` are mutually exclusive - don't add the latter alongside it |
| PR comment markdown breaks on one specific template | Raw backtick/pipe interpolated into a code span or table cell | CommonMark fencing, or `tr -d` in table cells |
| A workflow_call output looks empty even though the step set it | Caller didn't use `if: always()` to read it after a later step failed | Add `if: always()` on the consuming step |

## Also worth knowing

- `permissions: contents: write` is usually unnecessary - checkout needs `read`, and
  `gh secret set` authenticates via `GH_TOKEN`/`GITHUB_TOKEN` (`gh`'s recognized env vars) -
  map `secrets.REPO_ACCESS_TOKEN` to `GH_TOKEN` in the step's `env:`, not the implicit token.
- A local `uses: ./.github/actions/...` only resolves when the reusable workflow runs in its
  own repo's checkout - a reusable workflow called from a different repo runs in the caller's
  checkout, so a local relative path there needs a fully-qualified `owner/repo/path@ref`.
- Squash-merges don't produce a SHA match on `git log origin/main..branch` - `git fetch` +
  content-diff before trusting a commit list, and remember a self-referencing pin needs its
  own bump after a squash-merge.
