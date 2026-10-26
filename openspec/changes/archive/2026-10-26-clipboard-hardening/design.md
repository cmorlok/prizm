# Design

## Context

Sources: `clients` at HEAD 2026-10-23.

**Delay options and default.**
- `ClearClipboardDelay`: never, tenSeconds, twentySeconds, thirtySeconds, oneMinute, twoMinutes,
  fiveMinutes (`libs/common/src/autofill/constants/index.ts:66-74`).
- Default five minutes (`libs/common/src/autofill/services/autofill-settings.service.ts:126-131, 371-373`).
- Desktop Settings lists all seven (`apps/desktop/src/app/accounts/settings-dialog.component.ts:256-264`).

**Clear timer.** `SystemService.clearClipboard` schedules one app-wide task; a new copy replaces the
previous task. When it fires, it clears only if the clipboard still holds the copied value
(`libs/common/src/platform/services/system.service.ts:29-59`). The desktop renderer starts it on the
`copiedToClipboard` message (`apps/desktop/src/app/app.component.ts:306`), not in any view.

**Clear on lock and log out.** `LockService` calls `systemService.clearPendingClipboard()` after
wiping decrypted state (`libs/unlock/src/lock.service.ts:137-140`). The desktop app does the same on
`loggedOut` and `locked` (`apps/desktop/src/app/app.component.ts:210, 239`). `clearPendingClipboard`
runs the pending clear immediately, with the same "still our value" check (`system.service.ts:82-87`).

**Clear on quit.** Desktop main process: on `before-quit`, if the clipboard still equals the last
value Prizm wrote, write an empty string (`apps/desktop/src/platform/main/clipboard.main.ts:10-20`).

**History exclusion.** Every desktop copy is written with `password: true` unless `allowHistory`
(`apps/desktop/src/platform/services/electron-platform-utils.service.ts:127-145`). On macOS that
calls arboard's `exclude_from_history()` (`apps/desktop/desktop_native/core/src/clipboard/arboard_backend.rs:44-53`).
The exact pasteboard types arboard writes are not in the checkout; the audit assumed
`org.nspasteboard.ConcealedType` (task 1.1 confirms).

**Prizm today.**
- `VaultBrowserViewModel.writeConcealed` and `copy` (`Presentation/Vault/VaultBrowserViewModel.swift:215-250`):
  concealed marker, 30 s clear, only if unchanged. The task is owned by the view model and cancelled
  in its `deinit` (`:170-173`).
- `PasswordGeneratorViewModel.copyToClipboard` (`Presentation/Vault/Edit/PasswordGeneratorViewModel.swift:83-99`):
  no marker, own 30 s task, cancelled in `deinit` (`:59-61`).
- `lockVault()` (`App/PrizmApp.swift:477-494`) and `signOut()` (`:458`) do not touch the clipboard.
- No `applicationWillTerminate` handling of the clipboard.

## Goals / Non-Goals

**Goals**
- Every value Prizm copies is concealed and cleared on the configured schedule, whatever happens to
  the view that copied it.
- A copied secret does not outlive the unlocked session, unless the user chose "Never".

**Non-Goals:** see proposal.md.

## Decisions

### D1. One `ClipboardService`

```swift
@MainActor protocol ClipboardService {
    func copy(_ value: String)   // concealed, schedules the clear
    func clearIfOwned()          // clears now if the clipboard still holds our value
}
```

`ClipboardServiceImpl` takes an `NSPasteboard` wrapper, a clock and the delay setting. It keeps the
last copied value's `changeCount` (from `NSPasteboard.changeCount`) rather than the string, and
clears only if `changeCount` is unchanged. This avoids holding the secret string for the whole delay
and is the same "still our value" rule as official clients.

It is created once by `AppContainer` and injected into `VaultBrowserViewModel` and
`PasswordGeneratorViewModel`. The `writeConcealed` helper moves into it.

**Rejected alternative:** keep a timer per view model and only fix `deinit`. Every new copy path
would need to remember the same rules, which is how the generator went wrong.

### D2. Delay setting

`ClipboardClearDelay`: `.never`, `.seconds(10|20|30)`, `.minutes(1|2|5)`. Stored in UserDefaults as
`clipboard.clearDelay`, read at each copy. Default 30 s: Prizm's current behaviour and FR-011, and
stricter than the official 5 min.

### D3. Clear on lock, sign-out and quit

`lockVault()` and `signOut()` call `clipboardService.clearIfOwned()` after clearing keys.
`NSApplicationDelegate.applicationWillTerminate` calls it too. With delay `.never`, lock and quit
still clear: "Never" refers to the timer, not to the end of the session. (Official clients behave the
same way: `clearPendingClipboard` only runs if a clear was scheduled, so with "never" they do not
clear on lock. Prizm is stricter here; Open Question 1.)

### D4. Settings UI

A "Clear clipboard" picker in Settings → Security, with the seven options. Labels from the list
above; VoiceOver reads the label and the selected value. Design tokens only.

## Risks / Trade-offs

- **[Low] `changeCount` differs from a value comparison.** If the user copies the same text again
  from another app, official clients would clear it (same value) and Prizm will not (new count).
  Not clearing a value the user copied elsewhere is the safer mistake.
- **[Low] Quit clearing is best effort** if the app is killed. Documented.

## Open Questions

1. With "Never", should lock and quit still clear (stricter than official)? Lean: yes.
2. Confirm that arboard's `exclude_from_history()` writes `org.nspasteboard.ConcealedType` on macOS
   (task 1.1). If it also writes `org.nspasteboard.TransientType`, add it. **Answered 2026-10-26:** arboard 3.6.1
   writes only `org.nspasteboard.ConcealedType` (empty string), the same as Prizm.
