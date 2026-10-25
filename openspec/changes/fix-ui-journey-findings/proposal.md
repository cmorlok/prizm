# Proposal

## Why

**Criticality:** P1 (High: one security bug, one crash, two accessibility bugs)

The UI journeys brought into the test target by `fix-ui-test-target` found five app bugs. Each was
confirmed in a UI run, and the arrow keys and VoiceOver also by hand. They are small, so they are
fixed together here, one commit per bug, so each can be reviewed or cherry-picked on its own.

1. **Locking leaves the decrypted item in memory (§III).** `RootViewModel.lockVault()` clears the
   vault store and the key caches, but not `VaultBrowserViewModel`, which lives as long as the app.
   The selected item, the listed items, folder and collection names and the search term stay in
   memory on the unlock screen, and Item → Edit stays enabled. Signing out has the same gap.
2. **⌘N in Trash crashes the app.** Spec `list-column-header` says the "+" button is not rendered
   in Trash, so ⌘N has no effect there. The button is always rendered. The view model's guard,
   which resets `createItemType` in its own `didSet`, does not take effect on a `@Published`
   property, so ⌘N in Trash sets it, and the app crashes.
3. **VoiceOver reads stale values (§VIII).** After Reveal, VoiceOver reads "bullet bullet …" while
   the password is visible. A selectable text (`.textSelection(.enabled)`) exposes the value it was
   created with, and SwiftUI does not update it. The same happens to the generator preview and to
   field values after switching to another item, where VoiceOver reads the previous item's
   username.
4. **Arrow keys do not move the selection (§VIII).** A click on a row selects it, but does not give
   the list keyboard focus: `.onMove` (sidebar) and `.draggable` (item list) make SwiftUI handle the
   click itself. The arrow keys go to the window, or to the list that had focus before.
5. **"Sign Out…" uses ⌘⇧Q,** the system's Log Out shortcut. A UI test that sent it logged the
   developer out of macOS.

## Origin of the current behaviour

| Bug | Origin | Evidence |
|---|---|---|
| 1 Lock keeps browser state | Oversight | `lockVault()` and `signOut()` never touch `vaultBrowserVM`; present since `c95e172` (v1 release prep, the squashed first public state) |
| 2 ⌘N in Trash | Implementation gap | Spec requires the "+" to be absent in Trash (`da579ab`); the toolbar renders it always, and the `didSet` guard is ineffective |
| 3 Stale VoiceOver values | Platform behaviour, unnoticed | `.textSelection(.enabled)` texts since `c95e172`; no test read the accessibility value |
| 4 Arrow keys | Side effect | `.onMove` in the sidebar (`a09a2eb`) and `.draggable` on item rows (`61398f1`, folder drag and drop) |
| 5 ⌘⇧Q | Unexplained choice | Added in `c95e172` without a stated reason; no spec mentions it |

## What Changes

1. `VaultBrowserViewModel.clearSession()` drops all decrypted state and closes the session until
   the vault is shown again; refresh results and late saves are dropped meanwhile. `lockVault()`
   and `signOut()` call it first. Copy commands check that the vault is unlocked.
2. The "+" button and its ⌘N shortcut are not rendered in Trash. `createItemType` checks Trash in a
   setter that works.
3. The masked field, field rows and the generator preview set `.accessibilityValue` to the shown
   text.
4. The sidebar and the item list take keyboard focus on every click on a row.
5. "Sign Out…" has no keyboard shortcut, as "Log out" in the official Bitwarden desktop client.

## Non-Goals

- Changing what is selectable or draggable.
- Announcing a revealed value or a new generator value to VoiceOver as it changes.
- A new shortcut for Sign Out (see design D5, open question).

## Dependencies

- **Requires** `fix-ui-test-target`: its journeys carry the markers this change removes.

## Impact

- **App:** `App/PrizmApp.swift`, `Presentation/Vault/VaultBrowserViewModel.swift`,
  `Presentation/Vault/VaultBrowserView.swift`, `Presentation/Vault/Sidebar/SidebarView.swift`,
  `Presentation/Vault/ItemList/ItemListView.swift`, `Presentation/Components/MaskedFieldView.swift`,
  `Presentation/Components/FieldRowView.swift`, `Presentation/Vault/Edit/PasswordGeneratorView.swift`.
- **Unit tests:** lock and sign-out clear the browser state; `clearSession()`; Trash guard.
- **UI tests:** the five known-bug markers become plain assertions, plus checks for the field row
  and generator values.
- **User-visible:** yes, CHANGELOG entries. "Sign Out…" loses its shortcut.
- **Security review:** yes, for bug 1.

## Estimate

| # | Step | Ideal days |
|---|---|---|
| 1 | Lock and sign-out clear browser state | 0.5 |
| 2 | ⌘N and "+" in Trash | 0.25 |
| 3 | Accessibility values | 0.25 |
| 4 | Arrow keys | 0.25 |
| 5 | Sign Out shortcut | 0.1 |
| 6 | Verify, review | 0.25 |
