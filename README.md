# Example Repository

If you are developing liquid templates for Silverfin, thhis is an example repository that can be cloned to use as a starting point.

The following tools assume that you use the structure detailed by this repository:

- [silverfin-cli](https://github.com/silverfin/silverfin-cli)
- [silverfin-vscode](https://github.com/silverfin/silverfin-vscode)

## Project structure

```bash
/project
    /reconciliation_texts
        /[handle]
            main.liquid
            config.json
            /text_parts
                part_1.liquid
                part_2.liquid
            /tests
                README.md
                [handle]_liquid_test.yml
    /shared_parts
        /[name]
            [name].liquid
            config.json
```

# Github Actions documentation

The document will go over all the Github Actions that currently automate a couple of tasks in the Silverfin development workflow. All the actions are designed to be reused across multiple market repositories. 


## Table of Contents

* [Overview](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfa4cff673955d42e9a609fab12)
* [Individual Action Documentation](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf5d38766349a742b78f139ee4d)
  * [Label management](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfda115c3c17e34b4c833cb4b0a)
    * [Add Code Review Label (add_code_review_label.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfce44f57a01564acd95f8c0c98)
    * [Remove Code Review Label (remove_code_review_label.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf2828559422d84087b81255dc8)
  * [Authentication](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf4f743db4b6854130af8693671)
    * [Repair a firm's CI auth token pair (repair_firm_auth.yml)](#repair-a-firms-ci-auth-token-pair-repair_firm_authyml)
  * [Testing](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf13d6dbd0df1e4450b3b22691c)
    * [Check YAML files (check_tests.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf931fa1547b4b419d940464f89)
    * [Run liquid tests, inline auth (run_tests_inline_auth.yml)](#run-liquid-tests-inline-auth-run_tests_inline_authyml)
  * [Slack updates](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfc9ca89d4b174494391ba075c5)
    * [Automated slack update (slack_changelog.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf862cf4257e68475d8b47891c6)
  * [Review firm deployment](#review-firm-deployment)
    * [Push templates to review firm (push_to_review_firm.yml)](#push-templates-to-review-firm-push_to_review_firmyml)
  * [Liquid sampler](#liquid-sampler)
    * [Run liquid sampler (run_sampler.yml)](#run-liquid-sampler-run_sampleryml)
    * [Authorizing a partner for staging (scripts/authorize-partner-secret.sh)](#authorizing-a-partner-for-staging-scriptsauthorize-partner-secretsh)


## Overview

All Github Actions are designed to be reused across multiple market repositories. As a result, they are stored in a specific repository in Github: [BSO Github Actions](https://github.com/silverfin/bso_github_actions). If an action needs to be added to a specific repository, these generic actions/workflows can be linked. 

Currently, there are three groups of actions available:

* Label management: Add/remove code review labels automatically
* Authentication: Check and refresh Silverfin API tokens
* Testing: Validate YAML files and run liquid tests



## Individual Action Documentation

### Label management

#### Add Code Review Label  `(add_code_review_label.yml)`

_Description_:
The workflow will automatically add a `code-review` label to pull requests when a review is requested. 

_Trigger_: 

* A reviewer is assigned/requested on any PR
* A draft PR is converted to "Ready for review"

#### Remove Code Review Label  `(remove_code_review_label.yml)`

_Description_: 
Automatically removes the "code-review" label from pull requests when review comments are provided. It will only execute if the review contains actual comments and the commenter is NOT CodeRabbit.

_Trigger_:

* A complete PR review (any type: approve, request changes, comment) is submitted
* An individual line comment has been submitted during the review



### Authentication

#### Repair a firm's CI auth token pair `(repair_firm_auth.yml)`

_Description_:
Repairs one firm's dead token pair in `CONFIG_JSON` by doing the OAuth `authorization_code` exchange
in CI, so no live token pair lands on a laptop. Only that firm's `accessToken`/`refreshToken` change;
every other field and firm is carried through. Refuses a firm that isn't already in `CONFIG_JSON`.

_Inputs:_

* `firm_id` (string, required) - the firm to repair.
* `auth_code` (string, required) - the one-time code from the firm's OAuth authorize screen, opened
  while logged into Silverfin as the "Github Actions" user (URL in the workflow's header comment).
  Masked line by line; still recorded in the run's dispatch inputs, so discard it after a refusal.
* `writer_workflows` (string, required) - whitespace-separated filenames of every workflow in the
  calling repo that writes `CONFIG_JSON`. The caller's own file is added automatically.

_Trigger_: `workflow_dispatch` in the caller, run by hand, one firm at a time.

_Steps:_

* Refuses a re-run (the code is single-use) and refuses while any listed writer is in flight or
  finished after this run was queued (its snapshot of `CONFIG_JSON` would revert that write)
* Exchanges the code for a token pair and writes the updated `CONFIG_JSON` back, retrying transient
  `gh secret set` failures

_Prerequisites_:

* `SF_API_CLIENT_ID`, `SF_API_SECRET`, `CONFIG_JSON`, `REPO_ACCESS_TOKEN`, declared under
  `workflow_call.secrets` - pass exactly these, not `secrets: inherit`

_Example caller:_

```yaml
name: Manually repair a firm's CI auth token pair
run-name: Repair CI auth for firm ${{ inputs.firm_id }}
on:
  workflow_dispatch:
    inputs:
      firm_id:
        description: "Firm ID to repair. Must already be a key in CONFIG_JSON."
        required: true
        type: string
      auth_code:
        description: "One-time authorization code from that firm's OAuth authorize screen."
        required: true
        type: string

permissions: {}

jobs:
  repair-firm-auth:
    permissions: {}
    uses: silverfin/bso_github_actions/.github/workflows/repair_firm_auth.yml@main
    with:
      firm_id: ${{ inputs.firm_id }}
      auth_code: ${{ inputs.auth_code }}
      writer_workflows: run_tests.yml
    secrets:
      SF_API_CLIENT_ID: ${{ secrets.SF_API_CLIENT_ID }}
      SF_API_SECRET: ${{ secrets.SF_API_SECRET }}
      CONFIG_JSON: ${{ secrets.CONFIG_JSON }}
      REPO_ACCESS_TOKEN: ${{ secrets.REPO_ACCESS_TOKEN }}
```

### Testing

#### Check YAML files `(check_tests.yml)`

_Description:_
Validates that at least 1 `.yaml/.yml` file has been added or updated when changes are made to templates. This can be by-passed by adding the `no-test-required` to the pull request. 

_Trigger:_

* Every time new commits are pushed to a PR
* When labels are added (important for the `no-test-required` bypass logic)
* When labels are removed (re-enables validation if `no-test-required` was removed)

#### Run liquid tests, inline auth `(run_tests_inline_auth.yml)`

_Description:_
Runs the liquid tests of the reconciliation texts and account templates a PR changes (a PR that only
changes shared parts skips the tests), grouped per firm and run in parallel. `test-templates`
refreshes `CONFIG_JSON` as its own first step: `secrets.*` is snapshotted when a run is created, so a
refresh in a separate job would never reach the tests. Used by every market. Temporary name: it will
be renamed to `run_tests.yml`, which needs each market's caller updated.

_Behaviour:_

* Refreshes tokens inline via the `refresh-config-json` action, seeding `autoRenew: false`, and blanks the refresh token on disk before tests run
* If a concurrent run wins a refresh race, the losing PR run's failed jobs are re-run once (`retry-on-race` dispatches a small helper run that waits for the losing run to finish, then re-runs it; helpers take turns per repo, so two losers from one burst can't race each other again). A re-run counts for the PR's required check and reads the fresh token; Slack is alerted only if that fails
* `test-templates` always runs, so the required check fails rather than passing as skipped when change detection fails or the run is cancelled
* A push to main diffs against the previous main commit (not `main` itself), so post-merge runs actually test something
* The silverfin-cli install happens outside the PR checkout

_Caller requirements:_

```yaml
on:
  pull_request:
    branches: ["*"]
  push:
    branches: ["main"]
  # retry-on-race dispatches this file on the default branch to re-run a losing PR run
  workflow_dispatch:
    inputs:
      rerun_run_id:
        description: "Run ID of the losing PR run to re-run (set by retry-on-race)"
        required: true
        type: string

permissions:
  contents: read

jobs:
  run-tests:
    # On this job only, so jobs added to the caller later don't inherit actions: write
    permissions:
      contents: read
      actions: write
    uses: silverfin/bso_github_actions/.github/workflows/run_tests_inline_auth.yml@main
    secrets: inherit
```

Don't add a scheduled `CONFIG_JSON` refresher (e.g. a cron) to a caller repo: it races the inline
refresh.

### Slack updates

#### Automated slack update (`slack_changelog.yml`)

_Description_: 
Posts a changelog update to Slack when a pull request is merged into the `main` branch. 

_Trigger:_

* A pull request targeting `main` is closed
* Only proceeds if the pull request was actually merged (not just closed)


_Steps:_

* Checks that the closed PR was merged
* Inherits repository/organization secrets and sends the Slack notification for the merged PR


_Prerequisites:_

* Set up a Slack workflow in the Slack settings.
    * [UK](https://slack.com/shortcuts/Ft09PPKBHW5N/f0d53e634f6fccff7335148ac0eab5d8)
    * [NL](https://slack.com/shortcuts/Ft09MT6C2CKW/c8cb614e95f1192fdbeb264361d04f73)
    * [LU](https://slack.com/shortcuts/Ft09ML70CL94/1a767ec100c7340772e48c84c24665fa)
    * [BE](https://slack.com/shortcuts/Ft09CP21L86M/ed8f5f30038e6ecca4adf2d01df996ef)
* This workflow will then generate a URL, which is called a webhook. 
* The webhook from the workflow should be stored in an environment variable in the market specific repository: `SLACK_WEBHOOK_URL`
* The GitHub action will create a text object (containing the formatted message) and will post this to the Slack webhook. This will then create the message in a pre-defined channel. 



### Review firm deployment

#### Push templates to review firm `(push_to_review_firm.yml)`

_Description_:
Reusable workflow. Pushes the latest template code from the development Pull Request(s) linked to a functional-review Jira ticket to a Silverfin "review" firm, so a product manager can populate their review environment with one click. It is the dispatch-driven, multi-PR, parameterised generalisation of `update_templates_review.yml`.

A market repo wraps this workflow with a `repository_dispatch` trigger (fired by a Jira Automation button on the functional-review ticket) and/or `workflow_dispatch` for manual testing, passing the development ticket key(s) and the product manager's review firm id.

_Trigger:_

* Called via `workflow_call` from a market-repo wrapper (which is itself triggered by `repository_dispatch` from Jira and/or `workflow_dispatch`).

_Inputs:_

* `dev_ticket_keys` (required) — comma-separated Jira keys of the development tickets linked to the functional-review ticket (e.g. `BE-1234,BE-5678`). Every open PR whose head branch equals or starts with one of these keys is pushed.
* `firm_id` (optional) — the firm to push to (the product manager's review firm). If empty, falls back to `firm_id_review_fallback`, then to the calling repo's `FIRM_ID_REVIEW` variable.
* `fr_ticket_key` (optional) — the functional-review ticket key (used in the PR comment and the Silverfin changelog message).
* `firm_id_review_fallback` (optional) — the wrapper should pass `vars.FIRM_ID_REVIEW` here so it is resolvable inside the reusable workflow.

_Steps:_

* Resolves the review firm id (`firm_id` → `firm_id_review_fallback` → `FIRM_ID_REVIEW`) and verifies it is authorized in `CONFIG_JSON`.
* Finds the open PR(s) whose head branch matches one of the development ticket keys.
* For each PR: checks out the head branch, diffs it against `main`, and for every changed template directory (`reconciliation_texts`, `shared_parts`, `account_templates`, `export_files`) runs `silverfin update-<type>` (or `create-<type>` if the template does not yet exist on the firm). A template touched by more than one PR is pushed once.
* If any shared part was pushed, runs `add-shared-part --all` to (re)link shared parts to their templates.
* Posts a status comment on each PR. Fails the run if any push failed.

_Authentication note:_

* This workflow only **reads** `CONFIG_JSON`; it never refreshes tokens and never writes the secret back, so it does not become a concurrent writer of `CONFIG_JSON`. It relies on the existing refresher to keep the secret fresh — see [docs/github_actions_authentication.md](docs/github_actions_authentication.md).

_Prerequisites:_

* `SF_API_CLIENT_ID`, `SF_API_SECRET` and `CONFIG_JSON` available to the caller (e.g. `secrets: inherit`).
* The review firm must already be authorized with the Silverfin CLI (its OAuth tokens present in `CONFIG_JSON`). If it isn't, the run fails with a message asking the developer who implemented the linked development ticket(s) to authorize it.
* `FIRM_ID_REVIEW` repository variable in the market repo (used as the default when no `firm_id` is supplied).



### Liquid sampler

#### Run liquid sampler `(run_sampler.yml)`

_Description_:
Reusable workflow. Runs the Liquid Sampler (`silverfin-cli run-sampler`) for a single partner's changed reconciliation texts, account templates and shared parts and posts the result on a PR. It is deliberately partner-agnostic and repo-layout-agnostic: given a partner id, a list of already-classified handles/account templates/shared parts, and firm ids, it loads that partner's credentials, runs the sampler, and reports back. All market-specific logic (which templates changed, which partner they belong to) lives in the calling wrapper.

_Trigger:_

* Called via `workflow_call` from a market-repo wrapper.

_Inputs:_

* `partner` (required) — partner environment id (must be authorized — see `PARTNER_CONFIG_JSON` secret).
* `handles` (optional) — reconciliation text handles to sample, **one per line** (directory names under `reconciliation_texts/`). Optional if `account_templates` is set.
* `account_templates` (optional) — account template names to sample, **one per line** (directory names under `account_templates/`). Optional if `handles` is set.
  * All three lists are newline-separated, **not** space-separated: account template directory names routinely contain spaces (e.g. `Investment- and depreciation details`), so a space-joined list is ambiguous and gets word-split into template names that don't exist (`Config file for account template "Investment-" not found`). Same convention as [`run_tests.yml`](#run-liquid-tests-run_testsyml). `firm_ids` is the exception — numeric, so it stays space-separated.
  * A name that **starts with `-`** is rejected before the CLI is called, and the job fails with the directory to rename. `silverfin-cli`'s `-h`/`-at`/`-s` are variadic options, so commander stops consuming values at the first `-`-prefixed token and would read such a name as a flag; a `--` separator does not protect variadic values. Only a leading `-` is affected — internal and trailing hyphens (`Cut-off`, `Investment- and depreciation details`) are fine.
* `shared_parts` (optional) — shared part names to sample, **one per line** (directory names under `shared_parts/`). Optional if `handles` or `account_templates` is set. The sampler backend expands each shared part to every reconciliation text / account detail template that includes it, so one name here can fan out to many rendered templates — no `used_in` expansion is needed on the caller's side.
* `firm_ids` (required) — firm id(s) to sample against, space-separated. The backend 422s if empty.
* `ref` (required) — git ref (commit SHA) to check out — the PR head, so sampled template content matches the PR under review.
* `pull_request_number` (optional) — PR number to post the result comment on. If empty, no comment is posted (results still upload as an artifact).

_Steps:_

* Validates that at least one of `handles`/`account_templates`/`shared_parts`, and `firm_ids`, were supplied.
* Checks out the repo at `ref` and installs `silverfin-cli`.
* Loads the partner's credentials from the `PARTNER_CONFIG_JSON` secret and captures the token on disk before the run.
* Runs `run-sampler`, retrying on a cross-repo "already in progress" 422 (the backend allows only one sampler run per partner at a time; retries while at least 60 minutes of the step deadline remain, so a retried run can still finish).
  * If the CLI stops polling and prints its `Timeout. Try to fetch the status by using the --id flag` line, the job re-attaches to the same run with `run-sampler --id <id>` (the id comes from the CLI's own `Sampler run started with ID:` line) instead of abandoning it — an abandoned run is still running server-side, so the next attempt collides with it on that same one-run-per-partner 422. `--id` is a single status read rather than a poll, so the job re-reads every 60 seconds until the step deadline (135 minutes after the job started, leaving ~45 minutes of the 180-minute cap for the token write-back, artifact uploads and PR comment); if the run is still going at that point the job fails loudly, since a "still in progress" read exits 0 on its own. Every CLI call runs under that same deadline, since the CLI's own poll lasts up to 2 hours.
* Captures the token again after the run and writes it back to `PARTNER_CONFIG_JSON_<partner>` via `gh secret set` only if it rotated (401 refresh mid-run).
* Downloads `results.zip`, best-effort adds a `diffs/` folder of before/after `view.html` for the entries the compact diff flagged, and uploads it as a 7-day workflow artifact.
  * The artifact is uploaded with `compression-level: 0`. GitHub re-zips every upload, and `results.zip` is already per-file deflated, so a second DEFLATE pass saves ~nothing while turning the outer entry into one compressed stream spanning the whole file — which makes the inner zip's central directory unreachable by HTTP Range and forces a consumer to download all 20+ MB to read a handful of `view.html` files. Storing it keeps the inner offsets intact so partial fetches work.
* Posts (or updates) a result comment on the PR with the compact diff and a link to the workflow artifact (kept 7 days; GitHub sign-in required) as the primary way to open the full report; falls back to the presigned report URL (short-lived, ~5 min) only if the artifact upload did not happen.
  * The comment ends with a machine-readable `<!-- silverfin-sampler-provenance {...} -->` footer (invisible when rendered) carrying `repository`, `run_id`, `run_attempt`, `event_name`/`workflow_dispatch`, `partner`, `pr_number`, `ref`, `artifact_id` and `sampler_ok` (ids are JSON numbers, matching the Actions API), so a tool can resolve the artifact and the originating PR without scraping links. The `<!-- silverfin-sampler-result-<partner> -->` marker that identifies the comment for updates is unchanged and still last.
* Fails the job if the sampler run did not complete successfully.

_Authentication note:_

* This workflow is the sole writer of `PARTNER_CONFIG_JSON_<partner>` — it only writes back if the on-disk token actually changed during the run (diffed before/after, not inferred from log output).

_Prerequisites:_

* `SF_API_CLIENT_ID`, `SF_API_SECRET`, `PARTNER_CONFIG_JSON` (per-partner secret resolved by the caller) and `REPO_ACCESS_TOKEN` (repo-scoped write PAT, for the token write-back) available to the caller.
* `SF_BASIC_AUTH` if the partner's host is a `*.staging.getsilverfin.com` gateway.
* The partner must already be authorized with the Silverfin CLI (`silverfin authorize-partner`) and its `config.json` stored as the `PARTNER_CONFIG_JSON_<partner>` secret.

#### Authorizing a partner for staging (`scripts/authorize-partner-secret.sh`)

_Description:_
One-off setup script that authorizes a partner `api_key` against staging and stores the result as that partner's `PARTNER_CONFIG_JSON_<partner_id>` GitHub secret — the secret [`run_sampler.yml`](#run-liquid-sampler-run_sampleryml) reads from. Run this once per partner, and again any time a partner's staging token is lost for good (see _When you need to re-run this_ below) — day-to-day token rotation during sampler runs is handled automatically by the workflow itself and does **not** need this script.

_Prerequisites:_

* `silverfin` CLI installed and on `PATH`.
* `gh` CLI installed and authenticated, with write access to the target market repo's secrets. Check this **before** you get a fresh token below — a bad `gh` session is a common failure mode (expired token, or needing to re-run `gh auth login` after a while):
  ```bash
  gh auth status
  ```
  If that doesn't show a valid logged-in account, run `gh auth login` and check again. The script also checks this itself right before it would need it, and prints these same steps if it isn't set up — but confirming it upfront saves you from going through the staging login flow below only to hit an avoidable failure at the very last step.
* A fresh partner `api_key`, obtained via the staging login flow below. Get this **right before** running the script — the token is shown once, in a banner, and you paste it straight into the prompt.

_Getting the partner `api_key` (staging login flow):_

By default your browser is logged into production (`https://live.getsilverfin.com`). To fetch a staging partner token:

1. In your browser, change the URL from `https://live.getsilverfin.com` to `https://bso-staging-beta.staging.getsilverfin.com`.
2. A basic-auth popup appears — log in with the **"Silverfin staging basic-auth"** credentials from 1Password. (This is the staging gateway's basic auth, not your Silverfin login.)
3. Adjust the URL again to `https://bso-staging-beta.staging.getsilverfin.com/partners`.
4. Log in with your normal partner credentials for the specific partner id you want to authorize.
5. In that partner env, click **"Configuration partners"** in the header.
6. Click the red **"Refresh API token"** button.
7. A banner appears with the token — copy it. Then immediately run the script (below) and paste the token when it prompts for the api key.
8. **Repeat steps 3–7 for every partner env** you need to authorize — each partner has its own login and its own token.

_Usage:_

```bash
./scripts/authorize-partner-secret.sh <partner_id> <market> [host]
```

* `<partner_id>` — numeric partner environment id, e.g. `2`.
* `<market>` — either a short code (`nl`, `be`, `lu`, `uk`, mapped to `silverfin/<market>_market` by the script's market → repo lookup) or a full `owner/repo`.
* `[host]` — optional. Defaults to `https://bso-staging-beta.staging.getsilverfin.com` (the same staging beta host used in the login flow above). Pass an explicit URL to target a different environment, or edit the `HOST` default in the script if you're permanently moving to a new environment.

Examples:

```bash
./scripts/authorize-partner-secret.sh 2 nl
./scripts/authorize-partner-secret.sh 11 lu
./scripts/authorize-partner-secret.sh 1 silverfin/be_market
./scripts/authorize-partner-secret.sh 2 nl https://some-other-staging-host.example.com
```

_What it does:_

* Resolves `<market>` to a repo, then checks `gh auth status` — exits immediately with the `gh auth login` steps above if it's not valid, before asking for anything sensitive.
* Prompts for the api key (hidden input).
* Creates a throwaway `HOME` directory so the authorization doesn't touch your real `~/.silverfin/config.json`.
* Runs `silverfin config --set-host <host>` and `silverfin authorize-partner -i <partner_id> -k <api_key> -n partner-<partner_id>` inside that throwaway `HOME`.
* Pushes the resulting `config.json` straight to the `PARTNER_CONFIG_JSON_<partner_id>` secret on the target repo via `gh secret set`.
* Deletes the throwaway `HOME` on exit (success or failure), via a `trap`.

_When you need to re-run this:_

* **Not needed for normal 401s.** A partner token that's simply gone stale (>24h old) self-heals — the sampler workflow's own refresh call authenticates on a digest match, not the token's age, so it mints a fresh token automatically mid-run and writes it back itself.
* **Re-run this script only after a staging DB snapshot/reset**, which overwrites the partner's stored credentials server-side — that invalidates any token you're holding client-side, including the refresh path, so the sampler workflow's automatic 401 recovery also fails. Signature: a partner token fails on first use *and* on the workflow's automatic refresh attempt in the same run. Get a backend/console regeneration of the partner's api_key first, then re-run this script with the new key.