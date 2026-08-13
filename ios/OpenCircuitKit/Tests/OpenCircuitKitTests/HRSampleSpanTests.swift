import XCTest
@testable import OpenCircuitKit

/// `HRSampleSpan.heldForward` — the primitive extracted from `HRZoneClassifier.timeInZonesHeld`
/// so the live zone display and what `WorkoutSessionAggregator.persistableSamples` writes to
/// `LocalStore` can never disagree.
///
/// Regression origin: `WorkoutSessionManager.collectHRSnapshot` stamps every live reading with a
/// fixed ~2 s span (the poll-lock window) even though the ring's native sport stream actually
/// reports HR roughly every 10 s. `ExerciseMinutes.elevatedPieces` trusts a spanned sample's own
/// duration verbatim — correct for a bulk sleep epoch (the stamped ~150 s IS the real epoch
/// width), wrong for a workout reading (the stamped 2 s is a lie). The Activity card priced a
/// workout's active-kcal at roughly 1/5 of its true value as a result (2026-08-12).
final class HRSampleSpanTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    /// The actual bug shape: readings 10 s apart, each stamped with a 2 s span (irrelevant to
    /// `heldForward` — only `start`/`bpm` are read; `end` is discarded and recomputed).
    private func cadence10s(count: Int, bpm: Int = 150, from base: Date? = nil) -> [HRSample] {
        let start = base ?? t0
        return (0..<count).map { i in
            HRSample(bpm: bpm, start: start.addingTimeInterval(Double(i) * 10),
                     end: start.addingTimeInterval(Double(i) * 10 + 2))
        }
    }

    // MARK: - Core cadence recovery

    func testRealCadenceIsRecoveredNotTheStampedTwoSeconds() {
        let samples = cadence10s(count: 6)   // t=0,10,...,50, each stamped 2 s
        let held = HRSampleSpan.heldForward(samples, sessionEnd: t0.addingTimeInterval(65))
        XCTAssertEqual(held.count, 6)
        // First 5: held to the NEXT sample's start (10 s each). Last: held to sessionEnd (15 s).
        for i in 0..<5 {
            XCTAssertEqual(held[i].end.timeIntervalSince(held[i].start), 10, accuracy: 0.001,
                           "sample \(i)")
        }
        XCTAssertEqual(held[5].end.timeIntervalSince(held[5].start), 15, accuracy: 0.001)
        let total = held.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        XCTAssertEqual(total, 65, accuracy: 0.001)   // vs. the old stamped total of 6×2 = 12
    }

    // MARK: - Dropout capping

    func testRealDropoutIsCappedNotFabricated() {
        let samples = [
            HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2)),
            HRSample(bpm: 150, start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(102)),
        ]
        let held = HRSampleSpan.heldForward(samples, sessionEnd: t0.addingTimeInterval(130),
                                            maxGapSeconds: 30)
        XCTAssertEqual(held.count, 2)
        XCTAssertEqual(held[0].end.timeIntervalSince(held[0].start), 30, accuracy: 0.001)
        XCTAssertEqual(held[1].end.timeIntervalSince(held[1].start), 30, accuracy: 0.001)
    }

    // MARK: - Zero-width samples are dropped (the load-bearing anti-regression check)

    /// A duplicate `start` must not appear twice in the output, and MUST NOT survive as a
    /// zero-width sample: a zero-width persisted sample looks like a POINT sample to
    /// `ExerciseMinutes.elevatedPieces`, which could then widen it to a full epoch under its
    /// ambient-run heuristic — silently reintroducing fabricated time through a different door.
    func testDuplicateStartProducesNoZeroWidthSample() {
        let samples = [
            HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2)),
            HRSample(bpm: 160, start: t0, end: t0.addingTimeInterval(2)),   // exact duplicate start
            HRSample(bpm: 150, start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(12)),
        ]
        let held = HRSampleSpan.heldForward(samples, sessionEnd: t0.addingTimeInterval(20))
        XCTAssertFalse(held.contains { $0.end == $0.start }, "no zero-width span may survive")
        XCTAssertEqual(held.count, 2, "the duplicate-start sample must be dropped, not duplicated")
    }

    /// A `start` at or after `sessionEnd` (clock skew) must not survive as a zero-width sample.
    func testStartAtOrAfterSessionEndProducesNoZeroWidthSample() {
        let samples = [
            HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2)),
            HRSample(bpm: 150, start: t0.addingTimeInterval(50), end: t0.addingTimeInterval(52)),
        ]
        // sessionEnd BEFORE the last sample's start.
        let held = HRSampleSpan.heldForward(samples, sessionEnd: t0.addingTimeInterval(30))
        XCTAssertFalse(held.contains { $0.end == $0.start })
        XCTAssertEqual(held.count, 1, "the sample starting after sessionEnd must be dropped")
    }

    // MARK: - Shape invariants

    func testResultIsSortedNonOverlappingAndNeverPastSessionEnd() {
        // Deliberately out-of-order input.
        let samples = [
            HRSample(bpm: 140, start: t0.addingTimeInterval(30), end: t0.addingTimeInterval(32)),
            HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2)),
            HRSample(bpm: 145, start: t0.addingTimeInterval(15), end: t0.addingTimeInterval(17)),
        ]
        let sessionEnd = t0.addingTimeInterval(40)
        let held = HRSampleSpan.heldForward(samples, sessionEnd: sessionEnd)
        XCTAssertEqual(held.map(\.start), held.map(\.start).sorted())
        for i in 0..<(held.count - 1) {
            XCTAssertLessThanOrEqual(held[i].end, held[i + 1].start, "spans must not overlap")
        }
        XCTAssertLessThanOrEqual(held.last!.end, sessionEnd)
    }

    func testOnlyEndIsRewrittenStartAndBpmArePreserved() {
        let samples = cadence10s(count: 3, bpm: 137)
        let held = HRSampleSpan.heldForward(samples, sessionEnd: t0.addingTimeInterval(35))
        for (original, corrected) in zip(samples, held) {
            XCTAssertEqual(corrected.start, original.start)
            XCTAssertEqual(corrected.bpm, original.bpm)
        }
    }

    // MARK: - Edge cases

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(HRSampleSpan.heldForward([], sessionEnd: t0), [])
    }

    func testSingleSampleIsHeldToSessionEndCapped() {
        let samples = [HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2))]
        let held = HRSampleSpan.heldForward(samples, sessionEnd: t0.addingTimeInterval(200),
                                            maxGapSeconds: 30)
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].end.timeIntervalSince(held[0].start), 30, accuracy: 0.001)
    }

    // MARK: - Anti-drift invariant: heldForward and timeInZonesHeld can never disagree

    /// The whole reason `heldForward` was extracted rather than reimplemented inline: this makes
    /// "the live zone display and the persisted span can never disagree" a test, not a comment.
    func testHeldForwardAgreesWithTimeInZonesHeldAcrossShapes() {
        let maxHR = 200
        let shapes: [(name: String, samples: [HRSample], sessionEnd: Date)] = [
            ("dense", cadence10s(count: 8), t0.addingTimeInterval(85)),
            ("gapped", [HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2)),
                       HRSample(bpm: 150, start: t0.addingTimeInterval(90), end: t0.addingTimeInterval(92))],
             t0.addingTimeInterval(150)),
            ("duplicateStarts", [HRSample(bpm: 150, start: t0, end: t0.addingTimeInterval(2)),
                                 HRSample(bpm: 160, start: t0, end: t0.addingTimeInterval(2)),
                                 HRSample(bpm: 150, start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(12))],
             t0.addingTimeInterval(20)),
            ("mixedSubThreshold", [HRSample(bpm: 80, start: t0.addingTimeInterval(5), end: t0.addingTimeInterval(7)),
                                   HRSample(bpm: 150, start: t0.addingTimeInterval(15), end: t0.addingTimeInterval(17))],
             t0.addingTimeInterval(30)),
        ]
        for shape in shapes {
            let heldSum = HRSampleSpan.heldForward(shape.samples, sessionEnd: shape.sessionEnd)
                .filter { HRZoneClassifier.zone(bpm: $0.bpm, maxHR: maxHR) != nil }
                .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
            let zoneTotal = HRZoneClassifier.timeInZonesHeld(hrSamples: shape.samples, maxHR: maxHR,
                                                             sessionEnd: shape.sessionEnd).totalZoneSeconds
            XCTAssertEqual(heldSum, zoneTotal, accuracy: 0.001, shape.name)
        }
    }
}
