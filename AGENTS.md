# Agents

## Main directive

Everything here is a work in progress and can be improved. If you find a problem, fix it if it's
small; otherwise register it as an issue in this repo.

Read [MSXOrg/docs AGENTS.md](https://github.com/MSXOrg/docs/blob/main/AGENTS.md) first for
ecosystem-wide onboarding. This file only covers what's specific to Custo.

## What this repo is

Custo is the distribution runtime described in [README.md](README.md). Read that first for the
architecture and the source-of-truth separation between standards, initiative docs, and this
runtime.

## Operator runbook: enabling live rollout

The MVP file set (`Repos/Module/AGENTS.md/`) and workflow are in place, but the scheduled sync
cannot run against real repositories until an operator completes these steps:

1. **Configure GitHub App credentials.** Add `CUSTO_BOT_CLIENT_ID` and `CUSTO_BOT_PRIVATE_KEY`
   as repository secrets on `MSXOrg/Custo`, using the same `PSModule's Custo` GitHub App
   (app id `1320343`, slug `psmodule-s-custo`) already installed on the `PSModule` organization.
   If that app's credentials are not available, generate a new private key for it or provision an
   equivalent app with `contents:write`, `pull_requests:write`, and
   `repository_custom_properties:read` on target repositories, plus enterprise custom-properties
   write/admin permission if enterprise schema sync is enabled.
2. **Confirm app installation scope.** Verify the app is installed on the `PSModule` organization
   with access to the module repositories that should receive `AGENTS.md`
   (`gh api orgs/PSModule/installations`).
3. **Set custom properties on target repositories.** Each subscribing module repository needs
   `Type = Module` and `SubscribeTo` including `AGENTS.md` set at the repository level.
   Custo now maintains allowed values at enterprise level from `Repos/` file sets when
   `customProperties.enabled=true` in `config/targets.json`.
4. **Dry-run via `workflow_dispatch`.** Trigger the `Sync Managed Files` workflow manually first
   and review the summary before relying on the daily schedule.

Until step 1 is complete, the workflow will fail at the authentication step
(`Connect-GitHub App`) — this is the current, expected blocker for this MVP.
