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

### SpO2 epoch-quality fraction: only the SUPPRESSING half has been exercised
- id: spo2-bad-epoch-fraction
- shipped: 4d0b884 (#73) 2026-08-13, branch `fix/spo2-alert-quality-gate`
- claim: `maxBadEpochFraction` (0.5, strict `>`) suppresses a run that is mostly motion while
  letting one bad epoch inside a genuine run survive
- needs: BOTH halves in real data — a mostly-bad run logging `badEpochMajority`, AND a
  partially-bad run (some epochs bad, but not a majority) still firing
- blocked-because: 🟡 UPDATED 2026-08-18 (device pull, `desktop/device_alert_audit.py --pull`) —
  now exercised exactly ONCE: `[Aug 16 18:47:22] lowSpO2 suppressed reason=badEpochMajority
  value=89 reading=Aug 16 18:00:05 run=2 evidence=2/2 bad`, correctly re-derived by the audit
  tool. That is the SUPPRESSING half only (2 of 2 resolved epochs bad). The survival half — one
  bad epoch inside a run that still fires — has still never happened on real data; every other
  logged decision either short-circuits at `.noCorroboration`/`.corroborationDisagrees` before
  `resolved` is computed, or (the one FIRED row, `2026-08-17 20:42`) resolved zero epochs and rode
  the fail-open path instead. Corroboration + fail-open are still carrying the feature.
- check: `desktop/device_alert_audit.py --pull` (phone on USB) — look for a FIRED row with
  `evidenceEpochs > 0` AND `badEpochs > 0` (that's the still-missing half); the tool's summary
  line already counts `evidenceEpochs > 0` rows explicitly
- passes-if: a mostly-moving run logs `badEpochMajority`, AND a still run containing one bad
  epoch still fires. Either one alone is half the claim — the first half is now observed, the
  second is not.
- check-after: 2026-09-08

### Live-reading miss rate measured 6x higher than the original estimate, twice now
- id: spo2-evidence-miss-rate
- shipped: c3426e0 2026-08-14 (measured by the new audit tool, not changed by it)
- claim: `spo2_alert_autopsy.py --miss-report` put the evidence-lookup miss rate at 5.3%, and the
  fail-open policy is justified in writing against that number
- needs: a 30 h snapshot from an ORDINARY day — no app-testing session inflating the count of
  live on-demand readings
- blocked-because: 🟡 RE-MEASURED 2026-08-18 (device pull, `desktop/device_alert_audit.py
  --pull`): **30.7%** (156/225 samples inside the archive's own span resolved). This is a SECOND
  independent measurement landing well above the original 5.3% estimate — the first
  (2026-08-14, 25.8%) was set aside as possibly inflated by that day's manual #73 testing, but
  this snapshot (2026-08-17 02:46 → 2026-08-18 08:46) reflects ordinary wear, not a testing
  session. Two measurements now agree with each other (25.8%, 30.7%) and disagree with the
  original 5.3% by the SAME direction and roughly the same margin — the pattern looks like the
  original figure was measured differently (a different corpus, or a different span-scoping),
  not like testing-day noise. Per the pre-declared `passes-if` below, this is past the ~20%
  concern line.
- check: `desktop/device_alert_audit.py --pull` after a day of normal wear, read the
  "resolve to a raw record" line. `--not-before <ISO8601>` (added 2026-08-18, #spo2-burst-fix)
  can replay an older snapshot's own span if a third reading is needed without a fresh pull.
- passes-if: the miss rate lands near 5% and the 5.3% figure in the #73 commit stands. If it
  stays above ~20% on a quiet day, that constant needs re-measuring and the fail-open reasoning
  needs revisiting. **Two independent readings now both fail this bar** — the fail-open path
  (D2, `docs/HEALTH_ALERTS_SPO2.md`) is real and load-bearing for a THIRD of SpO2 samples, not a
  rare diagnostic corner. The original 5.3% commit citation should be re-derived from source
  before being cited again.
- check-after: 2026-08-18 (ripe now — re-derive the original 5.3% figure's provenance)

### Burst-artifact rejection + first-sighting gate have never run on a real desaturation or a full week
- id: spo2-burst-fix-real-world
- shipped: `fix/spo2-burst-artifacts` 2026-08-18 (#spo2-burst-fix) —
  `SpO2AlertPolicy.isContradicted`/`burstWindow`/`burstContradictionDelta` (D1, rejects a
  candidate a healthy reading seconds away refutes) and `HealthNotificationStore`'s first-sighting
  ledger + `maxNotifiableAge` backstop (D3, a reading gets one chance to fire, on the pass that
  first sees it). Confirmed against the LOGGED incident only — re-deriving the 2026-08-17 20:42
  false positive at its pre-incident watermark now returns `noCorroboration` instead of `fired`
  (see `docs/HEALTH_ALERTS_SPO2.md`). Ships live: changes lowSpO2 output on any run with a tight
  (≤60s) neighbour, and gates every lowSpO2 notification on first-sighting.
- claim: (a) the burst rule does not suppress a genuine desaturation — specifically the overnight
  OSA channel (#91), where readings run at the ~300s sleep cadence, comfortably outside the 60s
  burst window; (b) the first-sighting gate does not silently swallow a legitimate late-arriving
  notification (an overnight reading whose corroborator only lands hours later); (c) daytime
  on-demand bursts, now measured at up to 100 tight pairs across 6 days on this wearer, do not
  produce a NEW false suppression of a real event
- needs: (a) at least one night with a genuine, corroborated overnight desaturation under the
  fixed rule; (b) at least one first-sighting notification that actually posts (proves the ledger
  doesn't over-suppress); (c) roughly a week of ordinary wear with zero new daytime false-positive
  reports
- blocked-because: shipped same day as this entry; no re-staged/re-evaluated data exists yet
  under the fixed rule
- check: `desktop/device_alert_audit.py --pull` after ≥7 days; confirm (i) no new `lowSpO2 FIRED`
  row traces to a burst pair (`contradicted by:` line absent from every FIRED row), (ii) at least
  one FIRED row exists if any real crossing occurred, and (iii) `desktop/device_alert_audit.py
  --not-before <pre-fix watermark>` continues to re-derive the 2026-08-17 incident as suppressed
- passes-if: zero new false-positive `lowSpO2 FIRED` rows over the week, AND at least one
  genuine crossing (if the wearer has one) still fires. A week with ZERO lowSpO2 candidates at
  all is inconclusive, not a pass — bump `check-after` rather than counting silence as success.
- check-after: 2026-08-25

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

### A single global arousalIntensityCut may not be fittable at all — 200 gave 3 and 22 on consecutive nights
- id: sleep-arousal-cut-refit
- shipped: `arousalIntensityCut = 200` is LIVE and unchanged (`SleepStaging.Tuning`,
  `markInteriorArousals`, `docs/SLEEP_INTERIOR_AROUSALS.md` §1b). Nothing was changed in response
  to the 2026-08-18 measurement — this entry exists because the shipped value is now known to be
  wrong-or-unstable, not because a fix is awaiting confirmation.
- claim: the open question is no longer "is 200 the right number" but whether a GLOBAL constant on
  the `[15:20]` intensity tail can work at all. See `sleep-arousal-cut-single-night-fit` under
  `## Settled`: at cut=200 the same code produced 3 awakenings on 08-16/17 and 22 on 08-17/18. If
  no constant lands in a plausible band across nights, the successor is a per-night adaptive
  threshold (e.g. a percentile of that night's own interior tail distribution), not a re-fitted
  constant.
- needs: paired label+epoch nights — a night with BOTH reference labels (Whoop/RingConn, imported
  via Diagnostics) AND its raw epochs still in the archive. Target ≥5 before re-fitting anything.
- blocked-because: ⚠️ THE CORPUS CAN ONLY BE BUILT FORWARD. The raw epoch archive holds roughly
  30 h, and `--sweep-arousal-cut` can only sweep a night whose epochs are still in it — on
  2026-08-18 it reported "no raw epochs in the pulled archive for this night" for all four nights
  older than that. The 2026-08-14/15 night the cut was originally fitted on **can never be swept
  again**; its epochs are gone. Every future night must be pulled WITHIN ~30 h of waking or it is
  lost the same way. Same constraint as `sleep-reference-label-corpus`.
- check: `desktop/sleep_reference_labels.py --pull --sweep-arousal-cut` within 30 h of each night,
  keeping each snapshot; once ≥5 paired nights are banked, look for a cut whose count lands in
  4–10/night on ALL of them
- passes-if: some single cut value puts the merged interior awakening count in 4–10 on every banked
  night (then re-fit `arousalIntensityCut` to it). If the best global cut still spans e.g. 2 and 20
  across nights, that is the REFUTATION of the global-constant approach and the entry closes by
  redirecting to a per-night adaptive threshold — a real outcome, not a failure to check.
- check-after: 2026-08-25

---

- id: lead-in-motion-onset-refit
- shipped: `leadInMotionOnsetMinRun = 6` is LIVE (`SleepStaging.Tuning`, `markLeadInMotionOnset`,
  plus `onsetSearchReach`), fix/sleep-onset-late-start, 2026-08-21. Leading-edge onset pass keyed on
  the DE-FLOORED MOTION channel: onset anchors after the last sustained motion episode in the
  leading region — "sleep starts when the moving stops". Replaces the same-day
  `leadInVitalsAwakeRatio` attempt (refuted, see `## Settled`).
- claim: three things were fitted on ONE night (2026-08-20/21) and none has a second data point yet:
  (a) `leadInMotionOnsetMinRun = 6` epochs (15 min) as the line between a mid-night STIR and getting
  up — measured 3 epochs (~7.5 min) vs 23 (~57 min) on that night; (b) clustering fragments across
  gaps of the same size, needed because a sustained episode lifts its own rolling floor and arrives
  as runs of 3,1,5,3,2,1; (c) `onsetSearchReach` = half the block for THIS pass only. The night it
  was fitted on gives onset 00:41:36 against NOOP 00:48:55 and Apple Watch 00:59:29.
- needs: nights with BOTH a Watch/NOOP/WHOOP asleep label (Diagnostics → "Import reference sleep
  labels") AND the ring's own staged summary in `ZSTOREDSLEEPSUMMARY`. No raw-epoch retention
  constraint: `--onset-error` reads the ALREADY-STAGED stored onset, not a re-simulation, so it
  checks as many past nights as the store holds. **At least one more night with a genuine
  got-up-in-the-middle lead-in is what actually tests this** — an ordinary night only confirms the
  pass stays inert.
- blocked-because: one grounding night. The ~30 h archive means no older night can be replayed
  through the new code, so the corpus can only be built forward — same constraint as
  `sleep-arousal-cut-refit`.
- check: `desktop/sleep_reference_labels.py --pull --onset-error`
- passes-if: across every night with a reference onset label, median |onset error| ≤ 20 min, no
  single night worse than 30 min, and no night where the pass fires and pushes onset LATER than the
  reference by more than 20 min (over-firing — declaring sleep started after it really did — is the
  failure mode this pass can newly cause, and it costs real sleep time).
  Falling short → do not re-fit the constant blindly. Check first WHICH of (a)/(b)/(c) moved: the
  duration bar, the clustering gap, and the reach are independent, and the honest answer may be that
  motion-run length is not a stable discriminator either, the way vitals density was not.
- check-after: 2026-08-28

---

## Settled

### Sleep-vitals DENSITY does not locate onset — refuted the same day it shipped, 2026-08-21
- id: lead-in-vitals-ratio-refit
- was: `leadInVitalsAwakeRatio = 0.6` (`markLeadInVitalsAwake`) shipped that morning on the theory
  that the ring emits sleep-vitals (HRV) epochs more often once the wearer is actually asleep, so a
  thin-density leading run marks quiet wakefulness that HR and motion both read as sleep. Grounding
  measurement: 21% density across the quiet-awake stretch vs 50% once asleep.
- observed: REFUTED by replaying the very night it was fitted on through the real epoch archive
  (`SleepStaging.classify`, not a simulation). It moves onset 22:11 → **22:41**, against a real
  onset of ~00:48 — it recovers 30 min of a ~2.5 h error. The aggregate density gap is real, but
  the pass scans 6-epoch blocks and stops at the first one that is not thin, and the ring's HRV
  emission is irregular enough that a block inside the quiet-awake stretch reads 0.333 against a
  0.283 cutoff. Widening the search horizon to 63, 72, or 96 epochs yields **22:41 in every case**,
  which is what proves the stop rule — not the horizon — is what binds.
- disposition: default set to `0` (disabled). The pass and its tests are KEPT, as a documented kill
  switch and as the record of a refuted approach — same discipline as `arousalIntensityCut` below.
  Superseded by `markLeadInMotionOnset` (`lead-in-motion-onset-refit`, still open), which reads the
  de-floored MOTION channel: on the same night that channel is silent for 175 consecutive epochs of
  real sleep and clearly active across the getting-up, and it lands onset at 00:41:36.
- lesson, and it is the same one twice now: a signal that separates two stretches IN AGGREGATE does
  not necessarily separate them WINDOW BY WINDOW, which is what a scanning pass actually needs.
  Check the per-window distribution before fitting a threshold to a difference of means.

### §1b's fix works; arousalIntensityCut = 200 does NOT generalize — 2026-08-18
- id: sleep-arousal-cut-single-night-fit
- was: does `arousalIntensityCut = 200` (`markInteriorArousals`, `docs/SLEEP_INTERIOR_AROUSALS.md`
  §1b, shipped `feat/sleep-awake-diagnostics` 2026-08-15) produce 5–8 interior awakenings/night —
  RingConn's own 5.8/night — without moving onset or final wake, on real nights generally and not
  just the 2026-08-14/15 night it was fitted on?
- observed, mechanism ✅: the pass is no longer inert. The 08-14/15 night, re-staged 08-16 05:52:44
  (i.e. after the §1b fix), now yields **9 merged interior awakenings / 32.5 m WASO**, where the
  pre-§1b run was byte-identical `0.0m`. Its in-bed window is unmoved at exactly
  `08-14 22:15:56 .. 08-15 08:23:26`, so the strictly-interior guard holds — the whole-block-vs-
  interior channel-selection bug is genuinely fixed. Per-night merged counts across the four nights
  re-staged since the fix: **9, 6, 1, 22**. (The two older nights still showing 0 were last staged
  08-13/08-14, BEFORE the fix — stale staging, not a failure of the pass.)
- observed, value ❌: `--sweep-arousal-cut` on the two nights whose raw epochs were still in the
  archive is what refutes the claim. At cut=200, on **consecutive nights**:

  ```
  08-16 22:07 .. 08-17 08:24   cut=200 →  3 awakenings,  7.5m WASO   (WHOOP labelled 27 in-window)
  08-17 22:20 .. 08-18 08:10   cut=200 → 22 awakenings, 75.0m WASO   (no reference labels)
  ```

  On 08-16/17 no cut swept, down to 50, reaches more than 4 — the tail channel carried almost
  nothing that night against Whoop's 27 labelled awake intervals. On 08-17/18 the same constant
  produces 22. A value that swings 3→22 night to night is not "5–8/night on real nights generally".
  Corroborating: nearly every detected awakening is exactly one 2.5 m epoch, the hallmark of a
  threshold sitting in the noise rather than on a signal.
- note on the numbers: two interior awakenings less than `MERGE_TOLERANCE_SECONDS` (150 s) apart
  merge into one, and the merged span includes the gap — so the canonical metric (the port of
  Swift's `SleepAwakenings.from`, what `--compare-own` prints and what ships) reads **9 awakenings
  / 32.5 m** for 08-14/15, while a raw segment count of the stored hypnogram reads 11 / 27.5 m.
  Both are correct at different definitions; this file cites the merged one throughout.
- provenance: the force-quit + Bluetooth-toggle re-stage run on 2026-08-18 **produced none of this
  data** — max `ZUPDATEDAT` stayed at 08-18 08:28:42, that morning's ordinary re-stage. The recipe
  is not broken; it can only re-stage nights whose epochs are still inside the ~30 h archive, and
  every night here was already outside it. The confirming re-stages had happened on their own.
- still open: see `sleep-arousal-cut-refit` under `## Open` — with the sharper question (can a
  global constant work at all?) and the constraint that the corpus can now only be built forward.

### The sleep-mirror ratchet survived a real re-stage cycle — 2026-08-18
- id: sleep-health-mirror-idempotent
- was: after `fix/health-sleep-mirror-duplicates` (2026-08-17, #health-sleep-mirror-duplicates) —
  `HealthKitWriter.mirrorSettledNight` records a night's mirror signature only once a post-delete
  COUNT confirms the prior copy is gone (`ownSleepCount`), with a verify failure persisting a
  `PendingSleepRepair` that `drainPendingSleepRepairs` retries delete-only on the next flush —
  does a night that re-stages leave Apple Health holding EXACTLY the stored hypnogram's samples,
  with no duplicate accumulated from a delete that silently failed?
- observed: Diagnostics → "Audit Apple Health sleep" on-device at `08-18 12:47:16`, then
  `desktop/sleep_reference_labels.py --pull --audit-own`. The 08-18 night was slept, staged, and
  re-staged by the ordinary morning re-stage on a build installed 08-17 carrying the ratchet —
  the first post-fix re-stage cycle. All six mirrored nights clean, Health own-sample count equal
  to stored segment count with zero same-stage overlapping pairs throughout:

  ```
  night         health  stored  overlaps   versions
    08-13 08:09      32      32         0   41
    08-14 08:16      27      27         0   41
    08-15 08:23      59      59         0   41
    08-16 06:02      38      38         0   41
    08-17 08:24      39      39         0   41
    08-18 08:10      76      76         0   41
  all 6 night(s) clean.
  ```

  `sleep.health.pending-repair.v1` is `[]` — no verify ever failed, so the repair queue was never
  exercised — and exactly one `sleep.mirror.night.*` signature is recorded per night. The four
  nights whose recomputed `sleepSignature` had drifted from the pre-fix mirror in
  `device-snapshot-2026-08-17/` (the evidence the bug was real) are now consistent.
- caveat: the `versions` column carries NO signal here — `CURRENT_PROJECT_VERSION` was not bumped
  for this fix, so pre- and post-fix builds both stamp 41. That clause of the original passes-if
  was trivially satisfied and is not part of what confirmed this.
- still open: the failure limb is unconfirmed. A clean run never enters the verify-failed branch,
  so `PendingSleepRepair` persistence and `drainPendingSleepRepairs`' delete-only retry have still
  never run against a real failed delete. Also untested: the 2026-08-18 `0a15a3e` revision (review
  findings + gating "Rebuild Apple Health sleep" on the Health-write lock) landed AFTER the
  re-stage that confirmed this, so what the 08-18 night exercised is the 08-17 ratchet mechanism,
  not that revision's changes on top of it.

### The evidence fail-open branch fired for the first time — and it was a false positive — 2026-08-18
- id: spo2-fail-open-miss
- was: when a corroborated low-SpO2 run resolves to NO raw `0x4c` records, does the alert fire
  anyway rather than being silently suppressed by a diagnostic detail — AND does that path stay
  safe in practice?
- observed: first-ever exercise, via `desktop/device_alert_audit.py --pull` against the device
  that produced the reported 12h-late notification:
  `[2026-08-17 20:42:12] lowSpO2 FIRED reason=fired value=90 reading=2026-08-17 08:45:51 run=2
  evidence=0/0 bad` — a corroborated run of two on-demand readings, neither resolving to an
  epoch record, took the fail-open path exactly as designed AND the notification did reach the
  phone (confirmed by the wearer independently, ~12h after the reading). So the MECHANICAL half
  of the claim holds: fail-open fired, and fired all the way to a delivered notification, not
  silently swallowed by the shared gate.
- but: the fired verdict was a FALSE POSITIVE. Both "corroborating" 90% readings sat 17 seconds
  from a 98% reading in the same on-demand measurement burst — a burst artifact, not a real
  desaturation, and something fail-open could not have caught even with resolved epochs (the
  epoch-quality gate never runs on the fail-open path by definition). Fixed by
  `fix/spo2-burst-artifacts` — see `docs/HEALTH_ALERTS_SPO2.md` D1 — which rejects a candidate
  contradicted by a healthy reading seconds away, independent of whether it resolves to an epoch.
  Re-derived against the fixed rule at the pre-incident watermark: this row no longer fires
  (`noCorroboration`).
- still open: fail-open remains untested for a run that (a) resolves to no epochs, (b) survives
  burst-artifact rejection, and (c) is a GENUINE desaturation — i.e. the case the branch exists
  to serve, as opposed to the false-positive case that happened to exercise it first. Also see
  `spo2-evidence-miss-rate`: fail-open is now measured load-bearing for ~30% of samples, not a
  rare corner.

### edgeIntensityCut (345) confirmed on a real re-stage — 2026-08-15
- id: sleep-edge-cut-single-night-fit
- was: does `markEdgeMotionAwake` recover real pre-sleep/post-wake movement that a block-scoped
  `motionSource` verdict hides from every other pass, without over-shooting into real sleep, and
  without moving `.inBed` (only onset/final wake inside it)? Passes-if bands, set before checking:
  in-bed window unchanged at exactly `08-14 22:15:56 .. 08-15 08:23:26`; OC head awake in `60..80`
  min (was 0.5m pre-fix); OC interior (WASO) down from 95.0m to `10..45` min (Whoop: 48.5m); OC tail
  awake not grown past its pre-fix ~29.5m.
- observed: built, installed (`com.bly.opencircuit`, personal team `KNK78KA6NE`), and force-launched
  on Jedi Master's iPhone 2026-08-15; the ring reconnected and `restageFromArchive` fired
  automatically (`ZUPDATEDAT` 808531223 → fresh) without needing a manual Bluetooth toggle.
  `sleep_reference_labels.py --pull --compare-own` on the re-staged 08-14/15 night:
  in-bed window **unchanged** (`22:15:56 .. 08:23:26`) — OC head **68.0m** (was 0.5m) — OC interior
  (WASO) **32.5m** (was 95.0m) — OC tail **29.5m** (unchanged). All four bands hit. Onset moved
  22:16 → **23:23:56**, 7 min from Whoop's own 23:31 (was 75 min early); final wake stayed
  **07:53:56** (no significant trailing spike at cut 345 on this night, as `--sweep-edge-cut` had
  predicted). The user's original complaint — reported awake reading ~2h against Whoop's 49 min —
  is now explained: ~68 of the ~120 min is real, Whoop-corroborated sleep latency (falling asleep at
  23:24–23:31, not 22:16), not over-detected wakefulness.
- still open: this is ONE night. The broader claim ("holds on real nights generally") still rests on
  a single confirmation, same caveat as `sleep-arousal-cut-single-night-fit` below — re-check as
  paired label+epoch nights accumulate (`sleep-reference-label-corpus`), and re-sweep
  `arousalIntensityCut` (currently 200, fitted against the OLD 75-min-early onset) now that onset
  has moved — its whole fitting window changed.

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
