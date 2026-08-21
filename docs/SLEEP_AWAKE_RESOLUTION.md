# Why brief awakenings don't show on the sleep page — diagnosis + options

Prompted by: Apple Health (Whoop) shows short awake blocks the hypnogram doesn't — e.g. ~00:19–
00:20 and ~01:24–01:28 on 2026-08-14/15. Is this a graphing bug or a categorization issue?

**Answer: categorization, and it is structural rather than a mistuned constant.** As of 2026-08-15
this is no longer an argument from source-reading — it is measured against reference labels from
two independent sources (§4). **No classifier constant has been changed**; this document is the
evidence and the option set, not a fix.

---

## 1. The renderer is innocent

`HypnogramChart` (`ios/OpenCircuit/SleepStagesSection.swift:411-461`) gives `.awake` a **larger**
minimum bar width than every other stage — 2.5pt vs 1.5pt (`:434`) — does no merging of adjacent
segments, and its own SwiftUI preview mock (`:655-660`) is built from 3–5 minute awake bars. The
chart was designed to display exactly the awakenings the classifier never emits. Nothing here
changes.

## 2. Four independent mechanisms each rule out a 1–4 minute awakening

All in `ios/OpenCircuitKit/Sources/OpenCircuitKit/Analytics/SleepStaging.swift`, in the order they
run, with the shortest awakening each admits at default `Tuning`:

| # | Mechanism | Location | Shortest awake it can pass |
|---|---|---|---|
| 1 | Epoch grid is **150 s** | `BulkRecord.epochSeconds` | 2.5 min — a 1-min arousal is sub-resolution |
| 2 | Wake HR is a **±2-epoch rolling median** | `:751` (`hrWakeHalfWindow: 2`) | 7.5 min (3 of 5 epochs must be elevated to move a median-of-5) |
| 3 | `wakeHRMarginBPM: 18`, set deliberately *above* REM elevation | `:750` | a brief arousal's ~5–15 bpm rise usually doesn't clear it |
| 4 | `erodeShortHRWake` deletes any awake run < `minHRWakeRunEpochs: 5` | `:1045-1060` | **12.5 min**, unless an epoch in the run has `motion > awakeMotion (15)` |

`smooth()` (`:968-987`) was the obvious first suspect and is innocent: `minAwakeRunEpochs: 1` makes
its `run < 1` test unreachable, so it never removes an awake epoch.

**Net rule today:** an interior awakening survives only if it carries real wrist motion in at least
one 150-second epoch, or runs ≥ 12.5 min at ≥ floor+18 bpm. (`rescueSecondBoutHRWake`, `:1101`,
additionally erases long *motion-free* awake runs in the [floor+18, floor+25) band, but only ever
touches runs already ≥ 5 epochs — so it is not what erases a 1-minute block; erosion (#4) is.)

## 3. The lever we already decode and throw away

`raw[10:15]` is five per-**30-second** motion counts (`BulkSleep.swift:235`, 🟢 role,
`PROTOCOL.md §5.3`). `BulkSleep.motionTimeline` (`:409-434`) already expands them for the coarse
`SleepDetection.detectFromMotion` path. But staging reads `BulkSleep.motionMagnitudes` (`:668-676`),
which **sums the five bytes into one per-epoch number** before staging sees them. The sub-epoch
signal exists and is decoded elsewhere in the same file; the staged path just doesn't use it.

---

## 4. 🟢 MEASURED: the three-way comparison (2026-08-15)

Reference labels are now read directly out of HealthKit — see §8. This replaced guesswork with a
measurement, and corrected two things this document previously got wrong (§7).

### 4.1 We emit **zero** interior awake segments. Ever.

Three nights where OpenCircuit and Whoop ran on the wearer simultaneously (our own stored
hypnograms from `ZSTOREDSLEEPSUMMARY.ZHYPNOGRAMDATA`, Whoop's from HealthKit):

| In-bed window | OC awake | OC **interior** | Whoop awake | Whoop n | OC efficiency |
|---|---|---|---|---|---|
| 08-12 22:25 → 08-13 08:09 | 37 m | **0.0 m** | 77.6 m | 20 | 0.94 |
| 08-14 02:37 → 08-14 08:16 | 12 m | **0.0 m** | 23.8 m | 14 | 0.97 |
| 08-14 22:15 → 08-15 08:23 | 30 m | **0.0 m** | 48.5 m | 19 | 0.95 |

All six awake segments we produced across three nights sit at an **edge** (sleep onset or final
wake). Not "few" mid-night awakenings — **none, on any night**. We undercount total awake time by
roughly 2×, and the missing minutes are counted as sleep, which is what inflates efficiency to the
implausible 0.94–0.97 range. (08-14 at 0.97 exceeds `SleepConfidence.implausibleEfficiency` = 0.95,
so the flag built for exactly this symptom is already firing.)

> **⚠️ SUPERSEDED for the 08-14/15 row, 2026-08-15 (`fix/sleep-onset-edge-motion`).** Shipping
> `markInteriorArousals` (§1b, same day) made the "zero interior, ever" finding above stop holding
> for that night — but not the way anyone wanted: OC awake jumped **30 m → 120 m**, with **95 m now
> reported as INTERIOR** (WASO), because the block-scoped `motionSource` verdict that hid the
> pre-sleep `[15:20]` movement from every other pass *also* anchored our onset **74.8 min early**
> (22:16 vs Whoop's 23:31, `docs/SLEEP_INTERIOR_AROUSALS.md` §4) — so the newly-live arousal pass
> correctly detected the wearer getting into bed, and correctly-but-wrongly filed it as mid-night
> WASO because it was sitting inside a sleep window that started too soon. Same root mechanism as
> §1b, mirror-image scope: `markEdgeMotionAwake` (`SleepStaging.swift`) fixes it by letting the
> LEADING/TRAILING regions decide their own motion-channel verdict, exactly as §1b's fix does for
> the interior. See its `docs/PENDING_VALIDATION.md` entry (`sleep-edge-cut-single-night-fit`) for
> the not-yet-on-device-confirmed numbers this is expected to produce.

### 4.2 Every real awakening is below our erosion floor

The 19 Whoop intervals on the traced night, in minutes:

```
0.5 0.5 0.5 0.5 0.5 0.5 1.0 1.0 1.5 1.5 2.0 2.5 4.0 4.0 4.5 5.0 5.5 6.0 7.0
```
median **1.5**, max **7.0**.

- **19/19** below `minHRWakeRunEpochs` × 150 s = **12.5 min** → `erodeShortHRWake` deletes all
- **11/19** below a single 150 s epoch → not representable on our grid at *any* threshold

Two independent structural limits, each sufficient on its own. This is why it is not a tuning miss.

### 4.3 The vendor's own app surfaces what we erase — and reveals the achievable target

The official RingConn app wrote to HealthKit until 2026-08-12 (the wearer then switched to
OpenCircuit). That gives 24 nights of **the vendor's own algorithm on this exact ring**:

| Source | Nights | Interior awakenings | Per night | Median | Min | < 12.5 min | < 2.5 min |
|---|---|---|---|---|---|---|---|
| **Whoop** | 3 | 50 | 16.7 | 1.0 m | 0.5 m | 50/50 | **32/50** |
| **RingConn app** | 24 | 140 | 5.8 | 5.0 m | 2.5 m | 137/140 | **0/140** |
| **OpenCircuit** | 3 | **0** | **0** | — | — | — | — |

The `0/140` is the load-bearing cell. **RingConn's own app never reports an awakening shorter than
one 150 s epoch** — strong evidence it stages on the same 150 s grid we do. That splits the goal in
two, and the split should drive any decision:

- **RingConn's profile (5.8/night, ≥ 2.5 min) is reachable inside our current architecture.** It
  needs threshold work, not a redesign — 137/140 of its awakenings die on our erosion floor alone.
- **Whoop's profile (16.7/night, 32/50 sub-epoch) is not**, without leaving the 150 s grid. Its
  finer events are below our sampling resolution, and §3's per-30 s channel is the only route to
  them.

### 4.4 🟢 The ring's intensity tail *does* encode arousals (p = 0.0054)

Per-epoch co-location over the traced night: does a non-zero `[15:20]` intensity tail land on
Whoop-labelled awake time more than chance?

| | tail > 0 | tail = 0 | rate |
|---|---|---|---|
| labelled AWAKE | 21 | 22 | **48.8 %** |
| not labelled awake | 51 | 145 | 26.0 % |

**1.88× lift, Fisher exact two-sided p = 0.0054.** This is the first evidence that the `[15:20]`
magnitudes carry arousal information — `PROTOCOL.md` currently marks their physical meaning 🔴
**not established**, and this does not resolve *what* they measure, only that they are not
independent of wakefulness.

⚠️ **Two honest limits.** Adjacent epochs are autocorrelated, so the effective n is below 239 and
the true p is weaker than 0.0054 — directionally solid, precise value optimistic. And it rests on
**one night** (n = 43 awake epochs), because of the retention constraint in §9.

---

## 5. What the reference projects do (`docs/REFERENCES.md`)

- Our 150 s epoch is the **coarsest of all five**: NOOP 30 s, Gadgetbridge 60 s, Fitbit 60 s,
  GarminDB event-driven, open-wearables source-defined.
- **Gadgetbridge does zero smoothing** — `prepareStages` is a plain run-length encoder, so a
  1-minute awake block survives to its chart intact.
- **Fitbit ships sub-3-minute wake separately** (`levels.shortData`) rather than folding it in.
- **NOOP erases them too**, by a different route: a 3-min `fragmentMergeMin` in the stager with no
  wake exemption, plus a 5-min renderer smoothing. Their measured wake sensitivity is ~30 % on
  independent PSG, 16–17.6 % on their own Whoop-derived nights.
- **No reference project has a dedicated short-wake class.** Garmin's `more_awake` and Fitbit's
  `restless` are intensity labels, not duration classes.

**Scope check.** Whoop is an ESTIMATE, not a sleep lab; the NOOP numbers above are the reason to
say so plainly. Fitting our thresholds to reproduce Whoop's labels would inherit Whoop's errors
along with its sensitivity. The defensible goal is *"our pipeline can represent a brief awakening
at all"* — today it emits zero — not *"our bars match Whoop's minutes."*

## 6. Why no constants were changed

`minHRWakeRunEpochs`, `wakeHRMarginBPM`, `hrWakeHalfWindow` are load-bearing for onset/offset —
roughly twenty commits (`e844442`..`0dc9d50`) tune the *edges* of the night against them, and
`SleepStaging.swift:219-234` records a measured night where `wakeHRMarginBPM` 18→8 collapsed onset
by 117 minutes and cost 157 minutes of sleep. §4 now supplies labels to fit against, but only for
one night with surviving raw epochs (§9) — not enough to move a knob that can cost two hours of
correctly-detected sleep on the nights it governs.

## 7. Corrections this measurement forced

Recorded because both were stated confidently before being checked, and the second would have
become folklore:

1. **"The ring's motion is dead during sleep."** The `[10:15]` primary channel is flat
   `[1,1,1,1,1]` for 100 % of in-sleep epochs but only 41.2 % of the whole archive — it varies
   richly while awake. `PROTOCOL.md` documents `01` = **still, not unworn**. The channel is
   working; it is reporting stillness. An earlier version of `sleep_awake_trace.py` scoped the
   `motionSource` verdict to the strict sleep window, which made a healthy channel read as
   "constant filler" and engaged a fallback the shipped classifier would not use. Fixed.
2. **"RingConn's own app is equally blind."** It is not — §4.3. That claim came from reading `0`
   awake intervals for the traced night without checking date ranges: the RingConn app stopped
   writing on 08-12, so the zero was **absence of data, not a negative result**. Always check
   source coverage before comparing sources.

## 8. Tooling added by this pass

| Tool | What it does |
|---|---|
| `desktop/sleep_awake_trace.py` | Per-epoch trace over the phone's own `sleep.epochArchive` (`--pull` over USB): motion sum, HR, rolling median, wake threshold, raw vs final awake mask, final stage, plus the motion-source verdict and a per-pass kill count. `--at HH:MM --window 20m` to zoom a known wake time. |
| `desktop/sleep_reference_labels.py` | Reads the cached reference labels; `--list-awake`, `--correlate` (the §4.4 2×2), `--export-groundtruth` (emits RingConn-style `sleepPhases` JSON that `ringconn_sleep_fit.py --groundtruth` consumes unmodified). |
| `ExternalSleepSample` + `ExternalSleepCodec` (Kit) | Reference-label model + pinned codec, 13 tests. Keeps `source` on every sample so two vendors can never be silently pooled. |
| `HealthKitWriter.readExternalSleepSamples` | Reads other apps' `.sleepAnalysis` intervals, excluding our own bundle id (else we would measure agreement against ourselves). |
| `ExternalSleepStore` | Caches them in UserDefaults — the prefs plist the `--pull` tooling already fetches. **Nothing in the health pipeline reads it, deliberately:** reference labels must not leak into the classifier they exist to evaluate. |
| Device Info → Diagnostics → *Import reference sleep labels* | The one-tap trigger. |

**`docs/RUNBOOK_SLEEP_GROUNDTRUTH.md` is largely superseded for label capture.** It specifies
mitmproxy plus a Frida certificate-pinning bypass to obtain RingConn's `sleepPhases` from their
cloud; the official app writes the same hypnogram into HealthKit, and the one-tap import above
retrieved 24 nights of it with no interception. The runbook remains the only route for a wearer who
never ran the official app.

⚠️ **HealthKit never reports READ authorization** (a denial could itself leak a health fact). Zero
samples is ambiguous between "Sleep read access is off" and "no other app writes sleep" — the UI
copy and desktop output both say exactly that and name the setting, rather than asserting a cause.

## 9. The binding constraint on doing anything about it

`EpochArchive` retains **~30 hours** of raw epochs; the labels span **30 days**. So:

- 24 nights of RingConn labels — **no surviving raw epochs**, cannot correlate or fit
- 3 nights of Whoop labels — only 08-14/15 has raw epochs
- §4.4's p = 0.0054 therefore rests on exactly **one night**

**Labels and raw epochs must be captured together, nightly, going forward.** The archive rolls over
faster than labels accumulate, so every day without that discards a night permanently. This is the
prerequisite for any fit, and it is the one thing that is time-sensitive.

## 10. Options, in order of risk

- **A — Sub-epoch motion awake.** Feed `motionTimeline`'s 30 s samples into staging so a 1-minute
  burst becomes a 1-minute awake segment. The only route to Whoop's sub-epoch profile (§4.3); uses
  data already decoded; the hypnogram codec is second-resolution and the chart already handles
  narrow awake bars. Risk contained to the motion path — does not touch the HR gates onset/offset
  depend on. Largest change, largest gain.
- **B — Lower `minHRWakeRunEpochs` / exempt tail-corroborated arousals from erosion.** The cheapest
  path to **RingConn's** profile, which §4.3 shows is reachable without leaving the 150 s grid
  (137/140 of its awakenings die on erosion alone). Now defensible in a way it was not before §4,
  but still a knob with onset/offset blast radius (§6) — needs the §9 corpus first.
- **C — Add WASO + awakening-count metrics.** None exist in the repo: only `summary.awake`, one
  scalar pooling edge and interior awake. §4.1 had to be computed by hand from stored hypnograms
  because of this. **No option here is measurable without it**, which argues for doing it first.
- **D — Widen `DecodeAnomaly`.** Unrelated to awakenings, surfaced by the firmware research: it
  catches only all-nil HR and out-of-band temp, so a shifted SpO2/HRV/motion offset from a future
  firmware would decode as plausible-but-wrong and trip nothing. The blood-pressure beta is the
  plausible trigger.

**Recommended order: C → §9 capture → B → A.** C makes the problem measurable, §9 makes it
fittable, B is the cheap reachable win, A is the architectural one. Doing B before C means changing
a high-blast-radius knob with no metric to detect a regression.

Tracked in `docs/PENDING_VALIDATION.md` as `sleep-reference-label-corpus` and
`sleep-tail-encodes-arousal`.

## 11. A related but distinct bug: the chart drew the in-bed envelope, not the sleep window

Everything above is about *interior* awakenings the classifier misses entirely. A separate bug,
found 2026-08-21 (`fix/sleep-onset-late-start`), is about the RENDERER showing correctly-detected
pre-sleep time as if it were sleep: `SleepStagesSection.domain` (the hypnogram's x-axis bounds) took
`min(start)/max(end)` over ALL segments, including the full-span `.inBed` envelope — so the chart
always started at bedtime, not at sleep onset, even on a night where onset was detected correctly.
No option above addresses this; it was never proposed anywhere in this document because it's a
display bug, not a detection gap. Fixed by anchoring `domain.start` on `SleepStaging.sleepWindow(_:)`
with a bounded 30-min lead-in (so a badly-wrong onset stays visible as an anomaly rather than
disappearing off-chart). See the `fix/sleep-onset-late-start` branch.

That same investigation also found a genuine ONSET-DETECTION miss the classifier had not covered.
The wearer was in bed and STILL from 22:11, awake on a phone, got up 23:44–00:39 to work at a
computer, and actually fell asleep ~00:48. Our onset landed at **22:11** — 2.5 h early — because
that first still-but-awake stretch is indistinguishable from sleep on HR (54–73, at the sleeping
floor) and is motionless. Every onset pass this document discusses keys on one of those two channels.

**The fix is `markLeadInMotionOnset` (`Tuning.leadInMotionOnsetMinRun`): anchor onset after the last
sustained motion episode in the leading region — sleep starts when the moving stops.** 🟢 On that
night the de-floored motion channel is silent for 175 consecutive epochs of real sleep and plainly
active across the getting-up, and the pass lands onset at 00:41:36 (NOOP 00:48:55, Apple Watch
00:59:29). Two non-obvious details are load-bearing and are documented on the pass itself: the
episode must be CLUSTERED before it is measured (a sustained episode lifts its own rolling floor, so
it arrives as runs of 3,1,5,3,2,1 rather than one run), and the mid-night-WASO guard has to be the
motion's DURATION, not the usual "consolidated sleep behind it" — on this night the quiet-awake
lead-in reads as asleep, so that guard reverted the fix.

⚠️ A first attempt, `markLeadInVitalsAwake` (sleep-vitals/HRV epoch density), is 🔴 REFUTED and now
ships disabled: the density gap is real in aggregate (21% vs 50%) but not window-by-window, so it
recovered only 30 min of the 2.5 h. See `docs/PENDING_VALIDATION.md` → `lead-in-vitals-ratio-refit`
(Settled) for why, and `lead-in-motion-onset-refit` (Open) for what still needs confirming about the
motion pass. Also `docs/SLEEP_INTERIOR_AROUSALS.md` §4's warning box.
