# Implementation Plan

Issues grouped by branch in recommended work order. Each branch depends on those above it unless noted.

---

## 1. `feat/configurable-paths`
*Do first — other issues depend on the path keys being available.*

| # | Issue |
|---|-------|
| [#3](https://github.com/ndomako10/mileage-tracker/issues/3) | Configurable `Source`, `Output`, `Logs`, `Reports` paths in `settings.json` |

---

## 2. `feat/input-validation`
*Depends on #3 so path keys can be validated at startup.*

| # | Issue |
|---|-------|
| [#7](https://github.com/ndomako10/mileage-tracker/issues/7) | Validate `settings.json` and `locations.json` at startup with clear error messages |

---

## 3. `feat/shouldprocess`
*Do before logging and error handling — removes `-DryRun` that other issues still reference.*

| # | Issue |
|---|-------|
| [#9](https://github.com/ndomako10/mileage-tracker/issues/9) | Replace `-DryRun` with `ShouldProcess` / `-WhatIf` / `-Confirm` |

---

## 4. `feat/error-handling`
*Can follow ShouldProcess — defines skip/warn behaviour that logging will surface.*

| # | Issue |
|---|-------|
| [#10](https://github.com/ndomako10/mileage-tracker/issues/10) | Explicit handling for OCR, EXIF, GPS, and rename-collision failures |

---

## 5. `feat/logging`
*Depends on #3 (needs `Logs` path), #9 (references `-WhatIf`), and #10 (surfaces skip warnings).*

| # | Issue |
|---|-------|
| [#8](https://github.com/ndomako10/mileage-tracker/issues/8) | Structured console logging with `Start-Transcript` and `-Verbose` support |

---

## 6. `feat/photo-sorting`
*Independent of the above but needs #3's `Output` path to be useful.*

| # | Issue |
|---|-------|
| [#2](https://github.com/ndomako10/mileage-tracker/issues/2) | Sort renamed photos into `yyyy/yyMM` subfolders |

---

## 7. `test/pester`
*Do after core features are stable — tests should reflect final behaviour.*

| # | Issue |
|---|-------|
| [#4](https://github.com/ndomako10/mileage-tracker/issues/4) | Pester test suite for both scripts |

---

## 8. `ci/github-actions`
*Do last — depends on #4 for the test job to be meaningful.*

| # | Issue |
|---|-------|
| [#5](https://github.com/ndomako10/mileage-tracker/issues/5) | GitHub Actions pipeline (PSScriptAnalyzer + Pester) |
