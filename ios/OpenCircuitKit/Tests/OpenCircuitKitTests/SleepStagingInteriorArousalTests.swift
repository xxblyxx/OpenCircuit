import XCTest
@testable import OpenCircuitKit

// Tests for `SleepStaging.markInteriorArousals` / `Tuning.arousalIntensityCut` — the fix in
// docs/SLEEP_INTERIOR_AROUSALS.md. Read that plan before changing this file; each test below maps
// to one of its §2.4 numbered cases.
//
// FIXTURE SHAPE: every night here is built ENTIRELY on the intensity-tail fallback path — flat
// `[1,1,1,1,1]` primary motion (a placeholder on every record) and flat HR at 50 bpm, well below
// any wake threshold, so NEITHER the primary motion gate NOR the HR gate ever marks anything awake
// on their own. That isolates the new pass completely: any `.awake` segment in these fixtures'
// output can only be `markInteriorArousals`'s doing. A small nonzero tail sum (5) is seeded on
// every epoch so `BulkSleep.motionSource` sees >= 2 non-zero tail epochs and actually engages the
// fallback (`.intensityTail`), matching a real degenerate-primary night.
final class SleepStagingInteriorArousalTests: XCTestCase {

    private let step: UInt32 = 150
    private let base: UInt32 = 10_000

    private func counter(_ index: Int) -> UInt32 { base + UInt32(index) * step }
    private func date(_ index: Int) -> Date {
        Date(timeIntervalSince1970: Double(Int(counter(index)) + Command.syncEpoch))
    }

    /// Fills a 5-byte tail with `sum`, spread across bytes (each capped at 255) — the raw
    /// `[15:20]` shape `motionIntensityTailSums` reads.
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

    /// A sleep-vitals epoch with flat placeholder primary motion (`[10:15]` all `1`s, so
    /// `motionIsPlaceholder` is true) and a caller-chosen `[15:20]` tail sum.
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

    /// A sleep-vitals epoch with EXPRESSIVE (non-placeholder) primary motion and a zero tail —
    /// the `.primary` motion-source shape, for the gate-off test.
    private func mvrec(_ counter: UInt32, hr: UInt8, moving: Bool) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x62
        let pattern: [UInt8] = moving ? [12, 30, 8, 25, 17] : [1, 1, 1, 1, 1]
        for k in 0..<5 { b[10 + k] = pattern[k] }
        // tail left at all-zero (unset) -- fewer than 2 non-zero tail epochs, so `motionSource`
        // never even considers the fallback regardless of the primary channel's own verdict.
        return BulkRecord(b)!
    }

    /// A 60-epoch (2.5 h) flat-HR (50 bpm, well below any wake threshold) night on the
    /// intensity-tail fallback path. Every epoch carries a small baseline tail sum (5) so the
    /// fallback engages; `arousalIndex`, when given, gets `arousalTailSum` instead.
    private func night(arousalIndex: Int? = nil, arousalTailSum: Int = 0, count: Int = 60) -> [BulkRecord] {
        (0..<count).map { i in
            let sum = (i == arousalIndex) ? arousalTailSum : 5
            return tvrec(counter(i), hr: 50, tailSum: sum)
        }
    }

    private func stage(_ segs: [SleepSegment], at index: Int) -> SleepStage? {
        let d = date(index)
        return segs.first { $0.stage != .inBed && $0.start <= d && d < $0.end }?.stage
    }

    // MARK: 1. The pass adds an interior awakening

    func testInteriorArousalBecomesAwake() {
        let records = night(arousalIndex: 30, arousalTailSum: 250)
        let segs = SleepStaging.classify(from: records)
        XCTAssertEqual(stage(segs, at: 30), .awake,
                       "an epoch whose tail sum clears arousalIntensityCut must stage awake")
    }

    // MARK: 2. Onset/final wake never move -- the load-bearing test

    func testOnsetAndFinalWakeAreUnchanged() {
        let records = night(arousalIndex: 30, arousalTailSum: 250)
        let on = SleepStaging.classify(from: records)                                    // default cut
        let off = SleepStaging.classify(from: records, tuning: .init(arousalIntensityCut: 0))
        XCTAssertEqual(SleepStaging.sleepWindow(on)?.onset, SleepStaging.sleepWindow(off)?.onset,
                       "the interior pass must never move sleep onset")
        XCTAssertEqual(SleepStaging.sleepWindow(on)?.wake, SleepStaging.sleepWindow(off)?.wake,
                       "the interior pass must never move final wake")
    }

    // MARK: 3. Edge epochs (at lo/hi themselves) are exempt

    func testEdgeEpochsAboveCutAreNotAdded() {
        var records = night()
        let lastIndex = records.count - 1
        // Arousal-strength tail sums AT the very first and last epoch. `sleepSpan` is computed
        // BEFORE this pass runs, over an `awake` array these fixtures guarantee is all-false, so
        // it resolves lo=0, hi=lastIndex regardless of what's placed there -- these ARE lo and hi.
        records[0] = tvrec(counter(0), hr: 50, tailSum: 250)
        records[lastIndex] = tvrec(counter(lastIndex), hr: 50, tailSum: 250)
        let segs = SleepStaging.classify(from: records)
        XCTAssertEqual(SleepStaging.sleepWindow(segs)?.onset, date(0),
                       "onset must still be the very first epoch despite its high tail sum")
        XCTAssertNotEqual(stage(segs, at: 0), .awake, "the epoch AT onset must not be marked awake")
        XCTAssertNotEqual(stage(segs, at: lastIndex), .awake, "the epoch AT final wake must not be marked awake")
    }

    // MARK: 4. Kill switch is byte-identical

    func testKillSwitchIsByteIdentical() {
        let withArousal = night(arousalIndex: 30, arousalTailSum: 250)
        let flat = night()
        let off1 = SleepStaging.classify(from: withArousal, tuning: .init(arousalIntensityCut: 0))
        let off2 = SleepStaging.classify(from: flat, tuning: .init(arousalIntensityCut: 0))
        XCTAssertEqual(off1, off2,
                       "arousalIntensityCut == 0 must ignore the arousal-strength tail sum entirely")
    }

    // MARK: 5. A primary-channel (non-fallback) night is untouched

    func testPrimaryChannelNightIsUntouched() {
        var records: [BulkRecord] = []
        var c = base
        for i in 0..<60 {
            records.append(mvrec(c, hr: 50, moving: i % 10 == 0))
            c += step
        }
        let on = SleepStaging.classify(from: records)   // default (non-zero) cut
        let off = SleepStaging.classify(from: records, tuning: .init(arousalIntensityCut: 0))
        XCTAssertEqual(on, off, "a primary-channel night must be unaffected by arousalIntensityCut")
    }

    // MARK: 6. The metric built for this actually observes it

    func testArousalCountMovesTheMetric() {
        let records = night(arousalIndex: 30, arousalTailSum: 250)
        let segs = SleepStaging.classify(from: records)
        XCTAssertGreaterThan(SleepAwakenings.from(segments: segs).count, 0,
                             "the new interior arousal must be visible to SleepAwakenings")
    }

    // MARK: Multiple arousals -- not in the plan's list, but a natural extension of #1/#6

    func testMultipleInteriorArousalsAreAllCounted() {
        var records = night()
        records[15] = tvrec(counter(15), hr: 50, tailSum: 250)
        records[35] = tvrec(counter(35), hr: 50, tailSum: 250)
        records[45] = tvrec(counter(45), hr: 50, tailSum: 250)
        let segs = SleepStaging.classify(from: records)
        XCTAssertEqual(SleepAwakenings.from(segments: segs).count, 3)
    }

    // MARK: Regression -- the shape that shipped inert (2026-08-15)

    /// A genuinely-expressive-primary "getting up" epoch, with elevated HR and zero tail (a real
    /// getting-up epoch clears BOTH the motion and HR gates on the primary channel -- unlike the
    /// tail-fallback arousals this pass targets, which the primary channel can't see at all).
    private func mvrecMoving(_ counter: UInt32, hr: UInt8 = 70) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[8] = 0x62
        let pattern: [UInt8] = [40, 60, 20, 55, 35]
        for k in 0..<5 { b[10 + k] = pattern[k] }
        return BulkRecord(b)!
    }

    /// 🟢 THE BUG THAT SHIPPED INERT (2026-08-15): a real night measured this exact shape. The
    /// sleep INTERIOR is 100% dead-primary (placeholder throughout), but a HANDFUL of genuinely
    /// expressive primary-motion epochs at the very tail of the in-bed block -- the wearer getting
    /// up -- flipped the WHOLE-BLOCK `motionSource` verdict to `.primary`, disabling the pass
    /// entirely even though the interior itself never had a usable primary signal
    /// (`BulkSleep.swift:462-466` already documents this exact failure mode). This is the test
    /// that would have caught the ship, and it must never regress silently: the premise assertion
    /// fails loudly if the fixture stops reproducing a block-level `.primary` verdict.
    func testGettingUpMotionDoesNotDisableTheInteriorPass() {
        var records = night(arousalIndex: 30, arousalTailSum: 250, count: 60)
        var c = counter(60)
        for _ in 0..<3 {
            records.append(mvrecMoving(c))
            c += step
        }

        // Premise: the WHOLE-BLOCK verdict really is .primary -- proving this fixture reproduces
        // the real failure mode, not a different one.
        XCTAssertFalse(BulkSleep.usesMotionIntensityFallback(records),
                       "premise failed -- the fixture must make the WHOLE block read .primary, "
                       + "exactly as the real night did")

        let segs = SleepStaging.classify(from: records)
        XCTAssertEqual(stage(segs, at: 30), .awake,
                       "an interior arousal must still be detected even though the block's OWN "
                       + "getting-up tail flips the whole-block motion-source verdict to .primary")
    }
}
