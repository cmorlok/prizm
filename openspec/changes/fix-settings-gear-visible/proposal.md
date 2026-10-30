# Proposal

## Why

`AccessibilityLabelTests.testSettingsGearHasLabel` fails on `develop`: the Settings gear is not in
the toolbar. The UI run of 2026-10-30 shows why. The gear is a toolbar item of the sidebar column
(`VaultBrowserView`), which the maintainer placed there on purpose, "next to the sidebar toggle"
(commit 01d12926). On macOS 26 the sidebar column restores at about 190 pt (minimum 180). The
window controls and the sidebar toggle already fill that toolbar section, so macOS moves the gear
into the "more toolbar items" overflow menu, even in a window 1878 pt wide. Users have to find
Settings in an overflow menu; VoiceOver users do not find it in the toolbar at all.

The spec still says the gear sits "next to the search field" in the detail column toolbar, which
is no longer true since that commit.

## What Changes

- The sidebar column gets a minimum width at which its toolbar holds the window controls, the
  sidebar toggle and the gear (minimum 220 pt, ideal 240 pt instead of 180 / 210).
- The `settings-screen` spec describes the gear where it is: in the sidebar toolbar next to the
  sidebar toggle, visible without the overflow menu.

## Capabilities

### Modified Capabilities
- `settings-screen`: placement of the gear button.

## Non-Goals

- Moving the gear to another toolbar position (the maintainer chose this one).
- A keyboard shortcut change: ⌘, stays.

## Dependencies

None.

## Impact

- **Presentation:** `VaultBrowserView` sidebar column width.
- **Tests:** the existing UI test `testSettingsGearHasLabel` passes again.
