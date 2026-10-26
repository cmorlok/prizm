# Tasks

Write a failing test first (§IV).

## 1. Fix (0.25 d)

- [x] 1.1 Failing tests: two clicks while the first request is in flight send `true` then `false` and end unstarred; three clicks send `true` only; a failure sends nothing further; a lock in flight sends nothing further.
- [x] 1.2 Implement design D1 and D2.
- [x] 1.3 CHANGELOG "Fixed": clicking the star twice quickly no longer leaves the item starred.
- [x] 1.4 Review.
- [x] 1.5 `openspec validate favorite-toggle-serialisation --type change --strict`.

## Results (2026-10-26)

- `ToggleFavoriteTests`: 5 new tests; the first 4 fail on the old view model (checked on the Mac); all 725 unit tests pass.
- Review (2026-10-26): after a lock and a quick unlock, a click could start a second request for an
  item while the old session's request was still open, and the older one could land last → D2
  changed (open requests survive `clearSession()`, the old request hands over to the new session's
  click), test `testClickAfterUnlock_waitsForTheOldRequest`, spec scenario. Also: the click's base
  is the selected item when newer; two tests now wait for the request to finish instead of a fixed
  sleep; the edit sheet's older race is noted under Risks.

