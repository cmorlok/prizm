# Tasks

Write a failing test first for each task (§IV).
**Prerequisite:** `fix-password-generator` (this branch is stacked on it).

## 1. Entropy (0.25 d)

- [x] 1.1 Failing tests for `GeneratorStrength.of`: default password → 97.7 bits, "Strong · 97 bits"; length 8 → 47 bits, Weak; length 12 with at least 9 numbers → 52.7 bits, Weak (exact count, design D1); 6 words → 77 bits, OK; 6 words with a number → 77.55 + 3.32 + 2.58 bits; length 24 with every set → 155 bits, Very strong; avoid ambiguous shrinks the pool; minimums above the length use the effective length. Done: `GeneratorStrengthTests` (`testDefaultPassword_isStrong97`, `testShortPassword_isWeak`, `testHighMinimums_countOnlyWhatTheSettingsAllow`, `testSixWords_isOK77`, `testSixWordsWithANumber_addsDigitAndPosition`, `testEverySet_24_isVeryStrong`, `testAvoidAmbiguous_shrinksThePool`, `testMinimumsAboveTheLength_useTheEffectiveLength`); red 20261030T195125Z (compile only). Code review: the first version multiplied the length by log2 of the pool and overstated high minimums (73 instead of 52.7 bits); the exact count replaced it (red 20261031T075451Z, green 20261031T075927Z, 1401).
- [x] 1.2 Thresholds at the edges: 63.99 Weak, 64 OK, 79.99 OK, 80 Strong, 127.99 Strong, 128 Very strong. Done: `testThresholds`.
- [x] 1.3 Implement D1 and D2 in Domain; pool sizes from `PasswordGenerator`'s sets. Done: `Domain/Utilities/GeneratorStrength.swift` (`passwordSpaceBits` counts the passwords the settings allow, in log space), sets from `PasswordGenerator.characterSets`; green 20261030T195416Z (1399).

## 2. Meter (0.25 d)

- [x] 2.1 View model `strength`: updates on every setting change; nil while `errorMessage` is set. Tests. Done: `PasswordGeneratorViewModelTests.testStrength_followsTheSettings` (length, a set, mode, word count, number option; extended at verification, green 20261031T181537Z), `testStrength_isHiddenOnError`.
- [x] 2.2 `StrengthMeterView`: bar and label (D3), colors by category with the OK gradient, `Spacing.strengthBarHeight` added to `DesignSystem.swift`, tooltip text from Risks. Done; the color mapping is `StrengthMeterView.color(for:)`, tested since verification (`testStrengthColor_weakIsRed_strongIsGreen`).
- [x] 2.3 Accessibility: one element, label "Strength", value "<Category>, <n> bits", identifier `generator.strength`. Done: `GeneratorStrengthTests.testAccessibilityValue`. The text carries label, value and identifier and the bar is hidden from VoiceOver: on macOS a group made with `.accessibilityElement(children: .ignore)` exposed no value (found by the UI run).

## 3. Verify and document (0.25 d)

- [x] 3.1 XCUITest: the meter exists with label "Strength" and a value that names a category and bits (UI run at batch end). Done: `PasswordGeneratorJourneyTests.testGeneratorPopover_showsStrengthWithCategoryAndBits`; failed in the full UI run 20261030T205732Z (empty value, see 2.3), passed after the fix in 20261031T074052Z (5/5) and 20261031T082242Z, and in the final run of the batch.
- [x] 3.2 VoiceOver hand check of the meter. Done: Christian, 2026-10-31 (Debug build of the batch-3 integration branch): "Strength, Strong, 97 bits" with the defaults; "Weak, 52 bits" with length 12 and at least 9 numbers; the weak bar red.
- [x] 3.3 CHANGELOG "Added": the generator shows the strength of its settings in bits with a colored category. Done.
- [x] 3.4 `openspec validate generator-strength-meter --type change --strict`. Done before the archive.
