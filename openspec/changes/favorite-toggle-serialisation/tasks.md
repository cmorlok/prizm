# Tasks

Write a failing test first (§IV).

## 1. Fix (0.25 d)

- [ ] 1.1 Failing tests: two clicks while the first request is in flight send `true` then `false` and end unstarred; three clicks send `true` only; a failure sends nothing further; a lock in flight sends nothing further.
- [ ] 1.2 Implement design D1 and D2.
- [ ] 1.3 CHANGELOG "Fixed": clicking the star twice quickly no longer leaves the item starred.
- [ ] 1.4 Review.
- [ ] 1.5 `openspec validate favorite-toggle-serialisation --type change --strict`.
