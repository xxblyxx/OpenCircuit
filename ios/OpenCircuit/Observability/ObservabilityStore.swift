import Foundation
import OpenCircuitKit
import UserNotifications

// Observability/alerting glue for the always-on tracker (#44). The PURE policy (thresholds +
// debounce + ring-buffer trim) lives in OpenCircuitKit (`SyncObservability.swift`); this file is the
// app-side persistence + notification plumbing. Deliberately UserDefaults-backed, NOT SwiftData:
// a separate, schema-free store avoids a migration and a collision with the steps lane. Plain
// `struct` over `UserDefaults` (itself thread-safe), so the foreground UI and the background task
// can both record without an actor hop.

/// One recorded sync/background-task outcome for the user-visible activity log.
struct TaskRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case appRefresh   // BGAppRefreshTask (short ~30 s window)
        case processing   // BGProcessingTask (longer window — gives background HR a chance, #45)
        case foreground   // a sync the user triggered / a foreground auto-refresh
        case cbWake       // a drain triggered by a BLE event while suspended (0x11 wake, #119)
        case sleepFocus   // a bounded sync when the configured Sleep Focus turns off
    }
    var id = UUID()
    var date: Date
    var kind: Kind
    var success: Bool
    var detail: String?
}

/// One persisted metric-capture / persistence diagnostic event. Kept lightweight and bounded so
/// "captured but not stored" incidents survive beyond the transient Xcode/unified log.
struct MetricRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var source: String
    var detail: String
}

/// One health-alert DECISION — fired or suppressed — with the reading that drove it.
///
/// WHY THIS EXISTS. Before this, the only trace an alert left was `HealthNotificationStore`'s
/// `alerts.health.lastFired` watermark, which is OVERWRITTEN in place: after a "Low blood oxygen
/// (80%)" notification you could recover "lowSpO2 last fired at T" and nothing else — not the
/// value, not the reading's own timestamp, not how many had fired. So "was that a false
/// positive?" had no denominator, and no change to the rule could be shown to have helped.
/// This log is that denominator. It records SUPPRESSED decisions too, which is the half that
/// matters: a suppression rule that silently over-fires is indistinguishable from a working one
/// unless you can see what it withheld.
///
/// ⚠️ EVERY FIELD EXCEPT `date` IS OPTIONAL-TOLERANT AT DECODE TIME, and new ones must be too —
/// but NOT via a property default alone. `HistorySyncEvidence` learned the underlying lesson (see
/// `nightRowOutcome` below): a non-optional key missing from old, already-persisted JSON fails
/// `JSONDecoder` on the WHOLE array, which silently wipes the wearer's log on upgrade.
///
/// A property default does NOT prevent that failure — this is a genuine Swift gotcha, not a
/// stylistic point. Swift's synthesized `Decodable.init(from:)` calls `decode(_:forKey:)` for
/// every NON-OPTIONAL stored property regardless of whether it has a default value; a default
/// only affects the synthesized MEMBERWISE initializer, which nothing here calls. Only a truly
/// `Optional` property gets the lenient `decodeIfPresent` treatment for free (that's why
/// `readingTime`/`evidenceSummary` below are safe as plain `Optional`s). Everything else needs the
/// custom `init(from:)` below, which is what actually keeps the promise this comment makes.
struct HealthAlertRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    /// When the decision ran (wall clock), NOT when the reading was taken.
    var date: Date
    /// `HealthNotification.rawValue`. Stored as a String, never the enum: the enum's order is
    /// pinned by `HealthNotificationOrderTests` and its cases may be appended to, so decoding
    /// an unknown future case must degrade to an unrecognised string rather than fail the array.
    var notification: String = ""
    var fired: Bool = false
    /// Why. `"fired"`, a `SpO2Verdict.Outcome` rawValue once the gated rule lands, or one of
    /// `"gated.quietHours"` / `"gated.backoff"` when the rule passed but the shared gate held.
    var reason: String = ""
    /// Percent for SpO2, bpm for the HR rules. 0 when the decision carried no reading.
    var value: Double = 0
    /// The reading's DEVICE timestamp — the thing the notification copy says "detected at".
    /// Distinct from `date`: a 12 h lookback means these routinely differ by hours, which is
    /// exactly how "why did this arrive while I was washing dishes?" gets answered.
    var readingTime: Date?
    /// Trigger + corroborators. 0 until the corroboration rule lands.
    var runSize: Int = 0
    /// How many of the run resolved to a raw 0x4c record, and how many of those were bad.
    /// `evidenceEpochs == 0` on a FIRED row means the alert rode the fail-open path — worth
    /// seeing, because that is the branch whose failure mode is hardest to reason about.
    var evidenceEpochs: Int = 0
    var badEpochs: Int = 0
    /// Human-readable one-liner of the epoch evidence, or nil when none resolved.
    var evidenceSummary: String?

    /// Explicit, since providing `init(from:)` below suppresses Swift's synthesized memberwise
    /// initializer — this keeps every existing construction call site unchanged.
    init(id: UUID = UUID(), date: Date, notification: String = "", fired: Bool = false,
        reason: String = "", value: Double = 0, readingTime: Date? = nil, runSize: Int = 0,
        evidenceEpochs: Int = 0, badEpochs: Int = 0, evidenceSummary: String? = nil) {
        self.id = id
        self.date = date
        self.notification = notification
        self.fired = fired
        self.reason = reason
        self.value = value
        self.readingTime = readingTime
        self.runSize = runSize
        self.evidenceEpochs = evidenceEpochs
        self.badEpochs = badEpochs
        self.evidenceSummary = evidenceSummary
    }

    /// `decodeIfPresent(...) ?? default` for every field but `date`, which is the one thing every
    /// row has always genuinely required. `Encodable.encode(to:)` is still synthesized normally —
    /// only `Decodable` needs to be hand-written, since only decoding old JSON against a widened
    /// schema is the failure mode this exists to survive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        notification = try c.decodeIfPresent(String.self, forKey: .notification) ?? ""
        fired = try c.decodeIfPresent(Bool.self, forKey: .fired) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        readingTime = try c.decodeIfPresent(Date.self, forKey: .readingTime)
        runSize = try c.decodeIfPresent(Int.self, forKey: .runSize) ?? 0
        evidenceEpochs = try c.decodeIfPresent(Int.self, forKey: .evidenceEpochs) ?? 0
        badEpochs = try c.decodeIfPresent(Int.self, forKey: .badEpochs) ?? 0
        evidenceSummary = try c.decodeIfPresent(String.self, forKey: .evidenceSummary)
    }
}

/// One persisted history-sync evidence bundle. Kept separate from the human-readable activity log:
/// this is a machine-oriented breadcrumb for "why did sleep not land?" incidents.
struct HistorySyncEvidence: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var ringID: String
    var trigger: String
    /// ⚠️ A NIGHT ROW WAS WRITTEN — not "the stage path was taken" (#204). See
    /// `RingSession.recordHistorySyncEvidence` for why the old meaning was actively misleading.
    var sleepCommitted: Bool
    var stagedSleepSegments: Int
    var mergedRecordCount: Int
    var historySampleCount: Int
    var channels: [HistoryChannelTrace]
    /// Reconstructed raw 0x4c records captured this sync (fixed 23-byte records concatenated).
    /// Stored for a few days so a failed overnight sync can be replayed/analyzed later.
    ///
    /// ⚠️ THIS IS THIS DRAIN'S SLICE, NOT THE ARCHIVE (#203). It is encoded from the same
    /// `bulkRecords` array that `mergedRecordCount` counts, so those two can never disagree and a
    /// blob-vs-count check proves nothing. Epochs the app persisted through a drain whose evidence
    /// row is missing — the ring buffer is only `historySyncEvidenceLimit` deep — appear NOWHERE in
    /// the union of these blobs, and a replay then sees a data hole the app never had.
    var rawRecordBlob: Data
    /// Which branch of the sleep-summary write ran (`SleepPersistOutcome.rawValue`), or nil when
    /// this drain did not stage a night. Optional so a bundle written before #204 still decodes —
    /// a non-optional addition would fail `JSONDecoder` on the whole array and silently wipe the
    /// wearer's evidence history on upgrade (the trap `HistorySyncAssessment` documents).
    var nightRowOutcome: String?
}

/// Reads/writes the observability timestamps + bounded outcome log in UserDefaults.
struct ObservabilityStore {
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Keep the last N outcomes (newest survive — see `BoundedLog`). Small: this is a debug aid.
    /// Sized for the wake-driven world (#119): hourly `.cbWake` records ≈ 16/day, and the log
    /// must still cover a few nights back for "did last night sync?" diagnostics.
    static let logLimit = 80
    static let metricLogLimit = 400
    /// The health-alert decision log. 120 covers roughly a week — matching `ActivityLogView`'s
    /// default period — because FIRED rows are capped by the 2 h renotify at <=12/day and
    /// suppressions only occur on a pass that actually had a sub-threshold candidate.
    static let healthAlertLogLimit = 120
    static let historySyncEvidenceLimit = 24
    static let historySyncEvidenceRetention: TimeInterval = 3 * 24 * 3600

    private enum Key {
        static let lastSync = "obs.lastSuccessfulSync"
        static let lastHealthWrite = "obs.lastHealthWrite"
        static let bgLastRun = "obs.bgLastRun"
        static let bgLastScheduled = "obs.bgLastScheduled"
        static let log = "obs.taskLog"
        static let metricLog = "obs.metricLog"
        static let historySyncEvidence = "obs.historySyncEvidence"
        static let healthAlertLog = "obs.healthAlertLog"
        static let alertFired = "obs.alertLastFired"        // [SyncAlert.rawValue: epoch]
        static let healthEverAuthorized = "obs.healthEverAuthorized"
    }

    // MARK: Timestamps

    var lastSuccessfulSync: Date? { date(Key.lastSync) }
    var lastHealthWrite: Date? { date(Key.lastHealthWrite) }
    var bgLastRun: Date? { date(Key.bgLastRun) }
    var bgLastScheduled: Date? { date(Key.bgLastScheduled) }
    var healthEverAuthorized: Bool { defaults.bool(forKey: Key.healthEverAuthorized) }

    private func date(_ key: String) -> Date? {
        let t = defaults.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Latch that Health share access was granted at least once, so a LATER revocation can be
    /// distinguished from "never opted in" (gates the `healthAuthLost` alert).
    func markHealthEverAuthorized() { defaults.set(true, forKey: Key.healthEverAuthorized) }

    // MARK: Recording

    /// Record a sync attempt's outcome. A success bumps "last successful sync"; any
    /// background-originated run (not `.foreground`) bumps "last background run" so the user can
    /// see whether iOS is actually waking the app. Appends to the bounded log either way.
    func recordSyncOutcome(kind: TaskRecord.Kind, success: Bool, detail: String?, at now: Date = Date()) {
        if kind != .foreground { defaults.set(now.timeIntervalSince1970, forKey: Key.bgLastRun) }
        if success { defaults.set(now.timeIntervalSince1970, forKey: Key.lastSync) }
        append(TaskRecord(date: now, kind: kind, success: success, detail: detail))
    }

    /// Record that we mirrored data into Apple Health (drives the "Last Health write" line).
    func recordHealthWrite(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastHealthWrite)
    }

    /// Record that we (re)submitted a BGTask request — lets the UI show "scheduled vs. last run"
    /// so a large gap reads as "iOS is throttling us", not "the app is broken".
    func recordScheduled(at now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.bgLastScheduled)
    }

    // MARK: Bounded outcome log

    func records() -> [TaskRecord] {
        guard let data = defaults.data(forKey: Key.log),
              let list = try? JSONDecoder().decode([TaskRecord].self, from: data) else { return [] }
        return list
    }

    func records(since cutoff: Date) -> [TaskRecord] {
        records().filter { $0.date >= cutoff }
    }

    private func append(_ record: TaskRecord) {
        let capped = BoundedLog.appendCapped(record, to: records(), limit: Self.logLimit)
        if let data = try? JSONEncoder().encode(capped) { defaults.set(data, forKey: Key.log) }
    }

    // MARK: Metric persistence breadcrumbs

    func metricRecords() -> [MetricRecord] {
        guard let data = defaults.data(forKey: Key.metricLog),
              let list = try? JSONDecoder().decode([MetricRecord].self, from: data) else { return [] }
        return list
    }

    func metricRecords(since cutoff: Date) -> [MetricRecord] {
        metricRecords().filter { $0.date >= cutoff }
    }

    func recordMetricEvent(source: String, detail: String, at now: Date = Date()) {
        let record = MetricRecord(date: now, source: source, detail: detail)
        let capped = BoundedLog.appendCapped(record, to: metricRecords(), limit: Self.metricLogLimit)
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: Key.metricLog)
        }
    }

    // MARK: History-sync evidence

    func historySyncEvidence() -> [HistorySyncEvidence] {
        guard let data = defaults.data(forKey: Key.historySyncEvidence),
              let list = try? JSONDecoder().decode([HistorySyncEvidence].self, from: data) else { return [] }
        return list
    }

    func recordHistorySyncEvidence(_ entry: HistorySyncEvidence, at now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.historySyncEvidenceRetention)
        var rows = historySyncEvidence().filter { $0.date >= cutoff }
        rows.append(entry)
        if rows.count > Self.historySyncEvidenceLimit {
            rows.removeFirst(rows.count - Self.historySyncEvidenceLimit)
        }
        if let data = try? JSONEncoder().encode(rows) {
            defaults.set(data, forKey: Key.historySyncEvidence)
        }
    }

    // MARK: Health-alert decision log (#73/#85 body-vital alerts)

    func healthAlertRecords() -> [HealthAlertRecord] {
        guard let data = defaults.data(forKey: Key.healthAlertLog),
              let list = try? JSONDecoder().decode([HealthAlertRecord].self, from: data) else { return [] }
        return list
    }

    func healthAlertRecords(since cutoff: Date) -> [HealthAlertRecord] {
        healthAlertRecords().filter { $0.date >= cutoff }
    }

    /// The instant a decision is de-duplicated against.
    ///
    /// ⚠️ FALLS BACK TO THE DECISION'S OWN DAY WHEN THERE IS NO `readingTime`, and that fallback is
    /// required, not defensive. Only the three #73 HR/SpO2 rules produce a `HealthAlertHit`, so
    /// only they carry a reading time; the #85 skin-temp/fever family and the #183 morning verdict
    /// are appended to `candidates` directly and always log with `readingTime == nil`. Keyed on the
    /// raw optional, every one of those collapses to a single `(notification, reason, nil)` tuple —
    /// so the FIRST `fever`+`fired` row ever written would block every later fever firing from
    /// being logged for as long as it survives the buffer, and the log whose whole purpose is to be
    /// the denominator would show one row per family, ever. Day granularity matches how those
    /// families already de-dupe (`alerts.health.lastNight`, once per night/day), so it suppresses
    /// the intended repeat-within-a-pass noise without erasing tomorrow's decision.
    private static func dedupeKey(_ record: HealthAlertRecord, calendar: Calendar) -> Int {
        if let reading = record.readingTime {
            return Int(reading.timeIntervalSince1970.rounded())
        }
        return Int(calendar.startOfDay(for: record.date).timeIntervalSince1970.rounded())
    }

    /// Append a decision, unless an identical one is already on the log.
    ///
    /// ⚠️ THE DE-DUPE IS LOAD-BEARING, NOT POLISH. `markFired` only advances the watermark for
    /// alerts that actually survive the gate, so a SUPPRESSED reading is re-evaluated on every
    /// subsequent pass until it ages out of the 12 h lookback — several times an hour on a busy
    /// sync day. Without this the buffer fills with copies of one reading and evicts the week of
    /// history the log exists to provide. Matching on (notification, readingTime, reason) rather
    /// than only against the newest row is deliberate: decisions from different families
    /// interleave, so a newest-row-only check would let the same pair alternate through.
    /// Reading times are compared at whole-second resolution — the epoch counter's own
    /// granularity — so a Date round-tripped through JSON can't miss by a float hair.
    func recordHealthAlert(_ record: HealthAlertRecord, calendar: Calendar = .current) {
        let existing = healthAlertRecords()
        let key = Self.dedupeKey(record, calendar: calendar)
        let duplicate = existing.contains {
            $0.notification == record.notification
                && $0.reason == record.reason
                && Self.dedupeKey($0, calendar: calendar) == key
        }
        guard !duplicate else { return }
        let capped = BoundedLog.appendCapped(record, to: existing, limit: Self.healthAlertLogLimit)
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: Key.healthAlertLog)
        }
    }

    // MARK: Alert debounce persistence (consumed by SyncAlertPolicy)

    func alertLastFired() -> [SyncAlert: Date] {
        let raw = defaults.dictionary(forKey: Key.alertFired) as? [String: Double] ?? [:]
        var out: [SyncAlert: Date] = [:]
        for (k, v) in raw where v > 0 {
            if let alert = SyncAlert(rawValue: k) { out[alert] = Date(timeIntervalSince1970: v) }
        }
        return out
    }

    func markAlertsFired(_ alerts: [SyncAlert], at now: Date = Date()) {
        var raw = defaults.dictionary(forKey: Key.alertFired) as? [String: Double] ?? [:]
        for a in alerts { raw[a.rawValue] = now.timeIntervalSince1970 }
        defaults.set(raw, forKey: Key.alertFired)
    }
}

/// Posts the debounced silent-failure notifications (#44). One notification per condition per
/// `SyncAlertPolicy.renotifyInterval`; never spams. Authorization is requested LAZILY and
/// provisionally — the first time there's actually something to say — so a healthy user is never
/// prompted on launch and quiet alerts land in Notification Center without an upfront dialog.
struct LocalAlertCenter {
    var store = ObservabilityStore()
    var policy = SyncAlertPolicy()
    // Computed (not a stored property) so the synthesized memberwise init stays internal — i.e.
    // `LocalAlertCenter()` is callable from the other files that fire alerts.
    private var center: UNUserNotificationCenter { .current() }

    /// Evaluate the current state and post a debounced notification for each firing condition.
    /// No-op when nothing's wrong. `batteryPercent == nil` (e.g. the background session is already
    /// torn down) simply skips the low-battery check rather than firing falsely.
    func evaluate(now: Date = Date(), batteryPercent: Int?, healthAuthorized: Bool) async {
        let fire = policy.alertsToFire(
            now: now,
            lastSuccessfulSync: store.lastSuccessfulSync,
            batteryPercent: batteryPercent,
            healthAuthorized: healthAuthorized,
            healthEverAuthorized: store.healthEverAuthorized,
            lastFired: store.alertLastFired())
        guard !fire.isEmpty, await ensureAuthorized() else { return }
        for alert in fire { await post(alert) }
        store.markAlertsFired(fire, at: now)
    }

    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            // Provisional auth posts quietly (no upfront prompt) — appropriate for an alert the
            // user hasn't asked for but would want when something silently breaks.
            return (try? await center.requestAuthorization(options: [.alert, .sound, .provisional])) ?? false
        default:
            return false
        }
    }

    private func post(_ alert: SyncAlert) async {
        let content = UNMutableNotificationContent()
        switch alert {
        case .notSynced:
            content.title = "Ring not synced"
            content.body = "OpenCircuit hasn't synced your ring in a while. Open the app to refresh, and check Settings ▸ General ▸ Background App Refresh."
        case .lowBattery:
            content.title = "Ring battery low"
            content.body = "Your RingConn battery is low — charge it soon to keep tracking."
        case .healthAuthLost:
            content.title = "Apple Health access off"
            content.body = "OpenCircuit can no longer write to Apple Health. Re-enable it in Settings ▸ Health ▸ Data Access & Devices."
        }
        // One pending request per condition (stable id) — re-posting just refreshes it.
        let request = UNNotificationRequest(identifier: "obs.alert.\(alert.rawValue)",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }
}
