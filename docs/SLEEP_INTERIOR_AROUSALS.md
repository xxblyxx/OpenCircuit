# Plan of record — interior arousal detection (option B, narrowed)

> **STATUS: BUILT (2026-08-15), SHIPPED INERT, THEN FIXED SAME DAY.** Implements the fix for
> `docs/SLEEP_AWAKE_RESOLUTION.md` §10. `Tuning.arousalIntensityCut = 200` shipped in `75f59ba`,
> re-staged a real night successfully, and produced **no change at all** — see §1a for what was
> wrong and §1b for the fix. Read §4 of `docs/SLEEP_AWAKE_RESOLUTION.md` first for the motivating
> measurement. On-device confirmation against a real re-staged night with the CORRECTED code is
> still pending — see §5.

## 1. What step-1 investigation established (2026-08-15)

Two things changed the shape of this fix from what SLEEP_AWAKE_RESOLUTION §10 assumed:

**🔴 CORRECTED (2026-08-15, same day) — the intensity-tail fallback was NOT engaged on the
whole affected block, and this section originally said it was.** The 239/239-flat-placeholder
measurement below is real, but it was taken over `sleep_awake_trace.py`'s own re-derived sleep
window — **not** the app's actual `BulkSleep.mainSleep` in-bed block, which runs ~8 minutes
longer and includes 3 genuinely-expressive primary-motion epochs (the wearer getting up,
08:16–08:21). `BulkSleep.motionSource`'s `constantFiller` test is all-or-nothing over whatever
set of records it's given — those 3 epochs alone flip the WHOLE BLOCK's verdict to `.primary`.
Evaluated correctly, over the real 243-record block: **3 non-placeholder, verdict `.primary`.**
This is why the pass, as first shipped, ran and touched nothing (§1b).

The narrower claim survives and is the one that matters for §2 onward: the sleep **interior**
(199 epochs, excluding the getting-up tail) really is 239→199/199 flat placeholder with 61
non-zero tails — `.intensityTail(degenerate: false)`, fallback-eligible. §1b's fix is to ask the
question over that interior slice instead of the whole block.

**🟢 The problem is the single cut `motionIntensityActiveCut = 345`, and the split is clean.**
Every epoch clearing 345 on that night — all 24 of them — is at an EDGE:

| Where | Count | Times |
|---|---|---|
| pre-onset (falling asleep) | 22 | 22:16 → 23:21 |
| post-wake | 2 | 07:56, 08:08 |
| **interior (mid-night)** | **0** | — |

Whoop's 19 labelled interior awakenings sit in a LOWER band the cut never sees: tail sums of
131, 194, 243, **329**, 111, 72, 177, 136, 30… (max on any labelled-awake epoch: **329**).

So 345 is correctly calibrated for GROSS movement (getting into/out of bed) and simply cannot
express a brief arousal. `BulkSleep.swift:745-751` already documents that this cut is weakly
supported — "achievable Youden J is only 0.414, the optimum is flat from 150 to 300, and the two
rings with a usable label disagree (280 vs 390)". This plan does not move it.

### Threshold sweep (same night, all epochs)

| cut | hits on labelled-awake epochs | hits elsewhere | of which are the 24 EDGE epochs |
|---|---|---|---|
| 345 (today) | 0 | 24 | 24 |
| 250 | 2 | 29 | 24 |
| 200 | 7 | 33 | 24 |
| 150 | 10 | 38 | 24 |
| 120 | 15 | 39 | 24 |
| 100 | 17 | 41 | 24 |

Subtracting the 24 edges, interior precision against Whoop peaks around 50 % — and "false" here
is measured against a reference whose own wake sensitivity is 16–30 % (SLEEP_AWAKE_RESOLUTION §5),
so some are real arousals Whoop missed. Do not chase a higher number.

## 1b. It shipped, ran, and did nothing — the same-day fix

`arousalIntensityCut = 200` (commit `75f59ba`) re-staged 2026-08-15's night successfully —
`ZUPDATEDAT` moved — and produced byte-identical output: `0.0m` interior awake, same as before
the fix landed.

**Root cause: `markInteriorArousals` was gated on the WHOLE-BLOCK motion-source verdict**
(`BulkSleep.usesMotionIntensityFallback(inBlock)`), not the interior it was about to mark. Of 243
worn epochs in the real block, exactly 3 — all in the final 5 minutes, all the wearer getting
up — were not `[10:15]` placeholders:

| time | primary motion | tail sum |
|---|---|---|
| 08:16:26 | `[1, 73, 31, 38, 49]` | 664 |
| 08:18:56 | `[110, 101, 98, 98, 99]` | 50 |
| 08:21:26 | `[97, 93, 132, 132, 145]` | 361 |

`constantFiller` is all-or-nothing: those 3 flipped the ENTIRE night's verdict to `.primary`, so
the pass correctly refused to run — even though the sleep interior itself (199 epochs, excluding
the getting-up tail) was 100 % dead-primary and fallback-eligible on its own.

**Not a surprise, in hindsight.** `BulkSleep.swift:462-466` already documents exactly this shape:
*"a handful of getting-up epochs disqualify the whole run."* The step-1 investigation read that
comment and didn't connect it to this pass's own gate.

**The fix**: `markInteriorArousals` now decides the verdict on the slice it is about to mark —
`records[lo+1..<hi]` — instead of the whole in-bed block. Same calibrated predicate
(`BulkSleep.usesMotionIntensityFallback`, unmodified), correct window, no new constant. It does
**not** touch `motionSource`/`motionMagnitudes` themselves — `BulkSleep.swift:462-478` measures
widening `constantFiller` globally as unsafe (a placeholder-share threshold swung staged sleep
−85…+45 min across the corpus), and this fix stays entirely clear of that: it's a second,
independent, strictly-interior-only decision consumed by nothing else.

Regression test: `SleepStagingInteriorArousalTests.testGettingUpMotionDoesNotDisableTheInteriorPass`
— reproduces the exact shape (interior all-placeholder, 3 expressive tail epochs), asserts the
premise (whole-block verdict really is `.primary`) so the fixture can't silently stop testing the
real failure, then asserts the interior arousal is still detected anyway.

**Known limitation, left as-is**: one genuine large mid-night movement makes the interior
non-all-placeholder too, disabling the pass for that night. Graceful degradation, not a
regression — that movement already clears `awakeMotion` and surfaces as an awakening through the
existing motion gate; only the smaller stirs on that particular night are lost. The fix is a
placeholder-*share* threshold, which is exactly the kind of constant §1b's own corpus measurement
warns against inventing without evidence. Revisit only if this is observed to bite.

### Measured 2026-08-18 — the fix works, the cut does not generalize

First check of §1b against real re-staged nights. **The fix is confirmed**: the 08-14/15 night
(re-staged 08-16 05:52, after the fix) now yields 9 merged interior awakenings / 32.5 m WASO where
the pre-§1b run was byte-identical `0.0m`, with the in-bed window unmoved — the strictly-interior
guard holds.

**`arousalIntensityCut = 200` does not.** `--sweep-arousal-cut` at that value gave **3 awakenings
on 08-16/17 and 22 on 08-17/18** — consecutive nights, same code. On 08-16/17 no cut down to 50
exceeded 4, against Whoop's 27 labelled in-window awake intervals; and nearly every detection is a
single 2.5 m epoch, which is what a threshold sitting in noise looks like. §4's "DONE, 200 chosen"
should be read as *chosen on one night, since refuted as a global constant*. The live value is
unchanged for now — see `docs/PENDING_VALIDATION.md` → `sleep-arousal-cut-single-night-fit`
(settled, with the numbers) and `sleep-arousal-cut-refit` (open), where the question is now whether
a global constant can work at all or whether this needs a per-night adaptive threshold. Note that
the ~30 h epoch archive means the corpus to decide that can only be built **forward**.

## 2. The change

Add a SECOND, lower cut that applies **only strictly between sleep onset and final wake**, only on
the intensity-tail path. The existing 345 cut is untouched.

Two properties make this low-risk, and both must survive review:

1. **ONSET AND FINAL WAKE CANNOT MOVE.** The new pass runs AFTER `sleepSpan` has fixed `(lo, hi)`
   and marks only `lo < i < hi`, so it can never add leading/trailing awake, and the span is NOT
   recomputed afterwards. This is the whole safety argument — `SleepStaging.swift:219-234` records
   a measured night where a threshold move cost 157 minutes of sleep, and that class of regression
   is structurally impossible here.
2. **INTENSITY-TAIL PATH ONLY.** The primary `[10:15]` channel's magnitudes are a different scale
   (raw byte sums, not the 0/1/16 the fallback emits), and a night with an expressive primary
   channel does not have this problem. Applying a tail-calibrated cut to primary magnitudes would
   be a silent unit error.

### 2.1 Kit — `BulkSleep.swift`

Add beside `motionIntensityFallbackMagnitudes`:

```swift
/// Raw `[15:20]` tail sums per record — the pre-threshold quantity both
/// `motionIntensityFallbackMagnitudes` and the interior-arousal pass threshold. Exposed so the
/// arousal pass can apply its OWN (lower) cut without re-deriving the sum or being handed the
/// already-collapsed 0/1/16 magnitudes.
static func motionIntensityTailSums(_ records: [BulkRecord]) -> [Int]
```

Keep `motionIntensityFallbackMagnitudes` behaviourally identical (it may call the new helper).

### 2.2 Kit — `SleepStaging.Tuning`

```swift
/// Tail-sum cut above which an epoch STRICTLY INSIDE the sleep window counts as a brief arousal.
/// Deliberately far below `BulkSleep.motionIntensityActiveCut` (345), which is calibrated for
/// gross movement and 🟢 measured to fire ONLY at the night's edges (22 pre-onset + 2 post-wake,
/// 0 interior on 2026-08-14/15). **0 DISABLES the pass entirely — byte-identical to pre-#C
/// staging** (the regression escape hatch every other pass in this file carries).
///
/// 🟡 FITTED ON ONE NIGHT against Whoop labels; re-fit as paired nights accumulate
/// (docs/PENDING_VALIDATION.md → sleep-reference-label-corpus).
public var arousalIntensityCut: Int = <fitted, see §4>
```

### 2.3 Kit — `SleepStaging.classifyContiguous`

Thread the tail sums alongside `rawMotion` (~`:690`), then insert the pass immediately AFTER the
span guard at `:846` and BEFORE the `stages` map at `:872`:

```swift
guard let (lo, hi) = sleepSpan(awake, sustain: tuning.onsetSustainEpochs) else { return [] }
markInteriorArousals(&awake, tailSums: tailSums, usesTailChannel: usesTail, lo: lo, hi: hi, tuning: tuning)
```

`markInteriorArousals` sets `awake[i] = true` for `lo < i < hi` where `tailSums[i] >= cut`.
No-ops when `cut <= 0` or `!usesTailChannel`. Do NOT recompute `sleepSpan` after it.

Note it runs after `erodeShortHRWake`, so arousals it adds are never eroded — correct, and the
same exemption motion-driven awake already enjoys ("a real movement is awake however brief",
`SleepStaging.swift:1018-1020`).

### 2.4 Tests — `SleepStagingInteriorArousalTests.swift` (new)

1. `testInteriorArousalBecomesAwake` — synthetic tail-channel night, one interior epoch above the
   cut → an interior `.awake` segment appears where there was none.
2. `testOnsetAndFinalWakeAreUnchanged` — same night with the pass ON vs OFF: `sleepWindow(...)`
   is byte-identical. **The load-bearing test.**
3. `testEdgeEpochsAboveCutAreNotAdded` — epochs above the cut at `lo` and `hi` themselves change
   nothing (strictly-interior guard).
4. `testKillSwitchIsByteIdentical` — `arousalIntensityCut = 0` reproduces current staging exactly.
5. `testPrimaryChannelNightIsUntouched` — a night with an expressive primary channel stages
   identically with the pass on (§2 property 2).
6. `testArousalCountMovesTheMetric` — `SleepAwakenings.from(...)` count goes 0 → N on the fixture,
   i.e. the instrument built in `docs/SLEEP_AWAKENING_METRICS.md` actually observes this.

### 2.5 Desktop — extend `desktop/sleep_reference_labels.py`

Add `--sweep-arousal-cut`: for each candidate cut, re-derive interior awakenings from the stored
hypnogram + archive and print resulting **awakening count per night** beside the reference sources'
counts. This is the fitting instrument for §4 — sweep against the COUNT, not epoch hits.

## 3. Out of scope

Sub-epoch (30 s) motion — SLEEP_AWAKE_RESOLUTION §10 option A, the only route to Whoop's
sub-2.5-min events. Also: no change to `motionIntensityActiveCut`, the HR gates, `wakeHRMarginBPM`,
or `minHRWakeRunEpochs`.

## 4. Choosing the cut — DONE, 200 chosen

Swept 345…50 with `desktop/sleep_reference_labels.py --sweep-arousal-cut` against the
2026-08-14/15 night, selecting for **5–8 interior awakenings per night** — the range RingConn's
own app produced on this ring (5.8/night, 🟢 24 nights, SLEEP_AWAKE_RESOLUTION §4.3). Did NOT
select for maximum agreement with Whoop's 19: half its events are sub-epoch and unreachable.

**A confound was found and corrected before fitting**: the sweep's first pass used OUR OWN
stored onset, which a separate, pre-existing bug placed 74.8 min too early (22:16 vs Whoop's own
23:31 for the same night — our classifier called "asleep" while the wearer was still visibly
getting into bed). That inflated every cut's count by ~2 phantom "arousals" that were really just
real pre-sleep motion. Re-fit against Whoop's OWN labelled onset/wake for that night instead
(a second, independent onset estimate) — this affects only which cut was PICKED, never what ships
(production always uses our own onset/finalWake, exactly as designed):

| cut | awakenings | WASO |
|---|---|---|
| 345 | 0 | 0.0 min |
| 300 | 1 | 2.5 min |
| 250 | 2 | 5.0 min |
| 230 | 2 | 10.0 min |
| **210** | **7** | 22.5 min — closest single-night match to RingConn's 5.8/night average |
| **200** | **8** | 30.0 min — **chosen**: top of the target band, clear of the 230→210 step |
| 150 | 13 | 50.0 min |

200 over 210: both land in range, but 210 sits right at a sharp step (230→210 jumps from 2 to 7),
which makes it more sensitive to exactly which epochs happen to sit near the boundary on any given
night. 200 gives the same practical result with more margin from that step.

Recorded in the `Tuning.arousalIntensityCut` doc comment (`SleepStaging.swift`), which is the
source of truth for this table going forward — update both together if this is ever re-fit.

> **⚠️ The 74.8-min confound above was routed around for the FIT, never for PRODUCTION — until
> `fix/sleep-onset-edge-motion` (2026-08-15).** The paragraph above says outright that using our own
> (broken) onset "affects only which cut was picked, never what ships (production always uses our
> own onset/finalWake, exactly as designed)" — true as written, but it meant production kept
> shipping the 74.8-min-early onset unfixed. The first real re-stage with this pass live confirmed
> the consequence: OC awake for 08-14/15 went 30 m → 120 m, with the new 95 m of "interior arousals"
> almost entirely being that same pre-sleep movement, now correctly detected but sitting inside a
> sleep window that opened too early (`docs/SLEEP_AWAKE_RESOLUTION.md` §4.1's superseded-note).
> `markEdgeMotionAwake` (`SleepStaging.swift`, same mechanism as this file's §1b fix, mirrored to the
> two edges) closes that gap. **Re-sweep `arousalIntensityCut` once the edge fix is confirmed
> on-device** — the 200 above was chosen against a night whose onset is about to change by ~70
> minutes, and every count in the table is downstream of that window.
>
> **The same warning applies again as of `fix/sleep-onset-late-start` (2026-08-21).**
> `markLeadInVitalsAwake` (`SleepStaging.swift`, `Tuning.leadInVitalsAwakeRatio`) can push onset
> LATER by up to 2+ hours on a night with a genuine quiet-awake-in-bed lead-in — a different failure
> mode than `markEdgeMotionAwake`'s (that one moved onset earlier→later by ~70 min; this one moves
> a WRONGLY-early onset later by however long the quiet lead-in actually was). Any night this pass
> fires on invalidates `arousalIntensityCut`'s fitting window the same way the edge fix did. See
> `docs/PENDING_VALIDATION.md` → `lead-in-vitals-ratio-refit`.

## 5. Acceptance criteria

1. **DONE** — `swift test`: 1457 tests (8 new, including the §1b regression test), same one known
   pre-existing failure and no others
   (`SleepStagingTests.testMidNightWASOIsImmuneToTheRescueButTheMorningTailIsNot`; confirmed via
   `git stash` against clean `master` earlier on this branch, unrelated to this change).
2. **DONE algorithmically, PENDING on-device with the §1b fix.** `testOnsetAndFinalWakeAreUnchanged`
   proves the guarantee directly (byte-identical `sleepWindow` with the pass on vs off), and every
   other pass/test confirms `lo`/`hi` are fixed before `markInteriorArousals` runs and never
   recomputed after. What's now known, that wasn't when this line was first written: the app DOES
   re-stage from the persisted archive on reconnect (`RingSession.restageFromArchive`, fired once
   per session at `startKeepalive`), so a forced reconnect (force-quit + Bluetooth toggle + reopen)
   is enough — no need to wait for a fresh overnight sync. The first attempt, on the pre-§1b code,
   proved this (the row's `ZUPDATEDAT` moved) but also proved the pass was inert. Re-run now that
   §1b is installed: force-quit, toggle Bluetooth, reopen, then
   `python3 desktop/sleep_reference_labels.py --pull --compare-own`. The in-bed window (column 1)
   for 08-14/15 must stay EXACTLY `08-14 22:15:56 .. 08-15 08:23:26` — any movement means the
   strictly-interior guard leaked — and the OC interior column should move off `0.0m`.
3. **Simulated DONE, on-device PENDING** — same gap as #2, now one fix closer. `--sweep-arousal-cut`
   (§4) is the simulated version and shows 8 at the chosen cut=200 on the one night it could check;
   that simulation never depended on the whole-block verdict bug (it re-derives interior hits
   directly from archived bytes against a fixed onset/wake), so it stays valid unchanged.
4. **DONE** — `testKillSwitchIsByteIdentical`.
5. Not yet checkable — needs a real re-staged night with the §1b fix installed (see #2/#3).

## 6. After it lands

Add a `docs/PENDING_VALIDATION.md` entry: the cut is fitted on ONE night, so it must be re-checked
once ≥ 7 paired label+epoch nights exist (`sleep-reference-label-corpus`). State `passes-if` in
advance: the count stays in 5–8/night on the majority of new nights, and onset/wake stay put.
