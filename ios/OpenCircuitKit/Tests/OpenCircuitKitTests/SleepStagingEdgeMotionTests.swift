import XCTest
@testable import OpenCircuitKit

// Tests for `SleepStaging.markEdgeMotionAwake` / `Tuning.edgeIntensityCut` — the mirror-image fix
// to `markInteriorArousals` (`SleepStagingInteriorArousalTests.swift`), diagnosed 2026-08-15 against
// the 08-14/15 night: reported awake 120 min vs Whoop's 48.5 min, ~70 of the gap being real
// pre-sleep movement that landed INSIDE a sleep window anchored 74.8 min too early.
//
// FIXTURE SHAPE: `tvrec` epochs are entirely on the intensity-tail fallback path (flat `[1,1,1,1,1]`
// placeholder primary motion, flat HR at 50 bpm — well below any wake threshold on its own). Some
// tests also insert ONE genuinely-expressive-primary epoch (`mvrecMoving`) in the DEEP INTERIOR
// (index 100 of a 200-epoch night, well outside both `onsetSearchEpochs` (48) edge regions) to
// reproduce the real failure mode: a handful of expressive epochs anywhere in the in-bed block flip
// `BulkSleep.motionSource`'s BLOCK-SCOPED verdict to `.primary` (`BulkSleep.swift:462-466`), which
// blinds every block-scoped pass (including the ordinary motion gate) to the tail-only pre-sleep/
// post-wake movement this pass exists to recover. `markEdgeMotionAwake` must still catch it because
// its OWN verdict is decided per-region, on a slice that never contains the interior anomaly.
final class SleepStagingEdgeMotionTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 10_000

    private func counter(_ index: Int) -> UInt32 { base + UInt32(index) * step }
    private func date(_ index: Int) -> Date {
        Date(timeIntervalSince1970: Double(Int(counter(index)) + Command.syncEpoch))
    }

    private func tailBytes(sum: Int) -> [UInt8] {
        var remaining = max(0, sum)
        var bytes = [UInt8](repeating: 0, count: 5)
        for i in 0..<5 {
            let v = min(remaining, 255)
            bytes[i] = UInt8(v)
            remaining -= v
        }
        return bytes
    }

    /// A sleep-vitals epoch with flat placeholder primary motion and a caller-chosen `[15:20]` tail sum.
    private func tvrec(_ counter: UInt32, hr: UInt8, tailSum: Int) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = 1 }
        let tail = tailBytes(sum: tailSum)
        for k in 0..<5 { b[15 + k] = tail[k] }
        return BulkRecord(b)!
    }

    /// A genuinely-expressive (non-placeholder) primary-motion epoch with zero tail — the real
    /// "getting up"/anomaly shape that disqualifies a WHOLE-BLOCK `constantFiller` verdict.
    private func mvrecMoving(_ counter: UInt32, hr: UInt8) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x62
        let pattern: [UInt8] = [12, 30, 8, 25, 17]
        for k in 0..<5 { b[10 + k] = pattern[k] }
        return BulkRecord(b)!
    }

    /// A `count`-epoch, flat-HR (50 bpm) night, placeholder-primary throughout, with optional tail-sum
    /// spikes in the leading/trailing edges and an optional single expressive-primary anomaly deep in
    /// the interior (outside both edge search regions) to force the whole-block verdict to `.primary`.
    private func edgeNight(leadingSpike: Range<Int>? = nil, trailingSpike: Range<Int>? = nil,
                          anomalyAt: Int? = nil, count: Int = 200,
                          spikeSum: Int = 400, baseSum: Int = 5, hr: UInt8 = 50) -> [BulkRecord] {
        (0..<count).map { i in
            if i == anomalyAt { return mvrecMoving(counter(i), hr: hr) }
            let spiked = (leadingSpike?.contains(i) ?? false) || (trailingSpike?.contains(i) ?? false)
            return tvrec(counter(i), hr: hr, tailSum: spiked ? spikeSum : baseSum)
        }
    }

    private func stage(_ segs: [SleepSegment], at index: Int) -> SleepStage? {
        let d = date(index)
        return segs.first { $0.stage != .inBed && $0.start <= d && d < $0.end }?.stage
    }

    // MARK: 1. Expressive primary motion at both edges -> pass no-ops

    func testExpressivePrimaryEdgesAreUntouched() {
        var awake = [Bool](repeating: false, count: 40)
        let before = awake
        // Expressive (non-placeholder) primary motion at every index -> usesMotionIntensityFallback
        // reads `.primary` for both regions regardless of the tailSums argument passed alongside it.
        let records = (0..<40).map { mvrecMoving(counter($0), hr: 50) }
        SleepStaging.markEdgeMotionAwake(&awake, tailSums: [Int](repeating: 400, count: 40),
                                         records: records, tuning: .default)
        XCTAssertEqual(awake, before,
                       "a night whose edges carry real primary motion must be untouched by the tail-fallback pass")
    }

    // MARK: 2. Leading region: onset moves past pre-sleep tail movement

    func testOnsetMovesPastLeadingMovement() {
        let records = edgeNight(leadingSpike: 0..<20, anomalyAt: 100)
        XCTAssertFalse(BulkSleep.usesMotionIntensityFallback(records),
                       "premise failed -- the interior anomaly must flip the WHOLE block to .primary, "
                       + "exactly as the real night did")

        let on = SleepStaging.classify(from: records)                                  // default cut
        let off = SleepStaging.classify(from: records, tuning: .init(edgeIntensityCut: 0))

        XCTAssertEqual(SleepStaging.sleepWindow(off)?.onset, date(0),
                       "bug reproduced: with the pass off, onset anchors on the very first in-bed epoch")
        XCTAssertEqual(SleepStaging.sleepWindow(on)?.onset, date(20),
                       "onset must move past the leading pre-sleep movement once the pass is on")
        XCTAssertEqual(stage(on, at: 10), .awake, "an epoch inside the leading spike must stage awake")
        XCTAssertNotEqual(stage(on, at: 25), .awake, "an epoch past the leading spike must not be awake")
    }

    // MARK: 3. Trailing region: final wake moves earlier than post-wake tail movement

    func testFinalWakeMovesBeforeTrailingMovement() {
        let records = edgeNight(trailingSpike: 180..<200, anomalyAt: 100)
        XCTAssertFalse(BulkSleep.usesMotionIntensityFallback(records),
                       "premise failed -- the interior anomaly must flip the WHOLE block to .primary")

        let on = SleepStaging.classify(from: records)
        let off = SleepStaging.classify(from: records, tuning: .init(edgeIntensityCut: 0))
        let wakeOn = SleepStaging.sleepWindow(on)?.wake
        let wakeOff = SleepStaging.sleepWindow(off)?.wake
        XCTAssertNotNil(wakeOn); XCTAssertNotNil(wakeOff)

        XCTAssertGreaterThanOrEqual(wakeOff!, date(190),
                                    "bug reproduced: with the pass off, final wake sits inside the trailing movement")
        XCTAssertLessThanOrEqual(wakeOn!, date(180),
                                 "final wake must land at or before the trailing pre-wake movement once the pass is on")
        XCTAssertLessThan(wakeOn!, wakeOff!, "the pass must move final wake meaningfully earlier")
        XCTAssertEqual(stage(on, at: 190), .awake, "an epoch inside the trailing spike must stage awake")
    }

    // MARK: 4. Survival guard: a night that is all tail-movement is not committed to all-awake

    func testAllMovementNightIsNotCommittedAwake() {
        var awake = [Bool](repeating: false, count: 30)
        let before = awake
        let records = (0..<30).map { tvrec(counter($0), hr: 50, tailSum: 400) }
        SleepStaging.markEdgeMotionAwake(&awake, tailSums: [Int](repeating: 400, count: 30),
                                         records: records, tuning: .default)
        XCTAssertEqual(awake, before,
                       "a pass that can only ADD awake must not be allowed to erase the night entirely")
    }

    // MARK: 5. Kill switch is byte-identical

    func testKillSwitchIsByteIdentical() {
        let spiked = edgeNight(leadingSpike: 0..<20, trailingSpike: 180..<200, anomalyAt: 100)
        let flat = edgeNight(anomalyAt: 100)
        let off1 = SleepStaging.classify(from: spiked, tuning: .init(edgeIntensityCut: 0))
        let off2 = SleepStaging.classify(from: flat, tuning: .init(edgeIntensityCut: 0))
        XCTAssertEqual(off1, off2,
                       "edgeIntensityCut == 0 must ignore the edge tail sums entirely")
    }

    // MARK: 6. The metric built for this actually observes it -- and observes the RIGHT thing

    /// Without the fix, the leading spike isn't misfiled as WASO — it is invisible to every pass
    /// (block verdict `.primary` blinds Pass1 to the tail channel; the interior anomaly ALSO
    /// disqualifies `markInteriorArousals`' own region-scoped check), so it is simply staged as
    /// ordinary sleep. This is the real mechanism `sleep_awake_trace.py` measured on the 08-14/15
    /// night ("motion source: primary" for the whole block, every night epoch's motion Σ reading 0
    /// despite real tail movement) — the fix's job is recovering it as `headAwake`, not shrinking an
    /// already-inflated WASO.
    private func totalAsleepMinutes(_ segs: [SleepSegment]) -> Double {
        SleepStaging.stageTotals(segs).reduce(0) { total, kv in
            [.asleepCore, .asleepDeep, .asleepREM].contains(kv.key) ? total + kv.value / 60 : total
        }
    }

    func testFixMovesPhantomAsleepIntoHeadAwake() {
        let records = edgeNight(leadingSpike: 0..<20, anomalyAt: 100)
        let on = SleepStaging.classify(from: records)
        let off = SleepStaging.classify(from: records, tuning: .init(edgeIntensityCut: 0))

        let headOff = SleepAwakenings.from(segments: off).minutes.headAwake
        let headOn = SleepAwakenings.from(segments: on).minutes.headAwake
        XCTAssertEqual(headOff, 0, "bug reproduced: without the fix onset sits at index 0, so there is no head awake to report")
        XCTAssertGreaterThan(headOn, 40, "the fix must recover the pre-sleep movement as head awake")

        XCTAssertLessThan(totalAsleepMinutes(on), totalAsleepMinutes(off),
                          "the recovered head-awake minutes must come OUT of total asleep, not appear from nowhere")
    }
}
