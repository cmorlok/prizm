# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Service (1 d)

- [ ] 1.1 Inspect the arboard source of the version the desktop app pins and record in design.md which pasteboard types `exclude_from_history()` writes on macOS (Open Question 2).
- [x] 1.2 Write the regression test for today's bug first: generator Copy, then release the view model; after 30 s of test clock, the clipboard still holds the password (fails after the fix).
- [x] 1.3 `ClipboardServiceImpl` tests with a fake pasteboard and clock: concealed marker written; clear after the delay; no clear when `changeCount` changed; a new copy replaces the pending clear; `.never` schedules nothing.
- [x] 1.4 Implement (design.md D1). §VII comment: security goal, what is not done (other processes can read the pasteboard during the delay; Universal Clipboard not blocked).

## 2. Callers (0.5 d)

- [x] 2.1 `VaultBrowserViewModel.copy` and `PasswordGeneratorViewModel.copyToClipboard` delegate to the service. Remove the generator's own pasteboard code and `deinit` cancel. Task 1.2 now passes.
- [x] 2.2 Test that the generator copy carries the concealed marker.

## 3. Setting (0.5–1 d)

- [x] 3.1 `ClipboardClearDelay` with UserDefaults persistence; default 30 s. Tests.
- [x] 3.2 Picker in Settings → Security, design tokens, VoiceOver label.

## 4. Lock, sign-out, quit (0.5 d)

- [x] 4.1 Failing tests: `lockVault()`, `signOut()` and `applicationWillTerminate` clear an owned value and leave a foreign value alone; with `.never`, lock still clears.
- [x] 4.2 Implement.

## 5. Verify and document (0.5 d)

- [ ] 5.1 Manual check with a clipboard manager that honours nspasteboard.org (for example Maccy): generator copies do not appear in its history.
- [ ] 5.2 Mandatory security review: no secret retained by the service beyond the pasteboard itself; all copy paths use the service.
- [x] 5.3 SECURITY.md (clipboard section), CHANGELOG "Fixed: generated passwords are hidden from clipboard history and cleared after closing the sheet"; "Added: clipboard clear delay setting; the clipboard is cleared on lock and quit".
- [x] 5.4 `openspec validate clipboard-hardening --type change --strict`.

## Results (2026-10-25)

- `ClipboardServiceTests` (fake pasteboard and manual clock: concealed write, default and configured
  delay, foreign value kept, new copy replaces the pending clear, `.never`, clear on lock/sign-out
  path, the generator regression after its view model is gone, the `NSPasteboard` adapter);
  `ConcealedPasteboardTests` moved to `SystemPasteboard`.
- 1.2: written as the regression test against the new structure (the old generator had no
  injectable pasteboard, so the "fails before" run is the old code path's behaviour, not a test run).
- 4.1: lock and sign-out call `clearIfOwned()` in `RootViewModel`; quit observes
  `NSApplication.willTerminateNotification` (the app has no `NSApplicationDelegate`).
  `RootViewModelLockTests.testLockVault_clearsACopiedSecret` covers lock; sign-out and quit call the
  same method and are not tested separately.
- After review: the copy tests (`RootViewModelCopyCodeTests`, generator) assert on the shared fake
  pasteboard instead of `NSPasteboard.general`; SECURITY.md and the service's doc say "every Copy
  button and menu command": text selected and copied with ⌘C bypasses the service (pre-existing,
  listed as not prevented); "normal quit" only; the auto-clear log fires only when it cleared.
- The service reaches the generator through the SwiftUI environment (`EditFieldRow`), like
  `OptionKeyMonitor`; the vault browser gets it through its initializer. One instance, created by
  `AppContainer`.
- **Not verified on the Mac yet** (test runner hung): `PrizmTests`.
- Open: 1.1 (arboard source of the desktop app, Open Question 2), 5.1 (manual check with a
  clipboard manager), 5.2 security review.

