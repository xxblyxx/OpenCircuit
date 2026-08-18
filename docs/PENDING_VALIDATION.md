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
