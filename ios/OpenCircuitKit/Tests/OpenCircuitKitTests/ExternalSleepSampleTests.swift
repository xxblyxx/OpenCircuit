import XCTest
@testable import OpenCircuitKit

// `ExternalSleepSample` is the reference-label store (Whoop / Apple Watch sleep intervals read back
// out of HealthKit). It holds data we did NOT produce and cannot regenerate from the ring, so the
// codec gets the same treatment `SleepHypnogramCodecTests` gives the hypnogram: pin the exact bytes,
// and prove the decoder never traps and never invents.
final class ExternalSleepSampleTests: XCTestCase {

    private func d(_ t: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    private func sample(_ source: String = "WHOOP", _ start: Int, _ end: Int,
                        _ stage: SleepStage = .awake) -> ExternalSleepSample {
        ExternalSleepSample(source: source, start: d(start), end: d(end), stage: stage)
    }

    // MARK: - Codec round-trip + pinned bytes

    func testRoundTripPreservesEverySample() {
        let samples = [
            sample("WHOOP", 1_000, 1_150, .awake),
            sample("WHOOP", 1_150, 2_000, .asleepDeep),
            sample("Apple Watch", 2_000, 2_500, .asleepREM),
            sample("WHOOP", 2_500, 2_600, .inBed),
            sample("WHOOP", 2_600, 3_000, .asleepCore),
        ]
        XCTAssertEqual(ExternalSleepCodec.decode(ExternalSleepCodec.encode(samples)), samples)
    }

    /// Pins the wire format. The stage codes must match `SleepHypnogramCodec`'s (0=inBed 1=awake
    /// 2=core 3=deep 4=REM) so one desktop parser can read both stores.
    func testEncodedBytesArePinned() {
        let data = ExternalSleepCodec.encode([sample("WHOOP", 100, 250, .awake)])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"[["WHOOP",100,250,1]]"#)
    }

    func testStageCodesMatchHypnogramCodec() {
        // Encode one sample per stage and read the trailing code out of each row.
        let stages: [(SleepStage, Int)] = [
            (.inBed, 0), (.awake, 1), (.asleepCore, 2), (.asleepDeep, 3), (.asleepREM, 4)
        ]
        for (stage, expected) in stages {
            let data = ExternalSleepCodec.encode([sample("S", 0, 10, stage)])
            let json = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(json.hasSuffix(",\(expected)]]"),
                          "\(stage) must encode as \(expected); got \(json)")
        }
    }

    // MARK: - Robustness (this is stored data: never trap, never invent)

    func testEmptyAndGarbageDecodeToEmpty() {
        XCTAssertEqual(ExternalSleepCodec.decode(Data()), [])
        XCTAssertEqual(ExternalSleepCodec.decode(Data([0xFF, 0x00, 0x13])), [])
        XCTAssertEqual(ExternalSleepCodec.decode(Data("not json".utf8)), [])
        XCTAssertEqual(ExternalSleepCodec.decode(Data("{}".utf8)), [])
    }

    func testMalformedRowIsDroppedButSiblingsSurvive() {
        // rows: valid, wrong arity, unknown stage code, reversed, valid
        let json = #"[["A",10,20,1],["A",10,20],["A",10,20,99],["A",50,40,1],["B",30,40,3]]"#
        let decoded = ExternalSleepCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded, [sample("A", 10, 20, .awake), sample("B", 30, 40, .asleepDeep)])
    }

    func testZeroLengthAndReversedSamplesAreNeverWritten() {
        let data = ExternalSleepCodec.encode([
            sample("A", 100, 100, .awake),   // zero-length
            sample("A", 200, 150, .awake),   // reversed
            sample("A", 300, 400, .awake),   // the only writable one
        ])
        XCTAssertEqual(ExternalSleepCodec.decode(data), [sample("A", 300, 400, .awake)])
    }

    /// Row order is preserved, so a stored night reads back in the order it was captured.
    func testOrderIsPreserved() {
        let samples = (0..<20).map { sample("WHOOP", $0 * 100, $0 * 100 + 50, .awake) }
        XCTAssertEqual(ExternalSleepCodec.decode(ExternalSleepCodec.encode(samples)), samples)
    }

    // MARK: - Queries

    func testAwakeIntervalsSelectsOnlyAwake() {
        let samples = [
            sample("W", 0, 100, .awake),
            sample("W", 100, 200, .asleepCore),
            sample("W", 200, 300, .awake),
            sample("W", 300, 400, .asleepREM),
        ]
        XCTAssertEqual(samples.awakeIntervals.map(\.start), [d(0), d(200)])
    }

    /// The guard that keeps two vendors from being pooled into one "truth" set.
    func testSourcesAreDistinctAndSorted() {
        let samples = [
            sample("WHOOP", 0, 10), sample("Apple Watch", 10, 20), sample("WHOOP", 20, 30)
        ]
        XCTAssertEqual(samples.sources, ["Apple Watch", "WHOOP"])
        XCTAssertEqual(samples.from(source: "WHOOP").count, 2)
        XCTAssertEqual(samples.from(source: "Apple Watch").count, 1)
        XCTAssertEqual(samples.from(source: "Oura").count, 0, "an absent source yields nothing, not everything")
    }

    func testOverlappingIsTouchesNotContains() {
        let samples = [
            sample("W", 0, 100),      // ends exactly at window start -> NOT overlapping (half-open)
            sample("W", 50, 150),     // straddles the start
            sample("W", 120, 180),    // fully inside
            sample("W", 180, 260),    // straddles the end
            sample("W", 200, 300),    // starts exactly at window end -> NOT overlapping
        ]
        let window = DateInterval(start: d(100), end: d(200))
        XCTAssertEqual(samples.overlapping(window).map(\.start), [d(50), d(120), d(180)])
    }

    func testOverlappingIsSortedByStart() {
        let samples = [sample("W", 300, 400), sample("W", 100, 200), sample("W", 200, 300)]
        let all = DateInterval(start: d(0), end: d(1000))
        XCTAssertEqual(samples.overlapping(all).map(\.start), [d(100), d(200), d(300)])
    }

    func testCoversIsHalfOpen() {
        let s = sample("W", 100, 200)
        XCTAssertTrue(s.covers(d(100)), "start is inclusive")
        XCTAssertTrue(s.covers(d(199)))
        XCTAssertFalse(s.covers(d(200)), "end is exclusive")
        XCTAssertFalse(s.covers(d(99)))
    }

    func testDuration() {
        XCTAssertEqual(sample("W", 100, 250).duration, 150)
    }
}
