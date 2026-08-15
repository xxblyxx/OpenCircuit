// WASO (Wake After Sleep Onset) + awakening-count metrics — option C of
// docs/SLEEP_AWAKE_RESOLUTION.md. See docs/SLEEP_AWAKENING_METRICS.md for the plan of record this
// implements; read it before changing this file.
//
// WHY THIS EXISTS: `SleepStaging.Summary.awake` is a single scalar pooling pre-sleep awake-in-bed,
// post-wake lie-in, and mid-night awakenings into one number — so "awake: 30 min" cannot
// distinguish a quiet 30-minute morning lie-in from six five-minute wakeups. This is a pure,
// DERIVED split of that scalar into edge vs interior awake, with the interior further broken into
// discrete awakenings. No classifier constant changes here, and nothing is stored — everything is
// computed from a night's already-staged `[SleepSegment]` on read (SLEEP_AWAKENING_METRICS.md §2.1).

import Foundation

public struct SleepAwakenings: Equatable, Sendable {
    /// Number of distinct interior awakenings (between sleep onset and final wake).
    public let count: Int
    /// Total time awake between onset and final wake — Wake After Sleep Onset.
    public let waso: TimeInterval
    /// Duration of the longest single interior awakening. `0` when `count == 0`.
    public let longest: TimeInterval
    /// Awake time OUTSIDE [onset, finalWake] — pre-sleep wind-down + post-wake lie-in.
    public let edgeAwake: TimeInterval
    /// The merged interior awake runs, in chronological order. Kept (not just the count) so a
    /// future UI can mark them on the hypnogram, and so tests can assert on more than a count.
    public let intervals: [DateInterval]

    public init(count: Int, waso: TimeInterval, longest: TimeInterval,
               edgeAwake: TimeInterval, intervals: [DateInterval]) {
        self.count = count
        self.waso = waso
        self.longest = longest
        self.edgeAwake = edgeAwake
        self.intervals = intervals
    }

    /// Rounded-minute convenience for display, mirroring `SleepStaging.Summary.minutes`.
    public var minutes: (waso: Int, longest: Int, edgeAwake: Int) {
        func m(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
        return (m(waso), m(longest), m(edgeAwake))
    }

    /// The zero value: a night with no interior awakenings and no edge awake. Distinct from "no
    /// asleep segments at all", which is ALSO this value (§3's "nil/empty behaviour" — no onset
    /// means no interior to speak of, never a phantom whole-night awakening).
    public static let zero = SleepAwakenings(count: 0, waso: 0, longest: 0, edgeAwake: 0, intervals: [])
}

public extension SleepAwakenings {
    /// Two interior awake runs merge into one awakening when the gap between them is at most this
    /// tolerance. One epoch (`BulkRecord.epochSeconds` = 150 s) of slack absorbs the segment
    /// boundaries `applyBedtimeWiden`'s append + re-sort, and multi-fragment concatenation, can
    /// produce — without bridging a REAL inter-fragment data gap, which is always much larger
    /// (`ActivityPeriod.gravityMaxGap`, minutes not seconds). See SLEEP_AWAKENING_METRICS.md §4.2.
    static let mergeTolerance: TimeInterval = 150

    /// Derive from a night's full staged segment list (as stored/rendered — `.inBed` included).
    /// Zeroed when the night has no asleep segments (no onset/final-wake window exists).
    static func from(segments: [SleepSegment]) -> SleepAwakenings {
        // .inBed tiles the whole in-bed window underneath every other segment and would
        // double-count anything that doesn't filter it (SLEEP_AWAKENING_METRICS.md §4.3).
        let staged = segments.filter { $0.stage != .inBed }
        guard let window = SleepStaging.sleepWindow(staged) else { return .zero }
        let onset = window.onset, finalWake = window.wake

        let awakeSegments = staged.filter { $0.stage == .awake }
        let totalAwake = awakeSegments.reduce(0) { $0 + $1.duration }

        // Clip every awake segment to [onset, finalWake] — usually a no-op by construction, but
        // `applyBedtimeWiden`/multi-fragment stitching can leave a straddling segment whose
        // interior portion must count toward WASO and whose edge portion must not (§4.4).
        let interiorRaw: [DateInterval] = awakeSegments.compactMap { seg in
            let start = max(seg.start, onset)
            let end = min(seg.end, finalWake)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }.sorted { $0.start < $1.start }

        // Merge runs touching within `mergeTolerance` (§4.1/§4.2) — NOT a blanket bridge, so a
        // real inter-fragment gap (always far larger than one epoch) still splits the run.
        var merged: [DateInterval] = []
        for interval in interiorRaw {
            if let last = merged.last, interval.start <= last.end + mergeTolerance {
                let newEnd = max(last.end, interval.end)
                merged[merged.count - 1] = DateInterval(start: last.start, end: newEnd)
            } else {
                merged.append(interval)
            }
        }

        let waso = merged.reduce(0) { $0 + $1.duration }
        let longest = merged.map(\.duration).max() ?? 0
        let edgeAwake = totalAwake - waso

        return SleepAwakenings(count: merged.count, waso: waso, longest: longest,
                               edgeAwake: edgeAwake, intervals: merged)
    }
}
