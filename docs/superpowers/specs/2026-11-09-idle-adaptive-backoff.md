# Idle Adaptive Backoff (P3)

## Problem

The store polls on a fixed cadence chosen from Cursor's app state:
`active` 60s (Cursor frontmost within 300s), `idle` 300s (running),
`dormant` 1800s (not running). Failure backoff already exists.

What is missing: when the account is **quiet** — repeated polls return the
same spend, the same today's total, and the same last activity timestamp —
the background timer keeps firing at the base interval even though nothing
can be learned from the next poll. On a machine with Cursor open but the
user away, this is pure background wakeups and network traffic.

## Design

Track a **quiet streak** of consecutive published refreshes whose activity
signature is unchanged. The signature covers the user-visible activity
fields only:

```
settledSpendCents, liveSpendCents, todayCents, lastActivity, events.count
```

Rules:

1. **Signature unchanged** on a published refresh → `quietStreak += 1`.
   Changed → `quietStreak = 0` and the new signature is stored.
2. **Effective interval** = base cadence × 2^clamp(quietStreak − 1, 0…3),
   i.e. the first repeated poll is free, then ×2, ×4, ×8.
   Hard cap: **1800s** for `active`/`idle`. `dormant` is already 1800s and
   is left untouched (no multiplier).
   The live timer is re-armed immediately whenever the effective interval
   changes, including from non-timer paths (menu open/close, team switch,
   manual or wake refreshes) — `refresh()` re-arms at its end, and
   `setMenuOpen`/`selectTeam` re-arm directly.
3. **Menu open** → quiet backoff never applies; the open menu keeps the
   base cadence so the user always sees fresh data. Opening the menu also
   resets the streak.
4. **Failures**: quiet backoff applies only when `consecutiveFailures == 0`.
   Failure backoff stays exactly as it is today; the two never compound.
5. **Team switch** (`selectTeam`) resets the streak and signature.
6. **Staleness**: `isStale` must measure against the *effective* interval,
   not the base cadence, otherwise a quiet-backed-off reading would be
   flagged stale between polls. Track the interval used for the most
   recent successful publish.
7. Re-arming is handled by `rearmIfNeeded()`: it runs at the end of every
   `refresh()` and directly in `setMenuOpen`/`selectTeam`, so streak-driven
   and cadence-driven changes take effect immediately, on and off the timer.

## Non-goals

- No change to the summary/full split, the incremental event merge, or
  the reconciliation cadence.
- No change to `RefreshCadence` values or to menu-open behaviour.
- No system-idle (HID) detection; quietness is judged from account data.

## Acceptance

- Three identical polls in a row move a closed-menu `active` poll from
  60s to 120s, then 240s, 480s, capped at 1800s.
- A changed signature returns the next interval to the base immediately.
- Menu open: interval is always the base cadence regardless of streak.
- `isStale` stays false between polls while quiet backoff is active.
- Full suite green on Mac.
