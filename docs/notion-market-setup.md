## Setting up a new market for template-docs sync

One-off, per market, before its sync_notion_docs.yml caller can run.

1. In the `template-specific documentation` Notion page, create a child
   page named `<flag emoji> <MARKET> market`.
2. Under it, create two databases: `Reconciliation Texts` and
   `Account Templates`, each with these properties:
   - `Name` (title)
   - `Handle` (text) - "Matches config.json handle field" for RT, "Folder
     name in account_templates/" for AT
   - `Market` (select, one option: the market code)
   - `Package` (multi-select) - leave empty, humans fill this in over time
   - `Last synced` (date)
   - `Source commit` (text)
   - `Repo path` (text)
3. Confirm the workspace's internal integration (the one already connected
   to BE market - check Settings -> Connections) is also connected to the
   new market's page. Do NOT create a second integration per market (see
   design doc §4.3 - one workspace-level integration, scoped by connection,
   not by credential).
4. Fetch each database's data source ID (Notion API: `GET /v1/databases/{id}`
   returns child data sources) and add it to `scripts/notion-config.json`
   under the new market code.
5. **Merge the `scripts/notion-config.json` change to `main`, then bump the
   immutable `REF` pin in `.github/workflows/sync_notion_docs.yml` to that
   commit and merge that workflow change too.** The reusable workflow always
   fetches both `sync-notion-docs.sh` and `notion-config.json` from the commit
   SHA set in its `REF` env var (not from `@main` and not from the caller's
   pin). A market added on a branch, or merged to `main` without a matching
   `REF` bump, is therefore invisible to the job until `REF` points at a commit
   that contains the new market entry. After the workflow change lands, pin
   the market repo's caller workflow (`uses: .../sync_notion_docs.yml@<sha>`)
   to the resulting workflow commit.
6. Provision the secrets the reusable workflow needs. Set them at the
   organisation level if you can, so every market repo inherits them;
   otherwise add them to the market repo itself (Settings -> Secrets and
   variables -> Actions):
   - `NOTION_TOKEN` (**required**) - the internal integration's token from
     step 3. The reusable workflow declares it as `required: true` and the
     caller below uses `secrets: inherit`, so if this secret does not exist
     the caller fails at workflow-resolution time, with an unhelpful error and
     before a single step runs.
   - `SLACK_CI_ALERTS_WEBHOOK_URL` (optional) - without it the sync itself
     still runs, but the "created pages" and "failed handles" alerts post
     nowhere and failures are only visible in the job log.
7. Add a caller workflow to the market repo, pinning the reusable workflow to
   an immutable commit SHA on `bso_github_actions` - not `@main`. The reusable
   workflow already handles `NOTION_TOKEN`; a caller pinned to a mutable ref
   gets none of that protection back if the workflow *definition* itself can
   still change out from under it. Use the current tip of `main` on
   `bso_github_actions` at setup time, and bump it deliberately (a one-line
   PR) whenever `sync_notion_docs.yml` changes in a way you want to pick up -
   the same convention this repo's own `push_to_review_firm.yml` uses for its
   self-reference:

   ```yaml
   name: sync-notion-docs
   on:
     push:
       branches: [main]
       # Only start the job when a template README actually changed - without
       # this, every push to main pays for a full-history checkout just to
       # discover there is nothing to sync.
       paths:
         - "reconciliation_texts/**/README.md"
         - "account_templates/**/README.md"
   jobs:
     sync-notion-docs:
       uses: silverfin/bso_github_actions/.github/workflows/sync_notion_docs.yml@<pin to a commit SHA on bso_github_actions main, not a branch>
       with:
         market: "<MARKET_CODE>"
       secrets: inherit
   ```
