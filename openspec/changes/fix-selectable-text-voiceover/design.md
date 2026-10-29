# Design

## Context

How the cause was found (2026-10-29):

1. A UI test that switches from Gamma to Kappa and reads the Website row's accessibility value
   passed: the value is Kappa's.
2. An accessibility hit test at the Website position, the call VoiceOver's mouse-follow uses
   (`AXUIElementCopyElementAtPosition`), also found Kappa's value. It needs the accessibility
   permission for the UI test runner, granted by hand.
3. The same test reading the character data showed the stale text: the outer text element, the one
   with the identifier, reports Kappa's value but Gamma's `AXNumberOfCharacters` (35) and Gamma's
   `AXStringForRange`. Username behaves the same. The inner text element has no character data.
4. By hand with VoiceOver: Website, Notes with a URL and Notes with plain text all read stale text
   at times; once a note's old text, after the note had been edited. So the trigger is a change of
   the shown text, not the item switch as such, and not URLs.

The accessibility permission was tied to the exact test runner binary and lost whenever the UI test
code changed; D4 fixes that.

Selectable texts in Presentation (`textSelection(.enabled)`):
- `FieldRowView`: the single-line and the multi-line value text
- `MaskedFieldView`: the masked or revealed value
- `PasswordGeneratorView`: the preview
- `TOTPCodeRowView`: the code, inside an element that ignores its children (not affected)

## Goals / Non-Goals

**Goals:** what VoiceOver reads by any route is the text on screen, after item changes, edits,
reveal and hide, Option-peek and new generator values.

**Non-Goals:** see proposal.md.

## Decisions

### D1. Recreate a selectable text when its text changes

One modifier in `Presentation/Components/SelectableValueText.swift`,
`selectableValueText(_ shown:, spokenAs:)`, does all of it, so no selectable value text can forget
part of it: `.textSelection(.enabled)`, `.accessibilityValue(spoken ?? shown)` (the D3 fix of
`fix-ui-journey-findings`; `FieldRowView` reads "03 / 2027" as "March 2027"), `.id(shown)` and
`.transition(.identity)`. A new identity makes SwiftUI create a new text element, whose character
data is the current text. The identity transition keeps the old and the new element from existing
side by side during an animated change, where VoiceOver could still reach the old text. The four
texts use it with `value ?? "—"` in `FieldRowView`, `effectiveDisplayValue` in `MaskedFieldView` and
`viewModel.generatedValue` in the generator.

What this resets: a text selection inside the value, when the value changes. A selection of the old
text has no use, so nothing is lost. Hover state lives on the row, not the text, and is kept.

Privacy: a masked value that is revealed and hidden again is a new element each time, so the
password is not left in the character data after Hide.

**Rejected:** `.id(itemId)`. It fixes the item switch but not edits, reveal or the generator.
**Rejected:** removing `.textSelection(.enabled)`. Users copy parts of values by selecting them.

### D2. A test that reads what VoiceOver reads

`AccessibilityTextProbe` in `UITestSupport` does an accessibility hit test at the centre of an
element and reads the text by range (`AXStringForRange` over `AXNumberOfCharacters`) of the element
found and of its parent, for those whose accessibility value is the shown text: those are the value
texts, so a hover overlay or a container is never checked by mistake. Tests assert that each such
text equals the shown text and that at least one exists, so they cannot pass vacuously.

The probe needs `AXIsProcessTrusted()`. Without it, the tests call `XCTSkip` with a message that
says how to grant the permission. CI does not run UI tests; on a developer Mac the permission is
granted once and survives rebuilds (D4). The hand check (task 3.1) stays the release gate.

Tests:
- switching from Gamma to Kappa: Website and Username
- Reveal and Hide on Alpha's password
- a new generator value

### D3. A second item with a website

The UI test vault gives Kappa the website `kappa.example.com/login`. Before, only Gamma had
websites, so no test could switch between two Website rows. Like Gamma's `example.com/login` it has
no scheme, so `URL(string:)?.host` is nil and no UI run asks the icon service for it. (The
measurement in proposal.md was taken with an earlier fixture, `https://kappa.example.com`.) Kappa is used by the attachment and
keyboard tests, which do not look at websites.

### D4. The UI test runner is signed with the team, so the permission survives rebuilds

macOS stores an Accessibility grant with the code requirement of the app it was granted to. The UI
test target had no base configuration, so it built without `DEVELOPMENT_TEAM`, and the runner got
the designated requirement `cdhash H"…"`: the grant matched only that one build and was lost
whenever the UI test code changed (seen three times on 2026-10-29). The UI test target now uses
`LocalConfig.xcconfig` as its base configuration, like the app target. The runner's designated
requirement is then `identifier "<runner bundle id>" and anchor apple generic and certificate
leaf[subject.CN] = "Apple Development: …"`, which every rebuild signed with the same certificate
meets. Checked with `codesign -d -r-` on the runner. CI is unaffected: it builds unsigned and
already needs `LocalConfig.xcconfig` for the app target.

## Risks / Trade-offs

- **[Low] More view churn:** a text is rebuilt when its value changes. In the details that happens
  on user actions. The generator preview is rebuilt on every step of the length slider; it is one
  small text, and VoiceOver's focus is on the slider then. The verification code, which changes
  every 30 seconds, is not part of this change.
- **[Low] VoiceOver focus on a text whose text changes** moves away, because the element is
  replaced. Reveal and Generate leave the focus on their button, and Option-peek reacts to Option
  alone, not to VoiceOver's Control-Option; a sync that changes the value under the cursor is rare.
  The hand check (task 3.1) found no problem.
- **[Low] The text-range tests skip without the permission.** → The hand check remains the gate;
  the tests document the cause and how to check it.

## Open Questions

None.
