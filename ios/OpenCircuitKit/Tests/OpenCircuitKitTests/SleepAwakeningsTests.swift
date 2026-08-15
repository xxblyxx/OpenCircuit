import XCTest
@testable import OpenCircuitKit

// Tests for `SleepAwakenings` — see docs/SLEEP_AWAKENING_METRICS.md for the plan these pin.
// Each test name maps to a numbered case in that plan's §5.2; keep the mapping if renaming.
final class SleepAwakeningsTests: XCTestCase {

    private func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    private func seg(_ start: TimeInterval, _ end: TimeInterval, _ stage: SleepStage) -> SleepSegment {
        SleepSegment(start: d(start), end: d(end), stage: stage)
    }

    // MARK: 1. Current real-world shape — edge-only awake, zero interior

    func testEdgeOnlyNightHasZeroAwakenings() {
        // inBed 0..1000, awake 0..100 (pre-onset), asleep 100..900, awake 900..1000 (post-wake).
        let segments = [
            seg(0, 1000, .inBed),
            seg(0, 100, .awake),
            seg(100, 900, .asleepCore),
            seg(900, 1000, .awake),
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.waso, 0)
        XCTAssertEqual(result.longest, 0)
        XCTAssertEqual(result.edgeAwake, 200, "the two edge segments sum to 100 + 100")
        XCTAssertTrue(result.intervals.isEmpty)
    }

    // MARK: 2. Separated interior runs

    func testInteriorRunsAreCounted() {
        // asleep 0..200, awake 200..250 (50s), asleep 250..500, awake 500..700 (200s),
        // asleep 700..900, awake 900..920 (20s), asleep 920..1000.
        // Gaps between awake runs are all >> mergeTolerance (150s), via the asleep segments between.
        let segments = [
            seg(0, 200, .asleepCore),
            seg(200, 250, .awake),
            seg(250, 500, .asleepCore),
            seg(500, 700, .awake),
            seg(700, 900, .asleepCore),
            seg(900, 920, .awake),
            seg(920, 1000, .asleepCore),
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.waso, 50 + 200 + 20)
        XCTAssertEqual(result.longest, 200)
        XCTAssertEqual(result.edgeAwake, 0)
    }

    // MARK: 3. Adjacent awake segments merge

    func testAdjacentAwakeSegmentsMergeIntoOneAwakening() {
        // Two awake segments that touch exactly (a.end == b.start) inside the sleep window.
        let segments = [
            seg(0, 100, .asleepCore),
            seg(100, 150, .awake),
            seg(150, 200, .awake),   // touches the previous segment exactly
            seg(200, 400, .asleepCore),
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 1, "two touching awake segments are ONE awakening")
        XCTAssertEqual(result.waso, 100, "50 + 50, merged")
    }

    // MARK: 4. A real gap (larger than tolerance) splits the run

    func testGapLongerThanToleranceSplitsTheRun() {
        // Two awake segments separated by an asleep segment shorter than the merge tolerance is
        // NOT how a real gap looks (that would just merge as adjacent-with-a-tiny-sleep-blip);
        // instead this models an inter-fragment DATA GAP: no segment at all between two awake
        // runs, separated by far more than 150s of nothing.
        let segments = [
            seg(0, 100, .asleepCore),
            seg(100, 150, .awake),
            // gap: no segment from 150 to 1000 (e.g. a stitched multi-fragment night)
            seg(1000, 1050, .awake),
            seg(1050, 1200, .asleepCore),
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 2, "a gap far larger than mergeTolerance must not bridge")
        XCTAssertEqual(result.waso, 50 + 50)
    }

    /// A gap of exactly `mergeTolerance` is still eligible to merge — an off-by-one on the
    /// boundary would silently split it. This test is data-only, not conceptually a real gap,
    /// but pins the boundary the implementation uses.
    func testGapExactlyAtToleranceMerges() {
        let tol = SleepAwakenings.mergeTolerance
        let segments = [
            seg(0, 100, .asleepCore),
            seg(100, 150, .awake),
            seg(150 + tol, 150 + tol + 50, .awake),   // starts exactly `tol` after the first ends
            seg(150 + tol + 50, 150 + tol + 250, .asleepCore),
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 1, "a gap exactly at the tolerance must still merge")
    }

    // MARK: 5. .inBed is ignored

    func testInBedSegmentIsIgnored() {
        let withoutInBed = [
            seg(0, 100, .awake),
            seg(100, 900, .asleepCore),
            seg(400, 450, .awake),
            seg(450, 900, .asleepCore),
            seg(900, 1000, .awake),
        ]
        let withInBed = [seg(0, 1000, .inBed)] + withoutInBed
        XCTAssertEqual(SleepAwakenings.from(segments: withoutInBed),
                       SleepAwakenings.from(segments: withInBed))
    }

    // MARK: 6. Clip to [onset, finalWake]

    func testAwakeStraddlingOnsetContributesOnlyItsInteriorPart() {
        // An awake segment 50..150 straddles onset at 100: only 100..150 (50s) should count as
        // interior/WASO; 50..100 (50s) is edge.
        let segments = [
            seg(0, 50, .awake),
            seg(50, 150, .awake),      // straddles onset (100)
            seg(100, 900, .asleepCore),
            seg(900, 1000, .awake),
        ]
        // Note: onset is the min start of an asleep segment = 100, per SleepStaging.sleepWindow.
        // total awake = 50 (0..50) + 100 (50..150) + 100 (900..1000) = 250; waso = 50 (the
        // 100..150 portion of the straddling segment); edge = 250 - 50 = 200.
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.waso, 50, "only the 100..150 portion of the straddling segment counts")
        XCTAssertEqual(result.edgeAwake, 200, "0..100 (fully pre-onset) + 900..1000 (post-wake)")
    }

    func testAwakeStraddlingFinalWakeContributesOnlyItsInteriorPart() {
        let segments = [
            seg(0, 100, .awake),
            seg(100, 900, .asleepCore),
            seg(850, 1000, .awake),   // straddles finalWake (900): interior 850..900, edge 900..1000
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.waso, 50, "only the 850..900 portion counts")
        XCTAssertEqual(result.edgeAwake, 100 + 100, "the 0..100 pre-onset span + the 900..1000 post-wake span")
    }

    // MARK: 7. Invariant: waso + edgeAwake == summary(segments).awake

    func testWasoPlusEdgeEqualsSummaryAwake() {
        for seed in 0..<200 {
            var segments: [SleepSegment] = []
            var t: TimeInterval = 0
            var rng = seed
            func next(_ bound: Int) -> Int {
                rng = (rng &* 1103515245 &+ 12345) & 0x7fffffff
                return bound > 0 ? rng % bound : 0
            }
            // Guaranteed asleep segment first: a night with NO asleep segments at all is a
            // deliberately separate, documented case (`testNightWithNoAsleepSegmentsIsZeroed`)
            // where `.from` returns `.zero` rather than preserving this invariant — §3 carves it
            // out explicitly. This loop is scoped to nights that have real sleep in them, so it
            // must never spuriously land on that degenerate branch.
            segments.append(seg(0, 200, .asleepCore))
            t = 200
            let stages: [SleepStage] = [.awake, .asleepCore, .asleepDeep, .asleepREM]
            let segmentCount = 5 + next(15)
            for _ in 0..<segmentCount {
                let duration = TimeInterval(30 + next(600))
                let stage = stages[next(stages.count)]
                segments.append(seg(t, t + duration, stage))
                t += duration
                // Occasionally insert a data gap (no segment) to exercise stitched nights.
                if next(6) == 0 { t += TimeInterval(200 + next(2000)) }
            }
            // Wrap with an inBed envelope, as production always tiles.
            let envelope = SleepSegment(start: segments.first!.start, end: segments.last!.end, stage: .inBed)
            let full = [envelope] + segments

            let awakenings = SleepAwakenings.from(segments: full)
            let summary = SleepStaging.summary(full)
            XCTAssertEqual(awakenings.waso + awakenings.edgeAwake, summary.awake, accuracy: 0.001,
                           "seed \(seed): waso + edgeAwake must equal summary.awake exactly")
        }
    }

    // MARK: 8/9. No asleep segments / empty input

    func testNightWithNoAsleepSegmentsIsZeroed() {
        let segments = [
            seg(0, 1000, .inBed),
            seg(0, 1000, .awake),
        ]
        XCTAssertEqual(SleepAwakenings.from(segments: segments), .zero)
    }

    func testEmptySegmentsIsZeroed() {
        XCTAssertEqual(SleepAwakenings.from(segments: []), .zero)
    }

    // MARK: Ordering

    func testIntervalsAreChronological() {
        let segments = [
            seg(0, 100, .asleepCore),
            seg(100, 150, .awake),
            seg(150, 400, .asleepCore),
            seg(400, 450, .awake),
            seg(450, 600, .asleepCore),
        ]
        let result = SleepAwakenings.from(segments: segments)
        XCTAssertEqual(result.intervals.map(\.start), result.intervals.map(\.start).sorted())
    }
}
