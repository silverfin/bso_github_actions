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
5. Add a caller workflow to the market repo:

   ```yaml
   name: sync-notion-docs
   on:
     push:
       branches: [main]
   jobs:
     sync-notion-docs:
       uses: silverfin/bso_github_actions/.github/workflows/sync_notion_docs.yml@main
       with:
         market: "<MARKET_CODE>"
       secrets: inherit
   ```
