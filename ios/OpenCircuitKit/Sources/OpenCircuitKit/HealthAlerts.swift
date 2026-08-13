// Local health-alert policy — the PURE decision layer shared by the high-HR / low-SpO2 /
// elevated-HR-while-inactive alerts (#73) AND the skin-temp / fever notifications (#85).
//
// The ring has NO vibration motor, so every alert is a phone notification (pp.txt:46223
// "App can receive the following notifications only when connected to the ring"). This file
// holds only the THRESHOLD + DE-DUPE + DND (quiet-hours) math — no Apple frameworks — so it
// unit-tests on the CLI. The `UNUserNotificationCenter` glue + UserDefaults persistence live
// in the app target (HealthNotificationCenter.swift), which routes BOTH tickets through this
// ONE engine (a single quiet-hours window, a single de-dupe namespace).
//
// Thresholds are user-configurable with sensible defaults — never a hardcoded reading of a
// person's data. Evidence: `highHrRemind`/`highHrRemindEnable`, `keyHeartRateReminderValue`;
// `lowSpo2Value`, `keyLowSpO2Detected` (SpO2 severity ≥95 / 90-95 / 75-90 / <75); 10-min
// sustained-while-non-exercising HR trigger (pp.txt:45915). Fever (0x14) + the four skin-temp
// flags (0x10–0x13) come from `SkinTempBaseline` (#69) and `VitalsBaseline` (#72).

import Foundation

/// Every user-facing health notification, across #73 (HR/SpO2), #85 (temp/fever),
/// #84 (reminders), and #86 (charging complete). One enum = one de-dupe namespace,
/// so the same condition can't re-fire from two code paths.
public enum HealthNotification: String, CaseIterable, Codable, Sendable {
    // #73 — heart rate & blood oxygen
    case highHR
    case lowSpO2
    case elevatedHRInactive
    // #85 — skin temperature (the four SkinTempBaseline flags) + fever
    case skinTempRise            // 0x12 skinTempAbnormalRise
    case skinTempDrop            // 0x13 skinTempAbnormalDrop
    case skinTempFluctuationRise // 0x10 skinTempFluctuationRise
    case skinTempFluctuationDrop // 0x11 skinTempFluctuationDrop
    case fever                   // 0x14 feverAbnormal (HR + temp cross-reference, #72)
    // #84 — app-side reminders
    case sedentaryReminder = "reminder.sedentary"
    case wearReminder      = "reminder.wear"
    case bedtimeReminder   = "reminder.bedtime"
    // #86 — battery charging complete
    case chargingComplete  = "battery.chargingComplete"
    // #183 — the once-a-morning overnight-signals verdict. APPENDED AT THE VERY END, NEVER
    // INSERTED: `NotificationGate.filter` returns survivors in `allCases` DECLARATION ORDER, so
    // appending leaves the relative order of every already-shipped pair byte-identical while an
    // insertion would silently reorder delivery for the four shipped families. The explicit String
    // rawValue keeps the persisted `alerts.health.lastFired` / `alerts.health.lastNight` ledger keys
    // stable. Pinned by `HealthNotificationOrderTests`.
    case headacheSigns     = "headache.signs"
}

// MARK: - Quiet hours (shared DND window)

/// A single nightly quiet-hours window, shared by every alert. Minutes are since-midnight (the
/// same timezone-free convention as `SleepWindow`), so a window may wrap past midnight.
public struct QuietHours: Equatable, Sendable {
    public var enabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int

    public init(enabled: Bool = false, startMinutes: Int = 22 * 60, endMinutes: Int = 7 * 60) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    /// Whether `date` falls inside the quiet window. Disabled ⇒ never. Handles a window that wraps
    /// past midnight (e.g. 22:00 → 07:00). A zero-length window (start == end) is treated as empty.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinutes != endMinutes else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if startMinutes < endMinutes {           // same-day window
            return m >= startMinutes && m < endMinutes
        }
        return m >= startMinutes || m < endMinutes // wraps past midnight
    }
}

// MARK: - De-dupe / DND gate

/// Decides whether a notification may fire NOW given quiet hours + an anti-spam backoff. Pure so
/// the routing is fully testable; the app persists `lastFired` and posts the survivors.
public struct NotificationGate: Equatable, Sendable {
    /// Minimum spacing between repeats of the SAME notification (anti-spam backoff).
    public var renotifyInterval: TimeInterval
    public init(renotifyInterval: TimeInterval = 2 * 3600) {
        self.renotifyInterval = renotifyInterval
    }

    public func shouldFire(_ n: HealthNotification, now: Date,
                           lastFired: [HealthNotification: Date],
                           quietHours: QuietHours, calendar: Calendar = .current) -> Bool {
        if quietHours.contains(now, calendar: calendar) { return false }
        if let fired = lastFired[n], now.timeIntervalSince(fired) < renotifyInterval { return false }
        return true
    }

    /// The subset of `candidates` allowed to fire now, in stable `HealthNotification.allCases` order.
    public func filter(_ candidates: [HealthNotification], now: Date,
                       lastFired: [HealthNotification: Date],
                       quietHours: QuietHours, calendar: Calendar = .current) -> [HealthNotification] {
        let set = Set(candidates)
        return HealthNotification.allCases.filter {
            set.contains($0) && shouldFire($0, now: now, lastFired: lastFired,
                                           quietHours: quietHours, calendar: calendar)
        }
    }
}

// MARK: - #73 thresholds + evaluator

/// One blood-oxygen reading (percent) with its time. SpO2 is stored as a 0…1 fraction elsewhere;
/// callers convert to whole percent so the threshold reads in the same units the user configures.
public struct SpO2Reading: Equatable, Sendable {
    public let percent: Int
    public let time: Date
    /// Quality evidence from the `0x4c` epoch that produced this reading, or nil when no raw
    /// record resolved (a live on-demand measurement, or a sample older than the archive).
    /// DEFAULTED so every existing construction site keeps compiling and keeps its old meaning.
    public let evidence: SpO2Evidence?
    public init(percent: Int, time: Date, evidence: SpO2Evidence? = nil) {
        self.percent = percent
        self.time = time
        self.evidence = evidence
    }
}

/// Policy for the low-SpO2 rule: how much agreement a low reading needs before it may notify,
/// and how much motion inside the run is tolerated.
///
/// WHY A CORROBORATION RULE AT ALL. The shipped rule was a single-sample crossing — one epoch at
/// or below the threshold notified, with no motion, wear or quality check. That reports an
/// artifact as a desaturation, and the failure is not hypothetical: an 80 % reading arrived while
/// the wearer's hands were in water. Optical SpO2 through a wet, moving finger is not a
/// measurement of blood.
///
/// ⚖️ THE SHAPE IS BORROWED, THE CODE IS NOT. No reference project implements low-SpO2 alerting
/// or artifact rejection (NOOP/Strand has no physiological alert at all; Gadgetbridge only ships a
/// threshold to watch firmware; GarminDB, open-wearables and fitbit-grafana do display bands and
/// rollups). Two facts were taken from NOOP/Strand and are cited on the constants below:
/// `IllnessSignalEngine.minCorroboratingSignals = 2` ("a single noisy night can never raise") and
/// `MetricArbitrationPolicy`'s SpO2 agreement bound of 2 percentage points. Its off-wrist rule is
/// FRACTIONAL rather than binary, which is where `maxBadEpochFraction` comes from.
public struct SpO2AlertPolicy: Equatable, Sendable {

    /// How far from the triggering reading a corroborating reading may sit.
    ///
    /// 🟢 MEASURED (2026-08-13, `desktop/spo2_alert_autopsy.py --sweep` against a real 30 h export
    /// from this wearer's own ring, 153 SpO2-carrying epochs). Confirms the concern this constant
    /// was provisionally set against:
    ///
    /// ⚠️ THIS CONSTANT MUST COVER **TWO** CADENCES AND THEY DIFFER BY AN ORDER OF MAGNITUDE.
    ///   • channel `0x00`, the sleep program — PROTOCOL.md §5.3, a 🟢 300 s duty cycle. MEASURED
    ///     here too: n=94, p50=300 s, p99=310 s, max=450 s.
    ///   • channel `0x03`, all-day — PROTOCOL.md §5.6.1. MEASURED here: n=31, p50=600 s,
    ///     p90=1417 s, **p99=2325 s, max=2550 s** — wider than the doc's single-capture estimate
    ///     of 20–30 min (1200–1800 s), which is why this was left provisional rather than frozen
    ///     against that one capture.
    /// The reported incident was DAYTIME, so it is on the second, wider regime. Sizing this to the
    /// 300 s sleep cadence would leave every daytime reading structurally uncorroborated and
    /// quietly reduce the whole feature to overnight-only — a "fix" that suppresses the false
    /// alarm by deleting the channel it came from; `HealthAlertsTests
    /// .testDaytimeCadenceStillCorroborates` pins exactly that trap. 2700 s is the smallest round
    /// number clearing the measured 2550 s max with margin, on one wearer's data — worth
    /// re-measuring as more exports accumulate, since n=31 daytime gaps is not a large sample.
    ///
    /// Widening this only ever ADDS alerts (more chances to find a corroborator); the suppression
    /// comes from `agreementTolerance`, not from the window.
    public var corroborationWindow: TimeInterval

    /// How far apart two readings may be and still be treated as the same event, in percentage
    /// points. 🟢 SOURCED: NOOP/Strand's `MetricArbitrationPolicy` treats SpO2 sources as agreeing
    /// within 2 % and conflicting beyond 4 %; the *agreement* bound is the conservative choice for
    /// a rule whose job is to demand corroboration. Independently, byte `[8]` is an integer
    /// percent, so 2 points is the smallest tolerance that survives quantisation plus ordinary
    /// epoch-to-epoch drift. The reported incident (80 % against 96–98 % neighbours) misses by 16.
    public var agreementTolerance: Int

    /// Readings required before an alert may fire — the trigger plus at least one corroborator.
    /// 🟢 SOURCED: NOOP/Strand's `IllnessSignalEngine.minCorroboratingSignals = 2`, one time-scale
    /// down. This is the direct answer to "a single epoch fires the alert today".
    public var minCorroboratingReadings: Int

    /// The fraction of RESOLVED epochs that may be bad before the run is rejected, applied with a
    /// STRICT `>` so exactly-half survives.
    ///
    /// 🟢 SHAPE SOURCED, threshold reasoned. NOOP/Strand's off-wrist rule drops a candidate run
    /// only when bad coverage reaches a fraction of its duration — never binary — so a real night
    /// with a short bad patch survives. The same asymmetry is wanted here, and the strict
    /// comparison is what delivers it at the minimum run size: 1 bad of 2 is 0.5, NOT `> 0.5`, so
    /// **one moving epoch inside a genuine run does not kill the alert**. Two bad of two — the
    /// shape of a hand held in water across both readings — is 1.0 and suppresses. 1 of 3 survives.
    public var maxBadEpochFraction: Double

    public init(corroborationWindow: TimeInterval = 2700,
                agreementTolerance: Int = 2,
                minCorroboratingReadings: Int = 2,
                maxBadEpochFraction: Double = 0.5) {
        self.corroborationWindow = corroborationWindow
        self.agreementTolerance = agreementTolerance
        self.minCorroboratingReadings = minCorroboratingReadings
        self.maxBadEpochFraction = maxBadEpochFraction
    }

    /// Whether ONE epoch is too compromised to count toward a desaturation.
    ///
    /// v1 gates on WEAR and INTRA-EPOCH MOTION only, and deliberately no further:
    ///
    /// • `unworn` — the idle template is `[4:8] == 05 00 0c 00`, which cannot carry an SpO2 byte
    ///   at all. Resolving one means something upstream is wrong.
    /// • `!resolvesStillness` — a step INSIDE the 150 s epoch. `BulkSleep` documents this as
    ///   exactly the motion component `ActivityPeriod.motionAboveLocalFloor` CANNOT remove: the
    ///   rolling floor subtracts a per-window LEVEL, so a flat plateau at any level cancels
    ///   (Gen-2 `01`, Gen-3 `0f`, drifting `16→24→39` alike) while an intra-epoch step survives
    ///   de-flooring intact. It keys on STRUCTURE, not on a device-dependent level, and reuses the
    ///   already-calibrated `motionStillThreshold` rather than inventing a number. This mirrors
    ///   `BulkRecord.measuredHRVRMSSD`, which already gates a recovered value on the ring's own
    ///   quiet verdict with its justification measured in the doc comment.
    ///
    /// NOT gated on, on purpose:
    /// • `confidence` (byte `[6]`) — 🟢 named but "range ~0…12, not yet bounded precisely" and
    ///   explicitly "NOT currently consumed by any analytic". PROTOCOL.md §5.3 measured it as the
    ///   WORST discriminator tested (Mann-Whitney AUC 0.42/0.27 vs wake, against the duty cycle's
    ///   0.819–1.000). It is carried and logged so the autopsy harness can screen it; baking in an
    ///   untested weighting ahead of that is what `BulkSleep` warns against.
    /// • `magnitudesAllZero` — 🟢 MEASURED at 1697/5648 = 30.0 % of corpus records, so its
    ///   negation flags 70 % of all epochs. As a suppressor it would kill essentially every alert.
    ///   Carried so a THRESHOLD (rather than the zero test) can be screened later.
    public func isBadEpoch(_ evidence: SpO2Evidence) -> Bool {
        evidence.unworn || !evidence.resolvesStillness
    }
}

/// The outcome of the low-SpO2 rule, carrying enough context for the health-alert log to say WHY.
///
/// A verdict rather than an `SpO2Reading?` on purpose: an optional loses the distinction between
/// "nothing crossed the threshold" and "something crossed and we chose to withhold it", and that
/// distinction is the entire point of the change.
public struct SpO2Verdict: Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The rule passed; this alert may fire (subject to the shared quiet-hours/backoff gate).
        case fired
        /// Nothing crossed the threshold. Never logged — it is the ordinary case.
        case noCandidate
        /// A crossing with no OTHER LOW reading inside the window to corroborate it. Covers both
        /// "nothing nearby at all" and "nearby readings were all healthy" — in the latter case
        /// there is nothing that could corroborate a desaturation, so it is the same story.
        case noCorroboration
        /// A crossing with another LOW reading nearby that disagrees by more than
        /// `agreementTolerance` — two sub-threshold readings that are not the same event.
        case corroborationDisagrees
        /// Corroborated, but more than `maxBadEpochFraction` of the resolved epochs were moving
        /// or unworn.
        case badEpochMajority
    }

    public let outcome: Outcome
    /// The worst candidate considered, or nil for `.noCandidate`.
    public let reading: SpO2Reading?
    /// Trigger + corroborators.
    public let runSize: Int
    /// |Δ%| of the closest in-window reading — the number that makes "disagrees" legible.
    public let nearestNeighbourDelta: Int?
    /// How many of the run resolved to a raw record, and how many of those were bad. A FIRED
    /// verdict with `evidenceEpochs == 0` rode the fail-open path; that is visible on purpose.
    public let evidenceEpochs: Int
    public let badEpochs: Int

    public var fired: Bool { outcome == .fired }

    public init(outcome: Outcome, reading: SpO2Reading?, runSize: Int,
                nearestNeighbourDelta: Int?, evidenceEpochs: Int, badEpochs: Int) {
        self.outcome = outcome
        self.reading = reading
        self.runSize = runSize
        self.nearestNeighbourDelta = nearestNeighbourDelta
        self.evidenceEpochs = evidenceEpochs
        self.badEpochs = badEpochs
    }
}

/// The result of one `HealthAlertEvaluator.evaluate` pass.
///
/// The SpO2 verdict is returned ALONGSIDE the hits rather than folded into them so a suppression
/// cannot be silently dropped on the floor — the caller is handed the decision whether or not it
/// produced a notification.
public struct HealthAlertOutcome: Equatable, Sendable {
    public let hits: [HealthAlertHit]
    public let spo2: SpO2Verdict
    public init(hits: [HealthAlertHit], spo2: SpO2Verdict) {
        self.hits = hits
        self.spo2 = spo2
    }
}

/// User-configurable thresholds for the HR/SpO2 alerts (#73). Defaults are conservative and
/// documented; each rule has its own enable flag so a user can opt out per-rule.
public struct HealthAlertThresholds: Equatable, Sendable {
    public var highHREnabled: Bool
    public var highHRBpm: Int
    public var lowSpO2Enabled: Bool
    public var lowSpO2Percent: Int
    public var elevatedHREnabled: Bool
    public var elevatedHRBpm: Int
    public var elevatedSustained: TimeInterval
    /// Max gap between consecutive readings still counted as one continuous elevated run (so a
    /// lone spike hours apart isn't "sustained").
    public var elevatedMaxGap: TimeInterval

    public init(highHREnabled: Bool = true,
                highHRBpm: Int = 120,
                lowSpO2Enabled: Bool = true,
                lowSpO2Percent: Int = 90,
                elevatedHREnabled: Bool = true,
                elevatedHRBpm: Int = 100,
                elevatedSustained: TimeInterval = 10 * 60,
                elevatedMaxGap: TimeInterval = 5 * 60) {
        self.highHREnabled = highHREnabled
        self.highHRBpm = highHRBpm
        self.lowSpO2Enabled = lowSpO2Enabled
        self.lowSpO2Percent = lowSpO2Percent
        self.elevatedHREnabled = elevatedHREnabled
        self.elevatedHRBpm = elevatedHRBpm
        self.elevatedSustained = elevatedSustained
        self.elevatedMaxGap = elevatedMaxGap
    }
}

/// One step-count snapshot's observation window + delta, carrying the device's own timestamps.
/// A pure value type so the #144 activity-gate math is testable off the app's SwiftData
/// `StoredStepSample` model (which is app-target-only). The app maps each `StoredStepSample` to one
/// of these before handing them to `activeStepIntervals`.
public struct StepWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let delta: Int
    public init(start: Date, end: Date, delta: Int) {
        self.start = start; self.end = end; self.delta = delta
    }
}

/// One fired alert with the reading that triggered it (for the "… detected at [time]" copy).
public struct HealthAlertHit: Equatable, Sendable {
    public let notification: HealthNotification
    public let value: Double   // bpm for HR alerts, percent for SpO2
    public let time: Date
    public init(notification: HealthNotification, value: Double, time: Date) {
        self.notification = notification; self.value = value; self.time = time
    }
}

// NOTE: HR alerts intentionally have NO device-timestamp "freshness" gate. All-day HR reaches the
// phone via ~hourly background drains whose device timestamps are routinely 30–60+ min old on
// arrival, evaluated ONCE right after each drain; a freshness window would permanently silence the
// older half of every drain. De-dupe is done here by the per-notification `lastFired` filter in
// `evaluate` (a crossing fires once on first sight and never replays), not by the sample's age.

public enum HealthAlertEvaluator {

    /// The worst (highest) HR reading at/above the threshold, or nil. "High heart rate detected at
    /// [time]" (pp.txt:48405) — an instantaneous crossing.
    public static func highHR(_ samples: [HRSample], thresholdBpm: Int) -> HRSample? {
        samples.filter { $0.bpm >= thresholdBpm }.max { $0.bpm < $1.bpm }
    }

    /// The low-SpO2 rule: does the worst fresh crossing that CAN corroborate have enough support
    /// to notify?
    ///
    /// ⚠️ THIS REPLACED an ungated `lowSpO2(_:thresholdPercent:) -> SpO2Reading?` that returned the
    /// minimum reading at or below the threshold and nothing else. That function is deliberately
    /// NOT kept as a convenience wrapper: an ungated variant sitting next to a gated one is
    /// precisely how the defect comes back.
    ///
    /// `notBefore` is the freshness bound (the caller's `lastFired[.lowSpO2]`), and it applies to
    /// the TRIGGER ONLY. Corroborators are searched over the FULL series on purpose: a genuine
    /// multi-epoch run that straddles the bound would otherwise lose its support and be suppressed
    /// by the very mechanism meant to stop it replaying.
    ///
    /// ⚠️ WHY THIS TRIES **EVERY** CANDIDATE, WORST FIRST, NOT JUST THE SINGLE WORST. An earlier
    /// version picked ONE trigger — the global worst reading in the lookback window — and returned
    /// whatever that one reading's verdict was, full stop. That silently masks a REAL desaturation:
    /// if an isolated artifact (no corroborator, e.g. a wet-finger 80 %) happens to be numerically
    /// worse than a genuine corroborated event elsewhere in the same 12 h window (e.g. an 88/86 %
    /// pair five minutes apart), the artifact would be chosen as the sole trigger, fail
    /// corroboration, and the pass would report a suppression for the WHOLE window — the legitimate
    /// event never gets its own turn at evaluation. Trying candidates worst-first and firing on the
    /// first one that has real support fixes this without weakening the corroboration requirement:
    /// each candidate is still judged entirely on its own run. If nothing fires, the worst
    /// candidate's own verdict is returned, matching the prior single-trigger behaviour exactly —
    /// so this only changes the outcome when the worst reading fails and a LESS severe one would
    /// have fired, which is precisely the masking case.
    public static func lowSpO2(_ readings: [SpO2Reading],
                               thresholdPercent: Int,
                               notBefore: Date = .distantPast,
                               policy: SpO2AlertPolicy = SpO2AlertPolicy()) -> SpO2Verdict {
        let candidates = readings.filter {
            $0.percent > 0 && $0.percent <= thresholdPercent && $0.time > notBefore
        }
        guard !candidates.isEmpty else {
            return SpO2Verdict(outcome: .noCandidate, reading: nil, runSize: 0,
                               nearestNeighbourDelta: nil, evidenceEpochs: 0, badEpochs: 0)
        }

        var worstVerdict: SpO2Verdict?
        // Tie-broken on TIME, not left to sort stability. Equal-percent candidates are common
        // (integer percents), and the input order genuinely varies between passes, so an
        // unspecified tie-break would let `worstVerdict.reading` — and therefore the logged
        // `readingTime`, which is part of the decision log's dedupe key — differ pass to pass on
        // identical data, re-logging the same suppression and evicting real history.
        for trigger in candidates.sorted(by: { ($0.percent, $0.time) < ($1.percent, $1.time) }) {
            let verdict = evaluateOne(trigger, readings: readings,
                                      thresholdPercent: thresholdPercent, policy: policy)
            if verdict.fired { return verdict }
            if worstVerdict == nil { worstVerdict = verdict }
        }
        // worstVerdict is guaranteed non-nil here: candidates is non-empty, so the loop ran at
        // least once and captured the first (worst) candidate's verdict before any `return`.
        return worstVerdict!
    }

    /// The corroboration + evidence check for ONE candidate trigger. Pulled out of `lowSpO2` so
    /// that function can try every candidate worst-first without duplicating this logic.
    private static func evaluateOne(_ trigger: SpO2Reading, readings: [SpO2Reading],
                                    thresholdPercent: Int, policy: SpO2AlertPolicy) -> SpO2Verdict {
        let neighbours = readings.filter {
            $0.time != trigger.time
                && abs($0.time.timeIntervalSince(trigger.time)) <= policy.corroborationWindow
        }
        let nearestDelta = neighbours
            .min { abs($0.time.timeIntervalSince(trigger.time)) < abs($1.time.timeIntervalSince(trigger.time)) }
            .map { abs($0.percent - trigger.percent) }

        let corroborators = neighbours.filter {
            $0.percent <= thresholdPercent && abs($0.percent - trigger.percent) <= policy.agreementTolerance
        }
        let run = [trigger] + corroborators
        guard run.count >= policy.minCorroboratingReadings else {
            // "Nothing low nearby" and "another low reading that disagrees" are different stories
            // for the wearer and for whoever tunes the constants, so they get different outcomes.
            //
            // ⚠️ The discriminator is whether a nearby reading was ITSELF LOW — not merely whether
            // any neighbour existed. Keying on `neighbours.isEmpty` mislabels the common case: a
            // lone low reading surrounded by perfectly healthy ones (the reported dishes incident,
            // 80 % between 97 % and 96 %) has neighbours, but they are not low readings that
            // disagree — there is simply nothing to corroborate it. Reporting that as
            // `.corroborationDisagrees` puts normal readings into the population someone would
            // later mine to tune `agreementTolerance`, which they have nothing to do with.
            let lowNeighbours = neighbours.filter { $0.percent <= thresholdPercent }
            return SpO2Verdict(outcome: lowNeighbours.isEmpty ? .noCorroboration : .corroborationDisagrees,
                               reading: trigger, runSize: run.count,
                               nearestNeighbourDelta: nearestDelta,
                               evidenceEpochs: 0, badEpochs: 0)
        }

        let resolved = run.compactMap(\.evidence)
        guard !resolved.isEmpty else {
            // MISS — no raw record for any reading in the run. FAIL OPEN: corroboration carries it.
            //
            // Making a miss fatal would permanently un-alert every live on-demand measurement
            // (which has no `0x4c` record BY CONSTRUCTION), plus any differently-namespaced ring
            // and anything after a UserDefaults reset — a silent, unbounded false negative created
            // by a DIAGNOSTIC detail. The bound that makes fail-open safe: this path is never more
            // permissive than the rule it replaced, which fired on ONE reading with no evidence at
            // all. Strictly monotone improvement in every case. `evidenceEpochs == 0` on the
            // resulting log row is what makes the branch visible the first time it matters.
            return SpO2Verdict(outcome: .fired, reading: trigger, runSize: run.count,
                               nearestNeighbourDelta: nearestDelta,
                               evidenceEpochs: 0, badEpochs: 0)
        }

        let bad = resolved.filter { policy.isBadEpoch($0) }.count
        // The denominator is `resolved`, NOT `run`: a partial miss must not dilute the fraction
        // toward "good". One resolved-and-bad epoch of a 2-run whose other reading missed is 1/1,
        // and suppresses — "the evidence we have says this was motion" is the coherent reading,
        // and it is the direction that catches the reported incident when only one epoch resolves.
        guard Double(bad) <= Double(resolved.count) * policy.maxBadEpochFraction else {
            return SpO2Verdict(outcome: .badEpochMajority, reading: trigger, runSize: run.count,
                               nearestNeighbourDelta: nearestDelta,
                               evidenceEpochs: resolved.count, badEpochs: bad)
        }
        return SpO2Verdict(outcome: .fired, reading: trigger, runSize: run.count,
                           nearestNeighbourDelta: nearestDelta,
                           evidenceEpochs: resolved.count, badEpochs: bad)
    }

    /// The reading that COMPLETES a continuous run of HR ≥ threshold spanning ≥ `minDuration`,
    /// or nil. Mirrors the APK's "HR exceeds the set maximum for a continuous 10 minutes while in a
    /// non-exercising state" (pp.txt:45915). The caller is responsible for passing only inactive /
    /// non-exercising samples (#61 sharpens that gate); the sustained-window math is here.
    public static func elevatedHRInactive(_ samples: [HRSample], thresholdBpm: Int,
                                          minDuration: TimeInterval,
                                          maxGap: TimeInterval = 5 * 60) -> HRSample? {
        let sorted = samples.sorted { $0.start < $1.start }
        var runStart: Date?
        var prev: Date?
        for s in sorted {
            guard s.bpm >= thresholdBpm else { runStart = nil; prev = nil; continue }
            if let p = prev, s.start.timeIntervalSince(p) > maxGap {
                runStart = s.start            // gap too big — start a fresh run here
            } else if runStart == nil {
                runStart = s.start
            }
            prev = s.start
            if let rs = runStart, s.start.timeIntervalSince(rs) >= minDuration { return s }
        }
        return nil
    }

    /// Default cap on a step snapshot's window width still treated as a discrete activity burst
    /// (#144). Normal per-reading step windows are the gap between two step readings — seconds on the
    /// live poll, up to a few minutes across a background drain — comfortably under this. A window
    /// WIDER than this is the day-wide `[startOfDay, sampleDate]` FALLBACK that `StoredStepSample`
    /// records on a fresh baseline / day rollover (no prior same-day reading to anchor to); those run
    /// to multiple hours and must be excluded from the gate (see `activeStepIntervals`). Chosen short
    /// on purpose: it cleanly excludes every hours-long fallback, and erring short only risks
    /// under-gating (an occasional post-workout false alarm) — never the catastrophic direction of
    /// suppressing a real cardiac crossing.
    public static let maxActivityWindow: TimeInterval = 30 * 60

    /// Build the concurrent-activity intervals for the HR gate (#144) from step snapshots, dropping:
    ///  - zero/negative-`delta` windows (no actual movement), and
    ///  - windows WIDER than `maxActivityWindow` — the day-wide `[startOfDay, sampleDate]` FALLBACK
    ///    `StoredStepSample` records on a fresh baseline / day rollover. This exclusion is
    ///    SAFETY-CRITICAL: feeding a multi-hour fallback window into `nonExercising` would suppress
    ///    EVERY HR crossing since midnight — including a genuine resting tachycardia — a health-safety
    ///    false negative, the worst outcome. Excluding it costs at most an occasional missed gate (a
    ///    post-workout false alarm), which is the far safer failure direction.
    public static func activeStepIntervals(_ steps: [StepWindow],
                                           maxActivityWindow: TimeInterval = maxActivityWindow)
    -> [(Date, Date)] {
        steps.filter { $0.delta > 0 && $0.end.timeIntervalSince($0.start) <= maxActivityWindow }
             .map { ($0.start, $0.end) }
    }

    /// Drop HR samples that overlap concurrent step activity (or its `pad`-long recovery tail), so
    /// exercise heart rate can't trip the resting high-HR / elevated-while-inactive alarms (#144).
    /// A sample is EXCLUDED when its device timestamp `start` lies inside any `activeIntervals`
    /// window `[from, to]` — or within `pad` after `to`, covering the post-exercise HR recovery
    /// tail. Match is by the DEVICE timestamps carried on BOTH series (never wall-clock arrival):
    /// all-day HR and steps ride in on the same ~hourly background drains with timestamps 30–60+
    /// min old, so only their device times line up.
    ///
    /// KEY SAFETY PROPERTY: this only ever SUPPRESSES on positive evidence of concurrent activity.
    /// An empty `activeIntervals` (no step data synced for the window) returns the series unchanged,
    /// so a genuine resting tachycardia with no steps still fires and missing step data can never
    /// silence a real alert. It never narrows the lookback window — it filters by activity overlap,
    /// not recency.
    public static func nonExercising(_ hr: [HRSample], activeIntervals: [(Date, Date)],
                                     pad: TimeInterval = 10 * 60) -> [HRSample] {
        guard !activeIntervals.isEmpty else { return hr }
        return hr.filter { sample in
            !activeIntervals.contains { interval in
                sample.start >= interval.0 && sample.start <= interval.1.addingTimeInterval(pad)
            }
        }
    }

    /// Evaluate all three #73 rules and return the hits (disabled rules are skipped). `inactiveHR`
    /// is the HR series for the sustained-while-inactive rule; the instantaneous rules use `hr`.
    public static func evaluate(hr: [HRSample], spo2: [SpO2Reading], inactiveHR: [HRSample],
                                thresholds: HealthAlertThresholds,
                                lastFired: [HealthNotification: Date] = [:],
                                spo2Policy: SpO2AlertPolicy = SpO2AlertPolicy()) -> HealthAlertOutcome {
        var hits: [HealthAlertHit] = []
        let freshHR = hr.filter { $0.start > (lastFired[.highHR] ?? .distantPast) }
        let freshInactiveHR = inactiveHR.filter {
            $0.start > (lastFired[.elevatedHRInactive] ?? .distantPast)
        }

        if thresholds.highHREnabled, let s = highHR(freshHR, thresholdBpm: thresholds.highHRBpm) {
            hits.append(HealthAlertHit(notification: .highHR, value: Double(s.bpm), time: s.start))
        }
        // NOTE the argument is the FULL `spo2` series, not a pre-filtered fresh one: the rule
        // applies `notBefore` to the trigger itself and needs the unfiltered series to find
        // corroborators that may sit before the bound. Pre-filtering here is the bug that would
        // suppress a genuine run straddling the last-fired watermark.
        var spo2Verdict = SpO2Verdict(outcome: .noCandidate, reading: nil, runSize: 0,
                                      nearestNeighbourDelta: nil, evidenceEpochs: 0, badEpochs: 0)
        if thresholds.lowSpO2Enabled {
            spo2Verdict = lowSpO2(spo2, thresholdPercent: thresholds.lowSpO2Percent,
                                  notBefore: lastFired[.lowSpO2] ?? .distantPast,
                                  policy: spo2Policy)
            if spo2Verdict.fired, let s = spo2Verdict.reading {
                hits.append(HealthAlertHit(notification: .lowSpO2, value: Double(s.percent), time: s.time))
            }
        }
        if thresholds.elevatedHREnabled,
           let s = elevatedHRInactive(freshInactiveHR, thresholdBpm: thresholds.elevatedHRBpm,
                                      minDuration: thresholds.elevatedSustained,
                                      maxGap: thresholds.elevatedMaxGap) {
            hits.append(HealthAlertHit(notification: .elevatedHRInactive, value: Double(s.bpm), time: s.start))
        }
        return HealthAlertOutcome(hits: hits, spo2: spo2Verdict)
    }
}

// MARK: - #85 routing (temp flags + fever → notifications)

public enum TempFeverNotifications {
    /// The #85 skin-temp/fever notifications — the ones that de-dupe per night. Single source of
    /// truth so every classifier (`notifications` routing, the app-side `isTempFever` filter, and
    /// the disclaimer logic) stays in lock-step; adding a skin-temp case means adding it here once.
    public static let notificationSet: Set<HealthNotification> = [
        .skinTempRise, .skinTempDrop, .skinTempFluctuationRise, .skinTempFluctuationDrop, .fever,
    ]

    /// Timezone-stable `yyyymmdd` day key for a night's start-of-day. Used as the per-night ledger
    /// key instead of a raw instant: an instant (`timeIntervalSince1970`) shifts under westward
    /// travel between two syncs of the same night, which could re-fire the duplicate; the calendar
    /// day components do not.
    public static func dayKey(for night: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: night)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// Map the four `SkinTempBaseline` anomaly flags (#69) + the suspected-fever flag (#72) to the
    /// notifications they should raise. Pure flag→notification routing; the de-dupe/DND gate and
    /// posting happen in the shared app-side center. (#85)
    public static func notifications(flags: SkinTempBaseline.AnomalyFlags,
                                     feverSuspected: Bool) -> [HealthNotification] {
        var out: [HealthNotification] = []
        if flags.abnormalRise { out.append(.skinTempRise) }
        if flags.abnormalDrop { out.append(.skinTempDrop) }
        if flags.fluctuationRise { out.append(.skinTempFluctuationRise) }
        if flags.fluctuationDrop { out.append(.skinTempFluctuationDrop) }
        if feverSuspected { out.append(.fever) }
        return out
    }

    /// Per-NIGHT de-dupe for the skin-temp/fever notifications. Each of these flags pertains to ONE
    /// overnight summary, so once we've notified for a given night it must NOT re-fire on later
    /// syncs of the same night — the 2h anti-spam backoff alone would re-raise the same night's flag
    /// every couple hours all day (the user sees the same "skin temperature dropped" alert after
    /// every sync). Keeps only the flags whose night is strictly newer than the last night already
    /// notified for that flag; a fresh night's summary re-arms it. `night` and the map values are
    /// timezone-stable `yyyymmdd` day keys (see `dayKey(for:)`).
    public static func freshForNight(_ candidates: [HealthNotification], night: Int,
                                     lastNotifiedNight: [HealthNotification: Int]) -> [HealthNotification] {
        candidates.filter { n in
            guard let last = lastNotifiedNight[n] else { return true }
            return night > last
        }
    }
}

// MARK: - #183 routing (overnight-signals verdict → the morning notification)

/// The once-a-morning "last night was unusual for you" notification (#183).
///
/// ══ READ THE COPY RULE BEFORE YOU TOUCH ANY STRING IN HERE ══
///
/// This notification reports WHAT WE MEASURED. It never states, implies, or numerically hints that
/// a headache is coming, and the word "headache" appears nowhere in its title or body.
///
/// The arithmetic behind that rule is in `HeadacheSignals.swift` §1: the published ceiling for
/// physiology-only headache forecasting is AUC ≈ 0.62–0.68, and at this feature's operating point
/// (flag the top 10 % of the user's OWN days) that is ~26 % precision — about three in four flagged
/// mornings do not become a headache. A FORECAST at that precision is wrong three times in four. A
/// MEASUREMENT at that precision is true every single time, because the thing being asserted is the
/// deviation itself, which we actually observed. That is the entire difference, and it is why the
/// notification exists at all rather than waiting on proof that may never arrive.
///
/// The user opted into a feature called "Headache signals", so the context is already theirs.
/// Putting the word into the alert converts a true statement ("these signals drifted") into a false
/// one ("you are about to get a headache") without adding one bit of information.
///
/// Consequences, so nobody has to re-derive them:
///  - NO probability, percentage, score, "risk", "early warning", "likely" or "may get" phrasing;
///  - NO actions on the notification — see the category registration in `AppDelegate.swift` for the
///    label-bias reason. Quick-reply buttons that appear only on flagged mornings would collect
///    ground-truth labels conditioned on our own flag and permanently inflate every later precision
///    number by construction;
///  - it fires AT MOST ONCE PER CALENDAR DAY (`freshForDay`), never on the rolling 2 h backoff.
public enum HeadacheSignsNotifications {

    /// Membership, as its own set rather than a case added to `TempFeverNotifications`. That
    /// separation is load-bearing: the temp family's set also drives the per-NIGHT ledger filter and
    /// the disclaimer branch, and widening it by accident would put this notification on the wrong
    /// ledger convention.
    public static let notificationSet: Set<HealthNotification> = [.headacheSigns]

    /// The `UNNotificationCategory` identifier, so the registration site (`AppDelegate`) and the
    /// posting site (`HealthNotificationCenter.post`) read ONE constant. The category carries no
    /// actions — deliberately; see the type comment above.
    public static let categoryIdentifier = "headache.signs"

    // MARK: Delivery window

    /// Hard never-fire window, in minutes since local midnight, enforced INDEPENDENTLY of the user's
    /// quiet-hours toggle. 🔴 PROVISIONAL.
    ///
    /// Quiet hours ship DISABLED (`HealthAlertDefaults` registers `quietEnabled: false`, and
    /// `QuietHours.init` defaults `enabled: false`), so on a default install the shared DND gate
    /// protects nothing overnight. Every other family in this file is an ACUTE reading the user
    /// asked to hear about the moment it happens; this one is a summary of a night that is already
    /// over. Holding it until morning costs nothing, while a 04:00 buzz costs sleep — which is one
    /// of the very inputs being measured. A verdict computed before the window simply waits: the
    /// day ledger is still fresh, so the next evaluate pass inside the window delivers it.
    public static let earliestMinutes = 7 * 60
    public static let latestMinutes = 21 * 60

    /// Whether `date`'s local time-of-day is inside the hard delivery window.
    public static func withinDeliveryWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m >= earliestMinutes && m < latestMinutes
    }

    // MARK: Per-DAY ledger

    /// Timezone-stable `yyyymmdd` key for a calendar day. Forwards to `TempFeverNotifications` so
    /// there is exactly ONE implementation of the day-key math in the codebase — an instant would
    /// shift under westward travel between two syncs of the same morning and re-fire the duplicate;
    /// calendar day components do not.
    public static func dayKey(for day: Date, calendar: Calendar = .current) -> Int {
        TempFeverNotifications.dayKey(for: day, calendar: calendar)
    }

    /// Per-DAY de-dupe. The verdict describes ONE night, so once a day has been notified it must not
    /// re-fire on any later sync that day.
    ///
    /// This must NOT be left to the shared 2 h anti-spam backoff. That is exactly the bug the #85
    /// temp flags hit and documented in `freshForNight` above: with a 2 h backoff the same morning's
    /// verdict re-appears after every sync, all day. The rule is identical to `freshForNight` —
    /// keep only candidates whose key is strictly newer than the one already notified — so it
    /// forwards rather than re-implementing it; the separate NAME exists so a reader at the call
    /// site sees "day", and the separate `notificationSet` keeps the temp family's night ledger and
    /// disclaimer branch from being widened by accident.
    public static func freshForDay(_ candidates: [HealthNotification], day: Int,
                                   lastNotifiedDay: [HealthNotification: Int]) -> [HealthNotification] {
        TempFeverNotifications.freshForNight(candidates, night: day, lastNotifiedNight: lastNotifiedDay)
    }

    // MARK: The decision

    /// Whether this morning's frozen verdict may be raised as a notification candidate NOW.
    ///
    /// UNLOCK — `frozenDayCount >= tuning.minDaysForBanding` (21). This is the NATURAL floor, not a
    /// proof gate: below it `HeadacheSignals.band` cannot produce a band at all, so there is
    /// literally nothing to report. It deliberately replaces the plan-of-record's
    /// "no alert until this user's own logged headaches show the detector beats chance", which for a
    /// typical episodic user is ~10 months (§1.1) — an unshippable wait for a notification that only
    /// ever claims to have measured something. Those per-user statistics are still computed; they
    /// now drive `retired` below (fire, measure, and switch it OFF for users it demonstrably does
    /// not help) instead of gating the first fire. Same statistics, inverted polarity.
    ///
    /// `frozenDayCount` must be counted over the SAME trailing `bandWindowDays` window the band was
    /// taken against — a lifetime count would unlock a user who has 21 rows spread over two years
    /// and whose percentile budget is therefore built on almost nothing.
    ///
    /// `band` is the FROZEN band of record, never a live recompute: re-deriving it at notify time
    /// would let the alert disagree with the card the user opens two seconds later.
    ///
    /// `suppressedBy` withholds only the NOTIFICATION — the score is still computed, stored and
    /// shown (`HeadacheSignals.assess` gates 5/6). Fever wins because HRV↓ + RHR↑ + temp↑ IS the
    /// fever signature and the existing fever alert is the more actionable one; "already logged one
    /// today" wins because telling someone their morning was unusual while they are already in it
    /// is noise.
    public static func candidates(enabled: Bool,
                                  band: HeadacheSignals.Band?,
                                  suppressedBy: HeadacheSignals.Suppression?,
                                  frozenDayCount: Int,
                                  retired: Bool,
                                  now: Date,
                                  lastNotifiedDay: [HealthNotification: Int],
                                  tuning: HeadacheSignals.Tuning = HeadacheSignals.Tuning(),
                                  calendar: Calendar = .current) -> [HealthNotification] {
        guard enabled,
              // The auto-retire QUALITY MONITOR has switched this off for this user, because their
              // own logged headaches show the flag is not helping them. A retired user keeps the
              // card and the log; they just stop being interrupted.
              !retired,
              band == .flagged,
              suppressedBy == nil,
              frozenDayCount >= tuning.minDaysForBanding,
              withinDeliveryWindow(now, calendar: calendar)
        else { return [] }
        return freshForDay([.headacheSigns], day: dayKey(for: now, calendar: calendar),
                           lastNotifiedDay: lastNotifiedDay)
    }

    // MARK: Copy

    /// Plain words for one feature, for the "what drifted" sentence. Lower-case; the copy builder
    /// capitalises the first one.
    ///
    /// These name the OBSERVABLE, not the analytic term. "Arousal let-down" and "schedule shift" are
    /// our vocabulary, not the user's, and a notification is the worst place to teach it.
    public static func plainName(_ feature: HeadacheSignals.Feature) -> String {
        switch feature {
        case .sleepEfficiencyDrop:    return "sleep efficiency"
        case .arousalLetdown:         return "daytime heart rate"
        case .hrvDeviation:           return "heart rate variability"
        case .restingHRDeviation:     return "resting heart rate"
        case .sleepFragmentation:     return "time awake in bed"
        case .sleepDurationDeviation: return "sleep duration"
        case .scheduleShift:          return "bedtime"
        case .skinTempDeviation:      return "skin temperature"
        case .perimenstrual:          return "cycle phase"
        }
    }

    /// The RING-DERIVED features that drifted furthest, largest first, at most `limit`.
    ///
    /// `weighted` maps a feature to its WEIGHTED contribution (effective weight × ramp position) —
    /// the share of the index that feature actually supplied. Ranking on the ramp alone would let a
    /// 0.08-weight feature outrank a 0.18-weight one that moved the number more.
    ///
    /// `perimenstrual` is EXCLUDED even though it can carry weight: it is a calendar lookup, and it
    /// did not "drift from your usual range" — saying so would misdescribe a date as a measurement.
    /// Ties break by `Feature.allCases` declaration order, so the same morning always words itself
    /// the same way.
    public static func topSignals(_ weighted: [HeadacheSignals.Feature: Double],
                                  limit: Int = 2) -> [HeadacheSignals.Feature] {
        let order = Dictionary(uniqueKeysWithValues:
            HeadacheSignals.Feature.allCases.enumerated().map { ($0.element, $0.offset) })
        return weighted
            .filter { $0.key.isRingDerived && $0.value > 0 }
            .sorted {
                $0.value == $1.value ? (order[$0.key] ?? 0) < (order[$1.key] ?? 0) : $0.value > $1.value
            }
            .prefix(max(0, limit))
            .map(\.key)
    }

    /// The period a named feature was actually MEASURED over, as a trailing phrase.
    ///
    /// Eight of the nine features are nightly; `arousalLetdown` is the exception, and the whole
    /// reason this exists. It compares yesterday's WAKING heart rate with the day before's
    /// (`HeadacheSignals.assess`, the let-down term), so the blanket "last night" this copy used to
    /// append to whatever it named asserted a measurement of a night that term never looks at. The
    /// one sentence this entire design rests on being LITERALLY TRUE cannot carry a timeframe that
    /// is sometimes wrong. The app-side `HeadacheSignalCopy.unreadClause` solved the same problem
    /// for the missing-input sentence; this mirrors its approach.
    /// The one phrase that means "overnight". Extracted so the TITLE can ask whether every named
    /// signal is nightly without re-encoding the answer — a second copy of the string is how the
    /// title and the body drift apart, which is the exact defect this pair of functions exists to
    /// prevent.
    static let nightlyPhrase = "last night"

    public static func timeframe(_ feature: HeadacheSignals.Feature) -> String {
        feature == .arousalLetdown ? "over the past two days" : nightlyPhrase
    }

    /// The notification copy. A MEASUREMENT, never a forecast — see the type comment.
    ///
    /// The timeframe FOLLOWS the signals that were named rather than being a constant suffix. Two
    /// signals measured over the same period share one trailing phrase — the common all-nightly
    /// case, which keeps the compact sentence it always had; only a mixed pair pays the extra words
    /// to spell both out. A notification body that wraps to four lines is its own failure.
    ///
    /// Pinned by `HealthAlertsHeadacheTests.testCopyIsAMeasurementNeverAForecast`: no "headache",
    /// no percentage, no probability, no "risk"/"warning"/"likely"/"predict"/"will"; and by
    /// `testTheTimeframeFollowsTheNamedSignals` for the daytime term.
    public static func copy(topSignals: [HeadacheSignals.Feature]) -> (title: String, body: String) {
        let drifted = " drifted furthest from your usual range"
        let subject: String
        switch topSignals.count {
        case 0:
            // The frozen row carried no legible per-feature detail (an older row, or a decode
            // miss). Still true, still a measurement — just less specific. Naming a feature we
            // cannot actually evidence would be the one thing worse than being vague. Nothing
            // daytime can be named here, so the nightly phrase is the correct one.
            subject = "Several of your overnight signals" + drifted + " last night"
        case 1:
            subject = sentenceCased(plainName(topSignals[0])) + drifted
                + " " + timeframe(topSignals[0])
        default:
            let (first, second) = (topSignals[0], topSignals[1])
            subject = timeframe(first) == timeframe(second)
                ? sentenceCased(plainName(first)) + " and " + plainName(second)
                    + drifted + " " + timeframe(first)
                : sentenceCased(plainName(first)) + " " + timeframe(first)
                    + " and " + plainName(second) + " " + timeframe(second) + drifted
        }
        // The TITLE has to follow the signals too, for the same reason the body does. When the only
        // named driver is the daytime let-down term (a D−2 → D−1 comparison), "last night" asserts a
        // timeframe nothing was measured over — the title would contradict the body directly beneath
        // it. Reachable, if uncommon: gate 4 requires a nightly anchor to be PRESENT, not to
        // CONTRIBUTE, so a day can score entirely on the daytime term.
        let allDaytime = !topSignals.isEmpty && topSignals.allSatisfy { timeframe($0) != nightlyPhrase }
        let title = allDaytime ? "Your recent signals stood out" : "Last night was unusual for you"
        return (title,
                subject + " (estimate). That is what we measured — it is not a forecast.")
    }

    private static func sentenceCased(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}
