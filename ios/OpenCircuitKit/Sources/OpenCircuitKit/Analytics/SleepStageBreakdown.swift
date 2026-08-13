// Sleep-stage percentage breakdown + presentation helpers for the "Sleep Stages" chart (#70
// clone). Pure over `SleepStaging.Summary.minutes` — no SwiftUI, no storage — so it is testable
// the same way as `SleepDetailMetrics`.

import Foundation

public enum SleepStageBreakdown {

    /// One stage's share of the night, in the RingConn screenshot's own order (Awake, REM,
    /// Light, Deep).
    public struct StageShare: Equatable, Sendable {
        public let stage: SleepStage
        public let minutes: Int
        /// Share of `awake + rem + light + deep` — NOT of `inBed` (which is gap-excluded and can
        /// disagree with the summed stage minutes on a stitched multi-fragment night).
        public let fraction: Double
        public init(stage: SleepStage, minutes: Int, fraction: Double) {
            self.stage = stage; self.minutes = minutes; self.fraction = fraction
        }
    }

    /// Breaks a night's stage minutes into Awake/REM/Light/Deep shares. `fraction` is 0 for every
    /// stage when the night has no staged time at all (never divides by zero).
    public static func breakdown(
        _ m: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)
    ) -> [StageShare] {
        let denom = Double(m.awake + m.rem + m.light + m.deep)
        func share(_ stage: SleepStage, _ minutes: Int) -> StageShare {
            StageShare(stage: stage, minutes: minutes, fraction: denom > 0 ? Double(minutes) / denom : 0)
        }
        return [
            share(.awake, m.awake),
            share(.asleepREM, m.rem),
            share(.asleepCore, m.light),
            share(.asleepDeep, m.deep),
        ]
    }

    /// "16min" / "2hr" / "3hr45min" — hours omitted under 60 min, minutes omitted when exactly on
    /// the hour, no space (matches the RingConn reference screenshot's formatting).
    public static func durationText(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)min" }
        if m == 0 { return "\(h)hr" }
        return "\(h)hr\(m)min"
    }

    /// 5 evenly-quartered clock labels spanning `[start, end]`, for the chart's time axis.
    /// Returns `[]` when `end <= start`.
    public static func axisLabels(start: Date, end: Date) -> [Date] {
        guard end > start else { return [] }
        let span = end.timeIntervalSince(start)
        return (0...4).map { start.addingTimeInterval(span * Double($0) / 4) }
    }

    /// Reference-range band for a stage's percent-of-night, drawn as the pair of tick marks
    /// bracketing each stat row. Population norms for adult sleep architecture (WASO ≤ ~10% of
    /// time-in-bed; REM 18–23%, N2/Light 50–58%, N3/Deep 13–19% of total sleep time), cross-checked
    /// against the tick positions measured on the RingConn Gen 2 reference screenshot. These are
    /// general population norms, NOT this wearer's personal baseline — same caveat
    /// docs/HEADACHE_SIGNALS.md §1 makes about unearned thresholds. `inBed` has no meaningful
    /// range here and returns nil.
    public static func referenceRange(for stage: SleepStage) -> ClosedRange<Double>? {
        switch stage {
        case .awake:      return 0...10
        case .asleepREM:  return 18...23
        case .asleepCore: return 50...58
        case .asleepDeep: return 13...19
        case .inBed:      return nil
        }
    }
}
