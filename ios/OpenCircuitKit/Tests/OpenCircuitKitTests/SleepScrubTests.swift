import XCTest
@testable import OpenCircuitKit

/// Pins the touch-position math behind the hypnogram scrub feature (#186): date <-> fraction
/// round-tripping, nearest-sample snapping with a tolerance gap, and stage lookup across the
/// `.inBed` envelope. Regressions here would show up as the scrub rule landing on the wrong
/// instant or the callout reporting a fabricated reading inside a real gap.
final class SleepScrubTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private lazy var end = start.addingTimeInterval(8 * 3600) // 8h night

    // MARK: - fraction / date round trip

    func testFractionDateRoundTrip() {
        for f in stride(from: 0.0, through: 1.0, by: 0.1) {
            let d = SleepScrub.date(atFraction: f, start: start, end: end)
            let back = SleepScrub.fraction(of: d, start: start, end: end)
            XCTAssertNotNil(back)
            XCTAssertEqual(back!, f, accuracy: 0.001)
        }
    }

    func testFractionIsNotClampedOutsideDomain() {
        // MovementStrip relies on out-of-window epochs reporting <0 or >1 so it can drop them.
        let before = start.addingTimeInterval(-600)
        let after = end.addingTimeInterval(600)
        XCTAssertLessThan(SleepScrub.fraction(of: before, start: start, end: end)!, 0)
        XCTAssertGreaterThan(SleepScrub.fraction(of: after, start: start, end: end)!, 1)
    }

    func testFractionNilOnDegenerateDomain() {
        XCTAssertNil(SleepScrub.fraction(of: start, start: start, end: start))
        XCTAssertNil(SleepScrub.fraction(of: start, start: end, end: start))
    }

    func testDateAtFractionClampsPastEdges() {
        XCTAssertEqual(SleepScrub.date(atFraction: -0.3, start: start, end: end), start)
        XCTAssertEqual(SleepScrub.date(atFraction: 1.4, start: start, end: end), end)
    }

    // MARK: - nearestIndex

    func testNearestIndexEmptySeries() {
        XCTAssertNil(SleepScrub.nearestIndex(in: [], to: start))
    }

    func testNearestIndexWithinTolerance() {
        let times = [start, start.addingTimeInterval(150), start.addingTimeInterval(300)]
        let target = start.addingTimeInterval(160)
        XCTAssertEqual(SleepScrub.nearestIndex(in: times, to: target), 1)
    }

    func testNearestIndexOutsideToleranceReturnsNil() {
        let times = [start, start.addingTimeInterval(1000)]
        let target = start.addingTimeInterval(500) // 500s from both — beyond the 300s window
        XCTAssertNil(SleepScrub.nearestIndex(in: times, to: target))
    }

    func testNearestIndexTieBreaksToEarlierIndex() {
        let times = [start, start.addingTimeInterval(200)]
        let target = start.addingTimeInterval(100) // exactly equidistant
        XCTAssertEqual(SleepScrub.nearestIndex(in: times, to: target), 0)
    }

    func testNearestIndexGoesBlankAcrossARealGap() {
        // A 20-minute dropout either side of its centre — no sample should read as "now" there.
        let before = start
        let after = start.addingTimeInterval(20 * 60)
        let center = start.addingTimeInterval(10 * 60)
        XCTAssertNil(SleepScrub.nearestIndex(in: [before, after], to: center))
    }

    func testNearestIndexToleratesOneDroppedEpoch() {
        // 150s cadence with one epoch missing: gap of 300s should still resolve to a neighbor.
        let times = [start, start.addingTimeInterval(300)]
        let target = start.addingTimeInterval(150) // exactly at the tolerance boundary from both
        XCTAssertNotNil(SleepScrub.nearestIndex(in: times, to: target))
    }

    // MARK: - stage(at:)

    func testStageRealSegmentBeatsInBedEnvelope() {
        let segments = [
            SleepSegment(start: start, end: end, stage: .inBed),
            SleepSegment(start: start.addingTimeInterval(600), end: start.addingTimeInterval(1200), stage: .asleepDeep),
        ]
        let t = start.addingTimeInterval(800)
        XCTAssertEqual(SleepScrub.stage(at: t, in: segments), .asleepDeep)
    }

    func testStageFallsBackToInBedEnvelope() {
        let segments = [
            SleepSegment(start: start, end: end, stage: .inBed),
            SleepSegment(start: start.addingTimeInterval(600), end: start.addingTimeInterval(1200), stage: .asleepDeep),
        ]
        let t = start.addingTimeInterval(100) // before the staged segment begins
        XCTAssertEqual(SleepScrub.stage(at: t, in: segments), .inBed)
    }

    func testStageBoundaryBelongsToIncomingSegment() {
        let boundary = start.addingTimeInterval(600)
        let segments = [
            SleepSegment(start: start, end: boundary, stage: .asleepCore),
            SleepSegment(start: boundary, end: end, stage: .asleepREM),
        ]
        XCTAssertEqual(SleepScrub.stage(at: boundary, in: segments), .asleepREM)
    }

    func testStageFinalInstantOfNightStillResolves() {
        let segments = [SleepSegment(start: start, end: end, stage: .asleepCore)]
        XCTAssertEqual(SleepScrub.stage(at: end, in: segments), .asleepCore)
    }

    func testStageGapReturnsNil() {
        let segments = [
            SleepSegment(start: start, end: start.addingTimeInterval(600), stage: .asleepCore),
            SleepSegment(start: start.addingTimeInterval(1200), end: end, stage: .asleepREM),
        ]
        let inGap = start.addingTimeInterval(800)
        XCTAssertNil(SleepScrub.stage(at: inGap, in: segments))
    }

    func testStageOverlappingStitchedSegmentsLaterStartWins() {
        let segments = [
            SleepSegment(start: start, end: start.addingTimeInterval(1000), stage: .asleepCore),
            SleepSegment(start: start.addingTimeInterval(500), end: start.addingTimeInterval(1000), stage: .asleepDeep),
        ]
        let t = start.addingTimeInterval(700)
        XCTAssertEqual(SleepScrub.stage(at: t, in: segments), .asleepDeep)
    }

    // MARK: - SleepVitalsSeries

    func testSeriesClampedDropsOutOfDomainSamples() {
        let series = SleepVitalsSeries(
            hr: [.init(time: start.addingTimeInterval(-100), value: 50), .init(time: start.addingTimeInterval(100), value: 55)],
            hrv: [.init(time: end.addingTimeInterval(100), value: 40)],
            spo2: [.init(time: start.addingTimeInterval(50), value: 0.96)])
        let clamped = series.clamped(to: start, end: end)
        XCTAssertEqual(clamped.hr.map(\.value), [55])
        XCTAssertTrue(clamped.hrv.isEmpty)
        XCTAssertEqual(clamped.spo2.map(\.value), [0.96])
    }

    func testSeriesValueNearHonorsWindow() {
        let series = SleepVitalsSeries(hr: [], hrv: [.init(time: start, value: 42)], spo2: [])
        XCTAssertEqual(series.value(in: series.hrv, near: start.addingTimeInterval(200)), 42)
        XCTAssertNil(series.value(in: series.hrv, near: start.addingTimeInterval(400)))
    }
}
