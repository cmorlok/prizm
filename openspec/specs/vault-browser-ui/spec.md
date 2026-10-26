## Purpose

Browse the vault in a three-pane layout with predictable focus.

## Requirements

### Requirement: User can browse their vault in a three-pane layout
The system SHALL display a `NavigationSplitView` with a sidebar (categories + counts), a middle item list, and a detail pane. The sidebar SHALL be organised into sections: *Menu Items* (All Items, Favorites), *Folders* (section header always visible; folder rows shown when folders exist), *Types* (Login, Card, Identity, Secure Note, SSH Key), *Organizations* (section visible only when the user belongs to at least one org; each org is a disclosure group containing its collections), and *Trash*, each with a live item count. Soft-deleted items (Trash) SHALL be excluded from all non-Trash views.

#### Scenario: Sidebar shows all categories with counts
- **WHEN** the vault browser opens
- **THEN** the sidebar shows Menu Items, Folders (header always visible; rows when folders exist), Types, Organizations (only when orgs exist), and Trash sections; each entry displays its item count; type entries are shown even when the count is zero

#### Scenario: Selecting a sidebar category updates the item list
- **WHEN** the user selects a sidebar entry (category, folder, type, org, or collection)
- **THEN** the middle pane shows only items belonging to that selection; the detail pane resets to its empty state

#### Scenario: No item selected — empty detail state
- **WHEN** no item is selected in the middle pane
- **THEN** the detail pane shows a "No item selected" empty state

#### Scenario: Selecting an item shows its full content
- **GIVEN** an item is selected
- **WHEN** the detail pane renders
- **THEN** all fields for that item type are displayed, along with creation date and last-modified date

#### Scenario: Item list shows type-specific subtitles and icons
- **WHEN** the item list renders
- **THEN** each row shows: favicon (or type-icon fallback), item name, type-specific subtitle (Login=username; Card=`*`+last 4 digits; Identity=first+last name; Secure Note=first 30 chars truncated; SSH Key=fingerprint), and a favorite star if marked as favorite

#### Scenario: Item list is sorted alphabetically
- **WHEN** any category is selected
- **THEN** the item list is sorted alphabetically by item name, case-insensitive

#### Scenario: Org item rows show org membership badge
- **WHEN** an org item appears in the item list (e.g., under All Items or a type selection)
- **THEN** the item row SHALL display a small badge or secondary label indicating the organization name

#### Scenario: Organizations section absent when user has no orgs
- **WHEN** the user belongs to no organizations
- **THEN** no "Organizations" section SHALL appear in the sidebar

---

### Requirement: Focus SHALL return to a logical element after dismissals
When a sheet, alert, or destructive action completes, keyboard and VoiceOver focus SHALL return to a logical element rather than being lost.

#### Scenario: Focus returns after edit sheet dismiss
- **WHEN** the user dismisses the edit sheet (save or discard)
- **THEN** focus SHALL return to the detail pane or the previously selected item

#### Scenario: Focus returns after delete confirmation
- **WHEN** the user confirms a soft delete and the item is removed from the list
- **THEN** focus SHALL move to the next item in the list, or the empty state if no items remain

#### Scenario: Focus returns after alert dismiss
- **WHEN** the user dismisses an error alert via the OK button
- **THEN** focus SHALL return to the element that was focused before the alert appeared

### Requirement: Arrow keys move the selection after a click
After the user clicks a row in the sidebar or in the item list, the arrow keys SHALL move the selection within that list. This SHALL also hold when the clicked row was already selected.

#### Scenario: Sidebar
- **GIVEN** the user clicked "Login" in the sidebar
- **WHEN** the user presses the down arrow
- **THEN** "Card" SHALL be selected

#### Scenario: Item list
- **GIVEN** the user clicked the first item in the list
- **WHEN** the user presses the down arrow
- **THEN** the second item SHALL be selected and shown in the detail pane

#### Scenario: Returning to a list
- **GIVEN** the user clicked an item row after selecting a sidebar row
- **WHEN** the user clicks the selected sidebar row again and presses the down arrow
- **THEN** the next sidebar row SHALL be selected

### Requirement: Menu commands SHALL NOT use system-wide shortcuts
No menu command SHALL use a key combination that macOS reserves system-wide, such as ⌘⇧Q (Log Out) or ⌃⌘Q (Lock Screen). "Sign Out…" SHALL have no keyboard shortcut.

#### Scenario: Sign Out menu item
- **WHEN** the user opens the Prizm menu
- **THEN** "Sign Out…" SHALL show no keyboard shortcut

### Requirement: File → New Window opens a main window
The "New Window" command (⌥⌘N) SHALL open a new main window, also when no window is open.

#### Scenario: No window open
- **GIVEN** Prizm is running with no window open
- **WHEN** the user chooses File → New Window
- **THEN** a main window SHALL open, showing the current screen (login, unlock or vault)
