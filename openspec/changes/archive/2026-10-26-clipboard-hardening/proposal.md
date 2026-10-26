# Proposal

## Why

**Criticality:** P2 (Medium)
**Findings:** CF-03, CF-16 (`06-client-features.md`)

Two clipboard paths behave differently:
- Copies from the detail pane, the menu and the Codes list go through
  `VaultBrowserViewModel.copy` (`Presentation/Vault/VaultBrowserViewModel.swift:232-250`). They are
  marked `org.nspasteboard.ConcealedType` and cleared after 30 seconds.
- The password generator's Copy button (`Presentation/Vault/Edit/PasswordGeneratorViewModel.swift:83-99`)
  writes a plain string with no concealed marker. Its 30-second clear task is cancelled in `deinit`
  (`:59-61`), and the view model lives in `@State` of `EditFieldRow` (`EditFieldRow.swift:79, 119`).
  In the usual flow (Copy → Use → Save → sheet closes) the clear is cancelled and the generated
  password stays on the clipboard indefinitely, recorded by clipboard managers.

Also:
- The delay is fixed at 30 seconds. Official clients let the user choose.
- Nothing clears the clipboard when the vault locks or Prizm quits. The clear task dies with the
  process (`openspec/changes/archive/2026-03-15-vault-browser-ui/design.md:65`). Official clients
  clear on lock and, on desktop, on quit.

User-visible impact: a freshly generated password can stay on the clipboard and in clipboard
history after the user has moved on, and a copied secret survives locking or quitting Prizm.

**Origin of the current behaviour:**
- Generator copy: accidental. The generator predates the concealed marker (527b024, 2026-03-23); the
  marker was added only to `VaultBrowserViewModel` with the TOTP work (70389ad, 2026-10-16), and the
  generator was not migrated.
- Fixed 30 s: deliberate, FR-011 of the first spec.
- No clear on quit: deliberate. vault-browser-ui `design.md:65`: "clipboard clear is best-effort on
  quit only (FR-011 explicitly permits this)". No clear on lock: accidental.

## What Changes

- **One clipboard service for every copy.** An app-wide `ClipboardService` writes the value with the
  concealed marker and owns the clear timer. The timer does not depend on any view or sheet.
- **Generator uses it.** Its own pasteboard code and `deinit` cancel are removed.
- **Configurable delay** in Settings → Security: Never, 10 s, 20 s, 30 s, 1 min, 2 min, 5 min. These
  are the official options. Prizm keeps 30 s as its default (official default: 5 min).
- **Clear on lock, sign-out and quit** if the clipboard still holds the value Prizm put there.

## Capabilities

### New Capabilities
- `clipboard-protection`: concealed copy, configurable auto-clear, and clearing on lock, sign-out and
  quit, for every copy path.

### Modified Capabilities
_None as deltas._ Related existing specs: `copy-menu-commands`, `vault-browser-ui` (FR-011),
`password-generator`, `settings-screen`. They are not edited here because several do not pass strict
validation.

## Non-Goals

- Stopping Universal Clipboard (Handoff) from sending the value to other devices. macOS's
  `NSPasteboard` has no public "local only" option; the desktop app does not do this either.
- Clearing a value the user or another app replaced on the clipboard.
- Clearing after a crash or force quit (no process left to do it).

## Dependencies

- None hard.
- **Soft:** `vault-timeout` (timeout locks go through `lockVault()`, so they clear too),
  `password-history` and `enforce-master-password-reprompt` (their copies use the same service).

## Impact

- **Presentation/App:** new `ClipboardService` (`@MainActor`, owned by `AppContainer`); callers:
  `VaultBrowserViewModel.copy`, `PasswordGeneratorViewModel.copyToClipboard`. `lockVault()`,
  `signOut()` and `applicationWillTerminate` call `clearIfOwned()`.
- **Data:** the delay is a UI preference in UserDefaults (`clipboard.clearDelay`), not a secret.
- **Presentation:** a picker in `SettingsView`.
- **No new dependencies.**
- **Security review required:** yes (handling of copied secrets).

## Estimate

Ideal engineer-days, TDD included.

| Step | Scope | Estimate |
|---|---|---|
| 1 | `ClipboardService` with injected pasteboard and clock | 1 d |
| 2 | Migrate both callers; remove the generator's own code | 0.5 d |
| 3 | Delay setting and picker | 0.5–1 d |
| 4 | Clear on lock, sign-out, quit | 0.5 d |
| 5 | Security review, docs, CHANGELOG | 0.5 d |
| **Total** | | **3–3.5 d** |
