// Pure comparison logic behind "Audit Apple Health sleep" (DeviceInfoView) and
// `desktop/sleep_reference_labels.py --audit-own`: given what we BELIEVE we staged (the stored
// hypnogram) and what Apple Health actually HOLDS for our own bundle id (`OwnSleepSample`), report
// whether they agree. No HealthKit types here on purpose — this is the part of the audit that is
// unit-testable without a device (docs/PENDING_VALIDATION.md → `sleep-health-mirror-idempotent`).
//
// This is deliberately NOT the mirror's own post-delete verification (`HealthKitWriter.
// mirrorSettledNight`, which only needs a same-window COUNT) — this is the full diagnostic used to
// decide whether the ratchet fix worked and whether a rebuild is needed, so it also reports
// per-stage minute totals and same-stage overlaps, the two things a duplicate copy actually breaks.

import Foundation

public enum SleepHealthAudit {
    /// One night's comparison. `.inBed` segments are EXCLUDED from `overlappingPairs` and the
    /// per-stage totals on both sides — an `.inBed` envelope is expected to overlap every staged
    /// segment by design (`SleepStaging.swift`'s efficiency comment), so counting it here would
    /// misreport a healthy night as broken.
    public struct NightResult: Equatable, Sendable {
        public let night: Date
        public let healthSampleCount: Int
        public let storedSegmentCount: Int
        /// Minutes per stage as Health holds them vs. as the stored hypnogram has them. Equal on a
        /// clean night; Health's total running noticeably ABOVE stored is the signature of
        /// duplicate/stale copies.
        public let healthMinutesByStage: [SleepStage: Double]
        public let storedMinutesByStage: [SleepStage: Double]
        /// Count of (Health-sample) pairs of the SAME stage whose intervals overlap at all. Zero on
        /// a clean night — a hypnogram partitions time, so two genuine same-stage samples never
        /// overlap; > 0 means Health holds more than one write's worth of the night.
        public let overlappingPairs: Int
        /// Distinct `appVersion` values seen among Health's own samples for this night, so a caller
        /// can tell "old build, already fixed" apart from "current build, still happening".
        public let appVersions: [String]

        public var isClean: Bool {
            healthSampleCount == storedSegmentCount && overlappingPairs == 0
        }

        public init(night: Date, healthSampleCount: Int, storedSegmentCount: Int,
                    healthMinutesByStage: [SleepStage: Double],
                    storedMinutesByStage: [SleepStage: Double],
                    overlappingPairs: Int, appVersions: [String]) {
            self.night = night
            self.healthSampleCount = healthSampleCount
            self.storedSegmentCount = storedSegmentCount
            self.healthMinutesByStage = healthMinutesByStage
            self.storedMinutesByStage = storedMinutesByStage
            self.overlappingPairs = overlappingPairs
            self.appVersions = appVersions
        }
    }

    /// Compare one night. `health` and `stored` are both expected to include `.inBed`, matching
    /// `HealthKitWriter.write(sleep:)`'s input and `LocalStore.hypnogram(night:)`'s output — the
    /// `.inBed` exclusion happens inside this function, not at the call site.
    public static func compare(night: Date, health: [OwnSleepSample],
                               stored: [SleepSegment]) -> NightResult {
        let healthStaged = health.filter { $0.stage != .inBed }
        let storedStaged = stored.filter { $0.stage != .inBed }
        return NightResult(
            night: night,
            healthSampleCount: health.count,
            storedSegmentCount: stored.count,
            healthMinutesByStage: minutesByStage(healthStaged.map { ($0.start, $0.end, $0.stage) }),
            storedMinutesByStage: minutesByStage(storedStaged.map { ($0.start, $0.end, $0.stage) }),
            overlappingPairs: overlappingSameStagePairs(healthStaged.map { ($0.start, $0.end, $0.stage) }),
            appVersions: Array(Set(health.map(\.appVersion))).sorted())
    }

    private static func minutesByStage(_ intervals: [(Date, Date, SleepStage)]) -> [SleepStage: Double] {
        var out: [SleepStage: Double] = [:]
        for (start, end, stage) in intervals where end > start {
            out[stage, default: 0] += end.timeIntervalSince(start) / 60
        }
        return out
    }

    /// O(n log n): sort by stage then start, and within each stage sweep for overlaps against a
    /// running "furthest end seen so far" — correct because within one stage, an overlap always
    /// involves consecutive-by-start entries once sorted (if `i` overlaps `k` but not the entries
    /// between, the between entries already extended the running max past `i`'s end).
    private static func overlappingSameStagePairs(_ intervals: [(Date, Date, SleepStage)]) -> Int {
        let byStage = Dictionary(grouping: intervals.filter { $0.1 > $0.0 }, by: { $0.2 })
        var pairs = 0
        for (_, group) in byStage {
            let sorted = group.sorted { $0.0 < $1.0 }
            var runningEnd: Date?
            for (start, end, _) in sorted {
                if let runningEnd, start < runningEnd { pairs += 1 }
                runningEnd = max(runningEnd ?? end, end)
            }
        }
        return pairs
    }
}
