# Proposal

## Why

**Criticality:** P2 (Medium: VoiceOver reads a different value than the one on screen)

During the hand checks of 2026-10-29 (`safe-uri-launch` task 3.4), VoiceOver read the previous
item's website (`https://webauthn.io/`) while the screen showed the selected item's
(`https://keyless.example.com`). The same happened to Notes, with plain text and with URLs, and even
with a note's old text after it had been edited. Which value VoiceOver read changed from one try to
the next.

A selectable text (`.textSelection(.enabled)`) keeps the text it was created with. SwiftUI reuses
the text element when the item changes, when a value is revealed and when the generator produces a
new value. `fix-ui-journey-findings` (design D3) fixed the element's accessibility *value*, so a UI
test that reads the value passes. But VoiceOver can also read a text through its character data
(the number of characters and the text for a range), and that data still holds the old text.
Whether VoiceOver uses the value or the character data depends on how the user reaches the
element, which is why the stale text came and went.

Measured with the accessibility API on the UI test vault, after switching from Gamma to Kappa:

| Field | Value | Text by range |
|---|---|---|
| Website | `https://kappa.example.com` | `file:///Applications/Calculator.app` (Gamma's) |
| Username | `user-kappa` | `user-gamma` (Gamma's) |

## Origin of the current behaviour

Platform behaviour of selectable texts. `fix-ui-journey-findings` D3 chose `.accessibilityValue`
over recreating the text, because recreating it "resets text selection and view state for no gain".
No test read the character data, so the remaining gap was not visible.

## What Changes

- Every selectable text that shows a vault value, a masked value or a generated value is recreated
  when the text it shows changes. Its character data then always matches the screen.
- A UI test reads the character data the way VoiceOver does. It needs the accessibility permission
  for the UI test runner and is skipped with a message where that permission is missing. The runner
  is now signed so that the permission, once granted, survives rebuilds.

## Non-Goals

- The verification code row: it is one accessibility element with its own value, and VoiceOver
  never reaches the selectable text inside it.
- The SwiftUI warning "Publishing changes from within view updates is not allowed", logged in every
  UI test that selects an item. It is not shown to cause this bug and gets its own follow-up.

## Dependencies

None.

## Impact

- **Presentation:** a `selectableValueText` modifier in `Components`, used by `FieldRowView` (both
  value texts), `MaskedFieldView` and `PasswordGeneratorView` (preview).
- **App (DEBUG only):** the UI test vault gives Kappa a website, so switching from Gamma reuses the
  Website row.
- **UI tests:** a probe for the character data in `UITestSupport`, three tests, and a value test for
  the Website row.
- **Project:** the UI test target uses `LocalConfig.xcconfig` as its base configuration, so the
  test runner is signed with the developer's team and an accessibility grant survives rebuilds
  (design D4).
- **No new dependencies.** No security review needed: no keys, tokens or crypto are touched, and a
  revealed password stays readable only while it is revealed (design D1).

## Estimate

| Step | Scope | Estimate |
|---|---|---|
| 1 | Tests and probe, run red | 0.25 d |
| 2 | Fix, run green, full suites | 0.25 d |
| 3 | VoiceOver hand check, docs | 0.25 d |
| **Total** | | **0.75 d** |
