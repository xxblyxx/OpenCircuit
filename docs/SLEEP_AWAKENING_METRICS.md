# Plan of record — WASO + awakening-count metrics (option C)

> **STATUS: PROPOSED, not built.** This is the implementation plan for option C of
> `docs/SLEEP_AWAKE_RESOLUTION.md` §10. Read §4 of that document first — it is the measurement
> that motivates this one.
>
> **Self-contained on purpose.** An implementer should be able to execute this without the
> conversation that produced it. Where a decision is already made, it says so and gives the reason,
> so it is not relitigated mid-implementation.

## 1. Why

The entire vocabulary for wakefulness today is **one number**: `SleepStaging.Summary.awake`
(`Analytics/SleepStaging.swift:507-530`). It pools three different things:

- pre-sleep awake-in-bed (before sleep onset)
- post-wake lie-in (after final wake)
- **mid-night awakenings** (between the two)

So `awake: 30 min` cannot distinguish *a 30-minute morning lie-in with zero disturbances* from
*six five-minute wakeups*. `StoredSleepSummary` has no other column either — only `awakeMin`.

**This is why the brief-awakening gap survived unnoticed.** 🟢 MEASURED (SLEEP_AWAKE_RESOLUTION
§4.1): across three nights OpenCircuit emitted **zero interior awake segments**, while reporting
`awake: 37m / 12m / 30m` — numbers that look entirely reasonable. Had the card said
**`awakenings: 0`** on a ten-hour night, it would have been obviously wrong long ago. §4.1 had to
be computed by hand from stored hypnogram blobs precisely because no metric expressed it.

**This is the measuring instrument for options A and B.** Changing `minHRWakeRunEpochs` without it
means the only way to detect whether it helped — or whether it wrecked onset/offset — is another
hand computation. With this in place there is a number that should move from 0 toward RingConn's
own 5.8 interior awakenings/night, and an edge-awake regression becomes visible instead of silent.

It also stands alone as a feature: "you woke 6 times" is more useful on the sleep card than
"awake 30m", and it is what Whoop/Oura/Apple all surface as *disturbances*.

## 2. Decisions already made — do not relitigate

### 2.1 DERIVE from the stored hypnogram. Do NOT add SwiftData columns.

**No `StoredSleepSummary` fields, no SchemaV6.** Every night already stores its full staged
hypnogram in `StoredSleepSummary.hypnogramData`, and `LocalStore.hypnogram(night:)`
(`Store/LocalStore.swift:1583-1586`) already decodes it. Everything this plan computes is a pure
function of `[SleepSegment]`, so it can be derived on read.

Two reasons, both load-bearing:

1. **Schema changes here are genuinely dangerous, and that is measured, not assumed.**
   `App.swift:110-135` documents the V4→V5 addition of `hypnogramData`: pointing V4 at the live
   type made a build-34 store fail to open with `NSCocoaErrorDomain 134504`, routing to
   `wipeAndRecoverForeground`, which **deletes every raw `StoredSample`/`StoredCursor`/
   `StoredStepSample`/`StoredDaytimeTemp` row — history the ring cannot re-supply.** It needed a
   frozen nested snapshot of V4 to be safe. A new column means a V6 with that same care, for
   numbers we can compute for free.
2. **Deriving backfills history immediately.** All existing nights with a stored hypnogram get the
   metric retroactively, with no migration and no backfill job.

Cost is negligible: decode is a small JSON blob per night, and the computation is O(segments).

**If a future trend view makes per-night recomputation genuinely hot, revisit then** — with a
measurement, not a guess.

### 2.2 Do NOT invent a reference range for awakening count

`SleepStageBreakdown.referenceRange(for:)` carries population norms **with their sources cited**
and an explicit caveat that they are not the wearer's personal baseline
(`Analytics/SleepStageBreakdown.swift:57-71`). Adding a made-up "normal: 2–5 awakenings" band would
violate the standard that file sets and the one `docs/HEADACHE_SIGNALS.md` §1 argues for at length.

Show the count without a band. If a sourced norm is wanted later it can be added deliberately —
note that the literature figure for *brief arousals* (10–20/night) is not the same quantity as a
consumer device's *awakenings*, and conflating them would be worse than showing no band at all.

### 2.3 Scope: Kit computation + tests + one UI surface

Out of scope for this plan: changing any classifier constant (that is option B), sub-epoch motion
(option A), HealthKit writing (there is no HealthKit type for WASO or awakening count), and trend
charts over history.

## 3. Definitions — be precise here, this is where it goes wrong

Given a night's `[SleepSegment]`:

| Term | Definition |
|---|---|
| **onset** | `SleepStaging.sleepWindow(segments)?.onset` — earliest start of any asleep segment (`asleepCore`/`asleepDeep`/`asleepREM`) |
| **final wake** | `SleepStaging.sleepWindow(segments)?.wake` — latest end of any asleep segment |
| **interior awake** | `.awake` segments clipped to `[onset, finalWake]` |
| **awakening** | one maximal run of *contiguous* interior awake, after merging (see §4.1) |
| **awakeningCount** | number of such runs |
| **waso** | total duration of interior awake (Wake After Sleep Onset) |
| **longestAwakening** | duration of the longest run, `0` when none |
| **edgeAwake** | total `.awake` duration **minus** `waso` — the pre-onset + post-wake time |

**Invariant, and it must be a test:** `waso + edgeAwake == SleepStaging.summary(segments).awake`
(within floating-point tolerance). If that fails, the split is wrong somewhere.

`nil`/empty behaviour: a night with **no asleep segments at all** has no onset, so it has no
interior and no awakenings — return a zeroed value, never crash, never treat the whole night as one
awakening.

## 4. Traps

Each of these has bitten an existing analytic in this codebase; they are not hypothetical.

### 4.1 Adjacent awake segments MUST be merged before counting

Segments that touch (`a.end == b.start`) are **one** awakening, not two. The run-length encoder in
`classifyContiguous` (`SleepStaging.swift:902-913`) merges same-stage runs *within* a fragment, but
two other paths can produce touching awake segments anyway:

- `applyBedtimeWiden` (`:580-599`) **appends** an `.awake` segment and re-sorts
- a stitched multi-fragment night **concatenates** each fragment's segments (`:557-560`)

Counting raw segments would overcount. Merge first.

### 4.2 A data gap splits a run — and is not awake time

In a stitched night, fragments are separated by real gaps where the ring recorded nothing. Two
awake segments on either side of a gap are **not** one awakening, and the gap itself must not be
counted as awake (`SleepStaging.summary` already excludes inter-fragment gaps from `inBed` for
exactly this reason, `:937-941`).

Policy: merge two awake segments only when they **touch within a small tolerance**. Use
`BulkRecord.epochSeconds` (150 s) as that tolerance — one epoch of slack absorbs rounding without
bridging a real gap. Document the choice where it is made.

### 4.3 `.inBed` overlaps everything — filter it out first

`.inBed` tiles the whole window underneath every other segment (`:897`). Any code that iterates
segments without filtering it will double-count. `SleepStaging.stageTotals` (`:923-927`) and
`SleepDetailMetrics.averageHRByStage` both filter it; do the same.

### 4.4 Clip, don't assume

By construction the pre-onset awake segment ends exactly at onset, so clipping to
`[onset, finalWake]` is usually a no-op. Clip anyway — `applyBedtimeWiden` and the multi-fragment
path both mutate the segment list after staging, and a straddling segment must contribute only its
interior portion to `waso`.

## 5. Implementation

### 5.1 Kit — `ios/OpenCircuitKit/Sources/OpenCircuitKit/Analytics/SleepAwakenings.swift` (new)

Pure, no I/O, no SwiftUI — same shape as `SleepDetailMetrics`/`SleepStageBreakdown`.

```swift
public struct SleepAwakenings: Equatable, Sendable {
    public let count: Int                  // interior awakenings
    public let waso: TimeInterval          // wake after sleep onset
    public let longest: TimeInterval       // longest single awakening, 0 when none
    public let edgeAwake: TimeInterval     // pre-onset + post-wake awake
    public let intervals: [DateInterval]   // the merged interior runs, in order

    public var minutes: (waso: Int, longest: Int, edgeAwake: Int) { … }
}

public extension SleepAwakenings {
    /// Derive from a night's staged segments. Zeroed when the night has no asleep segments.
    static func from(segments: [SleepSegment]) -> SleepAwakenings
}
```

Keep `intervals` — the UI may want to mark them on the hypnogram later, and tests assert on them
directly rather than only on the count.

Algorithm: filter out `.inBed` → get onset/finalWake via `SleepStaging.sleepWindow` → take `.awake`
segments, clip to `[onset, finalWake]`, drop empties → sort by start → merge runs touching within
150 s → derive the four scalars.

### 5.2 Kit tests — `Tests/OpenCircuitKitTests/SleepAwakeningsTests.swift` (new)

Required cases, each pinning something from §3/§4:

1. **`testEdgeOnlyNightHasZeroAwakenings`** — awake before onset and after final wake only.
   Expect `count == 0`, `waso == 0`, `edgeAwake == total awake`. **This is the current real-world
   shape** (SLEEP_AWAKE_RESOLUTION §4.1) and documents the bug this metric exists to expose.
2. **`testInteriorRunsAreCounted`** — three separated interior awake blocks → `count == 3`, `waso`
   equals their sum, `longest` is the largest.
3. **`testAdjacentAwakeSegmentsMergeIntoOneAwakening`** — two touching `.awake` segments → `count == 1`
   (§4.1).
4. **`testGapLongerThanToleranceSplitsTheRun`** — two awake segments separated by > 150 s of nothing
   → `count == 2` (§4.2).
5. **`testInBedSegmentIsIgnored`** — same night with and without the overlapping `.inBed` segment
   produces identical results (§4.3).
6. **`testAwakeStraddlingOnsetContributesOnlyItsInteriorPart`** (§4.4).
7. **`testWasoPlusEdgeEqualsSummaryAwake`** — the §3 invariant, over several shapes. Prefer a small
   randomised loop (fixed seeds, as `SleepStagingLeadingWakeTests.testExemptionOnlyEverAddsAwake`
   does) so it holds generally, not just on hand-picked fixtures.
8. **`testNightWithNoAsleepSegmentsIsZeroed`** — no crash, no phantom awakening.
9. **`testEmptySegmentsIsZeroed`**.

### 5.3 UI — one surface

**`ios/OpenCircuit/SleepStagesSection.swift`** already renders per-stage stat rows with a
`StageStatRow` (~`:598-650`). Add an **Awakenings** row near the Awake row:

- value: `count` (e.g. `6`), plus WASO as the secondary duration using
  `SleepStageBreakdown.durationText(minutes:)` so formatting matches the existing rows
- **no reference-range ticks** (§2.2) — the row must render correctly without them, so check
  `StageStatRow`'s tick rendering handles a nil range, or use a simpler row type
- derive from the same `[SleepSegment]` the section already has; do not thread a new dependency

Copy: `"Awakenings"` with a value like `6 · 24min`. When `count == 0` on a night with real sleep,
show `0` plainly — a zero here is information, not an empty state, and must not be hidden.

### 5.4 Desktop verification — extend `desktop/sleep_reference_labels.py`

Add a mode that computes the same three numbers from the stored hypnograms in
`captures/device-snapshot/default.store` (`ZSTOREDSLEEPSUMMARY.ZHYPNOGRAMDATA`) and prints them
beside the reference-label counts — i.e. reproduce the SLEEP_AWAKE_RESOLUTION §4.1 table
automatically instead of by hand. This is what turns the table into a repeatable check.

## 6. Acceptance criteria

1. `swift test` passes, with the **one known pre-existing failure** and no others:
   `SleepStagingTests.testMidNightWASOIsImmuneToTheRescueButTheMorningTailIsNot` (fails identically
   on clean `master` — verify with `git stash` before blaming this work).
2. **The metric reproduces the hand-computed result**: run against the three stored nights and get
   `awakenings == 0` on all three, matching SLEEP_AWAKE_RESOLUTION §4.1. **A non-zero answer here
   means the metric is wrong, not that the bug is fixed** — nothing in this plan changes staging.
3. The §3 invariant holds (`waso + edgeAwake == summary.awake`).
4. The sleep card shows the row, and shows `0` rather than hiding it.
5. No new SwiftData columns; no `SchemaV6`; the store opens without migration.

## 7. Verification

```bash
cd ios/OpenCircuitKit && swift test --filter SleepAwakeningsTests   # new tests
cd ios/OpenCircuitKit && swift test                                 # full suite (expect the 1 known failure)

# Build + install (see CLAUDE.md "Build & deploy" — note --spec project.local.yml)
cd ios
DEV=819D37A3-B45A-56CF-9FEC-40D460EC74F8
xcodegen generate --spec project.local.yml
xcodebuild -project OpenCircuit.xcodeproj -scheme OpenCircuit -configuration Debug \
  -destination "id=$DEV" -allowProvisioningUpdates build

# Reproduce §4.1 automatically
python3 desktop/sleep_reference_labels.py --pull --compare-own   # (name per 5.4)
```

## 8. After this lands

`docs/PENDING_VALIDATION.md` → `sleep-reference-label-corpus` and `sleep-tail-encodes-arousal` are
the gate on option B. This plan does **not** satisfy either: it adds the instrument, not the
evidence. Option B still needs the paired label+epoch nights described in
SLEEP_AWAKE_RESOLUTION §9 — and that capture is the one time-sensitive item, because the ~30 h
`EpochArchive` retention discards a night permanently for every day it is not paired.

Once both exist, the success measure for option B is concrete and stated in advance: **interior
awakening count moves from 0 toward RingConn's own 5.8/night, without edge-awake or onset/offset
regressing** — which is exactly what this metric makes observable.
