# vault-browsing-parity Specification

## Purpose
Browsing in Prizm works as in the official Bitwarden clients: multi-word search over the same fields, "No Folder" and "My Vault" views, folder and collection trees that keep case-different names apart, natural sort order, and editing of custom fields (add, rename, remove, reorder).

## Requirements

### Requirement: Multi-term, diacritic-insensitive search
The system SHALL split the search query on whitespace and SHALL show an item only when every term occurs, ignoring case and diacritics, in at least one of the item's search targets. Search targets SHALL be: name and notes for every item; username and every URI for logins; cardholder name, brand and the last four digits of the number (never the full number) for cards; first name, last name, email and company for identities; and the key fingerprint for SSH keys.

#### Scenario: Terms in different fields
- **GIVEN** a login named "GitHub" with username "alice@work.example"
- **WHEN** the user searches for "github work"
- **THEN** the login SHALL appear in the results

#### Scenario: Diacritics ignored
- **GIVEN** an identity with last name "Müller"
- **WHEN** the user searches for "muller"
- **THEN** the identity SHALL appear in the results

#### Scenario: Notes are searched
- **GIVEN** a secure note whose notes contain "router admin"
- **WHEN** the user searches for "router"
- **THEN** the note SHALL appear in the results

#### Scenario: Card by last four digits
- **GIVEN** a Visa card whose number ends in 4242
- **WHEN** the user searches for "4242"
- **THEN** the card SHALL appear in the results

#### Scenario: Card number prefix is not searched
- **GIVEN** a card whose number is 4111 1111 1111 1111
- **WHEN** the user searches for "4111"
- **THEN** the card SHALL NOT appear in the results

#### Scenario: Highlighting
- **GIVEN** a login named "Müller GitHub"
- **WHEN** the user searches for "muller git"
- **THEN** "Müller" and "Git" SHALL be bold in the row
- **AND** a match only in notes that the row does not show SHALL have no highlight

### Requirement: No Folder and My Vault views
The sidebar SHALL offer, when the user has at least one folder, a "No Folder" row at the end of the Folders section, listing active items that have no folder, and, when the user belongs to at least one organization, a "My Vault" row at the start of the Organizations section, listing active items that belong to no organization. Each row SHALL show an item count like every other sidebar row. When the selected row is hidden, the selection SHALL become All Items.

#### Scenario: Items without a folder
- **GIVEN** three personal items without a folder and two in folder "Work"
- **WHEN** the user selects "No Folder"
- **THEN** the list SHALL show exactly the three items without a folder

#### Scenario: Personal items only
- **GIVEN** a user with personal items and items in one organization
- **WHEN** the user selects "My Vault"
- **THEN** the list SHALL show only items that belong to no organization

#### Scenario: No folders at all
- **GIVEN** the user has no folders
- **THEN** the sidebar SHALL show no "No Folder" row

#### Scenario: Last folder deleted while No Folder is selected
- **GIVEN** "No Folder" is selected and the user has one folder
- **WHEN** the user deletes that folder
- **THEN** the "No Folder" row SHALL disappear and All Items SHALL be selected

### Requirement: Case-sensitive nesting of folders and collections
When building the folder and collection trees from "/"-separated names, the system SHALL treat path segments that differ only in case as different nodes, and SHALL show every folder even when two have identical names. A missing parent SHALL still appear as a non-selectable grouping node without an item count.

#### Scenario: Two folders differing in case
- **GIVEN** folders named "Work/A" and "work/B"
- **WHEN** the sidebar shows the folder tree
- **THEN** "A" and "B" SHALL appear under two separate parent nodes, "Work" and "work"

#### Scenario: Identical folder names
- **GIVEN** two folders both named "Work"
- **WHEN** the sidebar shows the folder tree
- **THEN** both SHALL appear

### Requirement: Natural sort order
Item lists SHALL be sorted by name with locale-aware, numeric comparison, and logins with equal names SHALL be ordered by username.

#### Scenario: Numbers in names
- **GIVEN** items named "Server 10" and "Server 2"
- **WHEN** the list is shown
- **THEN** "Server 2" SHALL come before "Server 10"

#### Scenario: Same name, different usernames
- **GIVEN** two logins named "Google" with usernames "zoe" and "adam"
- **WHEN** the list is shown
- **THEN** the login with username "adam" SHALL come first

### Requirement: Custom fields can be added, renamed, removed and reordered
In the edit sheet, the system SHALL let the user add a custom field of type text, hidden, checkbox or linked (linked only for logins, cards and identities), rename a field, remove a field, and move a field up or down. The type of an existing field SHALL NOT be changeable. The saved item SHALL contain the fields in the order shown.

#### Scenario: Add a hidden field
- **GIVEN** a login with no custom fields
- **WHEN** the user opens the edit sheet, adds a hidden field named "PIN" with value "1234", and saves
- **THEN** the item SHALL show a masked custom field "PIN"
- **AND** the official `bw` CLI SHALL list the same field

#### Scenario: Reorder with VoiceOver
- **GIVEN** an item with custom fields "Question 1" and "Question 2"
- **WHEN** a VoiceOver user activates "Move Question 2 up"
- **THEN** "Question 2" SHALL become the first field
- **AND** the announcement text SHALL be "Question 2 moved to position 1 of 2"

#### Scenario: Remove a field and cancel
- **GIVEN** an item with a custom field "Old"
- **WHEN** the user removes "Old" in the edit sheet, then cancels and confirms Discard
- **THEN** the item SHALL still have the field "Old"

#### Scenario: Rename keeps what Prizm does not show
- **GIVEN** a field "Old name" that carries data from another client Prizm does not model
- **WHEN** the user renames it to "New name" and saves
- **THEN** the saved field SHALL still carry that data

#### Scenario: Pick a linked target
- **GIVEN** a login
- **WHEN** the user adds a linked field
- **THEN** the first linkable login field SHALL be preselected
- **AND** the user SHALL be able to pick another one, which the saved field links to

#### Scenario: Name of an existing field cleared
- **GIVEN** a field that was read with the name "PIN"
- **WHEN** the user clears its name
- **THEN** Save SHALL be disabled and the row SHALL say that a name is required

#### Scenario: Name typed for a nameless field and cleared again
- **GIVEN** a field read without a name
- **WHEN** the user types a name and then deletes it again
- **THEN** the field SHALL be saved without a name, as it was read

#### Scenario: New field needs a name
- **WHEN** the user adds a field and leaves its name empty
- **THEN** Save SHALL be disabled and the row SHALL say that a name is required

### Requirement: Deliberate browsing differences are documented
The project SHALL document in the README or this capability the browsing behaviours that differ from official Bitwarden clients on purpose: Option-key peek, full-URI search, no "Unassigned" filter, grouping nodes for missing parent folders, and the absence of clone, bulk delete, bulk restore and TOTP seed editing.

#### Scenario: User looks for clone
- **WHEN** a user reads README "Known Limitations"
- **THEN** it SHALL state that cloning items and bulk delete or restore are not available in Prizm
