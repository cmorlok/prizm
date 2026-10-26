# Design

## Context

Found by the UI run of `fix-ui-test-target` on 2026-10-25 (design.md there, Findings). The causes
below were established with unit tests and with diagnostic UI tests on the Mac that report the key
window's first responder and the accessibility values, not by reading the code alone.

- **Bug 1.** `RootViewModel.lockVault()` and `signOut()` (`App/PrizmApp.swift`) clear the vault
  store and the key caches. `VaultBrowserViewModel` is created once in `RootViewModel.init` and kept.
  `RootViewModel.menuBarCanEdit` and `selectedLogin` derive from its `itemSelection`.
- **Bug 2.** A unit test sets `sidebarSelection = .trash`, then `createItemType = .login`; the value
  stays `.login`. The crash report stays on the Mac, so the crash itself is not traced further;
  with the "+" absent and the guard working, ⌘N in Trash does nothing and the app keeps running.
- **Bug 3.** After Reveal, the masked value's accessibility element reports "••••••••" while its
  child text reports the password. After switching from Alpha to Gamma, the username row reports
  `user-alpha`. The generator preview keeps its first value.
- **Bug 4.** After a click on a sidebar row, the key window's first responder is the window itself.
  After a click on an item row, it is a list, but not always the one clicked (↓ once moved the
  sidebar). Sending ↓ to the outline element directly sometimes worked, which is why the UI test
  passed in some runs.
- **Bug 5.** "Log out" in the official desktop client has no accelerator
  (`apps/desktop/src/main/menu/menu.first.ts`); "Lock all" has ⌘L, as Prizm's Lock Vault.

## Goals / Non-Goals

**Goals:** fix the six bugs with the smallest change each; every fix has a test that failed
before. **Non-Goals:** see proposal.md.

## Decisions

### D1. The vault browser has a session that closes on lock and sign-out

`VaultBrowserViewModel.clearSession()` sets `itemSelection`, `displayedItems`, `itemCounts`,
`folders`, `organizations`, `collections`, the search term and global-search state, `createItemType`,
`editSheetOpen` and `actionError` back to their empty values, and closes the session.
`lockVault()` and `signOut()` call it synchronously before their `Task`, so the copies are gone
before the awaits. `transitionToVault` calls `beginSession()` when the unlocked vault is shown.

While the session is closed, nothing is put back:
- Each refresh (`refreshItems`, `refreshItemSelection`, `refreshCounts`, `refreshFolders`,
  `refreshOrganizations`) records `sessionGeneration` when it starts and assigns its result only if
  the session is open and the generation is unchanged. Both methods increment the generation. The
  lock clears the vault store only after some awaits, so a refresh that starts after
  `clearSession()` (resetting the search term starts one) would otherwise still read decrypted
  items, and a read from before the lock could deliver into the next session.
- Saves report back through `saveHandler()`, which records the generation when the edit sheet
  opens or the favorite toggle starts, and drops the saved item if that session has ended. A save
  in flight during the lock can complete afterwards, even after the next unlock or another
  account's sign-in, and would select the decrypted item again.

Defense in depth: the copy commands check `isVaultUnlocked`, and Copy Code checks it again after
generating the code. Sign-out also resets the sidebar to
All Items, so the next account does not start in a folder of the previous one.

Kept: the sidebar category on lock and the sync timestamp, which hold no vault content. The
clipboard keeps its 30-second auto-clear, which runs on across a lock; clearing it at lock time is
out of scope.

**Rejected:** a new `VaultBrowserViewModel` per session. `RootViewModel` exposes it as `let` and the
menu-bar state subscribes to it once; replacing it means rewiring those subscriptions.

### D2. "+" absent in Trash, and a guard that works

The toolbar item is wrapped in `if viewModel.sidebarSelection != .trash`, as the spec requires;
the hidden ⌘N button lives inside it, so the shortcut goes with it. `createItemType` becomes a
computed property over a private `@Published` value, with the Trash check in its setter. The binding
`$viewModel.createItemType` and all callers stay unchanged.

### D3. Selectable texts set their accessibility value

`.accessibilityValue(...)` with the shown text on the masked field, both field-row texts and the
generator preview. Verified: the element then reports the revealed password, the new item's
values and the new preview. The verification code row already sets its value explicitly and is
unchanged.

**Rejected:** `.id(value)`, which recreates the view on every change. It also works, but resets
text selection and view state for no gain.

### D4. Lists take focus on click

Both lists get a `@FocusState` with `.focused(...)` and a
`.simultaneousGesture(TapGesture().onEnded { focused = true })`. The tap gesture also covers a click
on the row that is already selected, which does not change the selection. Drag and drop and the
row context menus are unchanged.

**Rejected:** setting focus in the selection binding's setter. It misses the click on the already
selected row, so the arrow keys still failed after coming back from the other list.

### D5. Sign Out has no shortcut

The `.keyboardShortcut` is removed. Signing out is rare and clears all local data; the alert stays.

**Open question for the maintainer:** if a shortcut is wanted, ⌃⌥⌘Q is free in macOS and hard to
press by accident. ⌥⌘Q is not proposed: many apps use it for "Quit and Keep Windows".

### D6. "New Window" opens the main window; UI tests open one when there is none

The `WindowGroup` gets the id `main`, and "New Window" calls `openWindow(id:)`.

Launched by XCUITest, the app gets no "reopen" event, so SwiftUI shows a window only when macOS
restores one from the saved window state. After a run that ended without a window, the app started
without one and every UI test failed (2026-10-26, also on this branch, which had passed before).
`launch(in:)` therefore opens a window with File → New Window if none exists after 3 s.
Checked: with the fix, the test log shows "No window after launch" for each test and the tests
pass; before it, 0 of 4 passed. This corrects the explanation in `fix-ui-test-target`, which named
`-ApplePersistenceIgnoreState` as the cause.

## Review

Two rounds of independent review. The first found two gaps that D1 now closes: a refresh started
after `clearSession()`, and a save completing after the lock. The second found that a save could
also complete in the next session, and that Copy Code could copy across a lock. Each has a unit test
that fails without its guard.

Accepted after review: an error from a delete or folder action that fails while the vault is
locked still shows after unlocking (no vault content). Out of scope, pre-existing: locking while
the unlock flow's sync runs; if that sync later reports success, the vault is shown again.

## Risks / Trade-offs

- **[Low] Tap gesture on a list with drag and drop.** A tap gesture only fires without movement, so
  dragging items to folders and reordering sidebar sections keep working; check by hand once.
- **[Low] After unlocking, the item list is empty until the post-unlock sync refreshes it.** That
  sync runs on every unlock today (`handleSyncCompleted`).
- `ACCESSIBILITY.md` already claims keyboard operation and correct VoiceOver values. With bugs 3
  and 4 fixed, the claims hold; the document needs no change.
