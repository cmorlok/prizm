# Tasks

Write a failing test first for each task (§IV).
**Prerequisite:** `fix-password-generator` (this branch is stacked on it).

## 1. Entropy (0.25 d)

- [ ] 1.1 Failing tests for `GeneratorStrength.of`: default password → 97.7 bits, "Strong · 97 bits"; length 8 → 47 bits, Weak; length 12 with at least 9 numbers → 52.7 bits, Weak (exact count, design D1); 6 words → 77 bits, OK; 6 words with a number → 77.55 + 3.32 + 2.58 bits; length 24 with every set → 155 bits, Very strong; avoid ambiguous shrinks the pool; minimums above the length use the effective length.
- [ ] 1.2 Thresholds at the edges: 63.99 Weak, 64 OK, 79.99 OK, 80 Strong, 127.99 Strong, 128 Very strong.
- [ ] 1.3 Implement D1 and D2 in Domain; pool sizes from `PasswordGenerator`'s sets.

## 2. Meter (0.25 d)

- [ ] 2.1 View model `strength`: updates on every setting change; nil while `errorMessage` is set. Tests.
- [ ] 2.2 `StrengthMeterView`: bar and label (D3), colors by category with the OK gradient, `Spacing.strengthBarHeight` added to `DesignSystem.swift`, tooltip text from Risks.
- [ ] 2.3 Accessibility: one element, label "Strength", value "<Category>, <n> bits", identifier `generator.strength`.

## 3. Verify and document (0.25 d)

- [ ] 3.1 XCUITest: the meter exists with label "Strength" and a value that names a category and bits (UI run at batch end).
- [ ] 3.2 VoiceOver hand check of the meter.
- [ ] 3.3 CHANGELOG "Added": the generator shows the strength of its settings in bits with a colored category.
- [ ] 3.4 `openspec validate generator-strength-meter --type change --strict`.
