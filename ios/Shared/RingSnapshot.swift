// RingSnapshot.swift — the read-only display payload the app writes and the Home Screen /
// Lock Screen widget reads, via the App Group container (docs/WIDGETS_HOME_SCREEN.md).
//
// SHARED SOURCE, same discipline as HeadacheQuickLink.swift: FOUNDATION ONLY. No SwiftData, no
// OpenCircuitKit, no HealthKit, no CoreBluetooth, no SwiftUI. This file compiles into BOTH the
// app target and the WorkoutWidget extension, and that is what makes §1's invariant — the widget
// path may never move, open, or write the app's SwiftData store — structural rather than a
// promise: there is nothing in this file's import list that COULD reach the store.
//
// Every score's tier/band travels as a pre-computed raw String (SleepScore.Tier.rawValue,
// SleepStress.Band.rawValue, ActivityScore.Tier.rawValue) rather than the OpenCircuitKit enum
// itself — the app computes the tier, the widget only maps a known string to a colour. An
// unrecognized string (a future tier case, or a snapshot written by a newer build) renders as
// "no band" rather than a crash — the same forward-compatibility posture as the whole payload.
//
// NO FABRICATION: every metric is Optional. A widget with a missing field shows "—", never an
// invented 0. A missing or corrupt snapshot file is a stale/empty widget, never a crash and never
// data loss — reading the app's real history requires opening the app, which still owns the only
// SwiftData store there is.

import Foundation

// MARK: - Sleep stage span (Foundation-only mirror of OpenCircuitKit.SleepSegment)

/// One contiguous sleep-stage span, for the `systemLarge` face's hypnogram bar. Mirrors
/// `OpenCircuitKit.SleepSegment` (`Metrics.swift`) field-for-field, but the widget extension does
/// not link OpenCircuitKit (`project.yml`'s WorkoutWidget target is deliberately Kit-free), so
/// this is a plain value type instead. `stage` is `SleepStage.rawValue`; a string the widget
/// doesn't recognize renders as an unstaged span rather than crashing.
struct StageSpan: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    let stage: String

    init(start: Date, end: Date, stage: String) {
        self.start = start
        self.end = end
        self.stage = stage
    }

    private enum CodingKeys: String, CodingKey { case start, end, stage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? .distantPast
        end = try c.decodeIfPresent(Date.self, forKey: .end) ?? .distantPast
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
    }
}

// MARK: - Snapshot

/// Everything a widget face needs to render, as of the app's last sync. Hand-rolled `Codable`
/// (every field via `decodeIfPresent`, defaulting when absent) rather than the synthesized
/// conformance, so a snapshot written by an OLDER build — one missing a field this version added
/// — still decodes into a widget rather than blanking it. The reverse direction (a NEWER payload
/// read by an older widget) is handled for free: `JSONDecoder` ignores unrecognized keys.
struct RingSnapshot: Codable, Equatable, Sendable {

    // MARK: Sleep — last night's numbers, shown only when `sleepIsLastNight` is true
    var sleepScore: Int?
    var sleepBand: String?          // SleepScore.Tier.rawValue
    var asleepMinutes: Int?
    var stressScore: Int?
    var stressBand: String?         // SleepStress.Band.rawValue
    var inBedStart: Date?
    var inBedEnd: Date?
    /// True when the shown night actually ENDED today (the app's `MissedNight.endedToday` test —
    /// the same recency gate the Sleep card and Goals rings use, #147). This is the staleness
    /// signal the `accessoryCircular` face uses INSTEAD of `lastSyncAt`: a last-night score is
    /// correctly nine hours old at 9am, which is not the same thing as a nine-hour-old step count.
    var sleepIsLastNight: Bool
    /// Last night's stage spans for the `systemLarge` hypnogram bar. Coalesced and capped by the
    /// writer (~120 spans) so the payload stays small; empty when no night is credited.
    var stages: [StageSpan]

    // MARK: Activity — today
    var steps: Int?
    var stepsGoal: Int?
    var activeKcal: Double?
    var activeKcalGoal: Double?
    var activityScore: Int?
    var activityTier: String?       // ActivityScore.Tier.rawValue

    // MARK: Ring battery — in-memory only on the app side (no persistence outside the live BLE
    // session), so a snapshot written with no live session CARRIES FORWARD the previous battery
    // reading + its own timestamp rather than blanking or restamping it. See RingSnapshotWriter.
    var batteryPercent: Int?
    var batteryCharging: Bool
    var batteryAsOf: Date?
    var timeToEmptySeconds: TimeInterval?
    var timeToFullSeconds: TimeInterval?

    // MARK: Freshness
    /// When this snapshot was written.
    var lastSyncAt: Date
    /// How old `lastSyncAt` may get before a widget face should show it as stale. Written from
    /// the app's own `SyncAlertPolicy().staleSyncThreshold`, so the widget's notion of "stale" can
    /// never drift from the app's silent-failure notification threshold without duplicating the
    /// constant in a second place.
    var staleAfter: TimeInterval

    init(sleepScore: Int? = nil, sleepBand: String? = nil, asleepMinutes: Int? = nil,
        stressScore: Int? = nil, stressBand: String? = nil,
        inBedStart: Date? = nil, inBedEnd: Date? = nil, sleepIsLastNight: Bool = false,
        stages: [StageSpan] = [],
        steps: Int? = nil, stepsGoal: Int? = nil,
        activeKcal: Double? = nil, activeKcalGoal: Double? = nil,
        activityScore: Int? = nil, activityTier: String? = nil,
        batteryPercent: Int? = nil, batteryCharging: Bool = false, batteryAsOf: Date? = nil,
        timeToEmptySeconds: TimeInterval? = nil, timeToFullSeconds: TimeInterval? = nil,
        lastSyncAt: Date, staleAfter: TimeInterval) {
        self.sleepScore = sleepScore
        self.sleepBand = sleepBand
        self.asleepMinutes = asleepMinutes
        self.stressScore = stressScore
        self.stressBand = stressBand
        self.inBedStart = inBedStart
        self.inBedEnd = inBedEnd
        self.sleepIsLastNight = sleepIsLastNight
        self.stages = stages
        self.steps = steps
        self.stepsGoal = stepsGoal
        self.activeKcal = activeKcal
        self.activeKcalGoal = activeKcalGoal
        self.activityScore = activityScore
        self.activityTier = activityTier
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.batteryAsOf = batteryAsOf
        self.timeToEmptySeconds = timeToEmptySeconds
        self.timeToFullSeconds = timeToFullSeconds
        self.lastSyncAt = lastSyncAt
        self.staleAfter = staleAfter
    }

    private enum CodingKeys: String, CodingKey {
        case sleepScore, sleepBand, asleepMinutes, stressScore, stressBand
        case inBedStart, inBedEnd, sleepIsLastNight, stages
        case steps, stepsGoal, activeKcal, activeKcalGoal, activityScore, activityTier
        case batteryPercent, batteryCharging, batteryAsOf, timeToEmptySeconds, timeToFullSeconds
        case lastSyncAt, staleAfter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleepScore = try c.decodeIfPresent(Int.self, forKey: .sleepScore)
        sleepBand = try c.decodeIfPresent(String.self, forKey: .sleepBand)
        asleepMinutes = try c.decodeIfPresent(Int.self, forKey: .asleepMinutes)
        stressScore = try c.decodeIfPresent(Int.self, forKey: .stressScore)
        stressBand = try c.decodeIfPresent(String.self, forKey: .stressBand)
        inBedStart = try c.decodeIfPresent(Date.self, forKey: .inBedStart)
        inBedEnd = try c.decodeIfPresent(Date.self, forKey: .inBedEnd)
        sleepIsLastNight = try c.decodeIfPresent(Bool.self, forKey: .sleepIsLastNight) ?? false
        stages = try c.decodeIfPresent([StageSpan].self, forKey: .stages) ?? []
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        stepsGoal = try c.decodeIfPresent(Int.self, forKey: .stepsGoal)
        activeKcal = try c.decodeIfPresent(Double.self, forKey: .activeKcal)
        activeKcalGoal = try c.decodeIfPresent(Double.self, forKey: .activeKcalGoal)
        activityScore = try c.decodeIfPresent(Int.self, forKey: .activityScore)
        activityTier = try c.decodeIfPresent(String.self, forKey: .activityTier)
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        batteryCharging = try c.decodeIfPresent(Bool.self, forKey: .batteryCharging) ?? false
        batteryAsOf = try c.decodeIfPresent(Date.self, forKey: .batteryAsOf)
        timeToEmptySeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .timeToEmptySeconds)
        timeToFullSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .timeToFullSeconds)
        // The two truly load-bearing fields: a snapshot with no sync time is indistinguishable
        // from "always stale", which is the safe default for a payload this corrupted/old.
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt) ?? .distantPast
        staleAfter = try c.decodeIfPresent(TimeInterval.self, forKey: .staleAfter) ?? (6 * 3_600)
    }

    /// Whether `lastSyncAt` is older than `staleAfter` — the rule every face except
    /// `accessoryCircular` uses (that face gates on `sleepIsLastNight` instead; see its doc above).
    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSyncAt) > staleAfter
    }

    /// Equal to `other` on every DISPLAY field, ignoring `lastSyncAt` — the check
    /// `RingSnapshotWriter` uses to skip a write when a periodic empty drain produced nothing new,
    /// so the sync clock alone doesn't churn the App Group container (and therefore doesn't churn
    /// `WidgetCenter.reloadAllTimelines()`) on every ~hourly poll.
    func hasSameDisplayValues(as other: RingSnapshot) -> Bool {
        var lhs = self, rhs = other
        lhs.lastSyncAt = .distantPast
        rhs.lastSyncAt = .distantPast
        return lhs == rhs
    }
}

// MARK: - Group-container store

/// Reads/writes the `RingSnapshot` in the shared App Group container. Every failure here —
/// missing group entitlement, no bundle identifier, missing file, corrupt JSON — resolves to
/// `nil` / `false`, never a throw and never a crash. That is deliberate: a widget with no
/// snapshot renders its own "open the app" placeholder, which is the entire point of keeping this
/// data path separate from (and unable to threaten) the SwiftData store.
enum RingSnapshotStore {
    private static let fileName = "ring_snapshot.v1.json"

    /// The App Group id, DERIVED from this process's own bundle id rather than duplicated as a
    /// literal in two places (`project.local.yml`'s app + widget entitlements) or plumbed through
    /// Info.plist (tried and reverted: once a target's `INFOPLIST_FILE` points anywhere but the
    /// TRACKED `OpenCircuit/Info.plist`, Xcode stops excluding that old file from Copy Bundle
    /// Resources and it collides with the new one on the same output path — see
    /// `project.local.yml`'s comment on this block for the full story).
    ///
    /// Convention, and the thing that MUST stay true for this to resolve correctly: the group id
    /// is `"group.<the APP's bundle id>"`, and the extension's bundle id is the app's with
    /// `.WorkoutWidget` appended (`project.yml`). So both processes derive the SAME string from
    /// their own `Bundle.main.bundleIdentifier` without needing to agree out-of-band.
    private static var groupIdentifier: String? {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return nil }
        let widgetSuffix = ".WorkoutWidget"
        let appBundleID = bundleID.hasSuffix(widgetSuffix)
            ? String(bundleID.dropLast(widgetSuffix.count))
            : bundleID
        return "group.\(appBundleID)"
    }

    private static var fileURL: URL? {
        guard let id = groupIdentifier, !id.isEmpty else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent(fileName)
    }

    private static var decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static var encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func read() -> RingSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(RingSnapshot.self, from: data)
    }

    /// Atomic write so a widget refresh racing the write never reads a half-written file.
    @discardableResult
    static func write(_ snapshot: RingSnapshot) -> Bool {
        guard let url = fileURL, let data = try? encoder.encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
