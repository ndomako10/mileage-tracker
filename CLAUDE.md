# Claude Code Instructions — Mileage Tracker

## Project overview

Two-script PowerShell pipeline: odometer photos → renamed files → trip CSV.

1. `scripts/Rename-Photos.ps1` — reads EXIF, matches GPS to known location, OCRs odometer, renames files, writes `logs/rename-log.json`
2. `scripts/Build-Trips.ps1` — reads `rename-log.csv`, pairs entries into trips, writes `trips.csv`

## Repo layout

```
scripts/    PowerShell scripts
config/     settings.example.json, locations.example.json (templates only — see below)
logs/       rename-log output (gitignored)
```

## PowerShell version

**Scripts require Windows PowerShell 5.1.** They will not work under PowerShell 7+ because Windows OCR uses WinRT APIs that are unavailable in PS7. Do not add PS7 compatibility without confirming the WinRT dependency can be resolved.

## Configuration files

`config/settings.json` and `config/locations.json` are the user's local config. They are **gitignored and must never be committed**. Only the `*.example.json` templates belong in the repo.

The same applies to all generated output: `logs/rename-log.json`, `trips.csv`.

## Path conventions

Both scripts locate their dependencies using `$PSScriptRoot` with relative `..` traversal:

- Settings: `$PSScriptRoot\..\config\settings.json`
- Locations: resolved relative to the config directory (`Split-Path $settingsPath -Parent`)
- Log output: `$PSScriptRoot\..\logs\`

When adding new file references in either script, follow this same pattern — never hardcode absolute paths.

## Testing

Use `-WhatIf` to preview actions without making changes, or `-Confirm` to prompt before each action:

```powershell
.\scripts\Rename-Photos.ps1 -WhatIf
.\scripts\Build-Trips.ps1 -WhatIf
```

## Implementation plan

See [PLAN.md](../PLAN.md) for the full implementation plan, issue groupings, and recommended branch order.

## Changelog

This project does **not** maintain a `CHANGELOG.md`. This overrides the global `CLAUDE.md` convention. Release notes are generated automatically by GitHub from PR titles and descriptions when a release is cut.

## Releases

Releases are cut automatically by `.github/workflows/release.yml` when a PR is merged to `main`. The version bump is derived from the PR title:

| PR title prefix | Bump |
|-----------------|------|
| `type!:` or `BREAKING CHANGE:` in body | major |
| `feat:` / `feat(scope):` | minor |
| `fix:` / `perf:` | patch |
| `chore`, `docs`, `ci`, `test`, `refactor`, `style` | none |

**Requirements:**
- PRs must be merged using **squash merge** to keep a clean, readable `git log` on `main`.
- PR titles must follow Conventional Commits — the workflow uses the title to determine the bump level.
- **Write meaningful PR descriptions** — GitHub auto-generates release notes from PR titles and descriptions. The description becomes the release notes entry for that change.

