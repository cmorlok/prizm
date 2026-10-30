# Tasks

## 1. Fix

- [ ] 1.1 Sidebar column `min: 220, ideal: 240` in `VaultBrowserView` (design D1).
- [ ] 1.2 UI run: `AccessibilityLabelTests.testSettingsGearHasLabel` passes (it failed before: red).
- [ ] 1.3 UI test `AccessibilityLabelTests.testSettingsGear_staysVisible_atNarrowestSidebar` (replaces the planned hand check): the gear is next to the sidebar toggle at the smallest sidebar width; dragging the sidebar narrower stops at 220 pt.

## 2. Release

- [ ] 2.1 CHANGELOG "Fixed": the Settings button is visible in the toolbar again.
- [ ] 2.2 `openspec validate fix-settings-gear-visible --type change --strict`.
