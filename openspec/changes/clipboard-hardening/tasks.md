# Tasks

Estimates are ideal engineer-days. Write a failing test first for each task (§IV).

## 1. Service (1 d)

- [ ] 1.1 Inspect the arboard source of the version the desktop app pins and record in design.md which pasteboard types `exclude_from_history()` writes on macOS (Open Question 2).
- [ ] 1.2 Write the regression test for today's bug first: generator Copy, then release the view model; after 30 s of test clock, the clipboard still holds the password (fails after the fix).
- [ ] 1.3 `ClipboardServiceImpl` tests with a fake pasteboard and clock: concealed marker written; clear after the delay; no clear when `changeCount` changed; a new copy replaces the pending clear; `.never` schedules nothing.
- [ ] 1.4 Implement (design.md D1). §VII comment: security goal, what is not done (other processes can read the pasteboard during the delay; Universal Clipboard not blocked).

## 2. Callers (0.5 d)

- [ ] 2.1 `VaultBrowserViewModel.copy` and `PasswordGeneratorViewModel.copyToClipboard` delegate to the service. Remove the generator's own pasteboard code and `deinit` cancel. Task 1.2 now passes.
- [ ] 2.2 Test that the generator copy carries the concealed marker.

## 3. Setting (0.5–1 d)

- [ ] 3.1 `ClipboardClearDelay` with UserDefaults persistence; default 30 s. Tests.
- [ ] 3.2 Picker in Settings → Security, design tokens, VoiceOver label.

## 4. Lock, sign-out, quit (0.5 d)

- [ ] 4.1 Failing tests: `lockVault()`, `signOut()` and `applicationWillTerminate` clear an owned value and leave a foreign value alone; with `.never`, lock still clears.
- [ ] 4.2 Implement.

## 5. Verify and document (0.5 d)

- [ ] 5.1 Manual check with a clipboard manager that honours nspasteboard.org (for example Maccy): generator copies do not appear in its history.
- [ ] 5.2 Mandatory security review: no secret retained by the service beyond the pasteboard itself; all copy paths use the service.
- [ ] 5.3 SECURITY.md (clipboard section), CHANGELOG "Fixed: generated passwords are hidden from clipboard history and cleared after closing the sheet"; "Added: clipboard clear delay setting; the clipboard is cleared on lock and quit".
- [ ] 5.4 `openspec validate clipboard-hardening --type change --strict`.
