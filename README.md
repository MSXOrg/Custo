# Custo

Custo is the central managed-file distribution engine for MSX initiatives. It syncs shared,
centrally-owned files into subscribing repositories by pull request, so every repository
inherits the same governance, linting, and agent-context files without copy-pasting them by hand.

## Source of truth separation

- **Standards** — *what* every initiative must define and *why* — live in
  [`MSXOrg/docs`](https://github.com/MSXOrg/docs), specifically the
  [Organization Standard](https://msxorg.github.io/docs/Ways-of-Working/Organization-Standard/).
- **Initiative implementation guidance** — how a specific initiative applies those standards —
  lives in each initiative's own docs repository, for example
  [`PSModule/docs`](https://github.com/PSModule/docs).
- **Distribution runtime** — *how* managed files are actually delivered to repositories — lives
  here, in Custo.

Custo does not decide what files initiatives should manage. It only distributes what each
initiative's file sets declare, following the [managed files contract](https://msxorg.github.io/docs/Ways-of-Working/Organization-Standard/#managed-files)
defined in MSXOrg/docs.

Custo replaces [`PSModule/Distributor`](https://github.com/PSModule/Distributor) as the runtime
engine for the PSModule initiative, generalized so other initiatives can reuse it instead of
building their own distributor from scratch.

## How it works

File sets are organized by target organization, repository type, and selection:

```text
Repos/{Type}/{Selection}/
```

- **Type** — groups repositories by kind (`Module`, `Action`, `Template`, `Workflow`, ...).
- **Selection** — an individual file set repositories opt into via the `SubscribeTo` custom
  property. Each selection folder mirrors the root of a target repository.

Target discovery scope is declared in [`config/targets.json`](config/targets.json), not hardcoded
in the sync script. The default scope is `all-access`, which scans all repositories visible to the
current GitHub App installation token. This keeps Custo org-agnostic and lets one runtime process
all organizations and repositories it can access.

The [`scripts/Sync-Files.ps1`](scripts/Sync-Files.ps1) script, run by the
[`Sync Managed Files`](.github/workflows/sync-files.yml) workflow:

1. Reads repository discovery scope from `config/targets.json`.
2. Discovers file sets under `Repos/`.
3. Syncs enterprise-level custom-property schema definitions (`Type` and `SubscribeTo`) and
   allowed values from the discovered file-set tree when `customProperties.enabled=true`.
4. Discovers subscribing repositories from all accessible repositories (or explicit organizations
   when configured) and reads their `Type` and `SubscribeTo` custom properties.
5. Clones subscribing repositories, copies the relevant files, and opens or updates a
   `managed-files/update` pull request when changes are detected.

## MVP rollout scope

The first managed resource is **`AGENTS.md`** for PowerShell module repositories
(`Repos/Module/AGENTS.md/AGENTS.md`). The file is a thin pointer into the central docs rather than
a duplicated process document, matching the pattern already used by
[`PSModule/Template-PSModule`](https://github.com/PSModule/Template-PSModule) and
[`PSModule/memory`](https://github.com/PSModule/memory).

Additional file sets and rollout targets are added incrementally after this MVP is proven.

## Required secrets

The sync workflow authenticates as a GitHub App. For repository sync plus enterprise custom
property maintenance, the app needs:

- `contents:write`
- `pull_requests:write`
- `repository_custom_properties:read`
- enterprise custom-properties write/admin access (for `/enterprises/{enterprise}/properties/schema`)

Configure these repository secrets before enabling the scheduled sync:

- `CUSTO_BOT_CLIENT_ID`
- `CUSTO_BOT_PRIVATE_KEY`

See [`AGENTS.md`](AGENTS.md) for operator runbook steps and current rollout blockers.

## License

MIT License — see [LICENSE](LICENSE).
