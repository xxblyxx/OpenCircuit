import XCTest
@testable import OpenCircuitKit

// Cross-language parity: `desktop/ringconn_sleep_fit.py` is a hand-maintained Python PORT of this
// file, used to fit `SleepStaging.Tuning` against captured RingConn ground truth
// (docs/RUNBOOK_SLEEP_GROUNDTRUTH.md). A port that silently drifts from the Swift it mirrors makes
// every fit approximate without anyone noticing — which is exactly what happened before this test
// existed (see the drift notes on `ringconn_sleep_fit.Tuning`, corrected alongside this file).
//
// This fixture exercises three passes in one night — `markLeadInWakeOnset`, `rescueSecondBoutHRWake`
// and the erosion `awake` mask they build on — chosen because together they cover every AWAKE-mask
// pass the Python port newly mirrors. The expected epoch set below was established by RUNNING BOTH
// sides on the identical byte sequence (`parity_probe2.py` mirrors this fixture exactly) and
// recording what each produced — not derived by hand — so this test pins agreement, not a guess at
// what agreement should look like. If a future Swift change to these passes moves this fixture's
// output, update BOTH this file and `ringconn_sleep_fit.py`'s mirror together, then re-run the probe.
final class SleepStagingSwiftPythonParityTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 0x0c220000

    /// A sleep-vitals epoch. Mirrors `SleepStagingTests.vrec` / `SleepContinuationTests.vrec`.
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 60, motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// A moving activity epoch — the getting-up trip between the first bout and the second.
    private func arec(_ counter: UInt32, motion: UInt8 = 60) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = 0x12
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// The 191-epoch fixture (byte-identical to `desktop/parity_probe2.py`'s `build()`):
    ///   [0..14)    quietA      — floor HR (50), asleep on its own; sets up `longestPrior < 16`
    ///   [14..28)   leadin      — elevated HR (95), no real evening→floor descent (so ONLY
    ///                            `markLeadInWakeOnset`, not `markDescentOnsetAwake`, can catch it)
    ///   [28..108)  sleep1      — 80 real asleep epochs (floor HR) — the consolidated bout behind
    ///                            the rescue and the guard behind lead-in
    ///   [108..111) getup       — real motion, genuinely awake (never rescuable)
    ///   [111..131) secondbout  — motion-free, HR 72 (floor+22, inside the [+18,+25) rescue band)
    ///   [131..191) sleep2      — 60 real asleep epochs closing the night
    private func fixture() -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c = base
        func add(_ n: Int, hr: UInt8) { for _ in 0..<n { recs.append(vrec(c, hr: hr)); c += step } }
        add(14, hr: 50)     // quietA
        add(14, hr: 95)     // leadin
        add(80, hr: 50)     // sleep1
        for _ in 0..<3 { recs.append(arec(c)); c += step }   // getup
        add(20, hr: 72)     // secondbout
        add(60, hr: 50)     // sleep2
        return recs
    }

    /// Epoch index -> counter, matching the Python probe's `(counter - base) // step`.
    private func counter(_ index: Int) -> UInt32 { base + UInt32(index) * step }
    private func date(_ index: Int) -> Date {
        Date(timeIntervalSince1970: Double(Int(counter(index)) + Command.syncEpoch))
    }

    private func stage(_ segs: [SleepSegment], at index: Int) -> SleepStage? {
        // `.inBed` tiles the FULL span underneath every other segment (SleepStaging.swift:897) —
        // skip it so this matches the more specific awake/asleep segment, same as the hypnogram
        // chart's own `stagedSegments` filter (SleepStagesSection.swift).
        let d = date(index)
        return segs.first { $0.stage != .inBed && $0.start <= d && d < $0.end }?.stage
    }

    /// Established by running this exact byte sequence through both `SleepStaging.classify` (here)
    /// and `classify_prepared` (`parity_probe2.py`) and recording where they agreed: AWAKE at
    /// quietA+leadin (lead-in pushes onset past the elevated block, taking the quiet run with it)
    /// and at getup (real motion); ASLEEP everywhere else, including all of secondbout (rescued).
    private var expectedAwakeIndices: Set<Int> { Set(0..<28).union(108..<111) }

    func testSwiftMatchesThePythonPortOnTheSharedFixture() {
        let segs = SleepStaging.classify(from: fixture())
        var mismatches: [String] = []
        for i in 0..<191 {
            let expectAwake = expectedAwakeIndices.contains(i)
            let got = stage(segs, at: i)
            let gotAwake = got == .awake
            if gotAwake != expectAwake {
                mismatches.append("epoch \(i): expected \(expectAwake ? "awake" : "asleep"), got \(String(describing: got))")
            }
        }
        XCTAssertTrue(mismatches.isEmpty, "Swift/Python parity fixture diverged:\n" + mismatches.joined(separator: "\n"))
    }

    /// Cheaper regression guard once the per-epoch check above is green: the exact awake-minute
    /// total, so a future change that shifts the SET but not the COUNT still trips something.
    func testAwakeMinuteTotalMatchesTheFixture() {
        let segs = SleepStaging.classify(from: fixture())
        let awakeMinutes = SleepStaging.summary(segs).minutes.awake
        let expectedMinutes = Int((Double(expectedAwakeIndices.count) * Double(step) / 60).rounded())
        XCTAssertEqual(awakeMinutes, expectedMinutes)
    }
}
