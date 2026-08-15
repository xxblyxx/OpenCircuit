# Plan of record — interior arousal detection (option B, narrowed)

> **STATUS: PROPOSED, not built.** Implements the fix for `docs/SLEEP_AWAKE_RESOLUTION.md` §10.
> Read §4 of that doc first. Self-contained: execute without the conversation that produced it.

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

## 4. Choosing the cut

Start at **200** and sweep 100…345 with §2.5, selecting for **5–8 interior awakenings per night** —
the range RingConn's own app produced on this ring (5.8/night, 🟢 24 nights,
SLEEP_AWAKE_RESOLUTION §4.3). Do NOT select for maximum agreement with Whoop's 19: half its events
are sub-epoch and unreachable, so fitting to them would drive the cut into noise.

Record the sweep table in the `Tuning` doc comment, as the other fitted knobs in that file do.

## 5. Acceptance criteria

1. `swift test` green except the one known pre-existing failure
   (`SleepStagingTests.testMidNightWASOIsImmuneToTheRescueButTheMorningTailIsNot` — verify with
   `git stash` against clean `master` before blaming this work).
2. **Onset and final wake are unchanged on all three stored nights.** Check with
   `python3 desktop/sleep_reference_labels.py --compare-own` before and after: the in-bed windows
   in column 1 must be identical. Any movement here means the strictly-interior guard leaked.
3. Interior awakening count moves **0 → 5–8** on the traced night (`--compare-own`, OC interior
   column stops reading 0.0m).
4. `arousalIntensityCut = 0` is byte-identical to today.
5. Total sleep time falls by roughly the new WASO and no more — the reclassified minutes move from
   sleep to awake, they are not lost.

## 6. After it lands

Add a `docs/PENDING_VALIDATION.md` entry: the cut is fitted on ONE night, so it must be re-checked
once ≥ 7 paired label+epoch nights exist (`sleep-reference-label-corpus`). State `passes-if` in
advance: the count stays in 5–8/night on the majority of new nights, and onset/wake stay put.
