## MODIFIED Requirements

### Requirement: Org items appear in All Items and in their collection sidebar selection
Org items SHALL be included in the "All Items" sidebar selection alongside personal items. Org items SHALL appear when the user selects `.collection(id)` where `id` is in the item's `collectionIds`. Org items SHALL appear in a folder selection when the user filed them in that folder (folders are personal; see `org-items-in-folders`). Org items SHALL appear in type-based sidebar selections (Login, Card, etc.) regardless of org membership.

#### Scenario: Org items visible in All Items
- **GIVEN** the user has 3 personal items and 2 org items
- **WHEN** the user selects All Items
- **THEN** all 5 items SHALL appear in the item list

#### Scenario: Org items filterable by collection
- **GIVEN** item X has `collectionIds = ["col1"]`
- **WHEN** the user selects `.collection("col1")` in the sidebar
- **THEN** item X SHALL appear in the item list

#### Scenario: Org item filed in a personal folder
- **GIVEN** an org item with `organizationId = "org1"` that the user filed in folder "Work"
- **WHEN** the user selects "Work" in the sidebar
- **THEN** the org item SHALL appear in the item list

#### Scenario: Org item detail pane shows organization badge
- **GIVEN** the user selects an org item in the item list
- **WHEN** the detail pane renders
- **THEN** the item's organization name SHALL be displayed as a read-only badge or field row
