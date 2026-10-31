## ADDED Requirements

### Requirement: Tests wait for asynchronous state they assert on
A unit test that asserts on state which the code under test changes asynchronously (from a
notification, a task or a callback) SHALL wait for that change with a deadline before it asserts or
acts on it, and SHALL fail with a message when the deadline passes.

#### Scenario: Icons turned off and on again
- **GIVEN** a favicon loader that has cached an icon
- **WHEN** the test turns website icons off, waits until the loader has reset, turns them on and asks for the icon
- **THEN** the icon SHALL be requested from the server again, in every run
