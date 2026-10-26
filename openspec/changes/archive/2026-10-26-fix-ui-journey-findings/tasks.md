# Tasks

Estimates are ideal engineer-days. Write a failing test first (§IV). One commit per bug (1–5).
**Prerequisite:** `fix-ui-test-target`.

## 1. Lock and sign-out clear browser state (0.5 d)

- [x] 1.1 Failing unit tests: `lockVault()` and `signOut()` leave no selected item, listed item, folder or search term, and disable Edit and the copy commands (`RootViewModelLockTests`).
- [x] 1.2 Failing unit tests: `clearSession()` drops the create and edit sheet state; a read in flight and a read started after it are discarded; a late save is ignored, also in the next session; refreshes work again after `beginSession()` (`VaultBrowserViewModelSessionTests`); copy commands copy nothing while locked, also when the lock comes while a code is generated; sign-out resets the sidebar.
- [x] 1.3 Implement design D1.
- [x] 1.4 UI test `EditItemJourneyTests.testItemMenu_followsSelectionAndLock`: remove the known-bug marker.
- [x] 1.5 CHANGELOG.

## 2. ⌘N and "+" in Trash (0.25 d)

- [x] 2.1 Failing tests: `VaultBrowserViewModelTrashTests`; UI tests `testCmdN_isNoOp_inTrash` (real steps instead of the skip) and `testNewItemButton_hiddenInTrash` (marker removed).
- [x] 2.2 Implement design D2.
- [x] 2.3 CHANGELOG.

## 3. Accessibility values (0.25 d)

- [x] 3.1 Failing UI tests: the reveal marker removed; the username after switching items; the generator preview after a change.
- [x] 3.2 Implement design D3.
- [x] 3.3 CHANGELOG.

## 4. Arrow keys (0.25 d)

- [x] 4.1 Failing UI tests: the arrow-key markers removed; returning to the sidebar after a click in the item list.
- [x] 4.2 Implement design D4.
- [x] 4.3 CHANGELOG.

## 5. Sign Out shortcut (0.1 d)

- [ ] 5.1 Remove the shortcut (design D5). UI tests cannot read a menu item's key equivalent, so check by hand: the Prizm menu shows "Sign Out…" without a shortcut.
- [x] 5.2 CHANGELOG.

## 7. New Window (added 2026-10-26)

- [x] 7.1 Implement design D6 (`PrizmApp`: `WindowGroup(id:)`, "New Window" opens it; `UITestSupport.openWindowIfNone()`).
- [x] 7.2 UI check: `AccessibilityLabelTests` with no window restored: the fallback opens one, 3 of 3 pass (0 of 4 before).
- [ ] 7.3 By hand: close the window, File → New Window opens a new one.
- [x] 7.4 CHANGELOG.

## 6. Verify (0.25 d)

- [x] 6.1 `PrizmTests` pass.
- [x] 6.2 `PrizmUITests` pass with no known-bug markers left from `fix-ui-test-target`.
- [x] 6.3 Code review of all five commits; security review of bug 1.
- [ ] 6.4 By hand: drag an item to a folder and reorder sidebar sections (design, Risks); VoiceOver reads a revealed password.
- [x] 6.5 `openspec validate fix-ui-journey-findings --type change --strict`.

## Results (2026-10-25, macOS 26, signed with a contributor team)

- 6.1 `PrizmTests`: 564 passed. Each new guard was removed once to confirm its test fails without it.
- 6.2 `PrizmUITests`: 88 tests, 67 passed, 21 skipped (8 simulated Touch ID, 7 test backend for
  saving, 1 for downloads, 5 real account), 0 failed, no known-bug markers left.
- 6.3 Two review rounds (design.md, Review). Each fix commit was built and unit-tested on its own.
- Open, by hand: 5.1 (Sign Out shows no shortcut) and 6.4 (drag and drop, VoiceOver).

