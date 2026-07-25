# Agents

> ⚙️ This file is **centrally managed** by [MSXOrg/Custo](https://github.com/MSXOrg/Custo).
> Do not edit it here — changes will be overwritten on the next sync.
> To propose updates, open a PR in MSXOrg/Custo.

## Primary guidance

This repository is a **PSModule PowerShell module**. All agent policy lives in two canonical sources:

| Source | What it covers |
|--------|---------------|
| [PSModule/docs](https://github.com/PSModule/docs) | PSModule-specific standards: module structure, naming conventions, build pipeline, release process, and PowerShell coding style. Start here for any module task. |
| [MSXOrg/docs](https://github.com/MSXOrg/docs) | Cross-org foundations: vision, ways of working, issue/PR/commit conventions, and review etiquette. |

Read PSModule/docs first, then MSXOrg/docs for anything not covered there.

## Quick-start for an agent landing here

1. Clone `PSModule/docs` as a bare repo with worktrees into `~/.msx/PSModule/`:
   ```
   git clone --bare https://github.com/PSModule/docs ~/.msx/PSModule/docs
   cd ~/.msx/PSModule/docs && git worktree add main main
   ```
2. Start at `~/.msx/PSModule/docs/main/` — read the top-level `index.md` and follow links into the relevant section.
3. Clone `MSXOrg/docs` the same way into `~/.msx/MSXOrg/docs` for cross-org context.
4. Apply micro-commits on every logical change and push each commit.
