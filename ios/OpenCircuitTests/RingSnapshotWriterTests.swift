import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// `RingSnapshotWriter.compose(_:)` is the pure half of the writer (see the file header for why
/// it's split from `refresh`) — no SwiftData, no App Group, no ring, so it's exercised directly
/// with hand-built `Inputs`. This is the regression lock for the widget's most safety-relevant
/// rule: a night that didn't end TODAY must never be shown as last night's, on ANY face —
/// including the `accessoryCircular` Lock Screen gauge, which gates on exactly this flag instead
/// of the sync-freshness clock (docs/WIDGETS_HOME_SCREEN.md §5).
final class RingSnapshotWriterTests: XCTestCase {
    // A Tuesday well clear of midnight, so "same calendar day" arithmetic below isn't fighting a
    // day boundary.
    private let now = Date(timeIntervalSince1970: 1_750_000_000 + 12 * 3_600)

    private let profile = UserProfile(age: 35, weightKg: 70, heightCm: 170, sex: .male)

    private func baseInputs(sleep: RingSnapshotWriter.Inputs.SleepRow?,
                            stages: [SleepSegment] = []) -> RingSnapshotWriter.Inputs {
        RingSnapshotWriter.Inputs(
            now: now, staleAfter: 6 * 3_600,
            steps: 6_412, stepsGoal: 8_000,
            activeKcalGoal: 300, activityMinutesGoal: 30,
            hrSamples: [], stepWindows: [],
            profile: profile,
            sleep: sleep, stages: stages,
            liveBattery: nil,
            previousBattery: .init(percent: nil, charging: false, asOf: nil))
    }

    // MARK: sleepIsLastNight gating

    func testNightThatEndedTodayIsCreditedAsLastNight() {
        let sleep = RingSnapshotWriter.Inputs.SleepRow(
            night: Calendar.current.startOfDay(for: now),
            inBedStart: now.addingTimeInterval(-8 * 3_600),
            inBedEnd: now.addingTimeInterval(-30 * 60),   // ended earlier today
            sleepScore: 82, stressScore: 28, asleepMin: 434)
        let snapshot = RingSnapshotWriter.compose(baseInputs(sleep: sleep))

        XCTAssertTrue(snapshot.sleepIsLastNight)
        XCTAssertEqual(snapshot.sleepScore, 82)
        XCTAssertEqual(snapshot.sleepBand, "good")
        XCTAssertEqual(snapshot.stressScore, 28)
        XCTAssertEqual(snapshot.stressBand, "relaxed")
        XCTAssertEqual(snapshot.asleepMinutes, 434)
        XCTAssertNotNil(snapshot.inBedStart)
        XCTAssertNotNil(snapshot.inBedEnd)
    }

    /// The regression this locks: a days-old night must not be shown as if it were last night's,
    /// on ANY field — not the score, not the times, not the stage bar. This is what keeps the
    /// `accessoryCircular` face honest when it renders `sleepIsLastNight` straight from the
    /// snapshot with no date logic of its own.
    func testStaleNightYieldsNilSleepFieldsNotAStaleNumber() {
        let sleep = RingSnapshotWriter.Inputs.SleepRow(
            night: Calendar.current.startOfDay(for: now.addingTimeInterval(-2 * 86_400)),
            inBedStart: now.addingTimeInterval(-2 * 86_400 - 8 * 3_600),
            inBedEnd: now.addingTimeInterval(-2 * 86_400),   // two days ago
            sleepScore: 82, stressScore: 28, asleepMin: 434)
        let stages = [SleepSegment(start: now.addingTimeInterval(-2 * 86_400 - 3_600),
                                   end: now.addingTimeInterval(-2 * 86_400), stage: .asleepDeep)]
        let snapshot = RingSnapshotWriter.compose(baseInputs(sleep: sleep, stages: stages))

        XCTAssertFalse(snapshot.sleepIsLastNight)
        XCTAssertNil(snapshot.sleepScore)
        XCTAssertNil(snapshot.sleepBand)
        XCTAssertNil(snapshot.stressScore)
        XCTAssertNil(snapshot.stressBand)
        XCTAssertNil(snapshot.asleepMinutes)
        XCTAssertNil(snapshot.inBedStart)
        XCTAssertNil(snapshot.inBedEnd)
        XCTAssertEqual(snapshot.stages, [], "a stale night's hypnogram must not draw on the large face either")
    }

    func testNoSleepSummaryAtAllIsNotLastNight() {
        let snapshot = RingSnapshotWriter.compose(baseInputs(sleep: nil))
        XCTAssertFalse(snapshot.sleepIsLastNight)
        XCTAssertNil(snapshot.sleepScore)
    }

    /// `0` is StoredSleepSummary's "not computed" sentinel, not a real score — a night that ended
    /// today but never got scored must show "—", not a fabricated zero.
    func testUncomputedZeroScoreOnALastNightRendersNilNotZero() {
        let sleep = RingSnapshotWriter.Inputs.SleepRow(
            night: Calendar.current.startOfDay(for: now),
            inBedStart: now.addingTimeInterval(-8 * 3_600),
            inBedEnd: now.addingTimeInterval(-30 * 60),
            sleepScore: 0, stressScore: 0, asleepMin: 434)
        let snapshot = RingSnapshotWriter.compose(baseInputs(sleep: sleep))
        XCTAssertTrue(snapshot.sleepIsLastNight)
        XCTAssertNil(snapshot.sleepScore)
        XCTAssertNil(snapshot.sleepBand)
        XCTAssertNil(snapshot.stressScore)
        XCTAssertEqual(snapshot.asleepMinutes, 434, "a genuinely-zero sentinel only applies to the SCORES")
    }

    // MARK: Battery carry-forward (battery is in-memory only on the app side)

    func testNoLiveSessionCarriesPreviousBatteryForward() {
        var inputs = baseInputs(sleep: nil)
        inputs.previousBattery = .init(percent: 61, charging: true, asOf: now.addingTimeInterval(-1_800))
        let snapshot = RingSnapshotWriter.compose(inputs)
        XCTAssertEqual(snapshot.batteryPercent, 61)
        XCTAssertTrue(snapshot.batteryCharging)
        XCTAssertEqual(snapshot.batteryAsOf, now.addingTimeInterval(-1_800),
                       "carried-forward battery keeps ITS OWN timestamp, not `now`")
    }

    func testLiveSessionBatteryOverridesPreviousAndStampsNow() {
        var inputs = baseInputs(sleep: nil)
        inputs.previousBattery = .init(percent: 61, charging: true, asOf: now.addingTimeInterval(-1_800))
        inputs.liveBattery = .init(percent: 74, charging: false, tteSamples: [], chargeSamples: [])
        let snapshot = RingSnapshotWriter.compose(inputs)
        XCTAssertEqual(snapshot.batteryPercent, 74)
        XCTAssertFalse(snapshot.batteryCharging)
        XCTAssertEqual(snapshot.batteryAsOf, now)
    }

    // MARK: Stage coalescing

    func testCoalesceMergesAdjacentSameStageSegments() {
        let a = SleepSegment(start: now, end: now.addingTimeInterval(150), stage: .asleepDeep)
        let b = SleepSegment(start: now.addingTimeInterval(150), end: now.addingTimeInterval(300), stage: .asleepDeep)
        let c = SleepSegment(start: now.addingTimeInterval(300), end: now.addingTimeInterval(450), stage: .asleepREM)
        let merged = RingSnapshotWriter.coalesce([a, b, c])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, now)
        XCTAssertEqual(merged[0].end, now.addingTimeInterval(300))
        XCTAssertEqual(merged[0].stage, .asleepDeep)
        XCTAssertEqual(merged[1].stage, .asleepREM)
    }

    func testCoalesceDoesNotMergeAcrossAGap() {
        let a = SleepSegment(start: now, end: now.addingTimeInterval(150), stage: .asleepDeep)
        // A gap (not contiguous) between a.end and b.start — must stay two segments even though
        // the stage matches, since they aren't actually adjacent.
        let b = SleepSegment(start: now.addingTimeInterval(200), end: now.addingTimeInterval(350), stage: .asleepDeep)
        XCTAssertEqual(RingSnapshotWriter.coalesce([a, b]).count, 2)
    }
}
