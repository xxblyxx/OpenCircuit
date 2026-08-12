// RingSnapshotWriter.swift — assembles a RingSnapshot from the local store + (optional) live
// session and writes it to the App Group container for the Home Screen widget to read
// (docs/WIDGETS_HOME_SCREEN.md). APP TARGET ONLY — this is the one place allowed to import
// SwiftData/OpenCircuitKit AND write into the shared container; the extension only ever reads.
//
// Split the same way TrendsData.loadAsync is (Trends/TrendsData.swift:63): a main-actor `refresh`
// fetches SwiftData rows into a Sendable `Inputs` snapshot, and `compose(_:)` — pure, nonisolated,
// no SwiftData/App-Group/ring access at all — turns that into the `RingSnapshot`. Two reasons:
// the same one TrendsData/GoalsCardView/WellnessBalanceCardView already have (never run the O(n)
// Calories loop on the render/scene-update path, 0x8BADF00D), PLUS `compose` is what
// `RingSnapshotWriterTests` exercises directly — `refresh` itself can't be unit-tested in this
// target, since `RingSnapshotStore.write` needs a real App Group the test host doesn't carry.

import Foundation
import WidgetKit
import OpenCircuitKit

enum RingSnapshotWriter {

    /// Spans kept for the `systemLarge` hypnogram face — enough for a full night at 2.5-min
    /// epoch resolution (~192 raw segments/8h) after coalescing adjacent same-stage runs, capped
    /// so the JSON payload stays small regardless of how choppy a night was.
    static let maxStages = 120

    // MARK: - Pure composition (unit-tested directly)

    /// Everything `compose(_:)` needs, pre-fetched into Sendable value types. Mirrors
    /// `TrendsData.Inputs`'s reason for existing: SwiftData `@Model` rows aren't Sendable, so the
    /// main-actor fetch extracts what the pure compute needs before crossing off-main.
    struct Inputs: Sendable {
        var now: Date
        var staleAfter: TimeInterval
        var steps: Int
        var stepsGoal: Int
        var activeKcalGoal: Double
        var activityMinutesGoal: Double
        var hrSamples: [HRSample]
        var stepWindows: [StepWindow]
        var profile: UserProfile
        var sleep: SleepRow?
        /// Raw per-epoch stage segments for `sleep`'s night — only meaningful when `sleep` is
        /// non-nil; ignored (and never shown) when the night isn't credited as last night.
        var stages: [SleepSegment]
        /// The just-read live session's battery, or nil when no session/no reading — see
        /// `previousBattery` for what fills the gap.
        var liveBattery: LiveBattery?
        /// The PREVIOUS snapshot's battery reading, carried forward when `liveBattery` is nil
        /// (battery is in-memory-only on the app side; see the doc on `RingSnapshot.batteryPercent`).
        var previousBattery: PreviousBattery

        struct SleepRow: Sendable {
            var night: Date
            var inBedStart: Date
            var inBedEnd: Date
            var sleepScore: Int
            var stressScore: Int
            var asleepMin: Int
        }
        struct LiveBattery: Sendable {
            var percent: Int
            var charging: Bool
            var tteSamples: [BatteryTTE.Sample]
            var chargeSamples: [BatteryTTE.Sample]
        }
        struct PreviousBattery: Sendable {
            var percent: Int?
            var charging: Bool
            var asOf: Date?
        }
    }

    /// Pure: no SwiftData, no App Group I/O, no ring. Safe to call from anywhere, including a
    /// background thread and unit tests.
    static func compose(_ i: Inputs) -> RingSnapshot {
        let dayStart = Calendar.current.startOfDay(for: i.now)
        let sleepWindow: DateInterval? = i.sleep.flatMap { s in
            guard s.inBedStart > Date.distantPast, s.inBedEnd > s.inBedStart else { return nil }
            return DateInterval(start: s.inBedStart, end: s.inBedEnd)
        }
        let estimate = Calories.dailyEstimate(hrSamples: i.hrSamples, steps: i.steps, profile: i.profile,
                                              sleepWindow: sleepWindow, stepWindows: i.stepWindows,
                                              dayStart: dayStart)
        let activity = ActivityScore.score(.init(
            steps: i.steps, stepGoal: i.stepsGoal,
            activeMinutes: estimate.elevatedMinutes, activeMinutesGoal: i.activityMinutesGoal,
            activeKcal: estimate.activeKcal, activeKcalGoal: i.activeKcalGoal))

        // Same recency test as GoalsCardView.sleepCredited / the Sleep card's missed-night banner
        // (#147): a night that didn't end TODAY is not "last night", so its numbers must not be
        // shown as if they were. This is ALSO the accessoryCircular face's staleness gate — see
        // the doc on RingSnapshot.sleepIsLastNight for why that face uses this instead of the sync
        // clock.
        let sleepIsLastNight: Bool = {
            guard let s = i.sleep else { return false }
            let inBedEnd = s.inBedEnd > s.inBedStart ? s.inBedEnd : nil
            return MissedNight.endedToday(inBedEnd: inBedEnd, nightKey: s.night, now: i.now)
        }()

        let stages: [StageSpan] = sleepIsLastNight
            ? coalesce(i.stages).prefix(maxStages).map {
                StageSpan(start: $0.start, end: $0.end, stage: $0.stage.rawValue)
            }
            : []

        let sleepScore = sleepIsLastNight ? positive(i.sleep?.sleepScore) : nil
        let stressScore = sleepIsLastNight ? positive(i.sleep?.stressScore) : nil

        let batteryPercent: Int?
        let batteryCharging: Bool
        let batteryAsOf: Date?
        let tte: TimeInterval?
        let ttf: TimeInterval?
        if let live = i.liveBattery {
            batteryPercent = live.percent
            batteryCharging = live.charging
            batteryAsOf = i.now
            tte = BatteryTTE.timeToEmpty(live.tteSamples, now: i.now)
            ttf = live.charging ? BatteryTTE.timeToFull(live.chargeSamples, now: i.now) : nil
        } else {
            batteryPercent = i.previousBattery.percent
            batteryCharging = i.previousBattery.charging
            batteryAsOf = i.previousBattery.asOf
            tte = nil
            ttf = nil
        }

        return RingSnapshot(
            sleepScore: sleepScore,
            sleepBand: sleepScore.map { SleepScore.Tier.of($0).rawValue },
            asleepMinutes: sleepIsLastNight ? positive(i.sleep?.asleepMin) : nil,
            stressScore: stressScore,
            stressBand: stressScore.map { SleepStress.Band.of($0).rawValue },
            inBedStart: sleepIsLastNight ? i.sleep?.inBedStart : nil,
            inBedEnd: sleepIsLastNight ? i.sleep?.inBedEnd : nil,
            sleepIsLastNight: sleepIsLastNight,
            stages: stages,
            steps: i.steps,
            stepsGoal: i.stepsGoal,
            activeKcal: estimate.activeKcal,
            activeKcalGoal: i.activeKcalGoal,
            activityScore: activity.score,
            activityTier: activity.tier.rawValue,
            batteryPercent: batteryPercent,
            batteryCharging: batteryCharging,
            batteryAsOf: batteryAsOf,
            timeToEmptySeconds: tte,
            timeToFullSeconds: ttf,
            lastSyncAt: i.now,
            staleAfter: i.staleAfter)
    }

    /// `0` is the store's "not computed" sentinel for these columns (StoredSleepSummary), not a
    /// real score — never show a fabricated zero.
    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Merge adjacent same-stage segments before capping. `hypnogram(night:)` returns raw
    /// per-epoch segments (2.5-min resolution), so an uncoalesced night can run past `maxStages`
    /// on stage-flicker alone; coalescing first means the cap only ever trims genuine stage
    /// changes, never duplicates of the stage the bar already drew.
    static func coalesce(_ segments: [SleepSegment]) -> [SleepSegment] {
        var out: [SleepSegment] = []
        for seg in segments {
            if let last = out.last, last.stage == seg.stage, last.end == seg.start {
                out[out.count - 1] = SleepSegment(start: last.start, end: seg.end, stage: last.stage)
            } else {
                out.append(seg)
            }
        }
        return out
    }

    // MARK: - Fetch + write (app runtime only)

    /// Rebuild the widget snapshot and write it, but ONLY when a display value actually changed —
    /// so the ~hourly periodic drain (which is usually empty) doesn't churn the App Group
    /// container or call `WidgetCenter.reloadAllTimelines()` for no visible reason.
    @MainActor
    static func refresh(store: LocalStore, session: RingSession?, now: Date = Date()) async {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)

        let steps = ((try? store.dailies(from: dayStart, to: dayEnd)) ?? []).first?.steps ?? 0
        let hrSamples = ((try? store.samples(kind: .heartRate, from: dayStart, to: now)) ?? [])
            .map { HRSample(bpm: Int($0.value), start: $0.start, end: $0.end) }
        // Yesterday too, same as GoalsCardView.recentStepSamples: a step delta straddling
        // midnight still contributes its in-day share to today's active-energy attribution.
        let stepWindows = ((try? store.stepSamples(from: dayStart.addingTimeInterval(-86_400), to: now)) ?? [])
            .map { StepWindow(start: $0.start, end: $0.end, delta: $0.delta) }
        let sleepRow = try? store.latestSleepSummary()
        let sleep = sleepRow.map {
            Inputs.SleepRow(night: $0.night, inBedStart: $0.inBedStart, inBedEnd: $0.inBedEnd,
                            sleepScore: $0.sleepScore, stressScore: $0.stressScore, asleepMin: $0.asleepMin)
        }
        let stages = sleepRow.map { store.hypnogram(night: $0.night) } ?? []

        let defaults = UserDefaults.standard
        let stepsGoal = GoalDefaults.stepsGoal(for: now, calendar: cal, defaults: defaults)
        let activeKcalGoal = defaults.object(forKey: GoalDefaults.activeKcal) as? Double
            ?? GoalDefaults.defaultActiveKcal
        let activityMinGoal = defaults.object(forKey: GoalDefaults.activityMinutes) as? Double
            ?? GoalDefaults.defaultActivityMinutes

        // Battery is IN-MEMORY ONLY on the app side (RingSession, torn down between connections),
        // so a refresh with no live session carries the PREVIOUS snapshot's reading + its own
        // timestamp forward rather than blanking it or restamping it with a now that isn't real.
        let previous = RingSnapshotStore.read()
        let liveBattery: Inputs.LiveBattery? = (session?.batteryPercent).map { pct in
            Inputs.LiveBattery(percent: pct, charging: session?.charging ?? false,
                               tteSamples: session?.batteryTTESamples ?? [],
                               chargeSamples: session?.batteryChargeSamples ?? [])
        }

        let inputs = Inputs(
            now: now,
            staleAfter: SyncAlertPolicy().staleSyncThreshold,
            steps: steps, stepsGoal: stepsGoal,
            activeKcalGoal: activeKcalGoal, activityMinutesGoal: activityMinGoal,
            hrSamples: hrSamples, stepWindows: stepWindows,
            profile: HealthKitWriter.storedUserProfile(),
            sleep: sleep, stages: stages,
            liveBattery: liveBattery,
            previousBattery: .init(percent: previous?.batteryPercent,
                                   charging: previous?.batteryCharging ?? false,
                                   asOf: previous?.batteryAsOf))

        let snapshot = await Task.detached { compose(inputs) }.value

        if let previous, previous.hasSameDisplayValues(as: snapshot) { return }
        guard RingSnapshotStore.write(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
