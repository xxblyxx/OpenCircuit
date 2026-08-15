// Drag-to-scrub math for the Sleep Stages hypnogram (#186): map a touch position to a moment in
// the night, find the real sample nearest that moment, and say which stage covers it.
//
// Pure value-type math over Foundation `Date`s — no SwiftUI, no SwiftData — so it unit-tests on
// macOS same as `OvernightAverages`/`SleepStageBreakdown`. Never fabricates a reading: a touch
// that lands in a genuine gap reports "no sample here" rather than an interpolated number.

import Foundation

public enum SleepScrub {

    /// `d`'s position on `start…end` as a fraction, 0 at `start`, 1 at `end`. Deliberately NOT
    /// clamped — the movement strip filters the result to 0...1 itself to drop epochs outside its
    /// own window, so clamping here would silently break that filter. nil when the domain is
    /// degenerate (`end <= start`), the chart's only division-by-zero risk.
    public static func fraction(of d: Date, start: Date, end: Date) -> Double? {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        return d.timeIntervalSince(start) / span
    }

    /// Inverse of `fraction`. The fraction IS clamped to 0...1, so a finger dragged past either
    /// edge of the chart reads as the first or last instant of the night rather than a time
    /// outside it.
    public static func date(atFraction f: Double, start: Date, end: Date) -> Date {
        let span = end.timeIntervalSince(start)
        let clamped = min(max(f, 0), 1)
        return start.addingTimeInterval(span * clamped)
    }

    /// Ring bulk-sample epochs are 150s (`BulkRecord.epochSeconds`). 300s tolerates one dropped
    /// epoch on either side while still going blank across a real multi-minute gap.
    public static let matchWindow: TimeInterval = 300

    /// Index of the sample in `times` nearest `t`, or nil when `times` is empty or the nearest
    /// entry is farther than `maxDistance` — a real gap, where showing the closest sample would
    /// mislabel it as "now". On an exact tie, the earlier index wins (stable, deterministic).
    public static func nearestIndex(in times: [Date], to t: Date,
                                    maxDistance: TimeInterval = matchWindow) -> Int? {
        var bestIndex: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, time) in times.enumerated() {
            let d = abs(time.timeIntervalSince(t))
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }
        guard let bestIndex, bestDistance <= maxDistance else { return nil }
        return bestIndex
    }

    /// The stage covering instant `t`. A real (non-`.inBed`) segment always wins; `.inBed` is
    /// reported only when no staged segment covers `t` (it's the whole-night envelope, not a
    /// stage in its own right — see `SleepStagesSection.segments` doc). nil in a genuine gap
    /// between segments.
    ///
    /// Intervals are half-open (`start <= t < end`) so a boundary instant belongs to the
    /// *incoming* segment and two adjacent segments can't both claim it; `t == end` is accepted
    /// only on the segment that ends exactly at `t` so the very last instant of the night still
    /// resolves. Stitched nights can carry overlapping segments — the later-starting (more
    /// specific) one wins.
    public static func stage(at t: Date, in segments: [SleepSegment]) -> SleepStage? {
        var sawEnvelope = false
        var best: SleepSegment?
        for s in segments where s.start <= t && (t < s.end || t == s.end) {
            if s.stage == .inBed {
                sawEnvelope = true
                continue
            }
            if best == nil || s.start > best!.start {
                best = s
            }
        }
        if let best { return best.stage }
        return sawEnvelope ? .inBed : nil
    }
}

/// The night's overnight vitals on one shared timeline, for the hypnogram's Sleep HR overlay and
/// its scrub read-out. Replaces a bare `[(Date, Double)]` — the read-out needs three series and a
/// tuple array can't say which is which. `spo2` stays 0...1 exactly as HealthKit/`recentVitals`
/// store it; the view multiplies by 100 for display (see `SleepCardView` SpO₂ formatting).
///
/// Deliberately its own type rather than reusing `OvernightAverages.Point`: that type is the
/// mean-calculator's input shape, and coupling the chart to it would make either one harder to
/// change independently.
public struct SleepVitalsSeries: Equatable, Sendable {

    public struct Sample: Equatable, Sendable {
        public let time: Date
        public let value: Double
        public init(time: Date, value: Double) {
            self.time = time
            self.value = value
        }
    }

    /// Oldest→newest.
    public let hr: [Sample]
    public let hrv: [Sample]
    public let spo2: [Sample]

    public init(hr: [Sample], hrv: [Sample], spo2: [Sample]) {
        self.hr = hr
        self.hrv = hrv
        self.spo2 = spo2
    }

    public static let empty = SleepVitalsSeries(hr: [], hrv: [], spo2: [])

    /// The value in `series` within `SleepScrub.matchWindow` of `t`, or nil — used to decide
    /// whether the HRV/SpO₂ rows of the scrub callout appear at all.
    public func value(in series: [Sample], near t: Date) -> Double? {
        guard let i = SleepScrub.nearestIndex(in: series.map(\.time), to: t) else { return nil }
        return series[i].value
    }

    /// All three series narrowed to `start...end`. HR is windowed on the night's in-bed span
    /// today (`SleepCardView.vitals(_:)`), which can differ from the hypnogram's segment-derived
    /// domain on a live-staged night — scrubbing must snap only to samples that actually have an
    /// on-screen position, so callers filter through this before snapping or drawing.
    public func clamped(to start: Date, end: Date) -> SleepVitalsSeries {
        func filter(_ series: [Sample]) -> [Sample] {
            series.filter { $0.time >= start && $0.time <= end }
        }
        return SleepVitalsSeries(hr: filter(hr), hrv: filter(hrv), spo2: filter(spo2))
    }
}
