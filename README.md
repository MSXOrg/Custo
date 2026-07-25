# Custo

Central managed-file distribution and compliance orchestration for MSX initiatives.
Custo is the **MSXOrg** counterpart of [PSModule/Distributor](https://github.com/PSModule/Distributor) — it pushes shared files (AGENTS.md, coding standards, settings) to subscribing repositories across one or more GitHub organizations via pull requests.

## Ownership split

| Layer | Owner | What lives there |
|-------|-------|-----------------|
| **Policy & process** | [PSModule/docs](https://github.com/PSModule/docs) · [MSXOrg/docs](https://github.com/MSXOrg/docs) | Coding standards, ways of working, AGENTS instructions that agents read |
| **Runtime** | MSXOrg/Custo (this repo) | Sync workflow, script, file-set content that gets pushed to target repos |

Changes to _what agents do_ → edit PSModule/docs or MSXOrg/docs.
Changes to _how files are distributed_ → edit this repo.

## How it works

1. **File sets** live under `Repos/<Type>/<SetName>/` — any file in a set is synced verbatim to the target repo root.
2. **Target organizations** are listed in `config/targets.json`.
3. The workflow queries each org for repositories with GitHub Custom Properties:
   - `Type` — maps to a `Repos/<Type>/` folder (e.g. `Module`).
   - `SubscribeTo` — comma-separated list of set names within that type (e.g. `AGENTS.md`).
4. For each match the script clones the target repo, copies the files, and creates/updates a PR titled `⚙️ [Maintenance]: Sync managed files` on branch `managed-files/update`.
5. **No implicit deletes** — only files explicitly present in the selected sets are touched; files not in any set are left alone.
6. **No duplicate PRs** — if an open PR already exists on the same branch, it is updated rather than re-created.

## Repository layout

```
.github/
  workflows/
    sync-files.yml       # Schedule: daily 06:00 UTC + manual dispatch
config/
  targets.json           # List of target GitHub orgs
Repos/
  Module/
    AGENTS.md/
      AGENTS.md          # Thin-pointer instructions for PSModule module repos
scripts/
  Sync-Files.ps1         # Core sync logic (config-driven)
```

## Required secrets

Set these as **repository secrets** in MSXOrg/Custo (Settings → Secrets and variables → Actions):

| Secret | Description |
|--------|-------------|
| `CUSTO_BOT_CLIENT_ID` | GitHub App Client ID for the Custo bot app |
| `CUSTO_BOT_PRIVATE_KEY` | GitHub App private key (PEM format) |

The GitHub App must be **installed** on every target organization and granted the following permissions:

| Permission | Level | Reason |
|------------|-------|--------|
| Contents | Read & Write | Clone repos, commit files, push branch |
| Pull requests | Read & Write | Create and update PRs |
| Metadata | Read | List repositories and custom properties |

## Adding a new file set

1. Create a folder under `Repos/<Type>/<SetName>/` and add the files.
2. Target repos opt in by setting their `SubscribeTo` custom property to include `<SetName>`.
3. On next run the script will pick up the new set automatically.

## Adding a new target organization

1. Edit `config/targets.json` and add the org name to the `orgs` array.
2. Install the Custo GitHub App on the new org.
3. Set `Type` and `SubscribeTo` custom properties on the repos that should receive files.

## MVP scope

The current MVP ships a single file set: **`Repos/Module/AGENTS.md/`** containing a thin-pointer `AGENTS.md` for PSModule PowerShell module repositories. This file instructs agents to read [PSModule/docs](https://github.com/PSModule/docs) and [MSXOrg/docs](https://github.com/MSXOrg/docs) instead of embedding the full process text.

## Operator runbook — first AGENTS.md wave

### Prerequisites (blockers if not done)

1. **GitHub App exists** — create a GitHub App under the MSXOrg organization named `Custo Bot` (or similar) with the permissions listed above. Download the private key.
2. **App installed on PSModule org** — install the app from the MSXOrg org settings onto the `PSModule` organization, granting access to all repositories (or at minimum the module repos that should receive the sync).
3. **Secrets configured** — add `CUSTO_BOT_CLIENT_ID` and `CUSTO_BOT_PRIVATE_KEY` to MSXOrg/Custo repository secrets.
4. **Custom properties on target repos** — for each PSModule module repository that should receive the `AGENTS.md`:
   - Set custom property `Type` = `Module`
   - Set custom property `SubscribeTo` = `AGENTS.md`
   These can be set in bulk via the GitHub UI (Org Settings → Custom Properties) or the `gh` CLI:
   ```bash
   gh api -X PATCH /orgs/PSModule/properties/values \
     --field 'repository_names[]=<repo-name>' \
     --field 'properties[0][property_name]=Type' \
     --field 'properties[0][value]=Module' \
     --field 'properties[1][property_name]=SubscribeTo' \
     --field 'properties[1][value]=AGENTS.md'
   ```

### Triggering the first run

Once prerequisites are met, trigger the workflow manually:

```bash
gh workflow run sync-files.yml --repo MSXOrg/Custo
```

Or navigate to **Actions → Sync Managed Files → Run workflow** in the GitHub UI.

### What to expect

- Each qualifying PSModule repo gets a PR titled `⚙️ [Maintenance]: Sync managed files` with `AGENTS.md` added/updated on branch `managed-files/update`.
- The workflow summary shows counts of PRs created/updated/skipped.
- Review one sample PR before merging the rest. If the content looks correct, merge the wave.

### Rollback

If the `AGENTS.md` content needs correction before merge:
1. Update `Repos/Module/AGENTS.md/AGENTS.md` in this repo and push.
2. Re-run the workflow — it will force-push the branch and the existing PR will update automatically.

If PRs were already merged and the file needs to be removed, that must be done manually (no implicit delete by design).
