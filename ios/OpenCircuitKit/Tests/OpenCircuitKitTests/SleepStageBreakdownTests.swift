import XCTest
@testable import OpenCircuitKit

/// Pins the RingConn reference screenshot's own numbers (10:58 PM–7:06 AM,
/// Awake 16m / REM 120m / Light 225m / Deep 100m → 3.5% / 26.0% / 48.8% / 21.7%) so the clone
/// can't silently drift off the source it was built to match.
final class SleepStageBreakdownTests: XCTestCase {

    private let screenshotMinutes = (inBed: 461, awake: 16, light: 225, deep: 100, rem: 120, asleep: 445)

    func testBreakdownMatchesScreenshotPercentages() {
        let shares = SleepStageBreakdown.breakdown(screenshotMinutes)
        let byStage = Dictionary(uniqueKeysWithValues: shares.map { ($0.stage, $0) })

        XCTAssertEqual(byStage[.awake]?.minutes, 16)
        XCTAssertEqual((byStage[.awake]?.fraction ?? 0) * 100, 3.5, accuracy: 0.05)

        XCTAssertEqual(byStage[.asleepREM]?.minutes, 120)
        XCTAssertEqual((byStage[.asleepREM]?.fraction ?? 0) * 100, 26.0, accuracy: 0.05)

        XCTAssertEqual(byStage[.asleepCore]?.minutes, 225)
        XCTAssertEqual((byStage[.asleepCore]?.fraction ?? 0) * 100, 48.8, accuracy: 0.05)

        XCTAssertEqual(byStage[.asleepDeep]?.minutes, 100)
        XCTAssertEqual((byStage[.asleepDeep]?.fraction ?? 0) * 100, 21.7, accuracy: 0.05)
    }

    func testBreakdownOrderMatchesScreenshot() {
        let shares = SleepStageBreakdown.breakdown(screenshotMinutes)
        XCTAssertEqual(shares.map(\.stage), [.awake, .asleepREM, .asleepCore, .asleepDeep])
    }

    func testBreakdownAllZeroDoesNotDivideByZero() {
        let shares = SleepStageBreakdown.breakdown((inBed: 0, awake: 0, light: 0, deep: 0, rem: 0, asleep: 0))
        XCTAssertTrue(shares.allSatisfy { $0.fraction == 0 })
    }

    func testDurationText() {
        XCTAssertEqual(SleepStageBreakdown.durationText(minutes: 16), "16min")
        XCTAssertEqual(SleepStageBreakdown.durationText(minutes: 120), "2hr")
        XCTAssertEqual(SleepStageBreakdown.durationText(minutes: 225), "3hr45min")
        XCTAssertEqual(SleepStageBreakdown.durationText(minutes: 100), "1hr40min")
        XCTAssertEqual(SleepStageBreakdown.durationText(minutes: 0), "0min")
    }

    func testAxisLabelsAreEvenlyQuartered() {
        let epoch = 1_000_000
        let start = Date(timeIntervalSince1970: TimeInterval(epoch))          // 10:58 PM equivalent
        let end = start.addingTimeInterval(488 * 60)                          // 7:06 AM, 488 min later
        let labels = SleepStageBreakdown.axisLabels(start: start, end: end)

        XCTAssertEqual(labels.count, 5)
        XCTAssertEqual(labels.first, start)
        XCTAssertEqual(labels.last, end)
        for i in 1..<labels.count {
            XCTAssertEqual(labels[i].timeIntervalSince(labels[i - 1]), 488 * 60 / 4, accuracy: 0.01)
        }
    }

    func testAxisLabelsEmptyWhenEndNotAfterStart() {
        let d = Date()
        XCTAssertEqual(SleepStageBreakdown.axisLabels(start: d, end: d), [])
        XCTAssertEqual(SleepStageBreakdown.axisLabels(start: d, end: d.addingTimeInterval(-60)), [])
    }

    func testReferenceRangesMatchScreenshotTickPositions() {
        XCTAssertEqual(SleepStageBreakdown.referenceRange(for: .awake), 0...10)
        XCTAssertEqual(SleepStageBreakdown.referenceRange(for: .asleepREM), 18...23)
        XCTAssertEqual(SleepStageBreakdown.referenceRange(for: .asleepCore), 50...58)
        XCTAssertEqual(SleepStageBreakdown.referenceRange(for: .asleepDeep), 13...19)
        XCTAssertNil(SleepStageBreakdown.referenceRange(for: .inBed))
    }
}
