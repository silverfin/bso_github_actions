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
    * [Check authentication (check_auth.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf73af65c6455e4bb6a62454b15)
  * [Testing](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf13d6dbd0df1e4450b3b22691c)
    * [Check YAML files (check_tests.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBf931fa1547b4b419d940464f89)
    * [Run liquid tests (run_tests.yml)](https://silverfin.quip.com/avPDA9TrpJ9Y#temp:C:EBfa4878bb5baac49cbb0c39d927)
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

#### Check authentication `(check_auth.yml)`

_Description_:
Refreshes Silverfin API tokens to ensure authentication remains valid for subsequent operations.

_Inputs:_

* `seed_no_auto_renew` (boolean, optional, default `false`) - when `true`, ensures every firm in the
  calling repository's `CONFIG_JSON` carries an `autoRenew` flag, and fails the job if the CLI does
  not preserve it through a refresh. **The flag is written into the caller's own `CONFIG_JSON`
  secret, so a single enabled run affects every workflow in that repository from then on, and this
  workflow has no way to remove it again.** Nothing reads the flag yet, so enabling it changes no
  behaviour today; it exists so the flag can be proven durable before anything depends on it.

_Trigger_: 

* The authentication workflow is run before the `run-tests` workflow to make sure that we always have the correct authentication before communicating with the platform. 


_Steps:_

* Installs the latest silverfin-cli version
* Loads the CONFIG_JSON file from the secrets
* Refreshes the tokens for all configured firms
* Updates the CONFIG_JSON file secret with the refreshed tokens


_Prerequisites_:

* `SF_API_CLIENT_ID`: Silverfin API client ID
* `SF_API_SECRET`: Silverfin API secret
* `CONFIG_JSON`: Silverfin configuration file content
* `REPO_ACCESS_TOKEN`: GitHub personal access token



### Testing

#### Check YAML files `(check_tests.yml)`

_Description:_
Validates that at least 1 `.yaml/.yml` file has been added or updated when changes are made to templates. This can be by-passed by adding the `no-test-required` to the pull request. 

_Trigger:_

* Every time new commits are pushed to a PR
* When labels are added (important for the `no-test-required` bypass logic)
* When labels are removed (re-enables validation if `no-test-required` was removed)

#### Run liquid tests `(run_tests.yml)`

_Description:_
Executes liquid tests for updated reconciliations and reconciliations that use updated shared parts.

_Trigger_:

* On every pull request to any branch (comprehensive testing)
* When code is pushed directly to main (post-merge validation)
* Runs on PR creation, updates (commits), and rebasing/merging actions


_Steps:_

* Calls `check_auth.yml` to refresh tokens
* Identifies changed liquid/config files
* Determines which templates need testing
* Runs liquid tests using silverfin-cli `run-test` command
* Supports multiple firm ID selection strategies ℹ️


_Test firm options:_
There is a certain priority when it comes to test firm id’s. Users do have some options to configure which test firm is used for the liquid tests. 


1. **Template-specific test firm id**

This is the most specific option that is available on a template by template basis. An additional attribute `test_firm_id` can be added to the `config.json` file. That firm will always get priority over the other two options.


1. **Github test firm id**

If the `test_firm_id` is not used for a specific handle, the Github action will look for a Github environment variable `SF_TEST_FIRM_ID`. This variable can be defined on [this page](https://github.com/silverfin/be_market/settings/variables/actions) (link to BE market) and will be used for every template within the market repo (so not template specific). 


1. **Default test firm id**

If none of the above options is used/defined, we will fall back to the default option: the first firm id that is present in the `config.json` file. This is again template specific, but the order cannot be changed (the smallest firm id number will always be on top). 



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
Reusable workflow. Runs the Liquid Sampler (`silverfin-cli run-sampler`) for a single partner's changed reconciliation/account templates and posts the result on a PR. It is deliberately partner-agnostic and repo-layout-agnostic: given a partner id, a list of already-classified handles/account templates, and firm ids, it loads that partner's credentials, runs the sampler, and reports back. All market-specific logic (which templates changed, which partner they belong to) lives in the calling wrapper.

_Trigger:_

* Called via `workflow_call` from a market-repo wrapper.

_Inputs:_

* `partner` (required) — partner environment id (must be authorized — see `PARTNER_CONFIG_JSON` secret).
* `handles` (optional) — reconciliation text handles to sample, **one per line** (directory names under `reconciliation_texts/`). Optional if `account_templates` is set.
* `account_templates` (optional) — account template names to sample, **one per line** (directory names under `account_templates/`). Optional if `handles` is set.
  * Both lists are newline-separated, **not** space-separated: account template directory names routinely contain spaces (e.g. `Investment- and depreciation details`), so a space-joined list is ambiguous and gets word-split into template names that don't exist (`Config file for account template "Investment-" not found`). Same convention as [`run_tests.yml`](#run-liquid-tests-run_testsyml). `firm_ids` is the exception — numeric, so it stays space-separated.
  * A name that **starts with `-`** is rejected before the CLI is called, and the job fails with the directory to rename. `silverfin-cli`'s `-h`/`-at` are variadic options, so commander stops consuming values at the first `-`-prefixed token and would read such a name as a flag; a `--` separator does not protect variadic values. Only a leading `-` is affected — internal and trailing hyphens (`Cut-off`, `Investment- and depreciation details`) are fine.
* `firm_ids` (required) — firm id(s) to sample against, space-separated. The backend 422s if empty.
* `ref` (required) — git ref (commit SHA) to check out — the PR head, so sampled template content matches the PR under review.
* `pull_request_number` (optional) — PR number to post the result comment on. If empty, no comment is posted (results still upload as an artifact).

_Steps:_

* Validates that at least one of `handles`/`account_templates`, and `firm_ids`, were supplied.
* Checks out the repo at `ref` and installs `silverfin-cli`.
* Loads the partner's credentials from the `PARTNER_CONFIG_JSON` secret and captures the token on disk before the run.
* Runs `run-sampler`, retrying on a cross-repo "already in progress" 422 (the backend allows only one sampler run per partner at a time; retries for up to 90 minutes).
* Captures the token again after the run and writes it back to `PARTNER_CONFIG_JSON_<partner>` via `gh secret set` only if it rotated (401 refresh mid-run).
* Downloads `results.zip`, best-effort adds a `diffs/` folder of before/after `view.html` for the entries the compact diff flagged, and uploads it as a 7-day workflow artifact.
* Posts (or updates) a result comment on the PR with the compact diff and a link to the workflow artifact (kept 7 days; GitHub sign-in required) as the primary way to open the full report; falls back to the presigned report URL (short-lived, ~5 min) only if the artifact upload did not happen.
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