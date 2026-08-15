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

### The reference-label corpus has one usable night, and the archive rolls over nightly
- id: sleep-reference-label-corpus
- shipped: branch `feat/sleep-awake-diagnostics` 2026-08-15 — `ExternalSleepSample`,
  `HealthKitWriter.readExternalSleepSamples`, `ExternalSleepStore`, Device Info → Diagnostics →
  "Import reference sleep labels", `desktop/sleep_reference_labels.py`. Analysis-only; no
  classifier constant changed.
- claim: reference labels (Whoop / the official RingConn app, read from HealthKit) plus raw epochs
  give a corpus that can FIT the staging thresholds in `docs/SLEEP_AWAKE_RESOLUTION.md` §10
- needs: nights where BOTH exist. `EpochArchive` retains ~30 h of raw epochs while the labels span
  30 days, so a label is only usable if the archive was pulled within ~30 h of that night.
- blocked-because: measured 2026-08-15 — 24 nights of RingConn labels have NO surviving raw epochs;
  of 3 Whoop nights only 08-14/15 does. Every finding in §4.4 therefore rests on ONE night
  (n = 43 awake epochs). Nothing is wrong with the tooling; the archive simply rolls over faster
  than labels accumulate, so each day without a paired capture discards a night permanently.
- check: `desktop/sleep_reference_labels.py --pull` then `--correlate`; count nights where labels
  and epochs overlap (the tool prints the traced night's span and the label span)
- passes-if: ≥ 7 paired nights exist, AND the §4.4 co-location lift holds at ≥ 1.5× when pooled
  across them. Fewer than 7, or a lift that collapses toward 1.0, means the single-night result was
  small-sample noise and §10 option B must not proceed on it.
- check-after: 2026-08-29

### The intensity tail's arousal signal is one night, with autocorrelated epochs
- id: sleep-tail-encodes-arousal
- shipped: measured 2026-08-15, recorded in `docs/SLEEP_AWAKE_RESOLUTION.md` §4.4 (no code depends
  on it yet — this is the claim that would JUSTIFY option A/B, so it must hold before either lands)
- claim: a non-zero `[15:20]` intensity tail is enriched inside labelled-awake epochs — 48.8 % vs
  26.0 %, 1.88× lift, Fisher exact two-sided p = 0.0054 — i.e. the tail carries arousal
  information, which `PROTOCOL.md` marks 🔴 not established
- needs: more paired label+epoch nights (see `sleep-reference-label-corpus`), and ideally a night
  with labels from BOTH sources to check the effect is not Whoop-specific
- blocked-because: n = 1 night / 43 awake epochs. Adjacent epochs are autocorrelated, so the
  effective sample is smaller than 239 and the stated p is optimistic. The two label sources have
  ZERO overlapping nights (RingConn app stopped writing 08-12, Whoop started 08-12), so no
  cross-source check is possible from the current data at all.
- check: `desktop/sleep_reference_labels.py --pull --correlate` once ≥ 7 paired nights exist;
  pool the 2×2 across nights rather than averaging per-night lifts
- passes-if: pooled lift ≥ 1.5× with the enrichment present on a majority of individual nights. A
  pooled lift driven by one outlier night fails this — the point is that the tail is reliably
  informative, not that it was once.
- check-after: 2026-08-29

### arousalIntensityCut (200) is fitted on ONE night, and hasn't been checked against a real re-staged night with the working code
- id: sleep-arousal-cut-single-night-fit
- shipped: `feat/sleep-awake-diagnostics` 2026-08-15 — `SleepStaging.Tuning.arousalIntensityCut`
  (`markInteriorArousals`, `docs/SLEEP_INTERIOR_AROUSALS.md` §1b). Ships live: this DOES change
  classifier output on any night using the intensity-tail fallback path.
- claim: `arousalIntensityCut = 200` produces 5–8 interior awakenings/night — RingConn's own
  5.8/night average — without moving onset or final wake, on real nights generally (not just the
  one it was fitted on)
- needs: (a) at least one night the ring has re-staged WITH THE §1b FIX (the whole-block-vs-interior
  motion-source bug), and (b) ideally several more paired label+epoch nights (see
  `sleep-reference-label-corpus`) so the fit isn't resting on the single 2026-08-14/15 night it was
  chosen from
- blocked-because: 🟢 MEASURED same day — the FIRST re-stage attempt (force-quit + Bluetooth
  toggle, confirmed via `ZUPDATEDAT` moving to 08-15 16:36:16) proved the app DOES re-stage from
  the persisted archive on reconnect without waiting for a fresh overnight sync
  (`RingSession.restageFromArchive`), but it ALSO proved the shipped pass was inert: the interior
  column stayed exactly `0.0m`, byte-identical to before the fix. Root cause found and fixed same
  day (§1b: the channel-selection verdict was scoped to the whole in-bed block, where 3 real
  getting-up epochs disqualified it, rather than the sleep interior). The re-stage mechanism is
  no longer the blocker — only a re-run WITH the fix installed is.
- check: force-quit the app, toggle Bluetooth off/on, reopen (triggers a fresh
  `restageFromArchive` — no need to wait for an overnight sync), then
  `desktop/sleep_reference_labels.py --pull --compare-own`; separately,
  `desktop/sleep_reference_labels.py --pull --sweep-arousal-cut` on new paired nights as they
  accumulate, to see whether 200 still lands in range or needs re-fitting
- passes-if: the re-staged night's OC interior column in `--compare-own` shows a nonzero,
  plausible awakening count (roughly 0–15 min per awakening, total WASO not wildly larger than the
  night's total awake time), AND the in-bed window is unchanged at exactly
  `08-14 22:15:56 .. 08-15 08:23:26` (moving means the strictly-interior guard leaked). A flat
  0.0m again means either a NEW variant of the channel-selection bug, or that this specific
  night's interior itself now includes real primary motion (in which case §1b's own documented
  "known limitation" is the explanation, not a new bug).
- check-after: 2026-08-15 (same day — no longer needs to wait for morning; a forced reconnect is
  sufficient, see `check` above)

---

## Settled

### `sleep_awake_trace.py` correctly attributes why a known awakening is dropped — 2026-08-15
- id: sleep-brief-awakenings-visible
- was: does the per-epoch trace correctly explain why a specific known awakening does or doesn't
  survive `SleepStaging`'s awake mask, including whether the primary motion channel was usable?
- observed: run against the 2026-08-14/15 night with 19 Whoop-labelled awake intervals. The trace
  located every one, and the explanation held: all 19 are shorter than the 12.5 min
  `erodeShortHRWake` floor and 11 are shorter than a single 150 s epoch, so both mechanism #1 and
  mechanism #4 of §2 independently account for the loss. **It also caught two errors in its own
  first draft** (`SLEEP_AWAKE_RESOLUTION.md` §7): the motion-source verdict was being scored on the
  strict sleep window, making a healthy channel read as "constant filler" and engaging a fallback
  the shipped classifier would not use; and `intensity_tail` read 7 bytes where Swift's
  `motionIntensityTail` reads 5. Both fixed. The tool answers "why not" correctly.

_Nothing yet. Entries land here with the date and what was actually observed._
