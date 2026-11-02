## ADDED Requirements

### Requirement: The Release configuration compiles
The app SHALL compile in the Release configuration. Types and checks that exist only for tests
(UI-test seams such as `UITestFixtures`) SHALL be referenced only inside `#if DEBUG`, so that a
Release binary contains none of them and still builds.

#### Scenario: Release build
- **WHEN** the app is built with the Release configuration (`scripts/container/host-build.sh release`)
- **THEN** the build succeeds without errors
