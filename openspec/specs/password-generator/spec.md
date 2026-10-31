## Purpose

Generate passwords and passphrases with configurable options.

## Requirements

### Requirement: User can generate a random password with configurable options
The system SHALL generate cryptographically random passwords from these options: length (5–128, default 16), uppercase (A–Z, on), lowercase (a–z, on), digits (0–9, on), special `!@#$%^&*` (on), extended special `()_+-=[]{}|;':",.<>?/` (off), avoid ambiguous (off), minimum numbers and minimum special (0–9, default 1 and 0). Each enabled set SHALL contribute at least one character. The result SHALL NOT contain whitespace. The last enabled set SHALL NOT be switchable off.

#### Scenario: Default configuration produces a 16-character password
- **WHEN** the generator opens in Password mode with default settings
- **THEN** it SHALL produce a 16-character password with uppercase, lowercase, digits and characters from `!@#$%^&*`
- **AND** no character from the extended special set

#### Scenario: Disabling a character set excludes those characters
- **WHEN** the user disables the special toggle and the extended special toggle is off
- **THEN** subsequent generated passwords SHALL contain no non-alphanumeric character

#### Scenario: Extended special characters
- **GIVEN** the extended special toggle is on
- **WHEN** a password is generated
- **THEN** it SHALL contain at least one character from `()_+-=[]{}|;':",.<>?/`

#### Scenario: Toggle labels show their characters
- **WHEN** the generator shows the special and extended special toggles
- **THEN** each label SHALL list every character of its set

#### Scenario: At least one character from each enabled set is present
- **WHEN** a password is generated with multiple sets enabled
- **THEN** the result SHALL contain at least one character from each enabled set

#### Scenario: Avoid-ambiguous excludes specified characters
- **WHEN** the avoid-ambiguous toggle is enabled
- **THEN** the generated password SHALL not contain any of the characters `0`, `O`, `I`, `l`, `1`, `|`

#### Scenario: Minimum counts are honoured
- **GIVEN** special characters are enabled with minimum special 2 and minimum numbers 3
- **WHEN** a password is generated
- **THEN** it SHALL contain at least 2 characters from `!@#$%^&*` and at least 3 digits

#### Scenario: Minimums exceed the length
- **GIVEN** length 5 with uppercase, lowercase, numbers and special enabled, minimum numbers 3 and minimum special 3
- **WHEN** a password is generated
- **THEN** it SHALL be 8 characters long
- **AND** the length control SHALL show 8

#### Scenario: Minimum stepper follows its set
- **WHEN** the special toggle is off
- **THEN** the "Minimum special" stepper SHALL be disabled

#### Scenario: Last enabled set among five
- **GIVEN** only the extended special set is enabled
- **THEN** its toggle SHALL be non-interactive

#### Scenario: Length slider is clamped to valid range
- **WHEN** the user adjusts the length slider
- **THEN** the length SHALL be constrained to the range 5–128 inclusive

#### Scenario: Last enabled character set cannot be disabled
- **WHEN** only one character set toggle remains enabled
- **THEN** that toggle SHALL be non-interactive and the other disabled toggles SHALL remain operable

#### Scenario: Generated password contains no whitespace
- **WHEN** a password is generated with any combination of enabled character sets
- **THEN** the result SHALL NOT contain any whitespace characters (space, tab, newline, or carriage return)

#### Scenario: Existing user keeps the stored settings
- **GIVEN** a stored length of 20 with uppercase, lowercase and symbols on
- **WHEN** the generator opens after the update
- **THEN** the length SHALL be 20, special SHALL be on and extended special SHALL be off

#### Scenario: Existing symbols-only user
- **GIVEN** stored settings with symbols as the only enabled set and no stored extended setting
- **WHEN** the generator opens after the update
- **THEN** special and extended special SHALL both be on

### Requirement: User can generate a passphrase with configurable options
The system SHALL generate passphrases from the EFF Large Wordlist without its four hyphenated words. Options: word count (3–20, default 6), separator (any text, default `"-"`), capitalize (off), include number (off; appends one random digit to one random word).

#### Scenario: Default passphrase has 6 words separated by hyphens
- **WHEN** the generator is in Passphrase mode with default settings
- **THEN** it SHALL produce a passphrase of 6 words joined by `"-"`

#### Scenario: Word count change produces the correct number of words
- **WHEN** the user sets word count to 20
- **THEN** the generated passphrase SHALL contain exactly 20 words

#### Scenario: Custom separator is used between words
- **WHEN** the user sets the separator to `"."`
- **THEN** the generated passphrase SHALL use `"."` as the delimiter between every word

#### Scenario: Separator longer than one character
- **WHEN** the user sets the separator to `" :: "`
- **THEN** the generated passphrase SHALL use `" :: "` as the delimiter between every word

#### Scenario: Capitalize toggle uppercases the first letter of each word
- **WHEN** the capitalize toggle is enabled
- **THEN** each word in the passphrase SHALL begin with an uppercase letter

#### Scenario: Include-number toggle appends a digit to one word
- **WHEN** the include-number toggle is enabled
- **THEN** exactly one word in the passphrase SHALL have a single random digit (0–9) appended to it

#### Scenario: Word count is clamped to valid range
- **WHEN** the user adjusts the word count
- **THEN** the count SHALL be constrained to the range 3–20 inclusive

#### Scenario: Words are drawn from the EFF Large Wordlist
- **WHEN** any passphrase is generated
- **THEN** every word SHALL be a member of the EFF Large Wordlist

#### Scenario: No hyphenated words
- **WHEN** the word list is loaded
- **THEN** it SHALL contain no word with "-"
- **AND** it SHALL have exactly 7,772 words

### Requirement: Generated value preview updates live on every option change
The system SHALL display the currently generated value in a prominent preview area. The preview SHALL update immediately whenever any configuration option changes or the user explicitly requests a new value. The preview SHALL use a monospaced font to aid readability of passwords. The default mode on first launch SHALL be Password.

#### Scenario: Preview updates on toggle change
- **WHEN** the user changes any configuration toggle or control
- **THEN** the preview SHALL immediately display a newly generated value reflecting the updated settings

#### Scenario: Refresh button produces a new value with the same settings
- **WHEN** the user clicks the refresh/regenerate button
- **THEN** the preview SHALL show a new value generated with the current settings unchanged

#### Scenario: Mode switch updates the preview
- **WHEN** the user switches between Password and Passphrase modes
- **THEN** the preview SHALL immediately show a value in the new mode

#### Scenario: Generation failure surfaces an error to the user
- **WHEN** the underlying randomness source fails (e.g. `SecRandomCopyBytes` returns an error)
- **THEN** the preview SHALL display an error message and the Copy and Use buttons SHALL be disabled until a successful generation occurs

---

### Requirement: User can copy or apply the generated value
The system SHALL provide two primary actions on the generated value: Copy and Use. Copy SHALL write the generated value to the system clipboard and follow the 30-second auto-clear rule (per `vault-browser-ui` clipboard requirement). Use SHALL write the generated value into the password field that triggered the generator and dismiss the popover. The Use button label SHALL reflect the active mode: "Use Password" in Password mode and "Use Passphrase" in Passphrase mode.

#### Scenario: Copy writes to clipboard and auto-clears after 30 seconds
- **WHEN** the user clicks Copy
- **THEN** the generated value SHALL be placed on the system clipboard and SHALL be auto-cleared after 30 seconds

#### Scenario: Use writes the value to the triggering field
- **WHEN** the user clicks "Use Password" or "Use Passphrase"
- **THEN** the generated value SHALL be written into the password (or private key) field and the popover SHALL dismiss

#### Scenario: Use replaces any existing field value
- **WHEN** the password field already contains a value and the user clicks the Use button
- **THEN** the field value SHALL be replaced with the generated value

#### Scenario: Use button labelled "Use Password" in Password mode
- **WHEN** the generator is in Password mode
- **THEN** the Use button SHALL be labelled "Use Password"

#### Scenario: Use button labelled "Use Passphrase" in Passphrase mode
- **WHEN** the generator is in Passphrase mode
- **THEN** the Use button SHALL be labelled "Use Passphrase"

---

### Requirement: Generator settings are persisted between sessions
The system SHALL persist the user's last-used generator configuration (mode, all option values) to `UserDefaults`. On next open, the generator SHALL restore the previously used configuration. The persisted settings SHALL be classified as UI preferences (not vault data) and SHALL NOT be stored in the Keychain.

#### Scenario: Settings are restored on next open
- **WHEN** the user closes the generator popover and reopens it
- **THEN** all configuration controls SHALL reflect the values used in the previous session

#### Scenario: Default settings apply on first launch
- **WHEN** the generator is opened for the first time with no persisted settings
- **THEN** all controls SHALL show their default values and the mode SHALL be Password

---

### Requirement: Generator is accessible from the password field in the Login edit form
The system SHALL display a generator trigger button adjacent to the password field in the Login item edit sheet. Clicking the button SHALL open the password generator popover anchored to that button. The trigger button SHALL be visible at all times (not hover-only) within the edit form.

#### Scenario: Generator button visible on Login edit password field
- **WHEN** the Login edit sheet is open
- **THEN** a generator trigger button SHALL be visible alongside the password field at all times, regardless of pointer position

#### Scenario: Clicking generator button opens the popover
- **WHEN** the user clicks the generator trigger button on the password field
- **THEN** the password generator popover SHALL open anchored to the button

### Requirement: Random choices are uniform
The generator SHALL choose every character, every shuffle position, every passphrase word, and the included digit and its word with exactly uniform probability over the candidate set, using the system's cryptographic random source.

#### Scenario: Rejection boundary
- **GIVEN** a random source that yields the largest accepted 32-bit value for the candidate count, then the smallest rejected one
- **WHEN** one candidate is chosen
- **THEN** the first value SHALL be used and the second SHALL NOT be drawn

#### Scenario: Random source that never yields an acceptable value
- **GIVEN** a random source that returns only rejected values
- **WHEN** a value is generated
- **THEN** generation SHALL fail with an error after a bounded number of draws

#### Scenario: Random source failure
- **GIVEN** the random source fails
- **WHEN** a value is generated
- **THEN** generation SHALL throw an error and the generator SHALL show it

### Requirement: Word list failure is visible
If the word list cannot be loaded, the system SHALL log the failure at fault level, SHALL show an error naming the cause in the generator, SHALL announce it to VoiceOver, and SHALL NOT offer an empty value for use or copy.

#### Scenario: Missing word list
- **GIVEN** the bundled word list is missing
- **WHEN** the user switches to passphrase mode
- **THEN** the generator SHALL show "The word list for passphrases couldn't be loaded."
- **AND** Use and Copy SHALL be disabled
