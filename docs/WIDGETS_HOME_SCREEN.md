# Home Screen Widgets — plan of record

Status: **BUILT** (branch `docs/home-screen-widgets`, 2026-08-12). `WorkoutWidget/
RingSnapshotWidget.swift` + `RingSnapshotViews.swift` render `systemSmall` / `systemMedium` /
`systemLarge` / `accessoryCircular` from a snapshot `OpenCircuit/Widgets/RingSnapshotWriter.swift`
writes into the App Group container after each sync. §1's invariant held: the SwiftData store was
never relocated — see the new subsection at the end of §1, which documents a real near-miss the
build surfaced and fixed, not merely a design worry.

Provenance: a survey pass over (a) this codebase at `1511e7f` (build 41), (b) published
coverage of the official RingConn app's iOS widget. Everything tagged 🟢 below was verified
by reading or running this repo; everything about RingConn's own app is second-hand press
coverage, not a decompile, and is tagged accordingly.

**Read §1 first.** The one blocker that matters is not the widget UI and not the metrics —
it is the process boundary between the app and its extension, and the repo already carries a
strong, correct argument against the obvious fix. §1 is why that argument does not fully
apply here.

---

## 0. Confidence-tag convention (project rule: a claim needs a source)

| Tag | Meaning |
|---|---|
| 🟢 | Verified directly in this repo (read the file, ran the build) |
| 🟡 | Derived — inferred from 🟢 evidence, not observed end-to-end |
| 🔴 | External / unverified. Press coverage or assumption. Must be checked before it is trusted. |

---

## 1. The blocker, and why it is smaller than it looks

**The constraint** 🟢 — there is no App Group. `OpenCircuit/OpenCircuit.entitlements` carries
only the HealthKit entitlement. The `WorkoutWidget` extension therefore runs in a process that
**cannot see the app's SwiftData store**. This is why the Control Centre headache button hands
the app a `opencircuit://` URL instead of writing the row itself.

**The repo's standing argument against fixing it** 🟢 — `Shared/HeadacheQuickLink.swift:8-17`:

> Adding an App Group to fix that would mean RELOCATING the SwiftData store into the group
> container, which is precisely the container-open failure path whose foreground recovery
> WIPES 30 days of un-resyncable raw history (#40/#131).

That reasoning is sound and should not be relitigated **for the case it was written about**.

**Why a widget is a different case** 🟡 — that argument assumes the extension must *write into
the real store*, because a lost headache label is unrecoverable. A Home Screen widget is
**read-only** and needs roughly six display numbers — not the epoch archive, not raw history.

So there is a middle path: **add the App Group container, but leave the SwiftData store exactly
where it is.** The app writes a small snapshot (six values + a `lastSync` timestamp) into the
group container after each sync; the widget reads only that. The store is never relocated, so
the #40/#131 container-open failure path is never entered. Worst case for a corrupt or missing
snapshot is a stale widget — not data loss.

> ⚠️ **The invariant this plan must not break:** nothing in the widget path may move, open, or
> write the app's SwiftData store. If an implementation finds itself needing the store from the
> extension, the design is wrong — stop and revisit §1.

### 1.1. The invariant almost broke from a direction nobody was watching 🟢

The design above reasons about what the **widget** touches. It missed a second way the App Group
entitlement threatens the store, with no widget code involved at all: `ModelConfiguration`'s real
default is `groupContainer: .automatic`, and SwiftData's documented behavior for `.automatic` is
"if the target carries the `com.apple.security.application-groups` entitlement, store new/opened
containers inside the **first** App Group". `App.swift`'s `makeSchemaAndConfig()` — used by both
`makeContainerOrThrow()` and the recovery path — built its `ModelConfiguration` with no
`groupContainer` argument, i.e. at that default, from before this feature existed.

So the moment the app target gained the App Group entitlement (Step 1, needed for the widget
snapshot and nothing else), the **next app launch** would have had SwiftData silently try to open
the main store inside `group.com.bly.opencircuit` instead of the app's own container — a location
with nothing in it. That is not a hypothetical: it reproduced on the first simulator run after the
entitlement landed (`CoreData: error: ... Containers/Shared/AppGroup/.../default.store`), before
`groupContainer: .none` was added. Had that build reached the device and been launched, it is
exactly the container-open-failure shape `wipeAndRecoverForeground` exists for — the store SwiftData
tries to open is unpopulated, the open effectively "fails" to find prior data, and the foreground
recovery path would have treated it as first-launch-shaped, silently starting the user over rather
than opening their real history sitting one directory away.

**Fix:** `makeSchemaAndConfig()` now passes `groupContainer: .none` explicitly, and the in-memory
fallback (`inMemoryContainer`) is pinned the same way for defense in depth even though an in-memory
store has no location to relocate. This is a **one-line, load-bearing pin** — nothing else in the
codebase enforces it — so:

> ⚠️ **Second invariant, alongside the one above:** any `ModelConfiguration` for the app's
> persistent store MUST specify `groupContainer: .none` explicitly. Do not rely on it being unset
> meaning "no group" — once the App Group entitlement exists on the app target (which it now
> permanently does, for this feature), unset means the opposite.

This was caught only because a routine simulator test run logs `CoreData: error:` lines to stderr
and they were read rather than ignored — nothing in the type system flags a silently-wrong default
argument. `docs/HANDOFF_MACOS_IOS.md` / whoever next edits `App.swift`'s container builders should
know this pin exists and why before touching it.

---

## 2. What the official RingConn app ships 🔴

Six metrics, per press coverage of the v1.7.0 update (iOS widget originally launched ~mid-2023):

- **Sleep**, **Stress**, **Activity**, **Power** (ring battery) — the original set
- **Steps**, **Calories** — added in v1.7.0

🔴 Unverified and worth checking before mirroring the design: which widget *families* they
offer (small / medium / large / Lock Screen accessory), whether the widget is user-configurable
as to which metric it shows, and their refresh cadence. None of this came from a decompile.
Do not treat the six-metric list as a spec — treat it as evidence of what users find useful.

---

## 3. What we already have 🟢

All six metrics are already computed in `OpenCircuitKit` **and already rendered in the app UI**,
so each is wired to real data rather than sitting unused as library code:

| RingConn metric | OpenCircuit source | Rendered in |
|---|---|---|
| Sleep | `Analytics/SleepScore.swift` | `SleepCardView` |
| Stress | `Analytics/SleepStress.swift` | `SleepCardView`, `BLE/RingSession.swift` |
| Activity | `Analytics/ActivityScore.swift` | `GoalsCardView`, `WellnessBalanceCardView` |
| Power | `DeviceStatus.swift`, `Analytics/BatteryTTE.swift` | dashboard |
| Steps | `StepAccumulator.swift` | `GoalsCardView` |
| Calories | `Analytics/Calories.swift` | `GoalsCardView` |

**We can show more than RingConn does** 🟢 — `BatteryTTE` gives time-to-empty/time-to-full and
`DeviceStatus` exposes raw voltage and charging state, none of which the official widget shows.
`WellnessBalance` is also already on screen and has no RingConn widget counterpart.

**This is NOT blocked on #38** 🟡 — issues #94 (all-day stress), #95 (activity score) and #97
(wellness balance) are open, but they concern *deepening* these metrics. Usable versions ship
today and render in the app. A widget can consume what exists now and improve as those land.

---

## 4. Implementation sketch

Deliberately ordered so the risky-looking step (the entitlement) is provably contained before
any UI work starts.

1. **App Group entitlement.** Add `group.<your-bundle-prefix>.opencircuit` to the app *and* the
   extension. Needs the capability on the App ID — requires a paid team (🟢 confirmed available;
   the HealthKit entitlement provisions successfully today).
2. **Snapshot writer** (app target, ~100 lines). A `Codable` struct of the six values plus
   `lastSync: Date`, written to the group container after each sync completes. Must not import
   SwiftData — same discipline as `Shared/HeadacheQuickLink.swift`, which is deliberately kept
   free of SwiftData/UserDefaults/HealthKit so it stays correct in either process.
3. **Reload trigger.** `WidgetCenter.shared.reloadAllTimelines()` after the snapshot is written.
4. **The widget** (extension). `StaticConfiguration`, or `AppIntentConfiguration` if the shown
   metric should be user-selectable. `systemSmall` + `systemMedium`; `accessoryCircular` for the
   Lock Screen is a cheap add. No new target and no new bundle id — the `WorkoutWidget`
   extension already exists, builds, and runs on device 🟢.

**Two rules for whoever implements this:**

- **The widget must never touch BLE.** Extensions are memory-capped and short-lived; the app
  stays the only process that talks to the ring. The widget renders the last snapshot, nothing more.
- **Show the staleness.** Values are as old as the last sync, which may be hours. A widget that
  displays an hours-old step count as if it were live is the kind of quiet dishonesty this
  project's sleep work has repeatedly had to go back and fix. Put the timestamp on the face.

---

## 5. Fork / upstream considerations

- `OpenCircuit/OpenCircuit.entitlements` is committed upstream, so adding an App Group edits a
  tracked file. 🟢 **Decision: local spec only.** `ios/project.local.yml` points both targets at
  gitignored `*.local.entitlements` files (the same pattern already used to override signing), so
  `OpenCircuit/OpenCircuit.entitlements`, `project.yml`, and `git merge upstream/master` are never
  touched. Accepted consequence: a fresh clone builds the widget extension, but it renders its
  "open the app" placeholder until someone's own `project.local.yml` provisions the App Group —
  there is no snapshot to read without it. Each target DERIVES the group id from its own
  `Bundle.main.bundleIdentifier` (`Shared/RingSnapshot.swift`) rather than reading it from a
  second tracked-file edit — Info.plist plumbing was tried first and reverted: once a target's
  `INFOPLIST_FILE` points anywhere but the tracked `OpenCircuit/Info.plist`, Xcode stops excluding
  that old file from Copy Bundle Resources and it collides with the new one on the same output
  path ("Multiple commands produce .../Info.plist"). Deriving from the bundle id sidesteps the
  whole class of problem and needs no entitlements/Info.plist round-trip to add a metric later.
- **Do NOT contribute this upstream.** See the banner at the top of `CLAUDE.md`: this is a
  personal learning fork and nothing is PR'd back. (Noted only because the design in §1 would
  otherwise be a natural answer to the objection recorded in `HeadacheQuickLink.swift` — it
  stays here regardless.)
- Unlike #185 or #38, this needs **no protocol work and no ring captures** — which makes it a
  good first substantial Swift change in this codebase.

---

## 6. Open questions — resolved at implementation

1. 🔴 **Still open, deliberately.** Which widget families and which metric-per-widget model
   RingConn actually uses was never checked against the real app or a decompile — this repo built
   its own layout instead and treats the six-metric list as evidence of usefulness, not a spec.
2. 🟢 **Decided.** Small face: sleep score hero (tier-coloured) + steps + ring battery, with the
   snapshot's age always on the face. Medium/large add stress, activity score, active kcal;
   large adds last night's stage bar. `accessoryCircular` (Lock Screen) shows sleep score alone.
3. 🟢 **Resolved — not a real constraint.** The app never called `WidgetCenter` before this
   feature. App-initiated `reloadAllTimelines()` is not charged against the widget's own
   timeline-refresh budget (that throttling applies to `TimelineReloadPolicy`-driven refreshes);
   the throttling that matters is `RingSnapshotWriter`'s own no-op check
   (`RingSnapshot.hasSameDisplayValues`), which skips the write — and therefore the reload —
   when a periodic empty drain produced nothing the widget shows differently.
4. 🟢 **Resolved.** The widget inherits `docs/BACKGROUND_SYNC.md`'s caveats wholesale: every wake
   is at iOS's discretion, and the referenced 7-day activity log showed roughly a third of
   app-refresh runs ending early. Hours-old data is the NORMAL case, not a failure mode — which is
   why every face but `accessoryCircular` puts the sync age on its own face rather than treating
   staleness as something to hide (§4, §5's "show the staleness" rule).
