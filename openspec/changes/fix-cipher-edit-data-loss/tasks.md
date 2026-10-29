# Tasks

Estimates are ideal engineer-days. Write a failing test first for each code task (§IV); a task that
names a failing test is done only when that test passes. Ship this change before the possible
follow-up changes `macos-autofill-credential-provider`, `passkey-support` and
`per-item-key-on-create` (the proposal lists them). Server checks run against a Vaultwarden test
server; the official Bitwarden server is source-reviewed, not tested. Record every result in
design.md "Server behavior" with the image digest, the date and, where relevant, the browser
extension version and the tree hash of `Prizm/` that was tested.

## 0. Fixtures

Prerequisites, not tasks of this change: a Vaultwarden test server pinned by digest (1.37.4, and
1.37.3 for the checks that differ), and a keyed fixture authored on it with the Bitwarden browser
extension 2026.10.0 (a keyed login with a passkey, password history, two URIs and an attachment, an
archived item, an SSH key item, a keyed org login, and unkeyed control items). design.md "Server
behavior" records the digests, versions and dates.

- [x] 0.1 Capture a scrubbed `/api/sync` golden fixture (including `profile.organizationsNew[].name`) and the stale-update 400 response into `PrizmTests/Fixtures/`.
- [x] 0.2 Synthetic ciphers with real crypto for the cases the keyed fixture lacks: an org item without its own key, item keys that do not unwrap or have the wrong length, fields under another key; built with section 3.

## 1. Server behavior (1–1.5 d)

- [x] 1.1 E1, `encryptedFor` (tested on Vaultwarden 1.37.4, 2026-10-26): Prizm's create and update bodies have no `encryptedFor` and get HTTP 422 on Vaultwarden 1.37.4 (Rocket's generic body, no Bitwarden error message); the same update body plus `encryptedFor` = profile id gets 200. Vaultwarden 1.37.3 accepts Prizm's bodies.
- [x] 1.2 E0 and E3: does the keyed fixture load in today's Prizm, and does the extension key items with the flag switched on? Record E0 and the resulting D0 blocker status in design.md.
- [x] 1.3 E6: record the timestamp shapes the server emits (`revisionDate`, `creationDate`, `deletedDate`, `archivedDate`, password history and passkey dates) from the 0.3 golden fixture. No Prizm test in this task.
- [x] 1.4 On 1.37.4, with `encryptedFor` in every request body: E2 (update without `key` on the keyed fixture: is `key` cleared, does the attachment still open?), E4 (update without `archivedDate`), E5 (stale `lastKnownRevisionDate`; the competing edit is made at least 2 s after the reference read), E7 (does `revisionDate` change after soft delete, restore, attachment add and delete, `/collections`, favorite, single and bulk move?), E8 (SSH item without `keyFingerprint`), E9 (extension opens a keyed item with a wrong `uriChecksum`).
- [x] 1.5 On 1.37.3: E1 with `encryptedFor`, E4, and an E5 message check.

## 2. `encryptedFor`, wire model and record store (1.75–2.5 d)

- [x] 2.1 Failing test: create and full update bodies (personal and org; for the org create inside `cipher`) carry `encryptedFor` = the sync profile id and no `encryptedByKeyId`; `/partial` and `/collections` requests do not. With no profile id the save fails and no request is sent. The id is cleared on lock and sign-out.
- [x] 2.2 Implement design.md D5 in its own commit, independent of `RawCipherStore`, so it can be cherry-picked onto `main` on its own.
- [x] 2.3 Failing tests for `JSONValue`: integers and doubles stay apart, `null` stays distinct from absent, nesting and Unicode survive.
- [x] 2.4 Wire model (design.md D1): typed `uriChecksum`, `passwordRevisionDate` and encode-only `lastKnownRevisionDate`; `fido2Credentials`, `passwordHistory` and `archivedDate` as `JSONValue`; unknown keys carried at `login`, `uris[]`, `card`, `identity`, `sshKey` and `fields[]`; response-only keys dropped at decode. New initializer parameters get defaults. Failing tests first: a round trip of a fixture with every field type compares JSON semantically, and no never-sent key appears in the encoded output.
- [x] 2.5 `MockPrizmAPIClient` captures the sent `RawCipher` for every create and update.
- [x] 2.6 Failing tests for the store: one instance shared by sync and update; lock and sign-out empty it; a sync running at lock does not refill it (generation token); the store and `RawCipher` print no values.
- [x] 2.7 Implement `RawCipherStore` and its hooks: sync `replaceAll` before `populate`, `upsert` after create and update, `remove` on permanent delete, `clear` in `clearVault()`, one instance from `AppContainer`. `update()` does not yet use the stored record (that ships with 3.7).
- [x] 2.8 Canary test: fails on a top-level key in the golden fixture or the official-server-shaped fixture (labelled "source-reviewed, not tested") that is neither modelled, preserved nor known response-only. Snapshot test of the unknown keys at each nested level. At runtime, unknown top-level key names are logged once per sync at `.info`.
- [x] 2.9 Fix the `RawURI.match` comment: 0 Domain, 1 Host, 2 StartsWith, 3 Exact, 4 Regex, 5 Never, null default.

## 3. Effective-key read and write, field rules (3–4 d)

Commit order: 3.1-3.3, 3.8, then 3.4-3.7 in one commit, 3.9, 3.10. 3.8 comes before 3.7 so that no item with its own key is saved without correct URI checksums (E9).

- [x] 3.1 Failing test with real crypto: a keyed item's fields decrypt with its own key; a keyed item whose fields use another key is dropped and counted, with no retry; keyless personal and org items decrypt as before.
- [x] 3.2 Implement design.md D0 (`CipherMapper.effectiveKeys`) together with the edit guard (D4) and its temporary "has its own key" reason, in one commit: Domain edit-block reason on `VaultItem`, Edit button and shortcut disabled, note in the detail pane, also set as the Edit button's accessibility hint (whether VoiceOver reads the hint of a disabled button is a hand check in 5.4). §VII comment on key selection.
- [x] 3.3 Failing tests for the guard's lasting reasons: `data` with a format version, `partialData`, an unmappable shape, and a type-0 name (`legacyEncryption`). `data` alone does not block.
- [x] 3.4 Failing tests, five-case key matrix with real crypto: keyed and keyless, personal and org, and a wrong key that fails. `request.key` is byte-identical to the stored `key`, and absent for keyless items.
- [x] 3.5 Failing tests, fail closed with no request sent: no stored record, missing org key (update and create), item key unwrap failure, key check failure, organization differs from the stored record. The sheet keeps the user's input.
- [x] 3.6 Failing tests, overlay: from the fixture, edit only the username; `fido2Credentials`, `passwordHistory`, `archivedDate`, `autofillOnPageLoad` and nested unknown keys are byte-identical in the request. Same for `passwordHistory` on card, identity, secure note and SSH key items, and `keyFingerprint` on an SSH item.
- [x] 3.7 Implement design.md D2 (overlay, effective key, key check, typed `VaultError` cases and messages). This removes the temporary guard reason; a test shows a keyed item is editable again. Update the existing `update` tests in `VaultRepositoryImplTests` and the UI-test seeding (`AppContainer.seedUITestRecords` with `UITestFixtures.rawRecords`, called from `PrizmApp`) to seed stored records. §VII comments.
- [x] 3.8 `uriChecksum` (design.md D3), failing tests first: every URI on every save and create decrypts to base64(SHA-256(uri)); the two published vectors, the empty string, and a known answer from the extension-written fixture; no URI entry without a value is sent.
- [x] 3.9 `passwordRevisionDate` (design.md D3), failing tests first: set when the password is changed, added or cleared; kept otherwise.
- [x] 3.10 Regression test: moving an org item to a folder (single move through `/partial`, bulk move through `/ciphers/move`) keeps its organization and collections, and the next edit uses the org key. The cause was fixed by `fix-favorite-and-folder-partial-updates`; no code change expected.

## 4. Stale-write protection and conflict UX (3–4 d)

As built, the commits came in this order: the revision parse and refusal (4.0, 4.1), the local
pre-check and conflict detection (4.2, 4.3), the vault browser's resync and sheet hosting (4.7), the
lock fence for saves and sync results (4.5), the edit sheet's conflict state and reload (4.6, 4.8),
the per-item queue (4.5), the banner (4.9), the revision refresh (4.4) and the revision in the
update body (4.1); the save races came before the refresh, so the refresh was written inside the
queue and the lock fence, and the update body started carrying `lastKnownRevisionDate` only in the
last of these code commits, once the stored revision was kept current after Prizm's own operations,
so no commit in the series makes those operations look like conflicts.

- [x] 4.0 Failing test: which `revisionDate` shapes recorded in 1.3 `CipherMapper.iso8601` parses and which fall back to epoch 0. As built, one shared parser without the epoch fallback reads three to seven fractional digits, no fraction and an offset, serves both the item's date and the pre-check (4.2), and a stored revision it cannot read refuses the save (4.1).
- [x] 4.1 Failing tests: every full update sends the stored record's raw `revisionDate` string as `lastKnownRevisionDate`; create never sends it; a missing or unparsable stored revision fails the save and sends nothing. Then implement.
- [x] 4.2 Failing test: the local pre-check throws `VaultError.conflict` without a network call when the draft's revision differs from the stored record's. Then implement.
- [x] 4.3 Failing tests: HTTP 400 containing "out of date" (case-insensitive) maps to `VaultError.conflict`, with the Vaultwarden and official texts pinned; other errors fall through to the server's message. Then implement (`server-error-texts` delta).
- [x] 4.4 Revision refresh (design.md D6), failing tests first: a single-cipher `GET /api/ciphers/{id}`; `restoreCipher` returns the cipher; the stored record is refreshed after soft delete, restore, attachment add and delete, collection change, favorite, single and bulk move; a failed refresh is logged and the operation still succeeds; a refresh that finds the item's content changed leaves the cached revision, so the next save is a conflict (a record that differs only in revision, trash state, folder, favorite or collections still moves it); after an org save the revision is taken after `/collections`; a failed `/collections` shows the partial-save error and the retry does not report a conflict.
- [x] 4.5 Failing tests with a controllable mock, save races: writes to one item id run one after another; a save that completes after lock is discarded (no store update, no decrypt, no success callback); a sync that finishes after lock changes nothing. Then implement with the store's generation as a synchronous, lock-protected counter that `clearVault()` invalidates first, the session token the sync hands to `populate`, and a per-item queue (queued, never rejected; a queued save runs the pre-check). A sync that lands while a save is in flight is not ordered against it; the worst case is one conflict and a reload (design.md Risks).
- [x] 4.6 `ItemEditViewModel`, failing tests first: `isSaving` set synchronously (double click sends one request); on `.conflict` the conflict state, the `onConflict` callback, Save (button and ⌘S) disabled, input kept, `clearDraft()` not called.
- [x] 4.7 `VaultBrowserViewModel` gets `SyncUseCase` and `resyncAfterConflict()`, tolerating `SyncError.syncInProgress`; wiring in `AppContainer` and `PrizmApp.makeEditViewModel`. Tests.
- [x] 4.8 "Discard my changes and reload" refills draft and original in place, only after a successful sync; a failed sync shows the error, the first press of reload syncs again and a press after a successful sync refills; an item gone after the sync turns reload into Close. Tests.
- [x] 4.9 `ItemEditView`: the error banner gets the reload button and the sync status line (Design System tokens); the sheet announces the displayed banner message (the conflict message or the item-gone note), the sync status ("Synced" or the sync error, not "Syncing…") and each reload, instead of relying on the earlier announcement of every `saveError`; the banner icons are hidden from VoiceOver and the reload button follows the message in reading order. UI journeys cover the banner, reload and an item that is gone.

## 5. Hardening, verification and delivery (1–1.5 d)

- [x] 5.1 A security review and a code review of the whole diff: a deep code review in slices of at most 50 files; a security review of key selection on read and write, of the stored records holding no plaintext or keys, and of logs; and one independent review that does not share the author's notes. Critical and warning findings are fixed in the commit they belong to; every other finding is fixed or dismissed with a reason.
- [x] 5.2 CHANGELOG, four flat `- Fix:` bullets at the top of `## Unreleased`:
  - editing an item no longer deletes data that other Bitwarden apps added to it (passkeys, password
    history, archived state, SSH key fingerprint)
  - items that other Bitwarden apps encrypted with their own key can be read and edited, and keep
    their key
  - saving an edit that is based on an outdated copy is rejected instead of overwriting a newer
    change made in another app
  - creating and editing items works on Vaultwarden 1.37.4, which answered error 422 before

  The last bullet also says that items damaged by earlier Prizm versions cannot be repaired and that
  password history is kept on edit but not yet appended.
- [x] 5.3 Every commit of the series was built and tested with the full `PrizmTests` target: 740
  tests at the first commit, 1092 at the tip, all green; one unlock test failed once at an early
  commit and passed on the rerun. Tip: unit tests green and a Release build succeeds.
  `encryptedFor` (2.2) alone on top of the PR base: green, 756 tests. D0 with the edit guard (3.2) on
  top of `encryptedFor` alone: the commit applies cleanly but the test target does not compile,
  because the guard's tests read the golden fixture through the fixture reader that the fixtures
  commit and the wire-model commit add. With those two commits and `encryptedFor` beneath it, the
  full target is green (804 tests). The UI journeys of the edit sheet (conflict banner, reload, item
  gone) passed (11 tests). The full UI suite, run once on the tip: 97 tests, 75 passed, 21 skipped,
  1 failed. The failure is `AccessibilityLabelTests.testSettingsGearHasLabel`: with a very large
  main window the settings button moves into the toolbar overflow. The same test fails the same way
  on the base branch, so it is not caused by this change.
- [x] 5.4 Manual check on Vaultwarden 1.37.4 with the fixture (plus a second collection and a keyed
  organization item), on 2026-10-29, on exactly the tested `Prizm/` tree. Prizm was driven by a UI
  journey. The other client was a second API client that sends full updates shaped like an official
  client's and reads the full sync back, decrypted; the browser extension and the web vault pages
  were not used. Results:
  - Passkey, password history and both websites stay intact after Prizm edits the notes; the
    attachment record, its key and its file stay intact (the second client downloads the file,
    checks its MAC and decrypts it; opening it in the extension was not run). A file written by an
    official client does not open in Prizm and a file uploaded by Prizm does not open in the
    extension: known gaps; a possible follow-up change, `fix-attachment-file-format`, would cover them.
  - An archived item stays archived. An SSH key keeps its private key, public key and fingerprint.
  - Organization items with and without their own key edit with organization and collection intact;
    the item without a key was created in the web vault with per-item keys turned off on the server
    and was edited twice.
  - Soft delete, restore, favorite, move to a folder (also by drag and drop, with the drag done by
    hand), attachment add and delete, and a collection change each give no false conflict.
  - A competing edit by the second client is rejected with the conflict message, the other edit
    stays on the server, the reload shows it and the next save succeeds (on two items). A competing
    edit made before a favorite, with no sync in between, still shows the conflict on the next edit.
  - Lock during a save, with the server's answer slowed down, leaves the old or the new version,
    never a mix; a lock and unlock lists every item and every earlier edit is on the server.
  - Request log of the run: every one of the 25 Prizm updates carries `encryptedFor` and a real
    `lastKnownRevisionDate`; none was answered 422; each refused update was followed by a successful
    one; every item with its own key kept one unchanged key.
  - Smoke check on 1.37.3: the keyed passkey login was edited once with everything intact, one
    conflict was detected, and the reload and the next save worked.

  Not run: whether VoiceOver announces the conflict, and whether it reads the accessibility hint of
  the disabled Edit button of a blocked item (the note in the detail pane is the visible reason and
  the gap stays in Known gaps); whether the extension opens the attachment. The results are listed
  in the "Live verification" table of design.md, which is added when the change is archived.
- [x] 5.5 No cell of "Server behavior" in design.md is left to fill; check that no text claims more than was tested (the change, the CHANGELOG lines and the PR text).
- [x] 5.6 `openspec validate fix-cipher-edit-data-loss --type change --strict` and `/opsx:verify`.
