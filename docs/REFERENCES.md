# REFERENCES — other people's projects we read for ideas

Five related open/source-available projects are kept as local read-only clones in
`refs/` so we can grep them while designing and troubleshooting OpenCircuit. They
cover the two things we keep needing: **how a proprietary wearable's BLE protocol
gets reverse-engineered and parsed**, and **how each health metric is turned into a
chart a human can read**.

```bash
scripts/sync-refs.sh          # clone/refresh all of them into refs/ (gitignored)
scripts/sync-refs.sh noop     # or just one
```

---

## ⚖️ The rule: read for FACTS, never copy CODE

> This is not boilerplate. **Two of these are copyleft and one is noncommercial**,
> and OpenCircuit is a **public** repo. Pasting their code in would be a real
> licensing problem, and the most tempting one (NOOP) is the most restrictive.

**Facts are free.** Byte layouts, opcode numbers, checksum algorithms, sensor
semantics, schema columns, units, "SpO2 reads best as a banded time series with a
90% reference line" — none of that is copyrightable. Take it, and cite where it
came from.

**Implementations are not.** Do not copy their source into `ios/` or `desktop/`,
and do not paraphrase a file closely enough that it is a translation. Read it,
understand the approach, close the file, write ours.

NOOP's own LICENSE draws exactly this line, which is worth quoting because it is
the posture we should apply to all five:

> The protocol facts documented in this repository (BLE service/characteristic
> identifiers, frame layouts, CRC parameters, command/event/packet numbers, byte
> offsets) are uncopyrightable factual information about how bytes appear on a
> wire. They are not claimed as anyone's property and may be reused freely.

| Repo | License | Practical meaning |
|---|---|---|
| `refs/noop` | **PolyForm Noncommercial 1.0.0** | Source-available, *not* OSI open source. Code is off-limits; the author explicitly frees protocol facts (above). GitHub reports `NOASSERTION` only because PolyForm isn't an SPDX-standard license — it **is** licensed. |
| `refs/Gadgetbridge` | **AGPL-3.0** | Strong copyleft. Facts yes, code absolutely not. |
| `refs/GarminDB` | **GPL-2.0** | Copyleft. Facts yes, code no. |
| `refs/open-wearables` | MIT | Permissive — the one place we could actually borrow code, with attribution. Its score *algorithms* are documented in prose, so we don't even need to. |
| `refs/fitbit-grafana` | BSD-4-Clause | Permissive, attribution required. Note the "4-clause" advertising clause. |

**When in doubt, delegate the reading.** Having a subagent read AGPL/PolyForm
source and report back in prose keeps the implementation out of the main context
entirely, so it can't bleed into Swift we write an hour later. That containment is
worth more than the token cost.

---

## Start here: if you're working on X, read Y

| Working on | Read |
|---|---|
| **Sleep hypnogram rendering** | `refs/noop/Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift` — hand-built Canvas, because banded duration-width bars don't express well in Swift Charts. Its key idea: **smooth for display, compute totals from raw.** |
| **Hypnogram decode from a ring** | `refs/noop/Packages/OuraProtocol/Sources/OuraProtocol/HypnogramAssembler.swift` — reconstructs a sleep time axis from a burst-written event log. Closest analog anywhere to our RingConn problem. |
| **How to *store* sleep stages** | Run-length segments (stage + duration), not fixed epochs — see the Yawell/Colmi section below. Canonical 7-state vocabulary incl. a generic `SLEEPING` fallback: `refs/open-wearables/backend/app/constants/sleep.py`. |
| **Which chart for which metric** | `refs/fitbit-grafana/Grafana_Dashboard/` dashboard JSON — 30 panels, each an explicit chart-type + threshold decision. Parse with `jq`, don't dump it. |
| **HealthKit writing & dedup** | `refs/noop/StrandiOS/Health/HealthKitBridge.swift` — deterministic `HKMetadataKeyExternalUUID` (`deviceId + metric + day`) + delete-then-save scoped to own source, because HealthKit has no upsert. |
| **Background sync (#119)** | NOOP runs sync on **CoreBluetooth state restoration**, not `BGTaskScheduler` — its BGTask use is only a debug export. See `refs/noop/Strand/BLE/BLEManager.swift` (`willRestoreState`). Compare against `docs/BACKGROUND_SYNC.md`. |
| **Resumable history sync** | `refs/noop/Strand/Collect/Backfiller.swift` — decode → insert → cursor commit → ack "safe-trim" invariant. Compare to our `SyncCursor`. |
| **BLE history paging on a ring** | `refs/Gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/yawell/ring/YawellRingDeviceSupport.java` — client-driven paging + multi-packet reassembly to a declared length. |
| **Opcode table organization** | `refs/Gadgetbridge/.../devices/yawell/ring/YawellRingConstants.java` — one file, whole command set. Good precedent for a Swift opcode enum. |
| **Hypnogram, the other implementation** | `refs/Gadgetbridge/.../activities/charts/sleep/SleepDetailsView.java` — hand-drawn Canvas, same conclusion NOOP reached independently. |
| **Derived scores (Phase 5)** | `refs/open-wearables/docs/scores/sleep-score.mdx` and `resilience-score.mdx` — fully specified in prose, MIT, with citations. Implementable outright. |
| **Raw vs rollup data modeling** | `refs/GarminDB/garmindb/garmindb/monitoring_db.py` (per-reading) vs `garmin_db.py` (nightly) vs `refs/GarminDB/garmindb/summarydb/summary_base.py` (min/avg/max triad per period). |
| **Chart perf over long series** | `ChartDownsample` in `refs/noop/Packages/StrandDesign/Sources/StrandDesign/TrendChart.swift` — min/max per bucket, not average, so spikes survive decimation. |
| **Circadian / by-hour views (#183)** | fitbit-grafana's "Sleep Regularity" and "Hourly walk heatmap" panels — hour-of-day × day-of-week heatmap. Good fit for headache-signal-by-hour. |
| **Physiological alert design (corroboration, false-positive suppression)** | No project here ships a low-SpO2/high-HR alert — see "Where none of these help" below. The one transferable *pattern* is `refs/noop/Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift`: `minCorroboratingSignals = 2` ("a single noisy night can never raise"), same-day confounder dampening, and a *fractional* (never binary) off-wrist rejection rule. Ported as a pattern, not code, into our low-SpO2 gate (`ios/OpenCircuitKit/Sources/OpenCircuitKit/HealthAlerts.swift`, `SpO2AlertPolicy`). |

---

## 1. `refs/noop` — ryanbr/noop ("Strand") · Swift · PolyForm Noncommercial

**Why it's here:** the closest sibling project that exists. Offline WHOOP companion —
same problem shape as ours (proprietary wearable over BLE → on-device store →
HealthKit → charts), different device. Monorepo: iOS app (`StrandiOS/`), macOS app
(`Strand/`), Android (`android/`), over five platform-pure Swift packages
(`Packages/WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandImport`,
`StrandDesign`) — an architecture close to our `OpenCircuitKit` split.

**It also carries an experimental Oura *ring* driver** (`Packages/OuraProtocol/`),
which is the single most relevant thing in any of these five repos to our device.

Start with `refs/noop/docs/ARCHITECTURE.md` — it's a genuinely good system map.

### Charts

| Path (under `refs/noop/`) | What | Why it matters |
|---|---|---|
| `Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift` | Canvas/Shape banded sleep timeline with display-time smoothing | Our hypnogram priority, done well |
| `Packages/StrandDesign/Sources/StrandDesign/TrendChart.swift` | Swift Charts line/area/bar, gradient-by-value, crosshair, `ChartDownsample` | Reusable trend component + the min/max downsampler |
| `Packages/StrandDesign/Sources/StrandDesign/OverviewHRChart.swift` | Day-view HR/sleep/effort overlay, pinch-zoom, explicit x-axis window | **Gap handling**: fixes the axis domain so missing data is blank, not interpolated |
| `Packages/StrandDesign/Sources/StrandDesign/Palette.swift` | `StrandPalette` — light/dark color-ramp stops per domain (recovery, strain, sleep stage, HR zone, stress) | One source for every chart gradient; mirror the structure, not the colors |
| `Packages/StrandDesign/Sources/StrandDesign/DomainTheme.swift` | Per-metric theme registry (gradient/label/unit) | Ties metric identity to chart styling in one place |
| `Packages/StrandDesign/Sources/StrandDesign/RecoveryRing.swift`, `StrainGauge.swift`, `BevelGauge.swift` | Radial gauges for derived 0–100 / 0–21 scores | Renders *derived scores* distinctly from raw series |
| `Packages/StrandDesign/Sources/StrandDesign/YearHeatStrip.swift` | Year contribution grid; `nil` day = faint inset square | A concrete missing-data convention |
| `Packages/StrandDesign/Sources/StrandDesign/Sparkline.swift`, `TypicalRangeBar.swift`, `PipBar.swift` | Inline micro-trend, "typical range" band, discrete pip bars | Small-multiple encodings for card rows |
| `Packages/StrandDesign/Sources/StrandDesign/ChartHover.swift` | Shared crosshair/tooltip machinery | Shared chart-component layer |
| `Strand/Screens/SleepView.swift`, `TrendsView.swift`, `TodayView.swift` | Real call sites assembling the above | How charts actually get fed |

**Ideas worth taking:**

- **Two chart technologies, chosen deliberately.** Swift Charts for continuous
  numeric domains (trends, day HR overlay). Hand-built `Canvas`/`Shape` for things
  Charts can't express cleanly — the hypnogram's square-ended duration bars with
  round-capped risers, and the radial gauges. A good model for us.
- **Smooth for display, compute from raw.** The stager emits 30s epochs;
  sub-minute flicker is coalesced *only for rendering* (a `smoothingSeconds`
  parameter), while all totals and percentages come from the raw unsmoothed
  segments. Directly applicable to a RingConn hypnogram.
- **Min/max bucketing, not averaging.** Above a vertex threshold each bucket
  contributes only its min and max in chronological order, so HR/HRV/SpO2 spikes
  are never smoothed away.
- **Stable content-derived `Identifiable` ids** (stage+start+end, or the `Date`
  itself) rather than `UUID()` — their comments flag this repeatedly as the fix for
  SwiftUI/Charts re-animating on every hover.

### BLE / storage / HealthKit

| Path (under `refs/noop/`) | What | Why it matters |
|---|---|---|
| `Strand/BLE/BLEManager.swift` | The only CoreBluetooth surface: scan→connect→discover→bond→subscribe, keep-alive watchdog, auto-reconnect, `willRestoreState` | Reference lifecycle state machine; also where background sync actually lives |
| `Strand/BLE/FrameRouter.swift` | Pure decode→state router, no CoreBluetooth dependency | Clean "what arrived" vs "what it means" split |
| `Strand/Collect/Collector.swift`, `Backfiller.swift` | Live cadence buffering vs historical offload, with a trim-ack cursor invariant | Resumable-sync pattern for a device with an on-board buffer |
| `Strand/Collect/ClockCorrelation.swift`, `ClockPolicy.swift` | Device-monotonic-epoch ↔ wall-clock offset | Applicable if RingConn timestamps are device-relative |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift` | CRC8 / CRC16-Modbus / CRC32, frame verification, fragment `Reassembler` | Reassembly + checksum-gating patterns |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Schema.swift` | Declarative `FieldSpec`/`PacketSpec` describing layouts, loaded rather than switch-per-packet | "No hardcoded hex in app code" — worth considering for our opcode table |
| `Packages/WhoopStore/Sources/WhoopStore/` | GRDB/SQLite actor; composite natural-key PKs with idempotent `ON CONFLICT` upserts | **Their dedup strategy is DB-level upsert on natural keys**, not app-level "seen it" tracking. Compare to our `SyncCursor`. |
| `StrandiOS/Health/HealthKitBridge.swift` | Auth scoping (`quantityReadIds` / `quantityWriteIds` / `highResQuantityWriteIds`), anchored observer queries, write-back | **Highest-value single file for our HealthKit layer.** Read/write type sets are deliberately asymmetric. |
| `Packages/OuraProtocol/Sources/OuraProtocol/` | An actual BLE **ring** driver: generation dispatch, MTU clamping, history drain, hypnogram assembly | Read before designing RingConn's decode layer |
| `docs/OURA_PROTOCOL.md`, `docs/DEVICE_SUPPORT_ROADMAP.md` | Byte-level ring spec + honest gap list | Their own docs admit on-device staging undercounts deep/REM vs the vendor app — useful expectation-setting for our staging accuracy claims |

**Caveats:** `OuraProtocol` is explicitly experimental and gated, not a shipped
supported device — treat it as a decode-pattern reference, not a validated staging
algorithm. Strap-class features (raw PPG/ECG buffers, haptic coaching, double-tap
input) have no ring equivalent. `Packages/StrandAnalytics` (their HRV/recovery/
strain math) has **not** been surveyed yet — it needs its own pass if we want to
compare against our Baevsky/TRIMP ports.

---

## 2. `refs/Gadgetbridge` · Java/Android · AGPL-3.0

**Why it's here:** ~70 reverse-engineered wearables under one abstraction. The
richest source of "how does a proprietary wearable protocol actually get
structured" prior art — and it supports **a dozen rings**.

> ⚠️ **Track Codeberg, not GitHub.** The GitHub repo is an archived mirror, stale
> since 2024-12-22. `scripts/sync-refs.sh` points at
> `codeberg.org/Freeyourgadget/Gadgetbridge`. If you find yourself reading a clone
> whose HEAD is from 2024, re-run the sync script — the ring code and the sleep
> charts were both substantially restructured after that date.

Layout: a `DeviceCoordinator` (detection, capability flags) paired with a
`DeviceSupport` (the GATT conversation), split across two parallel trees keyed by
vendor — `devices/<vendor>/` and `service/devices/<vendor>/` — with
`model/DeviceType.java` as the registry. All under
`app/src/main/java/nodomain/freeyourgadget/gadgetbridge/`.

### 🔑 The Yawell/Colmi ring family — the closest protocol analog we've found

> **Path note:** these rings used to live under `devices/colmi/`. In the current
> tree they are `devices/yawell/ring/` and `service/devices/yawell/ring/` — Yawell
> appears to be the actual OEM behind the Colmi-branded rings. Any older write-up
> (including ours, before 2026-08-13) citing `ColmiR0x*` filenames is stale.
> Unrelated: `devices/moyoung/` holds Colmi-branded *watches*, a different platform.

One coordinator family covers **Colmi R02/R03/R06/R07/R09/R10/R12, H59, and Yawell
R05/R10/R11** (`devices/yawell/ring/`, all extending
`AbstractYawellRingCoordinator.java`). Structurally adjacent to RingConn Gen 2 —
with divergences that matter more than the similarities:

| | RingConn Gen 2 (ours, 🟢 confirmed) | Yawell/Colmi ring (verified in source, 2026-08-13) |
|---|---|---|
| Frame | `[cmd][len][payload][xor]` | Fixed **16 bytes**, byte 0 = opcode, **byte 15 = arithmetic sum mod 256** of the preceding bytes |
| Bulk payload integrity | same XOR byte | a *second* scheme: **CRC16-Modbus** (`YawellRingPacketHandler.crc16Modbus`) |
| Response opcode | `cmd XOR 0x80` | **Same opcode as the request** |
| Link security | Plaintext, no auth handshake | Plaintext, `BONDING_STYLE_NONE` |

> **These are facts about Yawell/Colmi, not about RingConn.** Do not import them
> into `docs/PROTOCOL.md` as OpenCircuit claims. Their value is as a *sanity check*
> — "is this the sort of thing rings in this tier do?" — and as a warning that our
> `cmd XOR 0x80` convention is a RingConn choice, not a market standard.

Verified facts (all from `devices/yawell/ring/YawellRingConstants.java` unless noted):

- **Whole command set in one file.** Set time `0x01`, battery `0x03`, preferences
  `0x0a`, **HR history sync `0x15`**, realtime HR `0x1e`, packet size `0x2f`,
  stress sync `0x37`, HRV sync `0x39`, activity sync `0x43`, find device `0x50`,
  manual HR `0x69`, notification `0x73`, **big-data-v2 `0xbc`**, factory reset
  `0xff`. A clean precedent for centralizing a RingConn opcode enum in Swift.
- **Two BLE generations coexist** behind stable app-level opcodes: Nordic-UART-style
  `6e40fff0-…` (write `6e400002`, notify `6e400003`) and `de5bf728-…` (command
  `de5bf72a`, notify `de5bf729`). This tier iterates transport while keeping
  commands fixed — worth expecting if RingConn revises firmware.
- **Bulk history is multiplexed** behind `0xbc` + a subtype byte:
  **temperature `0x25`, sleep `0x27`, SpO2 `0x2a`, alarms `0x2c`**. Chunks are
  concatenated into a growing buffer until a declared uint16 length is reached
  (`service/devices/yawell/ring/YawellRingDeviceSupport.java`).
- **Client-driven paging** — after each page the support class explicitly requests
  the next chunk/day; the device does not stream unprompted.
- **Sleep stages are run-length encoded**: stage byte + duration in minutes per
  segment, with session start/end as *minutes after midnight* — one record per
  transition, not per epoch (`YawellRingPacketHandler.historicalSleep()`).
- **Sleep stage encoding**: light `0x02`, deep `0x03`, REM `0x04`, awake `0x05`.
- **Resolutions** (`YawellRingPacketHandler`): stress and HRV on a **30-minute**
  grid; SpO2 as one **min/max pair per hour**; temperature at `:00` and `:30`
  (half-hourly); HR history interval is a **configurable device preference**, not a
  fixed slot size.
- **No on-device derived metrics** — sleep score / stress arrive pre-summarized
  from the device rather than being computed client-side.
- **No auth handshake.** Two independent budget rings with plaintext, unbonded
  links means our PROTOCOL.md §0 finding reflects the market norm, not a RingConn
  quirk.

The other ring, **Femometer Vinca II** (`devices/femometer/`), is a basal-temperature
device that looks like plain GATT with no custom framing — a useful contrast
showing the Yawell-style custom framing is the RingConn-like case, not the default.
(This "no custom framing" read is provisional — a grep, not a full audit.)

### Everything else

| Path (under `refs/Gadgetbridge/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/`) | What | Why it matters |
|---|---|---|
| `devices/yawell/ring/YawellRingConstants.java` | Full opcode / UUID / stage-byte table | Densest concrete fact source; read first |
| `service/devices/yawell/ring/YawellRingDeviceSupport.java` | Packet build + sum checksum (~L465), CRC16 for bulk (~L482), opcode dispatch, big-data reassembly, history paging | Richest "how a ring pages multi-day history" file |
| `devices/yawell/ring/YawellRingPacketHandler.java` | Static parsers: raw payload → typed samples (`historicalSleep`, `historicalSpo2`, `historicalTemperature`), plus `crc16Modbus` | Parser layer split cleanly from transport — mirror this as pure `Data`→sample functions |
| `devices/yawell/ring/AbstractYawellRingCoordinator.java` | Shared coordinator: capability flags, `getBondingStyle()` | Where the whole ring family's behaviour is declared |
| `devices/yawell/ring/samples/ColmiActivitySampleProvider.java`, `entities/AbstractColmiActivitySample.java` | Sample provider + entity for the ring family | Maps onto SwiftData model types |
| `devices/DeviceCoordinator.java`, `AbstractDeviceCoordinator.java`, `model/DeviceType.java` | Device-family abstraction + registry | Skim only — we target one ring |
| `service/btle/AbstractBTLEDeviceSupport.java`, `TransactionBuilder.java`, `BtLEQueue.java` | Queued GATT transactions | Concept transfers (serialize writes); the API shape does not |
| `activities/charts/sleep/SleepDetailsView.java` | **Dedicated custom-`View` hypnogram** — see below | The most directly relevant chart file in the repo |
| `activities/charts/sleep/SleepDetailsOverlay.java`, `SimpleSleepDetailsOverlay.java`, `AbstractOverlayData.java` | Overlay a second series (e.g. HR) on the hypnogram | Pattern for "stages + a vital on one timeline" |
| `activities/charts/SleepAnalysis.java` | Stage-duration aggregation | Where stage totals for legends/summaries get computed |
| `activities/charts/SleepDailyFragment.java`, `SleepPeriodFragment.java`, `SleepCollectionFragment.java` | Day / period / collection sleep screens | The daily-vs-trend screen split |
| `activities/charts/StressDailyFragment.java`, `StressPeriodFragment.java`, `Spo2ChartFragment.java`, `TemperatureChartFragment.java`, `HRVStatusFragment.java` | One fragment per metric | Enumerates the chart surface area we'd need to match |
| `activities/charts/AbstractActivityChartFragment.java` | Shared activity/HR overlay chart builder | The older stacked-series approach (see below) |
| `entities/AbstractHeartRateSample.java`, `AbstractSpo2Sample.java`, `AbstractTemperatureSample.java` | Shared per-metric base entities | Generic-metric-then-vendor-subclass schema shape |
| *(repo root)* `GBDaoGenerator/src/nodomain/freeyourgadget/gadgetbridge/daogen/GBDaoGenerator.java` | greenDAO schema for every device | Good "did we forget a field" checklist |

**Hypnogram — and this is the interesting part.** Gadgetbridge now ships a
**dedicated hypnogram widget**: `activities/charts/sleep/SleepDetailsView.java`, a
custom `View` (~520 lines) drawing directly to a `Canvas` — `drawRoundRect` for
each stage segment, a gradient-shaded `connectionPaint` line for the risers
between stages, dashed grid, and a hit-tested selector. Its older approach (one
filled `LineDataSet` per stage stacked in MPAndroidChart, still visible in
`AbstractActivityChartFragment.java`) was a library workaround they moved away from.

**That's convergent evidence.** Two independent projects — Gadgetbridge in Java and
NOOP in Swift — both concluded that a general-purpose charting library can't render
a good hypnogram, and both hand-drew it as duration-width rounded rects with
connecting risers. For us that means the SwiftUI `Canvas` route is the well-trodden
path, not the exotic one; a Swift Charts `RectangleMark` lane is the cheap
approximation to start from.

**Caveat:** Android/Java patterns that don't transfer — `TransactionBuilder`/
`BtLEQueue` exist to tame Android's callback-based `BluetoothGatt` API, and
CoreBluetooth + Swift concurrency want a different shape; greenDAO's code
generation has no SwiftData equivalent (only its *field lists* are useful).

---

## 3. `refs/fitbit-grafana` · Python + Grafana · BSD-4-Clause

**Why it's here:** the most directly on-point answer to "which chart for which
metric," despite being the smallest repo. The dashboard JSON is a literal,
enumerable panel-to-metric map — 30 real panels with explicit chart types, gauge
thresholds, and stage colors.

| Path (under `refs/fitbit-grafana/`) | What |
|---|---|
| `Grafana_Dashboard/` | The dashboard JSON. **Query it with `jq`, don't cat it.** |
| `extra/influxdb_schema.md` | Pre-written per-metric field/type/unit table — fastest way to see what's worth persisting per metric |
| `Fitbit_Fetch.py` | Fetch/transform only; computes nothing derived |

### Metric → chart decisions

| Metric | Chart | Bucketing |
|---|---|---|
| Heart rate | Time-series line | Intraday raw / 1-min |
| Resting HR | **Gauge**, thresholds 60/70/80, range 40–100 + trend line | Daily scalar |
| HR zones | Stacked bar | Daily duration per zone |
| HRV (RMSSD) | Time-series line | Daily (`dailyRmssd`, `deepRmssd`) |
| SpO2 | **Gauge**, thresholds 85/90/95 for "now" + time series for trend | Intraday raw + daily min/avg/max |
| Respiratory rate | Time-series line | Per reading |
| Skin temperature | **Bar, one per night, delta from baseline** — not an absolute line | Nightly |
| Sleep stages | **State-timeline** (categorical Gantt strip, colour per stage); numeric line as fallback | Per stage-transition event |
| Sleep composition | Bar (nightly stacked minutes) + pie (period-average share) | Nightly totals |
| Sleep efficiency | Bar, percent, red threshold line at 80% | Nightly scalar |
| **Sleep regularity** | **Hour-of-day × day-of-week heatmap** | `aggregateWindow(1h, mean)` |
| Hourly activity | Same heatmap panel type | Hourly step sums |
| Steps | Time series / bar + gauge for today | Per-minute raw |
| Battery | Level line + **derivative** ("usage rate") + state-timeline for "band wearing" | Raw telemetry |

**Design reasoning worth adopting:**

- **Categorical data wants a state-timeline, not a line.** They ship both variants
  for sleep stages and the timeline is the primary one.
- **Gauges with fixed physiological threshold bands for "now"; time series for
  trend.** A clean split for a Today screen vs a History screen.
- **The hour × day heatmap generalizes** to anything with a circadian or
  day-of-week pattern — a strong candidate for headache-signal-by-hour (#183).

---

## 4. `refs/open-wearables` · Python/FastAPI + React · MIT

**Why it's here:** cross-vendor normalization, and the only **freely usable
algorithm source** of the five. Its cloud/multi-tenant/OAuth architecture does not
map onto us; its data model and documented scores do.

| Path (under `refs/open-wearables/`) | What | Why it matters |
|---|---|---|
| `docs/scores/sleep-score.mdx`, `docs/scores/resilience-score.mdx` | Fully specified algorithms in prose, with a citation | **MIT + prose = implementable outright** for Phase 5 |
| `backend/app/algorithms/sleep.py`, `resilience.py` | Their implementations | Cross-check against the docs |
| `docs/architecture/unified-data-model.mdx` | Events vs series vs descriptors split, with an ER diagram | Directly useful local-first modeling split; also flags float-encoding of all series values as a storage compromise **worth avoiding upfront in SwiftData** |
| `backend/app/schemas/enums/series_types.py` | Canonical metric names, grouped by category | Naming reference for our own metric enum |
| `backend/app/schemas/enums/aggregation_method.py` | Per-metric SUM / AVG / MAX for daily rollup (steps=SUM, HR=AVG…) | A ready-made checklist of "how do I roll this metric up" |
| `backend/app/schemas/enums/data_granularity.py` | DAILY/HOURLY/RAW + window-seconds map | Explicit bucket-size semantics |
| `backend/app/constants/sleep.py` | `SleepStageType`: `IN_BED, AWAKE, SLEEPING, LIGHT, DEEP, REM, UNKNOWN` | **Adopt the generic `SLEEPING` fallback** — RingConn won't always give a clean four-stage breakdown |
| `backend/app/constants/series_types/polar.py` | Vendor hypnogram code → canonical stage map, plus qualitative label maps | Template for normalizing RingConn's proprietary codes |
| `backend/app/constants/health_scores.py` | Per-vendor score ranges (Whoop strain 0–21, Whoop recovery 0–100, Polar recovery 1–6, Oura readiness 1–100) | ⚠️ **The same score name means different ranges per vendor.** Define our own scale; don't assume comparability. Relevant to the Phase 5 ports. |
| `frontend/src/components/user/sleep-section.tsx` | `SleepStagesBar` proportional stacked bar + per-session HR line | The compact summary-row alternative to a full hypnogram |

**Algorithms, by shape:**

- **Sleep score** — in: net duration, deep/REM minutes, bedtime history (≥14 nights
  ideal), WASO/awake timeline. Out: 0–100 plus four independently bounded
  sub-scores (Duration, Stages, Consistency, Interruptions), weighted. Duration
  uses a sigmoid around a 7–9h optimum, steep below 7h, gentle above 9h.
- **Resilience** — in: overnight RMSSD restricted to confirmed-asleep windows,
  7-night lookback, needs ≥5 nights and ≥20 HR samples/night. Out: HRV-CV =
  stdev(nightly mean HRV) / mean(nightly mean HRV); lower = more stable ANS =
  better. Null if data insufficient.
- Both are presented to users as **component breakdowns, not one opaque number** —
  worth mirroring in our UI.

**Caveat:** their frontend is an internal operator/admin dashboard, not a consumer
health app. Reasonable, but not an aspirational bar for our iOS charts.

---

## 5. `refs/GarminDB` · Python · GPL-2.0

**Why it's here:** schema design for sleep/HRV/stress at a level of detail nobody
else here matches, plus plotting decisions in its notebooks.

| Path (under `refs/GarminDB/`) | What | Why it matters |
|---|---|---|
| `garmindb/garmindb/garmin_db.py` | Daily/rollup tables — `Sleep` (per-night total/deep/light/rem/awake as `Time` columns **plus** `avg_spo2`, `avg_rr`, `avg_stress`, `score`, `qualifier`), `Hrv`, `Stress`, `RestingHeartRate`, `DailySummary` | The "nightly summary combining sleep + SpO2 + RR + stress + HRV in one row" shape, close to what our SwiftData sleep-session model needs |
| `garmindb/garmindb/monitoring_db.py` | Per-timestamp raw tables (`MonitoringHeartRate`, `MonitoringRespirationRate`, `MonitoringPulseOx`, `MonitoringHrvValue`…) | Models the **raw-epoch vs daily-summary split** we'll want for BLE-ingested data |
| `garmindb/summarydb/summary_base.py` | Shared rollup columns: min/avg/max triads for HR, RHR, sleep, REM sleep, SpO2, RR, plus stress avg and body-battery max/min | Reusable weekly/monthly aggregation pattern |
| `Jupyter/graphs.py` | `__graph_over` / `graph_date` — single-day composition: filled "intensity" area underneath, cumulative-steps and HR lines on top, HR y fixed 30–220, intensity y fixed 0–10 | Reference composition for a single-day ring detail screen |
| `Jupyter/daily_trends.ipynb` | Multi-metric overlay: shared x, independent y per series, distinct colour **and** linestyle (stress dashed, body-battery dashed, sleep dash-dot, REM solid, deep solid) | Pattern for a future correlation view (recovery, headache risk) |

**HRV is stored as a rolling baseline, not a number** — `weekly_avg`,
`last_night_avg`, `last_night_5min_high`, `baseline_low`/`baseline_upper`, plus a
qualitative `status`. That's a good model for rendering an HRV "normal band"
behind the trend line rather than a bare series.

**Caveat:** several notebooks (`monitoring.ipynb`, `checkup.ipynb`, `daily.ipynb`,
`summary.ipynb`, `activities.ipynb`) had no direct plotting calls in their own
cells — they likely delegate to `graphs.py`/`jupyter_funcs.py` or emit markdown
reports. Their visual output is not fully characterized here.

---

## Where none of these help

- **Gap and outlier handling.** Only NOOP treats it deliberately (fix the axis
  domain so absent data reads as blank, never interpolate). The three Python repos
  do essentially nothing — `createEmpty: false` and a hold-last-value forward. For
  a *ring*, off-finger gaps are the dominant data condition, far more than for a
  strap or a cloud API. **We have to design this fresh**, and it's the highest-value
  thing this survey surfaced by absence.
- **Cloud-API assumptions.** GarminDB and fitbit-grafana are both built around
  scheduled pulls from a vendor's servers. There's no "intraday vs daily endpoint"
  distinction to inherit, gap handling is about BLE connection drops rather than
  rate limits, and their device/user tagging assumes vendor accounts we don't have.
- **Android and web idioms.** MPAndroidChart, greenDAO, recharts, and Grafana panel
  types are all reference for *decisions*, not for code we can lift into SwiftUI.
- **Strap-class sensing.** WHOOP's raw PPG/ECG buffer work assumes bandwidth and
  sampling a RingConn Gen 2 likely doesn't expose the same way.
- **SpO2 artifact rejection and physiological threshold alerting.** Surveyed all five
  specifically for this (2026-08-13, the false low-SpO2-while-washing-dishes fix). **None
  of them implements it.** NOOP/Strand has no physiological alert of any kind and
  deliberately refuses to compute a calibrated SpO2 % from raw optical data at all —
  `spo2Pct` is nulled for every device; only an import ever sets it. Gadgetbridge exposes a
  low-SpO2 threshold in its UI, but only as a value it forwards to the WATCH's own
  firmware — the app itself never evaluates it or notifies on it. GarminDB, open-wearables,
  and fitbit-grafana do display bands and rollups only. The de-facto contract across every
  non-Swift repo is "zero means no reading, everything else is truth" — none of them
  reject a reading for motion, poor skin contact, or low perfusion, even where the
  hardware ships a quality signal (Huami's per-sample `signalQuality` array, Garmin FIT's
  `reading_confidence` field, Polar's `spo2_quality_average_percent`) — every one of those
  is parsed and then discarded before persistence. That absence is itself the design input
  for our fix: see the row above and `HealthAlerts.swift`'s `SpO2AlertPolicy`.

---

## Not yet surveyed

Honest gaps, so nobody assumes coverage that isn't there:

- `refs/noop/Packages/StrandAnalytics/` — their HRV/recovery/strain/sleep-staging
  math. Worth a dedicated pass to compare against our Phase 5 Swift ports.
- `refs/noop/android/` — Kotlin reimplementation, out of scope for iOS work.
- Gadgetbridge's Huami/Xiaomi auth-key exchange — no ring here uses it, but it's
  the place to look if we ever need an auth-handshake reference.
- GarminDB's notebook internals (above).
