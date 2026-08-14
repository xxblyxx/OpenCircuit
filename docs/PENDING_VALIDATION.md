# Pending validation — claims shipped but not yet confirmed on real data

Some changes here cannot be validated when they land. The ring produces the confirming data
hours or days later, and some of it only when the wearer's body happens to do the thing the code
is watching for. That gap is where a fix quietly becomes folklore: it was reasoned about
carefully, the tests pass, nobody ever saw it work.

**This file is the list of those debts.** `scripts/pending-validation.py` reads it from a
`SessionStart` hook (see `.claude/settings.json`) and surfaces the entries whose `check-after`
date has arrived, so a new session opens by ASKING whether you want to check — regardless of what
that session was actually about.

## Scope — keep this narrow

Only **claims awaiting evidence**: something shipped, whose correctness rests on data that did
not exist yet. Not a TODO list, not a wishlist, not refactors. The moment "would be nice to clean
up X" lands here, the session-start reminder becomes wallpaper and stops working for the entries
that matter. Ordinary follow-ups belong in issues.

## How to use it

**Adding.** Any change whose correctness rests on unobserved data gets an entry before the work
is called done. Fill in every field — an entry that cannot be acted on in six months is noise:

| field | what it must answer |
|---|---|
| `id` | short kebab-case slug, unique |
| `shipped` | commit + issue + date, so the code is findable |
| `claim` | what we asserted is true and have not seen |
| `needs` | the DATA EVENT that must occur before checking is even possible |
| `blocked-because` | why it hasn't happened yet — the honest reason, not a placeholder |
| `check` | the exact command to run |
| `passes-if` | what would count as confirmation, decided NOW rather than after seeing the result |
| `check-after` | earliest date a check could be informative |

`check-after` is the whole anti-nag mechanism. Set it to when the data could *plausibly* exist,
not to tomorrow.

⚠️ A missing or malformed `check-after` is treated as **ripe**, deliberately — a typo must make
noise rather than bury an item forever.

**Checking.** Run the `check` command. If it passes, move the entry to `## Settled` with one line
saying what was actually observed. If the data still isn't there, bump `check-after` and, if the
reason changed, update `blocked-because`. Bumping is honest; deleting an unvalidated entry is not.

**Settling.** Entries move to `## Settled` rather than being deleted. It costs one line and it is
the difference between "we checked and it held" and "someone got tired of seeing it." Same
argument the #73 health-alert decision log makes about its suppressed rows: without the record
there is no denominator.

---

## Open

### SpO2 epoch-quality fraction has never run on real data
- id: spo2-bad-epoch-fraction
- shipped: 4d0b884 (#73) 2026-08-13, branch `fix/spo2-alert-quality-gate`
- claim: `maxBadEpochFraction` (0.5, strict `>`) suppresses a run that is mostly motion while
  letting one bad epoch inside a genuine run survive
- needs: a corroborated run — two readings at/below the SpO2 threshold agreeing within 2 points,
  inside the 45 min corroboration window
- blocked-because: every real decision so far (2 of 2, both 2026-08-13/14) short-circuits at
  `.noCorroboration`, and `evaluateOne` returns on that path BEFORE `resolved` is computed, so
  the fraction is structurally never reached. Corroboration alone is carrying the feature.
- check: `desktop/device_alert_audit.py --pull` (phone on USB) — look for any row with
  `evidenceEpochs > 0`; the tool prints the count of such rows explicitly in its summary
- passes-if: a mostly-moving run logs `badEpochMajority`, AND a still run containing one bad
  epoch still fires. Either one alone is half the claim.
- check-after: 2026-08-28

### The evidence fail-open branch has never been taken
- id: spo2-fail-open-miss
- shipped: 4d0b884 (#73) 2026-08-13, branch `fix/spo2-alert-quality-gate`
- claim: when a corroborated run resolves to NO raw records, the alert fires anyway rather than
  being silently suppressed by a diagnostic detail
- needs: a corroborated run made entirely of live on-demand readings, which have no `0x4c`
  record by construction
- blocked-because: same as `spo2-bad-epoch-fraction` — no corroborated run has occurred at all
  yet, so neither the resolved nor the unresolved branch below it has been exercised
- check: `desktop/device_alert_audit.py --pull` — a FIRED row with `evidenceEpochs == 0`
- passes-if: that row exists and the notification actually arrived on the phone. A fired row with
  no notification would mean the shared quiet-hours/backoff gate ate it, which is a different bug.
- check-after: 2026-08-28

### Live-reading miss rate measured 5x higher on device than on the export
- id: spo2-evidence-miss-rate
- shipped: c3426e0 2026-08-14 (measured by the new audit tool, not changed by it)
- claim: `spo2_alert_autopsy.py --miss-report` put the evidence-lookup miss rate at 5.3%, and the
  fail-open policy is justified in writing against that number
- needs: a 30 h snapshot from an ORDINARY day — no app-testing session inflating the count of
  live on-demand readings
- blocked-because: the 2026-08-14 snapshot measured 25.8% inside the archive span, but that day
  was full of manual app usage while testing #73, and live readings have no `0x4c` record by
  construction. Suspected artifact of the testing, not a real regression — unconfirmed either way.
- check: `desktop/device_alert_audit.py --pull` after a day of normal wear, read the
  "resolve to a raw record" line
- passes-if: the miss rate lands near 5% and the 5.3% figure in the #73 commit stands. If it
  stays above ~20% on a quiet day, that constant needs re-measuring and the fail-open reasoning
  needs revisiting.
- check-after: 2026-08-21

---

## Settled

_Nothing yet. Entries land here with the date and what was actually observed._
