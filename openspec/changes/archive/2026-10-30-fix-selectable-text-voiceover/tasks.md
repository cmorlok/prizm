# Tasks

Write a failing test first (§IV). The text-range tests need the accessibility permission for the UI
test runner (design D2); with D4 it is granted once and survives rebuilds.

## 1. Tests (red)

- [x] 1.0 UI test target uses `LocalConfig.xcconfig` as its base configuration (D4); `codesign -d -r-` on the runner shows a team-based designated requirement, not `cdhash`. Done: `designated => identifier "de.b0x42.de.PrizmUITests.xctrunner" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …"`; the grant survived every later rebuild.
- [x] 1.1 UI test vault: Kappa gets the website `kappa.example.com/login` (D3). Value test: after switching from Gamma to Kappa, the Website row's accessibility value is Kappa's website (passes before the fix; guards the value path).
- [x] 1.2 `AccessibilityTextProbe` in `UITestSupport` (D2), skipped with a message when `AXIsProcessTrusted()` is false.
- [x] 1.3 Text-range tests: switching items (Website, Username), Reveal and Hide (Alpha's password), a new generator value. Each asserts at least one element with character data and that its text equals the shown text.
- [x] 1.4 Run them with the permission granted: they fail on the current code. Record the failures. Run 2026-10-29 (`20261029T161324Z`): the three text-range tests failed with the previous text (`testFieldTextsByRangeFollowItemChange`, `testRevealedPasswordTextByRange`, `testGeneratorPreview_textByRangeFollowsNewValue`); the value test passed.

## 2. Fix (green)

- [x] 2.1 `selectableValueText(_:spokenAs:)` (selection, accessibility value, `.id(<shown text>)`, identity transition) on the selectable texts of `FieldRowView` (both), `MaskedFieldView` and `PasswordGeneratorView` (D1).
- [x] 2.2 Run the text-range tests again (UI test code unchanged, so the permission still holds): they pass. Run 2026-10-29 (`20261029T161749Z`): 20 tests, 0 failures.
- [x] 2.3 Unit tests (`PrizmTests`) and the full UI suite pass, apart from known failures, which are named. 2026-10-30: unit tests TEST SUCCEEDED (`20261030T071453Z`); full UI suite after the review fixes (`20261030T072233Z`): 101 run, 21 skipped, 1 failure, the known `AccessibilityLabelTests.testSettingsGearHasLabel` (also fails on develop; the gear goes into the toolbar overflow in a large window). The four new tests passed.

## 3. Verify

- [x] 3.1 By hand with VoiceOver on a build of this branch: Website, Username and Notes (plain text and a URL) read the selected item's text after switching items in both directions, after clicking and moving the mouse away; a note reads its new text after an edit; a revealed password is read, and after Hide the mask. Confirmed by Christian on 2026-10-30.
- [x] 3.2 Record the result of 3.1 under `safe-uri-launch` task 3.4 (archived) and tick it if the website value reads correctly with its hint "Copies Website to clipboard". Done 2026-10-30.
- [x] 3.3 `/code-review` of the change; findings fixed or declined with a reason. 2026-10-30, ten findings; dispositions in design.md "Review".

## 4. Release

- [x] 4.1 CHANGELOG "Fix": VoiceOver could read the previous item's value, or a value from before an edit, in the item details.
- [x] 4.2 `openspec validate fix-selectable-text-voiceover --type change --strict` and `/opsx:verify`. Valid; `/opsx:verify` 2026-10-30: no critical issues; the "Edited value" scenario is covered by the hand check (3.1) only.
- [x] 4.3 Archive the change.
