# Plan of record — interior arousal detection (option B, narrowed)

> **STATUS: BUILT (2026-08-15).** Implements the fix for `docs/SLEEP_AWAKE_RESOLUTION.md` §10.
> `Tuning.arousalIntensityCut = 200`, shipped and installed. On-device confirmation against a
> REAL re-staged night is still pending — see §5 item 2's note. Read §4 of
> `docs/SLEEP_AWAKE_RESOLUTION.md` first for the motivating measurement.

## 1. What step-1 investigation established (2026-08-15)

Two things changed the shape of this fix from what SLEEP_AWAKE_RESOLUTION §10 assumed:

**🟢 The intensity-tail fallback is ALREADY ENGAGED on the affected nights.** Measured on the
2026-08-14/15 night over the in-bed block `BulkSleep.mainSleep` actually hands staging:
all **239/239** worn epochs are flat `[1,1,1,1,1]` placeholder, and **72** carry a non-zero
`[15:20]` tail — so `BulkSleep.motionSource` returns `.intensityTail(degenerate: false)` and
staging reads the tail, not the dead primary channel. **No channel-selection work is needed.**

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

## 5. Acceptance criteria

1. **DONE** — `swift test`: 1456 tests (7 new), same one known pre-existing failure and no others
   (`SleepStagingTests.testMidNightWASOIsImmuneToTheRescueButTheMorningTailIsNot`; confirmed via
   `git stash` against clean `master` earlier on this branch, unrelated to this change).
2. **DONE algorithmically, PENDING on-device.** `testOnsetAndFinalWakeAreUnchanged` proves the
   guarantee directly (byte-identical `sleepWindow` with the pass on vs off), and every other
   pass/test confirms `lo`/`hi` are fixed before `markInteriorArousals` runs and never
   recomputed after. What's still open: the app has no re-stage-on-demand action, so the THREE
   already-stored nights keep their pre-fix hypnograms until the ring syncs fresh data and
   `classifyContiguous` runs again with the new code — i.e. tonight's sync. Check then with
   `python3 desktop/sleep_reference_labels.py --pull --compare-own`: the in-bed windows (column 1)
   for any newly-staged night must match what a human would expect from that night, and the OC
   interior column should read something in 0–15 min per awakening, not 0.0m flat.
3. **Simulated DONE, on-device PENDING** — the same sync/re-stage gap as #2 applies: `--compare-own`
   still reads the three pre-fix nights until fresh data arrives. `--sweep-arousal-cut` (§4) is the
   simulated version and shows 8 at the chosen cut=200 on the one night it could check.
4. **DONE** — `testKillSwitchIsByteIdentical`.
5. Not yet checkable — needs a real re-staged night (see #2/#3).

## 6. After it lands

Add a `docs/PENDING_VALIDATION.md` entry: the cut is fitted on ONE night, so it must be re-checked
once ≥ 7 paired label+epoch nights exist (`sleep-reference-label-corpus`). State `passes-if` in
advance: the count stays in 5–8/night on the majority of new nights, and onset/wake stay put.
