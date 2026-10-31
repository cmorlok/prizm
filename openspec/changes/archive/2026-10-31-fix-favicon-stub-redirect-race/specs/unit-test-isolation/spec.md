## ADDED Requirements

### Requirement: URL stubs keep one test's requests out of the next
A URL stub shared by unit tests SHALL NOT record or answer as current a request that a finished test
caused, including a redirect target the URL loading system starts after that test has ended, and
SHALL end a redirected request with the redirect response only when the redirect was not followed.

#### Scenario: Redirect followed at the end of a test
- **GIVEN** a test whose icon request was redirected and followed
- **WHEN** the next test starts and the follow-up request reaches the stub only then
- **THEN** the stub SHALL answer it without recording it, and the next test SHALL see only its own requests

#### Scenario: Redirect followed within the test
- **GIVEN** a redirect that the session's policy follows
- **WHEN** the stub reports the redirect
- **THEN** the request SHALL end with the target's answer, never with the 302
