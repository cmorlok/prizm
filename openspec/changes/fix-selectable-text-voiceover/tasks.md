# Tasks

Write a failing test first (§IV). The text-range tests need the accessibility permission for the UI
test runner (design D2); with D4 it is granted once and survives rebuilds.

## 1. Tests (red)

- [ ] 1.0 UI test target uses `LocalConfig.xcconfig` as its base configuration (D4); `codesign -d -r-` on the runner shows a team-based designated requirement, not `cdhash`.
- [ ] 1.1 UI test vault: Kappa gets the website `kappa.example.com/login` (D3). Value test: after switching from Gamma to Kappa, the Website row's accessibility value is Kappa's website (passes before the fix; guards the value path).
- [ ] 1.2 `AccessibilityTextProbe` in `UITestSupport` (D2), skipped with a message when `AXIsProcessTrusted()` is false.
- [ ] 1.3 Text-range tests: switching items (Website, Username), Reveal and Hide (Alpha's password), a new generator value. Each asserts at least one element with character data and that its text equals the shown text.
- [ ] 1.4 Run them with the permission granted: they fail on the current code. Record the failures.

## 2. Fix (green)

- [ ] 2.1 `selectableValueText(_:spokenAs:)` (selection, accessibility value, `.id(<shown text>)`, identity transition) on the selectable texts of `FieldRowView` (both), `MaskedFieldView` and `PasswordGeneratorView` (D1).
- [ ] 2.2 Run the text-range tests again (UI test code unchanged, so the permission still holds): they pass.
- [ ] 2.3 Unit tests (`PrizmTests`) and the full UI suite pass, apart from known failures, which are named.

## 3. Verify

- [ ] 3.1 By hand with VoiceOver on a build of this branch: Website, Username and Notes (plain text and a URL) read the selected item's text after switching items in both directions, after clicking and moving the mouse away; a note reads its new text after an edit; a revealed password is read, and after Hide the mask.
- [ ] 3.2 Record the result of 3.1 under `safe-uri-launch` task 3.4 (archived) and tick it if the website value reads correctly with its hint "Copies Website to clipboard".
- [ ] 3.3 `/code-review` of the change; findings fixed or declined with a reason.

## 4. Release

- [ ] 4.1 CHANGELOG "Fix": VoiceOver could read the previous item's value, or a value from before an edit, in the item details.
- [ ] 4.2 `openspec validate fix-selectable-text-voiceover --type change --strict` and `/opsx:verify`.
- [ ] 4.3 Archive the change.
