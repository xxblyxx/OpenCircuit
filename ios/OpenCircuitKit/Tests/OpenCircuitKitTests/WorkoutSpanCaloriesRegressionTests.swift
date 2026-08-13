import XCTest
@testable import OpenCircuitKit

/// Replays the reported incident end-to-end through the REAL `Calories.dailyEstimate` path: a
/// workout recorded with the buggy 2 s stamp reads roughly 1/5 of its true active-kcal on the
/// Activity card; the same readings corrected via `HRSampleSpan.heldForward` reconcile to the
/// workout summary's own number. Verified against real device data on 2026-08-12: a 38.5-min
/// ride recorded 290 kcal via `writeWorkout`/HealthKit but only 58 kcal reached the card.
final class WorkoutSpanCaloriesRegressionTests: XCTestCase {

    private let profile = UserProfile(age: 51, weightKg: 63.5, heightCm: 157.5, sex: .male)
    private let dayStart = Date(timeIntervalSince1970: 1_753_660_800)   // a local midnight

    /// A ride shaped like the real incident: 231 readings at true ~10 s cadence over 2310 s
    /// (38.5 min) at 140 bpm — comfortably above the ~84 bpm elevated-HR threshold for this
    /// profile, so every second of the ride is "elevated" and the threshold plays no part here.
    private func ride(bpm: Int = 140, stampedSpan: TimeInterval) -> [HRSample] {
        let start = dayStart.addingTimeInterval(15 * 3600)   // 15:00
        return stride(from: 0.0, to: 2310, by: 10).map { offset in
            HRSample(bpm: bpm, start: start.addingTimeInterval(offset),
                     end: start.addingTimeInterval(offset + stampedSpan))
        }
    }

    private var rideStart: Date { dayStart.addingTimeInterval(15 * 3600) }
    private var rideEnd: Date { rideStart.addingTimeInterval(2310) }

    /// THE regression, reproduced: today's buggy 2 s stamp reads far short of the ride's true
    /// active-kcal — the Activity card undercounts by roughly the ratio of the stamped span to
    /// the true cadence (2 s / 10 s = 20%).
    func testBuggyStampedSpanUndercountsByRoughlyTheStampToCadenceRatio() {
        let buggy = ride(stampedSpan: 2)
        let est = Calories.dailyEstimate(hrSamples: buggy, steps: 0, profile: profile,
                                         stepWindows: [], dayStart: dayStart)
        let trueKcal = Calories.workoutActiveKcal(avgHR: 140, durationSeconds: 2310, profile: profile)

        // ~20% of true value, not the full amount — this is the reported bug.
        XCTAssertLessThan(est.activeKcal, trueKcal * 0.3)
        XCTAssertGreaterThan(est.activeKcal, trueKcal * 0.1)
    }

    /// The fix: readings corrected via `HRSampleSpan.heldForward` before ever reaching the store
    /// reconcile to (within a couple percent of) the workout summary's own whole-duration figure.
    /// Keytel is linear in HR and duration, and held-forward pieces tile the ride's true elapsed
    /// time exactly (constant bpm, no dropouts), so this is a near-exact reconciliation.
    func testHeldForwardSpanReconcilesToTheWorkoutSummaryFigure() {
        let raw = ride(stampedSpan: 2)   // what collectHRSnapshot actually stamps
        let corrected = HRSampleSpan.heldForward(raw, sessionEnd: rideEnd)

        let est = Calories.dailyEstimate(hrSamples: corrected, steps: 0, profile: profile,
                                         stepWindows: [], dayStart: dayStart)
        let trueKcal = Calories.workoutActiveKcal(avgHR: 140, durationSeconds: 2310, profile: profile)

        XCTAssertEqual(est.activeKcal, trueKcal, accuracy: trueKcal * 0.02)
        XCTAssertEqual(est.elevatedMinutes, 2310.0 / 60.0, accuracy: 0.5)
    }

    /// Sanity: the buggy path's elevated minutes are also ~20% of the true ride duration — not
    /// just the kcal. Confirms the undercount is a TIME-ACCOUNTING bug, not a pricing bug.
    func testBuggyStampedSpanAlsoUndercountsElevatedMinutes() {
        let buggy = ride(stampedSpan: 2)
        let est = Calories.dailyEstimate(hrSamples: buggy, steps: 0, profile: profile,
                                         stepWindows: [], dayStart: dayStart)
        let trueMinutes = 2310.0 / 60.0
        XCTAssertLessThan(est.elevatedMinutes, trueMinutes * 0.3)
    }
}
