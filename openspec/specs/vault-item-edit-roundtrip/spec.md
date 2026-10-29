# vault-item-edit-roundtrip Specification

## Purpose
Edit items without losing data that other Bitwarden clients stored on them, encrypt with the key the server expects, and never overwrite a newer change made elsewhere.

## Requirements

### Requirement: Items with their own key are readable
When a synced item has its own wrapped `key`, the system SHALL unwrap it with the vault key (personal item) or the organization key (org item) and SHALL decrypt every field and every attachment of the item with that key. Items without their own key SHALL continue to decrypt with the vault or organization key. When the item key cannot be unwrapped, or a field does not decrypt with it, the system SHALL drop the item and count it as a failed item, and SHALL NOT retry with another key.

#### Scenario: Keyed login created by the browser extension
- **GIVEN** a login created by the Bitwarden browser extension with its own `key`, a password and one website
- **WHEN** Prizm syncs
- **THEN** the item SHALL be listed with its name, username, password and website decrypted

#### Scenario: Item without its own key
- **GIVEN** a personal login and an org login, neither with its own `key`
- **WHEN** Prizm syncs
- **THEN** both items SHALL be listed with all fields decrypted

#### Scenario: Fields encrypted with another key
- **GIVEN** an item with its own `key` whose name is encrypted with the vault key instead
- **WHEN** Prizm syncs
- **THEN** the item SHALL NOT be listed
- **AND** it SHALL be counted as a failed item

#### Scenario: Org login with its own key
- **GIVEN** an org login created by the Bitwarden browser extension with its own `key`, wrapped with the organization key
- **WHEN** Prizm syncs
- **THEN** the item SHALL be listed with its name, username, password and website decrypted with its own key

#### Scenario: Item key without integrity protection
- **GIVEN** an item whose own `key` is an encrypted string without a MAC (EncString type 0), or of a type Prizm does not support
- **WHEN** Prizm syncs
- **THEN** the item SHALL NOT be listed
- **AND** it SHALL be counted as a failed item

#### Scenario: Org login whose own key does not unwrap
- **GIVEN** an org login with its own `key` that does not unwrap with the organization key
- **WHEN** Prizm syncs
- **THEN** the item SHALL NOT be listed
- **AND** it SHALL be counted as a failed item

### Requirement: Editing an item preserves server fields Prizm does not edit
When the user saves an edit, the system SHALL send the item's last server record with only the fields Prizm edits replaced. It SHALL send back unchanged, without decrypting them: `login.fido2Credentials`, `login.autofillOnPageLoad`, `passwordHistory` on every item type, `archivedDate`, `sshKey.keyFingerprint`, and keys Prizm does not model inside `login`, `login.uris[]`, `card`, `identity`, `sshKey` and `fields[]`.

#### Scenario: Editing a login keeps its passkey
- **GIVEN** a login item holding a passkey created by the Bitwarden browser extension
- **WHEN** the user changes the item's username in Prizm and saves
- **THEN** the `PUT /api/ciphers/{id}` body SHALL contain the original `fido2Credentials` entries unchanged
- **AND** after the next sync the Bitwarden browser extension SHALL still list the passkey

#### Scenario: Editing an archived item
- **GIVEN** an item archived in the Bitwarden web vault
- **WHEN** the user changes its notes in Prizm and saves
- **THEN** the request SHALL contain the original `archivedDate`
- **AND** the item SHALL still be archived in the web vault

#### Scenario: Editing an SSH key item's name
- **GIVEN** an SSH key item with a private key, public key and fingerprint
- **WHEN** the user changes the item's name in Prizm and saves
- **THEN** the request SHALL contain the original encrypted `keyFingerprint`
- **AND** after the next sync the key SHALL still be shown in Prizm and in the Bitwarden browser extension

#### Scenario: Editing a card keeps its password history
- **GIVEN** a card item with a `passwordHistory` written by an official client
- **WHEN** the user changes the cardholder name in Prizm and saves
- **THEN** the request SHALL contain the original `passwordHistory` entries unchanged

### Requirement: Edits never send response-only keys
An update or create request SHALL NOT contain `data`, the legacy `login.uri`, or other keys that only appear in server responses.

#### Scenario: Response-only keys are not echoed
- **GIVEN** a stored server record that contains `data` and a legacy `login.uri`
- **WHEN** the user edits the item and saves
- **THEN** the request SHALL contain neither `data` nor `login.uri`

### Requirement: Saved URIs and passwords follow the official field rules
On every save and every create, the system SHALL set each URI's `uriChecksum` to the base64-encoded SHA-256 of the URI's UTF-8 bytes, encrypted with the item's effective key. It SHALL NOT send a URI entry without a value. It SHALL set `login.passwordRevisionDate` to the current time when the password is changed, added or cleared, and SHALL keep the stored value otherwise.

#### Scenario: Editing a URI refreshes its checksum
- **GIVEN** a login whose URI carries a `uriChecksum`
- **WHEN** the user changes that URI to `https://example.com` and saves
- **THEN** the saved `uriChecksum` SHALL decrypt to `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=`

#### Scenario: Unchanged URIs get a correct checksum too
- **GIVEN** a login with two URIs, one without a `uriChecksum`
- **WHEN** the user changes only the item's name and saves
- **THEN** both URIs SHALL carry a `uriChecksum` that matches their value

#### Scenario: Password unchanged
- **GIVEN** a login with a `passwordRevisionDate`
- **WHEN** the user changes only the username and saves
- **THEN** the request SHALL contain the original `passwordRevisionDate`

#### Scenario: Password changed
- **WHEN** the user changes a login's password and saves
- **THEN** the request SHALL contain a `passwordRevisionDate` set to the time of the save

#### Scenario: Password added
- **GIVEN** a login without a password
- **WHEN** the user adds a password and saves
- **THEN** the request SHALL contain a `passwordRevisionDate` set to the time of the save

#### Scenario: Password cleared
- **GIVEN** a login with a password
- **WHEN** the user clears the password and saves
- **THEN** the request SHALL contain a `passwordRevisionDate` set to the time of the save

#### Scenario: Creating a login writes checksums
- **WHEN** the user creates a login with the website `https://example.com`
- **THEN** the create request SHALL carry a `uriChecksum` for that website that decrypts to `EAaArVRs5qV39C9S3zO0z9ynVoWeZkuNfeMpsVDQnOk=`

#### Scenario: Website without a value
- **GIVEN** a login whose edit form has a website row left empty
- **WHEN** the user saves
- **THEN** the request SHALL contain no URI entry for that row

### Requirement: Editing an item uses its own key and never another key
When the edited item has its own wrapped `key`, the system SHALL encrypt the edited fields with that item's key and SHALL send the original `key` byte for byte. Items without their own key SHALL be encrypted with the organization key (org item) or the vault key (personal item) and SHALL be sent without `key`.

#### Scenario: Editing an item with its own key and an attachment
- **GIVEN** a login created by an official Bitwarden client with its own `key` and one attachment
- **WHEN** the user changes the item's name in Prizm and saves
- **THEN** the `PUT` body SHALL contain the original `key`
- **AND** after the next sync the item SHALL decrypt in Prizm and in the Bitwarden client
- **AND** the attachment record, its key and its file SHALL be unchanged on the server

#### Scenario: Org item without its own key
- **GIVEN** an org login without its own `key`
- **WHEN** the user edits and saves it
- **THEN** its fields SHALL be encrypted with the organization key
- **AND** the request SHALL contain no `key`

#### Scenario: Org item with its own key
- **GIVEN** an org login with its own `key` in a collection
- **WHEN** the user changes its notes in Prizm and saves
- **THEN** the `PUT` body SHALL contain the original `key`
- **AND** the edited fields SHALL be encrypted with the item's key, not with the organization key
- **AND** after the next sync the item SHALL still be in its collection, with the new notes, in Prizm and in the Bitwarden browser extension

#### Scenario: Org item moved to a folder, then edited
- **GIVEN** an org login in a collection
- **WHEN** the user moves it to a folder in Prizm, then renames it and saves
- **THEN** the `PUT` body SHALL be encrypted with the item's own key, or with the organization key when it has none
- **AND** the item SHALL keep its organization and collections
- **AND** the item SHALL stay in the chosen folder

### Requirement: A save fails instead of guessing a key
Before encrypting, the system SHALL check the key by decrypting the stored record's name with it. The save SHALL fail with an error, no request SHALL be sent, and the edit sheet SHALL stay open with the user's input when Prizm holds no server record for the item, the organization key is missing, the item key cannot be unwrapped, the key check fails, or the draft's organization differs from the stored record's. The system SHALL NOT fall back to another key.

#### Scenario: No stored server record
- **GIVEN** an item for which Prizm holds no server record
- **WHEN** the user saves an edit
- **THEN** the save SHALL fail with an error
- **AND** no request SHALL be sent

#### Scenario: Key check fails
- **GIVEN** an item whose stored name does not decrypt with the key Prizm would use
- **WHEN** the user saves an edit
- **THEN** the save SHALL fail with an error
- **AND** no request SHALL be sent

#### Scenario: Organization differs from the stored record
- **GIVEN** an item whose stored record belongs to one organization
- **WHEN** a save arrives for that item with another organization, or with none
- **THEN** the save SHALL fail with an error
- **AND** no request SHALL be sent

#### Scenario: Item key cannot be unwrapped
- **GIVEN** an item whose stored `key` does not unwrap with the vault or organization key Prizm holds for it
- **WHEN** the user saves an edit
- **THEN** the save SHALL fail with an error that tells the user to lock and unlock the vault and try again
- **AND** no request SHALL be sent

#### Scenario: Stored name without integrity protection
- **GIVEN** an item whose stored name is an encrypted string without a MAC (EncString type 0)
- **WHEN** a full save of the item arrives (anything other than a change of folder or favorite alone)
- **THEN** the save SHALL fail with the message that the item uses an older encryption format
- **AND** no request SHALL be sent

#### Scenario: Organization key missing
- **GIVEN** an org item whose organization key Prizm does not hold
- **WHEN** the user saves an edit or creates an item in that organization
- **THEN** the save SHALL fail with an error
- **AND** no request SHALL be sent, and nothing SHALL be encrypted with the vault key instead

### Requirement: Stored server records stay in memory as ciphertext
The system SHALL keep the last server record of each item only in memory, as received from the server, and SHALL NOT store keys or decrypted values with it. It SHALL replace all records on every sync, update a record from every server response that carries the item, and SHALL clear all records when the vault locks and when the user signs out. A sync or save that completes after the vault locked SHALL NOT add records. Records and their values SHALL NOT appear in logs.

#### Scenario: Lock clears stored records
- **GIVEN** a synced vault
- **WHEN** the user locks the vault
- **THEN** no stored server record SHALL remain

#### Scenario: Sync still running at lock
- **GIVEN** a sync is in progress
- **WHEN** the user locks the vault before the sync finishes
- **THEN** no stored server record SHALL remain after the sync finishes

#### Scenario: Sign-out clears stored records
- **GIVEN** a synced vault
- **WHEN** the user signs out
- **THEN** no stored server record SHALL remain

#### Scenario: Save completing after lock
- **GIVEN** a save is waiting for the server
- **WHEN** the user locks the vault before the server answers
- **THEN** no stored server record SHALL remain after the save finishes

#### Scenario: Sync finishing after lock does not refill the item list
- **GIVEN** a sync is waiting for the server
- **WHEN** the user locks the vault before the sync finishes
- **THEN** the item list SHALL stay empty after the sync finishes
- **AND** no item SHALL be decrypted from the sync's answer

### Requirement: Items Prizm cannot write back losslessly cannot be edited
When an item's stored server record is in a format Prizm cannot write back without loss (an encrypted blob, partial data, a shape the system cannot map, or a name in an old encryption format without a MAC), the system SHALL disable Edit and its keyboard shortcut for the item, and SHALL show a short plain-language note that explains why and where the item can be edited. The Edit button SHALL carry the note as its accessibility hint, and the detail pane SHALL show the same note as visible text.

#### Scenario: Blob item
- **GIVEN** an item whose stored record is an encrypted blob
- **WHEN** the user selects it
- **THEN** Edit SHALL be disabled
- **AND** the detail pane SHALL show the reason as a note, and the Edit button SHALL carry it as its accessibility hint

#### Scenario: Partial item
- **GIVEN** an item whose stored record has a `partialData` value that is not `null`
- **WHEN** the user selects it
- **THEN** Edit, the Item menu's Edit and its keyboard shortcut SHALL be disabled, and the detail pane SHALL show the reason
- **AND** a full save of the item (anything other than a change of folder or favorite alone) SHALL fail with that reason and no request SHALL be sent

#### Scenario: Item whose details are missing
- **GIVEN** a login, card, identity or SSH key item whose stored record has no `login`, `card`, `identity` or `sshKey` object, or `null` in its place
- **WHEN** the user selects it
- **THEN** Edit SHALL be disabled and the detail pane SHALL show that some of the item's details are missing
- **AND** a secure note without its `secureNote` object SHALL stay editable

#### Scenario: Item with a name in an old encryption format
- **GIVEN** an item whose stored name is an encrypted string without a MAC (EncString type 0)
- **WHEN** the user selects it
- **THEN** the item SHALL be listed and readable, and Edit and its keyboard shortcut SHALL be disabled
- **AND** the detail pane SHALL show "Prizm can't edit this item because it uses an older encryption format. Edit it in the Bitwarden web vault or browser extension."

#### Scenario: Legacy data alone
- **GIVEN** an item whose stored record has a `data` value without a `format_version` and a `partialData` of `null`, as the official server sends on every item (source-reviewed, not tested)
- **WHEN** the user selects it
- **THEN** Edit SHALL be enabled
- **AND** a save SHALL send neither `data` nor `partialData`

#### Scenario: Blocked item can still be starred and moved
- **GIVEN** an item that cannot be edited
- **WHEN** the user stars it or moves it to a folder
- **THEN** the change SHALL be sent through `PUT /api/ciphers/{id}/partial`
- **AND** the item SHALL stay blocked from editing

### Requirement: Saves identify the user they were encrypted for
Every cipher create request and every full update (`PUT /api/ciphers/{id}`) SHALL carry `encryptedFor` with the current user's id from the last sync, and SHALL NOT carry `encryptedByKeyId`. For an org create, `encryptedFor` SHALL be inside the `cipher` object. When that id is not known, the save SHALL fail with an error and no request SHALL be sent.

#### Scenario: Editing an item on Vaultwarden 1.37.4
- **GIVEN** the user is signed in to Vaultwarden 1.37.4
- **WHEN** the user changes an item's notes and saves
- **THEN** the `PUT /api/ciphers/{id}` body SHALL contain `encryptedFor` with the user's id
- **AND** the save SHALL succeed

#### Scenario: Creating an item on Vaultwarden 1.37.4
- **GIVEN** the user is signed in to Vaultwarden 1.37.4
- **WHEN** the user creates a login and saves
- **THEN** the create request SHALL contain `encryptedFor` with the user's id
- **AND** the item SHALL be created

#### Scenario: No account id from a sync
- **GIVEN** Prizm holds no user id from a sync
- **WHEN** the user saves an edit or creates an item
- **THEN** the save SHALL fail with an error
- **AND** no request SHALL be sent

### Requirement: Updates carry the server's last known revision
The system SHALL send the stored record's `revisionDate`, exactly as the server sent it, as `lastKnownRevisionDate` with every full update, and SHALL NOT send it on create. When the stored revision is missing or cannot be parsed, the save SHALL fail and no request SHALL be sent.

#### Scenario: Update carries the server's revision
- **GIVEN** an item whose stored record has `revisionDate` `2026-10-26T10:00:00.123456Z`
- **WHEN** the user edits it and saves
- **THEN** the request SHALL contain `lastKnownRevisionDate` `2026-10-26T10:00:00.123456Z`

#### Scenario: Create carries no revision
- **WHEN** the user creates an item
- **THEN** the create request SHALL NOT contain `lastKnownRevisionDate`

#### Scenario: Stored revision missing or unreadable
- **GIVEN** an item whose stored record has no `revisionDate`, an empty one, one that is not a date, or the epoch
- **WHEN** the user edits it and saves
- **THEN** no request SHALL be sent
- **AND** the edit sheet SHALL show "Prizm couldn't confirm which version of this item you are editing. Lock and unlock the vault, then try again." and keep the user's input

### Requirement: Edits based on an outdated copy are rejected, not applied
When the server answers an update with HTTP 400 and a message containing "out of date", or the draft's revision no longer matches the stored record, the system SHALL NOT overwrite the item and SHALL NOT retry. Edits made elsewhere within about two seconds of Prizm's copy may not be detected.

#### Scenario: Draft older than the stored record
- **GIVEN** an open edit sheet whose item was refreshed by a sync since the sheet opened
- **WHEN** the user saves
- **THEN** no update request SHALL be sent
- **AND** the conflict message SHALL be shown

#### Scenario: Server rejects an outdated copy
- **GIVEN** an item whose server copy changed after Prizm's last sync
- **WHEN** the user saves an edit and the server answers 400 with Vaultwarden's "The client copy of this cipher is out of date. Resync the client and try again." or the official server's "The item cannot be saved because it is out of date. To edit this item, first sync your vault, or log out and back in." (source-reviewed, not tested)
- **THEN** the conflict message SHALL be shown instead of the server's message
- **AND** the update SHALL NOT be sent again
- **AND** the server copy SHALL stay as it was

### Requirement: A conflict keeps the user's input and blocks Save until reload
On a rejected outdated edit, the system SHALL show "This item was changed on another device. Your changes were not saved. Reload to see the latest version, then make your changes again.", announce it to VoiceOver, start a sync, keep the edit sheet open with the user's input, and keep Save disabled until the user chooses "Discard my changes and reload".

#### Scenario: Item changed on another device
- **GIVEN** the user opened an item in Prizm and, more than two seconds later, the same item was changed in the Bitwarden browser extension
- **WHEN** the user saves their edit in Prizm
- **THEN** the server copy SHALL remain the version saved by the browser extension
- **AND** Prizm SHALL show the conflict message, announce it to VoiceOver, start a sync, and keep the edit sheet open with the user's input
- **AND** Save SHALL stay disabled

#### Scenario: Sync after the conflict fails
- **GIVEN** the edit sheet shows the conflict message
- **WHEN** the sync that follows the conflict fails
- **THEN** the sheet SHALL show the sync error and keep the user's input
- **AND** the first press of "Discard my changes and reload" SHALL start a new sync and SHALL NOT refill the sheet
- **AND** a press after that sync has succeeded SHALL refill the sheet

#### Scenario: Save from the Item menu while blocked
- **GIVEN** the edit sheet shows the conflict message
- **WHEN** the user chooses Save in the Item menu or presses ⌘S
- **THEN** no request SHALL be sent
- **AND** the sheet SHALL keep the user's input

### Requirement: Reload refills the sheet from the synced item
"Discard my changes and reload" SHALL refill the edit sheet with the item as synced, and only after a successful sync. When the item no longer exists after the sync, or is in the trash, the sheet SHALL say so and the action SHALL close the sheet.

#### Scenario: Reload after a conflict
- **GIVEN** the edit sheet shows the conflict message and the sync has finished
- **WHEN** the user chooses "Discard my changes and reload"
- **THEN** the sheet SHALL show the item as changed on the other device
- **AND** Save SHALL be enabled again

#### Scenario: Item deleted on another device
- **GIVEN** the edit sheet shows the conflict message
- **WHEN** the sync shows that the item was deleted on another device
- **THEN** the sheet SHALL show "This item is no longer available. It was deleted or moved on another device, or your access was removed."
- **AND** Save SHALL stay disabled, the reload action SHALL be named Close, and Close SHALL close the sheet

#### Scenario: Item moved to the trash on another device
- **GIVEN** the edit sheet shows the conflict message
- **WHEN** the sync shows that the item was moved to the trash on another device
- **THEN** the sheet SHALL show "This item is no longer available. It was deleted or moved on another device, or your access was removed."
- **AND** Save SHALL stay disabled, and Close SHALL close the sheet

### Requirement: Prizm's own changes do not cause a false conflict
After each of Prizm's own changes to an item (delete, restore, attachment, collection, favorite, move), the system SHALL store the server's current record of the item, from the response or a fetch, and SHALL move the cached revision to it only when the item's content is unchanged since Prizm read it. A failed fetch SHALL be logged and SHALL NOT fail the change. After an org save the revision SHALL be taken after the collection update.

#### Scenario: Delete, restore, then edit
- **GIVEN** an item the user moved to the trash and restored in Prizm
- **WHEN** the user edits the item and saves
- **THEN** the save SHALL succeed without a conflict

#### Scenario: Add an attachment, then edit
- **GIVEN** an item to which the user just added an attachment in Prizm
- **WHEN** the user edits the item and saves
- **THEN** the save SHALL succeed without a conflict

#### Scenario: Star or move, then edit
- **GIVEN** an item the user just starred or moved to a folder in Prizm
- **WHEN** the user edits the item and saves
- **THEN** the save SHALL succeed without a conflict

#### Scenario: Bulk move, then edit
- **GIVEN** several items the user just moved to a folder together in Prizm
- **WHEN** the user edits one of them and saves
- **THEN** the save SHALL wait for that item's refresh
- **AND** the save SHALL succeed without a conflict

#### Scenario: Org item edited twice
- **GIVEN** an org item in a collection that the user just edited and saved in Prizm
- **WHEN** the user edits it again and saves
- **THEN** the second save SHALL carry the revision taken after the collection update
- **AND** the save SHALL succeed without a conflict

#### Scenario: Item content changed elsewhere, then star, then edit
- **GIVEN** an item whose content another client changed after Prizm's last sync
- **WHEN** the user stars it in Prizm, then edits it and saves
- **THEN** the star SHALL be applied
- **AND** the save SHALL be rejected as a conflict, no update request SHALL be sent, and the other client's change SHALL stay on the server

#### Scenario: Members that are not content
- **GIVEN** an item whose server record differs from Prizm's copy only in its revision, trash state, folder, favorite flag, collections or attachments
- **WHEN** one of Prizm's own changes refreshes the record
- **THEN** the cached revision SHALL move to the fetched record's revision

#### Scenario: Only the revision changed
- **GIVEN** an item that Prizm moved to the trash, and a server that changes the revision of a trashed item and nothing else
- **WHEN** the user restores it, edits it and saves
- **THEN** the save SHALL succeed without a conflict

#### Scenario: Refresh fails
- **GIVEN** the item fetch after one of Prizm's own changes fails
- **WHEN** the change itself succeeded
- **THEN** the change SHALL count as successful and no error SHALL be shown
- **AND** the failure SHALL be logged without item contents

### Requirement: A failed collection update after a saved edit is reported separately
When an org item's update succeeds and the following collection update fails, the system SHALL show "Your changes were saved, but the collection change failed. Try again.", keep the edit sheet open, and SHALL NOT reject the retry as a conflict.

#### Scenario: Collection update fails
- **GIVEN** the user changed an org item's notes and collections
- **WHEN** the item update succeeds and the collection update fails
- **THEN** the sheet SHALL show the partial-save message
- **AND** saving again SHALL NOT show the conflict message

### Requirement: A save is sent once and never completes after lock
The system SHALL send at most one request per press of Save, also when Save is clicked twice quickly. Saves of the same item SHALL run one after another. When the vault locks while a save is in progress, the system SHALL discard the server's response without decrypting it, updating stored records or reporting success.

#### Scenario: Double-click on Save
- **WHEN** the user clicks Save twice in quick succession
- **THEN** exactly one update request SHALL be sent

#### Scenario: Lock during a save
- **GIVEN** a save request is in progress
- **WHEN** the user locks the vault before the response arrives
- **THEN** the response SHALL NOT be decrypted or stored
- **AND** after the next unlock the item SHALL show either the old or the new version, never a mix
- **AND** no decrypted item SHALL be added to the item list

#### Scenario: Saves of one item run one after another
- **GIVEN** a write to an item, such as a star or a save, is in progress
- **WHEN** the user saves an edit of the same item
- **THEN** the save SHALL wait until the first write has finished
- **AND** it SHALL be checked against the item's revision after that write
