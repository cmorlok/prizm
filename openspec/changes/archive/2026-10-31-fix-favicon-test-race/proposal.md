# Proposal

## Why

`FaviconLoaderTests.testIconsOff_sendsNothing_andEmptiesTheCache` (from `fix-website-icons-privacy`)
fails in about half of the unit runs (seen 2026-10-30 in batch 3, three times in five runs). The
loader empties its cache from a `UserDefaults.didChangeNotification` task; the test turns icons off
and straight back on without waiting for that task, so the reset sometimes runs after "on" and does
nothing, and the icon comes from the cache. The app is right in that case (icons are on again, so
keeping the cache is fine); the test asserts on asynchronous state it never waited for.

A flaky test hides real failures in every run and spoils the red/green evidence of every change.

## What Changes

- The test waits until the loader's reset has run (its `generation` counter) after turning icons
  off, as `testTurningIconsOff_resetsTheLoader` already does, before it turns them back on.
- `unit-test-isolation` gains a rule: a test that asserts on state changed asynchronously waits for
  that change with a deadline, never by luck of scheduling.

## Capabilities

### New Capabilities
_None._

### Modified Capabilities
- `unit-test-isolation`: tests wait for asynchronous state they assert on.

## Non-Goals

- Changing the loader. Its behaviour is correct (fix-website-icons-privacy, D2).

## Impact

- **Tests only:** `PrizmTests/Data/FaviconLoaderTests.swift`.

## Estimate

0.1 d.
