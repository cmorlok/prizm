# Tasks

## 1. Fix

- [x] 1.1 Sidebar column `min: 220, ideal: 240` in `VaultBrowserView` (design D1). Done: commit 0b1fb905, `VaultBrowserView.swift:125`. Unit tests green (`20261030T100656Z`, 1092 tests; after the squash `20261030T133625Z`).
- [x] 1.2 UI run: `AccessibilityLabelTests.testSettingsGearHasLabel` passes (it failed before: red). Red: full UI suite `20261030T094451Z` ("Settings button must exist"; it also failed on develop in `20261030T072233Z`). Green: `20261030T101027Z` and `20261030T121821Z`.
- [x] 1.3 UI test `AccessibilityLabelTests.testSettingsGear_staysVisible_atNarrowestSidebar` (replaces the planned hand check): the gear is next to the sidebar toggle at the smallest sidebar width; dragging the sidebar narrower stops at 220 pt. Done: passed in the approved UI run `20261030T134942Z` with the final drag (by the sidebar's full width); it first passed with the earlier 150 pt drag in `20261030T121821Z` (sidebar stopped at 221 pt). `testSettingsGearHasLabel` passed in the same run.

## 2. Release

- [x] 2.1 CHANGELOG "Fixed": the Settings button is visible in the toolbar again. Done: "Fix: the Settings button (gear) had moved into the toolbar's overflow menu, so it was hidden, and VoiceOver users did not find it in the toolbar. It is back next to the sidebar toggle; the sidebar is now at least 220 pt wide."
- [x] 2.2 `openspec validate fix-settings-gear-visible --type change --strict` and `/opsx:verify`. Valid; `/opsx:verify` 2026-10-30: no critical issues, no warnings once 1.3 ran; suggestions in design.md "Review".
- [x] 2.3 Archive the change.
