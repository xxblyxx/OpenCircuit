import XCTest
@testable import OpenCircuitKit

// SYNTHETIC-ONLY tests for the sleep-stage classifier. We have no per-epoch ground
// truth (the ring sends no hypnogram, §5.3), so these build controlled epoch
// sequences with a known intended stage and assert the classifier recovers it, plus
// one "constructed night" that checks the stage totals partition the night the way
// the RingConn app's night totals do (light ≫ rem > deep, modest awake).
final class SleepStagingTests: XCTestCase {

    /// Locks the user-ground-truthed quiet-wake onset calibration. The behavioural wind-down tests
    /// below guard its safety properties; this assertion prevents an unnoticed default rollback.
    func testQuietWakeOnsetCalibration() {
        XCTAssertEqual(SleepStaging.Tuning.default.onsetSettleFraction, 0.60)
    }

    // MARK: - Record builders

    /// A sleep-vitals epoch (sub 0x62) with explicit HR/HRV and a uniform motion byte.
    private func vrec(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 0, motion: UInt8 = 1) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// A sleep-vitals epoch that ALSO sets the respiratory-rate byte `[7] = rr*8`, so
    /// `BulkRecord.respiratoryRate` (raw[7]/8) decodes. The plain `vrec` leaves `[7] = 0`
    /// (RR = nil); this variant is for the RR-fusion tests. `rr` must be ≤ 31 (rr*8 ≤ 248).
    private func vrecRR(_ counter: UInt32, hr: UInt8, hrv: UInt8 = 0, motion: UInt8 = 1,
                        rr: Double) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[4] = hr; b[5] = hrv; b[7] = UInt8((rr * 8).rounded()); b[8] = 0x62
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    /// An active/awake epoch (sub 0x12, high motion, no vitals).
    private func arec(_ counter: UInt32, motion: UInt8 = 0x14) -> BulkRecord {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = UInt8(counter >> 24); b[1] = UInt8((counter >> 16) & 0xFF)
        b[2] = UInt8((counter >> 8) & 0xFF); b[3] = UInt8(counter & 0xFF)
        b[8] = 0x12
        for k in 0..<5 { b[10 + k] = motion }
        return BulkRecord(b)!
    }

    private let step: UInt32 = 150

    /// Fraction of asleep (non-inBed, non-awake) time spent in `stage`.
    private func fraction(_ segs: [SleepSegment], _ stage: SleepStage) -> Double {
        let totals = SleepStaging.stageTotals(segs)
        let asleep = (totals[.asleepCore] ?? 0) + (totals[.asleepDeep] ?? 0) + (totals[.asleepREM] ?? 0)
        guard asleep > 0 else { return 0 }
        return (totals[stage] ?? 0) / asleep
    }

    // MARK: - Sleep-vitals rescue reaches the STAGED (summary/Health) path

    /// Builds a still 6h night followed by a ~100-min restless-but-asleep morning: HR stays at the
    /// sleeping level and the ring keeps emitting sleep-vitals, but motion spikes (a still sleep-vitals
    /// epoch alternating with a high-motion activity epoch) so the motion detector alone scores the
    /// morning "active". This exercises `SleepStaging.classify` — the path that feeds the summary card
    /// and Apple Health — NOT just the coarse `detectFromMotion` layer.
    private func stillThenRestlessMorning(morningHR: UInt8, morningVitals: Bool) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 10_000
        for _ in 0..<144 { recs.append(vrec(c, hr: 55, hrv: 60, motion: 1)); c += step }   // 6h still sleep
        for i in 0..<40 {                                                                    // ~100-min morning
            if i % 2 == 0 { recs.append(vrec(c, hr: morningHR, hrv: morningVitals ? 60 : 0, motion: 2)) }
            else          { recs.append(arec(c, motion: 60)) }                               // spiky motion
            c += step
        }
        return recs
    }
    private func asleepMinutes(_ segs: [SleepSegment]) -> Double {
        let t = SleepStaging.stageTotals(segs)
        return ((t[.asleepCore] ?? 0) + (t[.asleepDeep] ?? 0) + (t[.asleepREM] ?? 0)) / 60
    }

    /// The fix reaches the summary: a moving-but-asleep morning (low HR, sleep-vitals present) is
    /// counted as sleep by the STAGED classifier, not re-trimmed back to awake-in-bed. Regression guard
    /// for the 2026-07-04 truncated night (5h44m → real 7h32m). The 6h still block alone is ~360 min, so
    /// asleep well past that proves the restless morning is honored end-to-end.
    func testStagedClassifierHonorsMovingButAsleepMorning() {
        let segs = SleepStaging.classify(from: BulkSleep.latestNightRecords(
            from: stillThenRestlessMorning(morningHR: 55, morningVitals: true)))
        XCTAssertGreaterThan(asleepMinutes(segs), 400,
                             "staged summary must count the moving-but-asleep morning, not trim it off")
    }

    /// Guard: a genuine morning WAKE (HR climbs above the sleeping floor + margin) is NOT counted, even
    /// with the same spiky motion — the staged softening is HR-gated, so it can't over-count wakefulness.
    func testStagedClassifierDoesNotCountElevatedHRMorning() {
        let asleepWake = asleepMinutes(SleepStaging.classify(from: BulkSleep.latestNightRecords(
            from: stillThenRestlessMorning(morningHR: 95, morningVitals: true))))
        XCTAssertLessThan(asleepWake, 380, "an elevated-HR (awake) morning must not be counted as sleep")
    }

    /// Guard: no sleep-vitals in the morning (ring stopped measuring = awake) → the morning is NOT
    /// counted, so a low-HR-but-awake lie-in isn't over-counted on motion+HR alone.
    func testStagedClassifierRequiresSleepVitalsToCountRestlessMorning() {
        let asleepNoVitals = asleepMinutes(SleepStaging.classify(from: BulkSleep.latestNightRecords(
            from: stillThenRestlessMorning(morningHR: 55, morningVitals: false))))
        XCTAssertLessThan(asleepNoVitals, 380, "without sleep-vitals coverage the restless morning stays awake")
    }

    /// A 6h still night with a ~40-min restless-but-low-HR episode in the MIDDLE (sustained sleep on
    /// BOTH sides) — the same spiky-motion + lingering-sleep-vitals shape as `stillThenRestlessMorning`,
    /// only its POSITION differs. A genuine mid-night WASO the rescue must NOT absorb.
    private func stillWithMidNightRestless(episodeHR: UInt8, episodeVitals: Bool) -> [BulkRecord] {
        var recs: [BulkRecord] = []
        var c: UInt32 = 10_000
        for _ in 0..<72 { recs.append(vrec(c, hr: 55, hrv: 60, motion: 1)); c += step }   // 3h still sleep
        for i in 0..<16 {                                                                   // ~40-min episode
            if i % 2 == 0 { recs.append(vrec(c, hr: episodeHR, hrv: episodeVitals ? 60 : 0, motion: 2)) }
            else          { recs.append(arec(c, motion: 60)) }                              // spiky motion
            c += step
        }
        for _ in 0..<72 { recs.append(vrec(c, hr: 55, hrv: 60, motion: 1)); c += step }   // 3h still sleep
        return recs
    }

    /// The reviewer's watch-item: the morning-tail rescue is SCOPED to the trailing tail, so a mid-night
    /// restless-but-low-HR episode surrounded by sustained sleep is still detected as WASO — not absorbed
    /// as sleep the way an un-scoped (whole-night) softening would. The proof is positional: the mid-night
    /// episode is IMMUNE to the softening knob (halfWindow 3 vs 0 stage identically), whereas the SAME
    /// shape at the morning tail IS rescued by it — so the softening still works, it just no longer reaches
    /// interior awakenings.
    func testMidNightWASOIsImmuneToTheRescueButTheMorningTailIsNot() {
        func asleep(_ recs: [BulkRecord], halfWindow: Int) -> Double {
            asleepMinutes(SleepStaging.classify(
                from: BulkSleep.latestNightRecords(from: recs),
                tuning: .init(motionAwakeVitalsHalfWindow: halfWindow)))
        }
        let mid = stillWithMidNightRestless(episodeHR: 55, episodeVitals: true)
        XCTAssertEqual(asleep(mid, halfWindow: 3), asleep(mid, halfWindow: 0), accuracy: 5,
                       "a mid-night WASO is interior, so the trailing-tail rescue must not change it")

        let morning = stillThenRestlessMorning(morningHR: 55, morningVitals: true)
        XCTAssertGreaterThan(asleep(morning, halfWindow: 3), asleep(morning, halfWindow: 0) + 20,
                             "the morning tail must still be rescued when the softening is on")
    }

    // MARK: - Single-stage recovery

    func testStillFlatLowHRIsMostlyDeep() {
        // A calm night: flat low HR, no motion -> should read as predominantly Deep.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }   // flat, still, low
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        XCTAssertGreaterThan(fraction(segs, .asleepDeep), 0.8, "calm flat low HR -> mostly Deep")
        XCTAssertEqual(fraction(segs, .asleepREM), 0.0, "no variability/elevation -> no REM")
    }

    func testElevatedFlatHRLowMotionIsREM() {
        // Deep baseline + a clearly elevated, still block -> elevated block is REM.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<100 { recs.append(vrec(c, hr: 50)); c += step }          // Deep baseline
        let remStart = c
        for _ in 0..<40 { recs.append(vrec(c, hr: 66)); c += step }           // elevated, still
        let remEnd = c
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        XCTAssertGreaterThan(fraction(segs, .asleepREM), 0.2, "elevated still block -> REM present")
        // The bulk of REM should sit in the elevated window (a couple boundary epochs
        // may bleed in due to transition variability — tolerate ±2 epochs).
        let lo = Date(timeIntervalSince1970: Double(Int(remStart) + Command.syncEpoch))
            .addingTimeInterval(-2 * Double(step))
        let hi = Date(timeIntervalSince1970: Double(Int(remEnd) + Command.syncEpoch))
            .addingTimeInterval(2 * Double(step))
        let remSegs = segs.filter { $0.stage == .asleepREM }
        let remTotal = remSegs.reduce(0.0) { $0 + $1.duration }
        let remInWindow = remSegs.filter { $0.start >= lo && $0.end <= hi }.reduce(0.0) { $0 + $1.duration }
        XCTAssertGreaterThan(remTotal, 0)
        XCTAssertGreaterThanOrEqual(remInWindow / remTotal, 0.8, "REM concentrates in the elevated window")
    }

    func testVariabilitySeparatesREMFromLightAtSameMeanHR() {
        // Two still blocks with the SAME mean HR (58): one flat, one oscillating.
        // Variability — not absolute HR — must put the oscillating one in REM.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        let flatStart = c
        for _ in 0..<100 { recs.append(vrec(c, hr: 55)); c += step }          // flat
        let varStart = c
        // 2-epoch steps so runs survive smoothing; mean 55, swings ±10.
        for k in 0..<40 { recs.append(vrec(c, hr: (k / 2) % 2 == 0 ? 45 : 65)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        let varLo = Date(timeIntervalSince1970: Double(Int(varStart) + Command.syncEpoch))
        let flatLo = Date(timeIntervalSince1970: Double(Int(flatStart) + Command.syncEpoch))
        let remInVar = segs.filter { $0.stage == .asleepREM && $0.start >= varLo }
            .reduce(0.0) { $0 + $1.duration }
        let remInFlat = segs.filter { $0.stage == .asleepREM && $0.start >= flatLo && $0.start < varLo }
            .reduce(0.0) { $0 + $1.duration }
        XCTAssertGreaterThan(remInVar, 0, "variable block reads as REM")
        XCTAssertGreaterThan(remInVar, remInFlat, "REM concentrates in the variable block, not the flat one")
    }

    func testHighMotionMidSleepIsAwake() {
        // A burst of motion inside the night must surface as an Awake segment.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<60 { recs.append(vrec(c, hr: 52)); c += step }
        let wakeStart = c
        for _ in 0..<3 { recs.append(arec(c, motion: 0x16)); c += step }     // mid-sleep movement
        for _ in 0..<60 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        let awake = segs.filter { $0.stage == .awake }
        XCTAssertFalse(awake.isEmpty, "mid-sleep motion -> Awake segment")
        let wt = Date(timeIntervalSince1970: Double(Int(wakeStart) + Command.syncEpoch))
        XCTAssertTrue(awake.contains { abs($0.start.timeIntervalSince(wt)) < Double(step) * 4 },
                      "awake segment aligns with the motion burst")
        // Awake stays inside the inBed window.
        let inBed = segs.first { $0.stage == .inBed }!
        for a in awake {
            XCTAssertGreaterThanOrEqual(a.start, inBed.start)
            XCTAssertLessThanOrEqual(a.end, inBed.end)
        }
    }

    // MARK: - SpO2 + respiratory-rate fusion (additive; default-inert)

    /// The new `rrVarWeight` knob defaults to 0, so the classifier output for ANY night —
    /// even one carrying respiratory-rate readings — must be byte-identical with the default
    /// tuning vs. an explicit `Tuning(rrVarWeight: 0)`. This is the safety property that
    /// guarantees the RR feature regresses nothing until it is deliberately fit.
    func testRrVarWeightZeroIsNoOp() {
        // Build a night WITHOUT RR (vrec, raw[7]=0) and the IDENTICAL night WITH RR injected
        // (vrecRR) — same HR/HRV/motion/SpO2. At the default tuning (rrVarWeight 0) RR carriage
        // must not change a SINGLE segment. This proves the feature is genuinely inert (the RR
        // values flow through the rows but never reach a decision), not merely that 0 == 0.
        func night(rr: Bool) -> [BulkRecord] {
            var recs: [BulkRecord] = []
            var c: UInt32 = 0x0c220000
            for _ in 0..<12 { recs.append(arec(c)); c += step }
            for k in 0..<140 {
                let hr: UInt8 = k % 3 == 0 ? 52 : 58
                recs.append(rr ? vrecRR(c, hr: hr, hrv: 55, rr: k % 2 == 0 ? 13 : 18)
                               : vrec(c, hr: hr, hrv: 55))
                c += step
            }
            for _ in 0..<12 { recs.append(arec(c)); c += step }
            return recs
        }
        let withoutRR = SleepStaging.classify(from: night(rr: false))
        let withRR = SleepStaging.classify(from: night(rr: true))
        XCTAssertFalse(withRR.isEmpty)
        XCTAssertEqual(withoutRR, withRR,
                       "RR carriage is inert at the default rrVarWeight (0): output is byte-identical with vs without RR")
        // And an explicit Tuning(rrVarWeight: 0) matches the default.
        XCTAssertEqual(withRR, SleepStaging.classify(from: night(rr: true),
                                                     tuning: SleepStaging.Tuning(rrVarWeight: 0)))
    }

    /// Respiratory-rate variability is a REM cue, mirroring the HRV term. A flat-HR /
    /// flat-HRV block whose ONLY variable signal is respiratory rate must NOT read as REM
    /// at the default (rrVarWeight = 0), but SHOULD gain REM once rrVarWeight is raised.
    /// This proves RR is genuinely fused into the variability score (not merely carried).
    func testRrVariabilityAddsREMCue() {
        // deepHR (p42) < target HR (54) < remHR (p86), so the target is neither Deep- nor
        // REM-by-HR; the only thing that can push it to REM is its RR variability.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }                              // onset (awake)
        for _ in 0..<120 { recs.append(vrecRR(c, hr: 50, hrv: 50, rr: 15)); c += step }  // low, flat (Deep)
        let tStart = c
        for k in 0..<16 {                                                                // FLAT HR/HRV, OSC RR
            recs.append(vrecRR(c, hr: 54, hrv: 50, rr: k % 2 == 0 ? 10 : 22)); c += step
        }
        let tEnd = c
        for _ in 0..<80 { recs.append(vrecRR(c, hr: 58, hrv: 50, rr: 15)); c += step }   // high, flat (light/REM-by-HR)
        for _ in 0..<12 { recs.append(arec(c)); c += step }                              // offset (awake)

        let lo = Date(timeIntervalSince1970: Double(Int(tStart) + Command.syncEpoch))
        let hi = Date(timeIntervalSince1970: Double(Int(tEnd) + Command.syncEpoch))
        func remInTarget(_ w: Double) -> Double {
            let segs = SleepStaging.classify(from: recs,
                                             tuning: SleepStaging.Tuning(rrVarWeight: w))
            return segs.filter { $0.stage == .asleepREM }.reduce(0.0) { acc, s in
                acc + max(0, min(s.end, hi).timeIntervalSince(max(s.start, lo)))
            }
        }

        let remOff = remInTarget(0)
        let remOn = remInTarget(1.0)
        XCTAssertEqual(remOff, 0, accuracy: 0.001,
                       "with rrVarWeight:0 the flat-HR/flat-HRV block carries no REM")
        XCTAssertGreaterThan(remOn, 0,
                             "raising rrVarWeight turns the RR-variable block into REM")
        XCTAssertGreaterThan(remOn, remOff, "RR variability adds a REM cue the HR-only model misses")
    }

    // MARK: - HR-aware onset/offset ("still but awake") — the screenshot fix

    /// A long, STILL block of elevated HR before real sleep (e.g. lying in bed awake)
    /// must NOT be counted as ASLEEP — but it IS time in bed, so under RingConn's
    /// two-window model it is kept as AWAKE-IN-BED, not trimmed out of the in-bed window.
    /// inBed spans the full bedtime window (pre-sleep included), the core stays the only
    /// asleep time, and efficiency = asleep / time-in-bed drops below 1.0. This is the
    /// case motion alone misses (no movement → "still" → falsely asleep).
    func testStillButElevatedHRPreSleepCountedAsAwakeInBedNotTrimmed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        let preStart = c
        let preEpochs = 40
        for _ in 0..<preEpochs { recs.append(vrec(c, hr: 78)); c += step }   // still but AWAKE (high HR)
        let onset = c
        for _ in 0..<120 { recs.append(vrec(c, hr: 54)); c += step }          // real sleep core
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // morning (motion-active)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let inBed = segs.first { $0.stage == .inBed }!
        let preStartDate = Date(timeIntervalSince1970: Double(Int(preStart) + Command.syncEpoch))
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        // (a) in-bed spans the FULL bedtime window: it starts at the FIRST epoch (pre-sleep
        // included), NOT the trimmed onset.
        XCTAssertEqual(inBed.start.timeIntervalSince(preStartDate), 0, accuracy: Double(step) * 2,
                       "in-bed spans the full bedtime window, pre-sleep included")
        // (b) the key invariant: the pre-sleep block is STILL not asleep — asleep ≈ the core.
        let s = SleepStaging.summary(segs)
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "asleep reflects the real core, not the pre-sleep wake")
        // (c) the pre-sleep span surfaces as AWAKE-IN-BED (not dropped): an awake segment
        // starts at the first epoch and runs up to onset.
        let awakeSegs = segs.filter { $0.stage == .awake }
        XCTAssertTrue(awakeSegs.contains {
            abs($0.start.timeIntervalSince(preStartDate)) < Double(step) * 2 &&
            $0.end <= onsetDate.addingTimeInterval(Double(step) * 2)
        }, "pre-sleep wake-in-bed is an awake segment, not trimmed away")
        // (d) efficiency is now < 1 (it was 1.0 when pre-sleep was trimmed out of in-bed).
        XCTAssertLessThan(s.efficiency, 1.0, "in-bed wake pulls efficiency below 100%")
        // Partition holds: in-bed == asleep + awake.
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step))
    }

    /// Two-window model end to end: still-but-awake time in bed BEFORE onset and AFTER
    /// final wake, bracketing a sleep core. All three are time-IN-BED; only the core is
    /// asleep, so efficiency = asleep / time-in-bed lands in a plausible 0.6–0.8 band and
    /// in-bed partitions exactly into asleep + awake (pre + post wake both counted).
    func testStillAwakePrePostSleepGivesPlausibleEfficiency() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // up, before bed (outside block)
        let bedStart = c
        for _ in 0..<30 { recs.append(vrec(c, hr: 78)); c += step }           // in bed, awake, still
        for _ in 0..<120 { recs.append(vrec(c, hr: 54)); c += step }          // asleep core
        for _ in 0..<30 { recs.append(vrec(c, hr: 78)); c += step }           // awake in bed, still
        let bedEnd = c
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // got up (outside block)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let s = SleepStaging.summary(segs)

        // Only the 120-epoch core counts as asleep; the 60 still-but-awake epochs do not.
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "only the core counts as asleep, not the still-but-awake tails")
        // efficiency = asleep / time-in-bed ≈ 120 / 180 = 0.67.
        XCTAssertGreaterThan(s.efficiency, 0.6, "efficiency includes in-bed wake → < 1")
        XCTAssertLessThan(s.efficiency, 0.8, "two awake tails pull efficiency down to ~0.67")
        // In-bed partitions exactly into asleep + awake.
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step))
        // In-bed spans the full bedtime window (both still-awake tails).
        let inBed = segs.first { $0.stage == .inBed }!
        let bedStartDate = Date(timeIntervalSince1970: Double(Int(bedStart) + Command.syncEpoch))
        let bedEndDate = Date(timeIntervalSince1970: Double(Int(bedEnd) + Command.syncEpoch))
        XCTAssertEqual(inBed.start.timeIntervalSince(bedStartDate), 0, accuracy: Double(step) * 2,
                       "in-bed starts at bedtime, not onset")
        XCTAssertEqual(inBed.end.timeIntervalSince(bedEndDate), 0, accuracy: Double(step) * 2,
                       "in-bed ends at final get-up, not last-asleep")
        // Both a pre-sleep and a post-wake awake-in-bed segment exist.
        XCTAssertGreaterThanOrEqual(segs.filter { $0.stage == .awake }.count, 2,
                                    "pre- and post-sleep wake-in-bed both present")
    }

    /// A sustained HR elevation in the MIDDLE of sleep with NO motion (lying still, eyes
    /// open) must surface as Awake. Pure-motion staging misses this — it's why a real
    /// ~1-hour morning wake was reported as ~10 min.
    func testInteriorSustainedHRWakeWithoutMotionIsAwake() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<60 { recs.append(vrec(c, hr: 54)); c += step }
        let wakeStart = c
        for _ in 0..<10 { recs.append(vrec(c, hr: 80)); c += step }           // still but AWAKE, 25 min
        for _ in 0..<60 { recs.append(vrec(c, hr: 54)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        let awake = segs.filter { $0.stage == .awake }
        XCTAssertFalse(awake.isEmpty, "sustained mid-sleep HR elevation -> Awake, even with no motion")
        let wt = Date(timeIntervalSince1970: Double(Int(wakeStart) + Command.syncEpoch))
        XCTAssertTrue(awake.contains { abs($0.start.timeIntervalSince(wt)) < Double(step) * 4 },
                      "awake segment aligns with the HR elevation")
        // It stays interior (sleep resumes after), so onset is before and offset after it.
        let inBed = segs.first { $0.stage == .inBed }!
        for a in awake { XCTAssertLessThan(a.end, inBed.end) }
    }

    // MARK: - Descent-relative onset trim (the "mild wind-down" fix)

    /// The case the FIXED `wakeHRMarginBPM` gate misses: HR drifting DOWN through a calm,
    /// still wind-down that never rises a full 18 bpm above the floor (e.g. 62 → 56 → 50).
    /// The old gate counted that whole stretch as asleep (efficiency pinned at ~100%); the
    /// descent-relative onset must mark it AWAKE-IN-BED instead, so asleep ≈ the real core
    /// and efficiency drops below 1. A control run with the trim disabled (huge
    /// `onsetMinDescentBPM`) shows the wind-down WOULD otherwise read as asleep.
    func testMildWindDownBelowFixedMarginIsTrimmedAsAwakeInBed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // before bed (outside block)
        let onset = { () -> UInt32 in
            for _ in 0..<12 { recs.append(vrec(c, hr: 62)); c += step }       // wind-down, still, < floor+18
            for _ in 0..<4  { recs.append(vrec(c, hr: 56)); c += step }       // settling
            let o = c
            for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }      // asleep core
            return o
        }()
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // morning (outside block)

        let segs = SleepStaging.classify(from: recs)
        let s = SleepStaging.summary(segs)
        // (a) asleep reflects the 120-epoch core, NOT the 16-epoch wind-down too.
        let coreMin = Double(120 * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), coreMin, accuracy: 30,
                       "mild wind-down is not counted as asleep")
        // (b) efficiency is now < 1 (the wind-down is awake-in-bed, not asleep).
        XCTAssertLessThan(s.efficiency, 0.95, "wind-down pulls efficiency below 100%")
        // (c) an awake-in-bed segment covers the pre-onset wind-down.
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        XCTAssertTrue(segs.contains { $0.stage == .awake && $0.end <= onsetDate.addingTimeInterval(Double(step) * 2) },
                      "the wind-down surfaces as awake-in-bed, ending at onset")
        // Control: with the descent gate disabled, the SAME wind-down reads as asleep (eff ~1).
        let disabled = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(onsetMinDescentBPM: 999))
        let sd = SleepStaging.summary(disabled)
        XCTAssertGreaterThan(sd.minutes.asleep, s.minutes.asleep,
                             "disabling the trim counts the wind-down as asleep (the old behavior)")
        XCTAssertGreaterThan(sd.efficiency, s.efficiency)
    }

    /// SAFETY 1 — descent gate. A night with NO real wind-down (flat HR from lights-out) must be
    /// BYTE-IDENTICAL with the trim on vs off: there is nothing to trim, so the calibrated split
    /// is untouched. This is what keeps the change inert on the nights it shouldn't touch.
    func testFlatNightIsByteIdenticalWithTrimOnVsOff() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        for k in 0..<140 { recs.append(vrec(c, hr: k % 3 == 0 ? 52 : 50, hrv: 55)); c += step }  // flat, calm
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let on = SleepStaging.classify(from: recs)                                       // default (trim on)
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(onsetMinDescentBPM: 999))
        XCTAssertEqual(on, off, "no wind-down (descent < gate) → trim is inert, output identical")
    }

    /// SAFETY 2 — bounded search. A night that stays elevated for HOURS and only settles past the
    /// onset search horizon must NOT be trimmed (we don't guess "awake until 2 a.m." from HR alone).
    /// The leading elevated stretch is left as-is rather than declared a multi-hour wake.
    func testLateSettleBeyondSearchWindowIsNotTrimmed() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        for _ in 0..<60 { recs.append(vrec(c, hr: 60)); c += step }    // 2.5 h elevated — beyond the 48-epoch search
        for _ in 0..<80 { recs.append(vrec(c, hr: 50)); c += step }    // settles only here
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let on = SleepStaging.classify(from: recs)
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(onsetMinDescentBPM: 999))
        // No onset found within the search window → identical to trim-off (no runaway leading wake).
        XCTAssertEqual(SleepStaging.summary(on).minutes.awake,
                       SleepStaging.summary(off).minutes.awake,
                       "a late settle past the search window is not trimmed (bounded, no runaway)")
    }

    // MARK: - Lead-in wake onset (the "lay still but awake for hours" fix)

    /// The 2026-06-26 screenshot night: the user lay still but AWAKE for hours before sleep, HR
    /// FLUCTUATING with a clearly-elevated (~90 bpm) block, then settled into sleep at a level the
    /// descent band never reaches within the search window. The fixed gate flags the 90-bpm block but
    /// leaves the short still dips before it reading as "asleep", so onset wrongly anchored to the
    /// FIRST dip (hours early, the "asleep 10:37 PM" bug). Onset must instead land AFTER the last
    /// pre-sleep wake block — the dips before it are awake-in-bed, not sleep.
    func testFragmentedPreSleepAnchorsOnsetAfterLastWakeBlock() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                    // before bed (outside block)
        let firstDip = c
        for _ in 0..<10 { recs.append(vrec(c, hr: 64)); c += step }            // brief still dip (pre-sleep, NOT real sleep)
        for _ in 0..<16 { recs.append(vrec(c, hr: 90)); c += step }            // clearly AWAKE (~90 bpm), still
        let afterWake = c
        for _ in 0..<40 { recs.append(vrec(c, hr: 60)); c += step }            // early light sleep, above the descent band
        for _ in 0..<100 { recs.append(vrec(c, hr: 52)); c += step }           // deep consolidated sleep (settles past the search window)
        for _ in 0..<8 { recs.append(arec(c)); c += step }                     // morning

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let firstDipDate = Date(timeIntervalSince1970: Double(Int(firstDip) + Command.syncEpoch))
        let afterWakeDate = Date(timeIntervalSince1970: Double(Int(afterWake) + Command.syncEpoch))
        // (a) onset is at/after the end of the wake block — NOT the first 64-bpm dip ~1 h earlier.
        XCTAssertGreaterThanOrEqual(win.onset, afterWakeDate.addingTimeInterval(-Double(step) * 2),
                                    "onset anchors after the last pre-sleep wake block, not the first still dip")
        XCTAssertGreaterThan(win.onset.timeIntervalSince(firstDipDate), Double(step) * 20,
                             "the fragmented pre-sleep (dip + wake block) is well before onset")
        // (b) control: with the lead-in rule off (consolidation guard 0 ⇒ never fires), onset
        // regresses to the early dip — proving the rule is what fixes it.
        let off = SleepStaging.classify(from: recs,
                                        tuning: SleepStaging.Tuning(minConsolidatedSleepEpochs: 0))
        guard let winOff = SleepStaging.sleepWindow(off) else { return XCTFail("no window (off)") }
        XCTAssertLessThan(winOff.onset, win.onset,
                          "without the lead-in rule, onset anchors earlier (the bug)")
    }

    /// GUARD: a night with REAL consolidated sleep before an early awakening must NOT have its onset
    /// pushed past that awakening — the lead-in rule only fires on a pre-sleep struggle (no sleep yet),
    /// never on a normal mid-night stir after the user is already asleep.
    func testConsolidatedSleepBeforeEarlyWakeKeepsOnsetEarly() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                     // before bed (outside block)
        let onset = c
        for _ in 0..<30 { recs.append(vrec(c, hr: 52)); c += step }            // real sleep (75 min) BEFORE the stir
        for _ in 0..<8 { recs.append(vrec(c, hr: 90)); c += step }             // early awakening (still asleep night)
        for _ in 0..<100 { recs.append(vrec(c, hr: 52)); c += step }           // back to sleep
        for _ in 0..<8 { recs.append(arec(c)); c += step }

        let segs = SleepStaging.classify(from: recs)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        // Onset stays at the FIRST sleep block (the 90-bpm stir is an interior awakening, not pre-sleep).
        XCTAssertEqual(win.onset.timeIntervalSince(onsetDate), 0, accuracy: Double(step) * 3,
                       "consolidated sleep before the stir keeps onset early — the stir is interior wake")
        let awake = segs.filter { $0.stage == .awake }
        XCTAssertFalse(awake.isEmpty, "the early awakening still surfaces as an interior awake segment")
    }

    // MARK: - Lead-in vitals-density onset (the "quiet-awake-on-a-phone" fix, 2026-08-20/21)

    /// Reproduces the grounding night: ~95 min at rest (HR flat, low, motion at floor) with SPARSE
    /// sleep-vitals coverage (the wearer awake, so the ring's optical read is dirtier / less frequent),
    /// followed by real sleep with DENSE sleep-vitals coverage. Neither HR (both stretches sit near the
    /// floor) nor motion (both still) can see the difference — this is the bug this pass exists for.
    /// `leadInEpochs` should be a multiple of `onsetSustainEpochs` (6, the default block size this
    /// pass scans in) so the lead-in's vitals pattern lands on a clean block boundary — otherwise a
    /// partial trailing block can alias to a different density than the rest of the lead-in.
    private func quietAwakeThenRealSleep(leadInVitalsEveryN: Int, sleepVitalsEveryN: Int,
                                         leadInEpochs: Int = 36, sleepEpochs: Int = 100)
        -> (recs: [BulkRecord], onset: UInt32) {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }             // before bed (outside block)
        for i in 0..<leadInEpochs {                                     // ~95 min quietly awake (HR 54-73 measured)
            recs.append(vrec(c, hr: 60, hrv: i % leadInVitalsEveryN == 0 ? 55 : 0)); c += step
        }
        let onset = c
        for i in 0..<sleepEpochs {                                      // real sleep: HR settles, vitals dense
            recs.append(vrec(c, hr: 52, hrv: i % sleepVitalsEveryN == 0 ? 55 : 0)); c += step
        }
        for _ in 0..<8 { recs.append(arec(c)); c += step }              // morning
        return (recs, onset)
    }

    /// THE FIX: with the pass enabled, onset is pushed past the quiet-awake lead-in (sparse vitals)
    /// to where real sleep (dense vitals) actually begins — even though HR alone never distinguishes
    /// the two stretches (both sit at/near the sleeping floor throughout).
    func testLeadInVitalsDensityPushesOnsetPastAQuietAwakeStretch() {
        // 1-in-6 (not 1-in-5): aligned to `onsetSustainEpochs`'s 6-epoch scan block so every block
        // of the lead-in has the SAME density (1/6 ≈ 0.167) — a 1-in-5 pattern aliases against a
        // 6-wide block boundary and lands some blocks at 2/6, which is a block-scan quantization
        // artifact of the TEST fixture, not a real failure mode (a real night's HRV emission isn't
        // periodic), so the fixture avoids it rather than the pass working around it.
        let (recs, onset) = quietAwakeThenRealSleep(leadInVitalsEveryN: 6, sleepVitalsEveryN: 2)
        let tuning = SleepStaging.Tuning(leadInVitalsAwakeRatio: 0.6)
        let segs = SleepStaging.classify(from: recs, tuning: tuning)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        XCTAssertEqual(win.onset.timeIntervalSince(onsetDate), 0, accuracy: Double(step) * 3,
                      "onset lands where sleep-vitals density picks up, not at the sparse-vitals lead-in")
    }

    /// Locks the vitals-density pass OFF (🔴 refuted 2026-08-21 by replaying the very night it was
    /// fitted on: it reaches 22:41 against a real 00:48, and widening the horizon does not help
    /// because the stop-on-first-non-thin-block rule is what binds). Superseded by the motion-onset
    /// pass below. Guards against an unnoticed re-enable; see the field's doc comment and
    /// `docs/PENDING_VALIDATION.md` → `lead-in-vitals-ratio-refit`.
    func testLeadInVitalsRatioShipsDisabled() {
        XCTAssertEqual(SleepStaging.Tuning.default.leadInVitalsAwakeRatio, 0)
    }

    /// SAFETY — `0` truly disables the pass: passing it explicitly must be byte-identical to a night
    /// with no vitals-density gap at all (the uniform-density fixture below), proving `0` is a real
    /// escape hatch and not just "a very strict cutoff".
    func testLeadInVitalsDensityRatioZeroDisablesThePass() {
        let (recs, _) = quietAwakeThenRealSleep(leadInVitalsEveryN: 6, sleepVitalsEveryN: 2)
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(leadInVitalsAwakeRatio: 0))
        let uniform = quietAwakeThenRealSleep(leadInVitalsEveryN: 2, sleepVitalsEveryN: 2).recs
        let uniformOff = SleepStaging.classify(from: uniform, tuning: SleepStaging.Tuning(leadInVitalsAwakeRatio: 0))
        // Not a direct equality (the two nights have different vitals bytes) — the properties that
        // must match are onset and total asleep, since `0` means the pass never looks at vitals at all.
        XCTAssertEqual(SleepStaging.sleepWindow(off)?.onset, SleepStaging.sleepWindow(uniformOff)?.onset,
                       "ratio 0 ignores vitals density entirely — a real density gap changes nothing")
    }

    /// SAFETY — a night with UNIFORM sleep-vitals density (no real awake/asleep density gap) must be
    /// left untouched: the pass only fires on a MATERIAL density gap, so an ordinary night's onset isn't
    /// disturbed by noise in when the ring happens to emit sleep-vitals.
    func testLeadInVitalsDensityUntouchedWhenDensityIsUniform() {
        let (recs, _) = quietAwakeThenRealSleep(leadInVitalsEveryN: 2, sleepVitalsEveryN: 2)
        let on = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(leadInVitalsAwakeRatio: 0.6))
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(leadInVitalsAwakeRatio: 0))
        XCTAssertEqual(on, off, "uniform vitals density (no real gap) → pass is inert, output identical")
    }

    /// SAFETY — a night with NO sleep-vitals coverage anywhere (rings that never emit HRV, or a stretch
    /// with zero HRV samples) must be untouched: absence of data is not evidence of wake, matching every
    /// other vitals-gated pass in this file.
    func testLeadInVitalsDensityNoOpWithoutAnyVitalsCoverage() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        for _ in 0..<38 { recs.append(vrec(c, hr: 60, hrv: 0)); c += step }
        for _ in 0..<100 { recs.append(vrec(c, hr: 52, hrv: 0)); c += step }
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let on = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(leadInVitalsAwakeRatio: 0.6))
        let off = SleepStaging.classify(from: recs, tuning: SleepStaging.Tuning(leadInVitalsAwakeRatio: 0))
        XCTAssertEqual(on, off, "no vitals coverage anywhere → nothing to judge against, pass is inert")
    }

    // MARK: - Lead-in MOTION onset (the "got up and did something" fix, 2026-08-20/21)

    /// Reproduces the shape of the grounding night, which no HR- or vitals-based pass can solve:
    /// ~90 min lying STILL and awake at resting HR (a phone), then ~55 min of real MOVEMENT (got up,
    /// worked at a computer), then real sleep. HR never separates the first stretch from the third —
    /// both sit at the sleeping floor — so onset must be anchored by where the MOVING stopped.
    /// The getting-up stretch is deliberately INTERMITTENT (moving epochs interleaved with brief still
    /// ones), matching the measured night: 🟢 on 2026-08-20/21 the desk trip read 91, 186, 76, 0, 0, 27,
    /// 14, 0, 36 … de-floored — a person at a computer is not in continuous motion. It also has to be
    /// this way for the fixture to be honest: a solid block of identical high motion lifts the rolling
    /// idle floor to its own level (`motionAboveLocalFloor` is RELATIVE by design, so a constant is
    /// always "still"), and a long enough solid block additionally splits the night in
    /// `mainSleepBlock`, so the staged night would no longer contain the lead-in at all.
    private func stillThenUpThenAsleep(motionEpochs: Int = 22) -> (recs: [BulkRecord], onset: UInt32) {
        var recs: [BulkRecord] = []
        // Anchored to a REAL overnight wall clock (21:40 local), not the arbitrary counter the older
        // fixtures use: `BulkSleep.latestNightRecords` applies an overnight-window rule, and a night
        // whose synthetic timestamps land in the afternoon gets scoped to the wrong block — which
        // silently removes the lead-in this fixture exists to exercise.
        var c: UInt32 = 209_493_600                                     // 2026-08-20 21:40:00 local
        for _ in 0..<8 { recs.append(arec(c)); c += step }              // before bed (outside block)
        for _ in 0..<36 { recs.append(vrec(c, hr: 60, hrv: 55)); c += step }   // still + AWAKE on a phone
        for i in 0..<motionEpochs {                                     // UP: real, intermittent movement
            // 4 moving : 1 still. The moving stretches must exceed `leadInMotionOnsetMinRun` (3) —
            // a 2:1 interleave yields only 2-epoch runs, which the pass correctly rejects as stirs.
            // The measured night has runs of this length (e.g. 91, 186, 76 consecutive).
            if i % 5 == 4 { recs.append(vrec(c, hr: 62, hrv: 0, motion: 1)) }   // a beat of stillness
            else          { recs.append(arec(c, motion: 90)) }
            c += step
        }
        let onset = c
        for _ in 0..<120 { recs.append(vrec(c, hr: 52, hrv: 60)); c += step }  // actually asleep
        for _ in 0..<8 { recs.append(arec(c)); c += step }              // morning
        return (recs, onset)
    }

    /// THE FIX: onset anchors after the last sustained motion run, NOT at the first quiet epoch of the
    /// still-but-awake lead-in — even though HR is identical in both stretches.
    func testLeadInMotionOnsetAnchorsAfterTheWearerStopsMoving() {
        let (recs, onset) = stillThenUpThenAsleep()
        let segs = SleepStaging.classify(from: recs)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        XCTAssertEqual(win.onset.timeIntervalSince(onsetDate), 0, accuracy: Double(step) * 3,
                       "onset lands where the moving stopped, not at the still-but-awake lead-in")
    }

    /// Drives the pass DIRECTLY on an awake mask, the way `markPointOfNoReturnOffset` and
    /// `erodeShortHRWake` are tested and for the same stated reason: on a SYNTHETIC night some other
    /// pass always reaches the answer first (a fabricated `arec` has a clean `[15:20]` tail, so
    /// `markEdgeMotionAwake` resolves a lead-in that on the REAL ring is buried in tail noise), so an
    /// end-to-end on/off comparison cannot isolate this pass's contribution. Its real-archive control
    /// is recorded instead: 🟢 replaying the 2026-08-20/21 night through `SleepStaging.classify` gives
    /// onset 00:41:36 with the pass on and 22:11:36 with `leadInMotionOnsetMinRun: 0`.
    ///
    /// Shape: a quiet head SHORTER than `minConsolidatedSleepEpochs` (so guard (d) reads "no real sleep
    /// yet" — the pre-onset lie-awake), one sustained motion run, then sleep. Only the pass under test
    /// can move onset here, because nothing in the mask itself says the head is awake.
    func testLeadInMotionOnsetDrivenDirectlyAnchorsAfterTheLastSustainedRun() {
        let n = 100
        var awake = [Bool](repeating: false, count: n)          // nothing is awake a priori
        var motion = [Bool](repeating: false, count: n)
        let head = SleepStaging.Tuning.default.minConsolidatedSleepEpochs - 2   // not yet consolidated
        for i in head..<(head + 6) { motion[i] = true }          // sustained: the getting-up
        SleepStaging.markLeadInMotionOnsetForTesting(&awake, motionAwake: motion, tuning: .default)
        XCTAssertTrue(awake[0..<(head + 6)].allSatisfy { $0 },
                      "everything up to the end of the motion run is awake-in-bed")
        XCTAssertTrue(awake[(head + 6)...].allSatisfy { !$0 },
                      "sleep begins at the first still epoch after it — nothing later is touched")
    }

    /// Guard (d), driven directly: what separates a mid-night STIR from getting up is the DURATION of
    /// the motion, not what precedes it. A short burst — however much sleep sits behind it — must not
    /// re-anchor onset. (The "consolidated sleep behind it" guard used by the HR passes was tried here
    /// and 🔴 fails on the real night, whose quiet-awake lead-in reads as asleep; see the pass's doc.)
    func testLeadInMotionOnsetIgnoresAShortBurstHoweverLateItFalls() {
        let n = 100
        var awake = [Bool](repeating: false, count: n)
        var motion = [Bool](repeating: false, count: n)
        let minRun = SleepStaging.Tuning.default.leadInMotionOnsetMinRun
        let start = SleepStaging.Tuning.default.minConsolidatedSleepEpochs + 4
        for i in start..<(start + minRun - 1) { motion[i] = true }      // one epoch short of the bar
        SleepStaging.markLeadInMotionOnsetForTesting(&awake, motionAwake: motion, tuning: .default)
        XCTAssertTrue(awake.allSatisfy { !$0 },
                      "a burst shorter than minRun is a stir — onset must not move")
    }

    /// The clustering that makes the duration bar meaningful on real data: a long getting-up arrives
    /// FRAGMENTED, because `motionAboveLocalFloor` is relative and a sustained episode lifts its own
    /// rolling floor. 🟢 measured — the grounding night's ~57-minute desk trip decomposes into runs of
    /// 3, 1, 5, 3, 2, 1, so no single run clears a useful bar while the cluster obviously does.
    func testLeadInMotionOnsetClustersFragmentedMotionIntoOneEpisode() {
        let n = 120
        var awake = [Bool](repeating: false, count: n)
        var motion = [Bool](repeating: false, count: n)
        // The measured fragmentation pattern, starting at epoch 10: runs of 3,1,5,3,2,1 with 1-2 gaps.
        for i in [10, 11, 12, 15, 18, 19, 20, 21, 22, 25, 26, 27, 29, 30, 32] { motion[i] = true }
        SleepStaging.markLeadInMotionOnsetForTesting(&awake, motionAwake: motion, tuning: .default)
        XCTAssertTrue(awake[0...32].allSatisfy { $0 },
                      "the fragmented episode is one getting-up — onset lands after its LAST fragment")
        XCTAssertTrue(awake[33...].allSatisfy { !$0 }, "sleep after it is untouched")
    }

    /// The kill switch and the two run-length guards, driven directly for the same reason as above.
    func testLeadInMotionOnsetDirectGuards() {
        let n = 100
        // (a) kill switch
        var awake = [Bool](repeating: false, count: n)
        var motion = [Bool](repeating: false, count: n); for i in 20..<26 { motion[i] = true }
        let before = awake
        SleepStaging.markLeadInMotionOnsetForTesting(&awake, motionAwake: motion,
                                                     tuning: .init(leadInMotionOnsetMinRun: 0))
        XCTAssertEqual(awake, before, "minRun 0 disables the pass entirely")
        // (b) a run shorter than minRun is a stir, not getting up
        awake = [Bool](repeating: false, count: n)
        motion = [Bool](repeating: false, count: n); motion[20] = true; motion[21] = true
        SleepStaging.markLeadInMotionOnsetForTesting(&awake, motionAwake: motion, tuning: .default)
        XCTAssertTrue(awake.allSatisfy { !$0 }, "a 2-epoch stir must not re-anchor onset")
        // (c) a run beginning OUTSIDE the leading reach cannot re-anchor onset
        awake = [Bool](repeating: false, count: n)
        motion = [Bool](repeating: false, count: n)
        let reach = SleepStaging.onsetSearchReach(epochCount: n, tuning: .default)
        for i in (reach + 2)..<(reach + 8) { motion[i] = true }
        SleepStaging.markLeadInMotionOnsetForTesting(&awake, motionAwake: motion, tuning: .default)
        XCTAssertTrue(awake.allSatisfy { !$0 },
                      "a motion run past the leading reach is a mid-night event, not the onset")
    }

    /// SAFETY — a brief mid-night stir must NOT re-anchor onset. The pass is scoped to the LEADING
    /// region and requires a SUSTAINED run, so a normal night (asleep early, one short 3 a.m. stir) is
    /// untouched: onset stays at the first sleep, and the stir stays an interior awakening.
    func testLeadInMotionOnsetLeavesAMidNightStirAlone() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let onset = c
        for _ in 0..<60 { recs.append(vrec(c, hr: 52, hrv: 60)); c += step }   // 2.5 h real sleep FIRST
        for _ in 0..<2 { recs.append(arec(c, motion: 90)); c += step }         // brief stir (< minRun)
        for _ in 0..<80 { recs.append(vrec(c, hr: 52, hrv: 60)); c += step }   // back to sleep
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let segs = SleepStaging.classify(from: recs)
        guard let win = SleepStaging.sleepWindow(segs) else { return XCTFail("no sleep window") }
        let onsetDate = Date(timeIntervalSince1970: Double(Int(onset) + Command.syncEpoch))
        XCTAssertEqual(win.onset.timeIntervalSince(onsetDate), 0, accuracy: Double(step) * 3,
                       "a brief mid-night stir must not move onset — consolidated sleep precedes it")
    }

    /// SAFETY — the pass only ever moves onset LATER. A night that is already anchored correctly (asleep
    /// almost immediately, no getting-up) must be byte-identical with the pass on vs. off.
    func testLeadInMotionOnsetIsInertOnAStraightforwardNight() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        for _ in 0..<140 { recs.append(vrec(c, hr: 52, hrv: 60)); c += step }
        for _ in 0..<8 { recs.append(arec(c)); c += step }
        let on = SleepStaging.classify(from: recs)
        let off = SleepStaging.classify(from: recs, tuning: .init(leadInMotionOnsetMinRun: 0))
        XCTAssertEqual(on, off, "no getting-up episode → the pass is inert, output identical")
    }

    /// Locks the shipped default. `0` is the documented kill switch; 3 epochs (~7.5 min) is the
    /// "sustained, not a stir" bar. See `docs/PENDING_VALIDATION.md` → `lead-in-motion-onset-refit`.
    func testLeadInMotionOnsetMinRunDefault() {
        XCTAssertEqual(SleepStaging.Tuning.default.leadInMotionOnsetMinRun, 6)
    }

    /// The derived reach is what makes a multi-hour lead-in REACHABLE at all: on the grounding night
    /// the real onset sat at epoch 72 while the old fixed bound stopped at 48. It must never SHRINK
    /// below the old bound, and never exceed half the night.
    func testOnsetSearchReachWidensButNeverShrinksOrEatsTheNight() {
        let t = SleepStaging.Tuning.default
        // A long night: reach grows past the fixed bound so a late onset is reachable.
        XCTAssertEqual(SleepStaging.onsetSearchReach(epochCount: 258, tuning: t), 129)
        XCTAssertGreaterThan(SleepStaging.onsetSearchReach(epochCount: 258, tuning: t), 72,
                             "the grounding night's real onset (epoch 72) must be inside the reach")
        // A short night: never shorter than the old fixed bound, never more than the night itself.
        XCTAssertEqual(SleepStaging.onsetSearchReach(epochCount: 60, tuning: t), t.onsetSearchEpochs)
        XCTAssertEqual(SleepStaging.onsetSearchReach(epochCount: 20, tuning: t), 20)
        XCTAssertEqual(SleepStaging.onsetSearchReach(epochCount: 0, tuning: t), 0)
    }

    // MARK: - Constructed-night partition (sanity vs. RingConn night totals)

    func testConstructedNightPartitionsLikeATracker() {
        // ~5 sleep cycles: Light-heavy with periodic Deep troughs and elevated REM,
        // plus brief awakenings. We assert the SHAPE (light ≫ rem > deep, modest awake,
        // inBed ≈ asleep + awake) the way the app's night totals do — NOT exact minutes.
        // Light/REM carry HR JITTER and Deep is FLAT — that's how the model separates them
        // (Deep = the flat low-HR troughs; real light sleep is never perfectly flat). A
        // flat-HR "Light" block would correctly read as Deep, which is why this models the
        // real variability structure (confirmed against the Helio hypnogram, 2026-06-20).
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // sleep onset (awake)
        for cycle in 0..<5 {
            for k in 0..<10 { recs.append(vrec(c, hr: k % 2 == 0 ? 54 : 62, hrv: 60)); c += step }   // Light (jittery mid)
            for _ in 0..<8  { recs.append(vrec(c, hr: 50, hrv: 70)); c += step }                      // Deep (flat low)
            for k in 0..<8  { recs.append(vrec(c, hr: k % 2 == 0 ? 54 : 62, hrv: 60)); c += step }   // Light (jittery mid)
            for k in 0..<10 { recs.append(vrec(c, hr: k % 2 == 0 ? 64 : 78, hrv: 45)); c += step }   // REM (elevated, jittery)
            if cycle < 4 { for _ in 0..<2 { recs.append(arec(c, motion: 0x15)); c += step } } // brief wake
        }
        for _ in 0..<8 { recs.append(arec(c)); c += step }                   // morning (awake)

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let s = SleepStaging.summary(segs)

        // All four stages present.
        XCTAssertGreaterThan(s.deep, 0); XCTAssertGreaterThan(s.rem, 0)
        XCTAssertGreaterThan(s.light, 0); XCTAssertGreaterThan(s.awake, 0)

        // Architecture sanity: Light dominates, REM exceeds Deep (as in the GT night:
        // light 285m > rem 102m > deep 70m). Not exact-minute matching.
        XCTAssertGreaterThan(s.light, s.rem, "Light is the largest asleep stage")
        XCTAssertGreaterThan(s.rem, s.deep, "REM exceeds Deep")

        // Totals partition the night: inBed ≈ asleep + awake (within one epoch of rounding).
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step))
        // Efficiency in a plausible nightly range.
        XCTAssertGreaterThan(s.efficiency, 0.6)
        XCTAssertLessThanOrEqual(s.efficiency, 1.0)

        // stageTotals agrees with the summary.
        let totals = SleepStaging.stageTotals(segs)
        XCTAssertEqual(totals[.asleepDeep], s.deep)
        XCTAssertEqual(SleepStaging.totalAsleep(segs), s.totalAsleep, accuracy: 0.001)
    }

    // MARK: - Stitching a night handed off in MULTIPLE fragments (the shrink fix)

    /// A night split by a data gap (ring buffer dropped epochs / a missed overnight drain) must be
    /// STITCHED: both fragments staged and summed, not just the latest one kept. This is the core of
    /// the "sleep shrinks on every sync" fix — previously a single gap discarded everything but one
    /// block.
    func testFragmentedNightIsStitchedAcrossGap() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        // Fragment 1: a ~5 h sleep core, bracketed by onset/EOF motion.
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        // Data gap well past the detector's break threshold (no records for 2 h).
        c += UInt32(2 * 3600)
        // Fragment 2: a second ~4 h sleep core.
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        for _ in 0..<100 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<8   { recs.append(arec(c)); c += step }

        XCTAssertEqual(BulkSleep.contiguousFragments(recs).count, 2, "gap splits into two fragments")

        let segs = SleepStaging.classify(from: recs)
        XCTAssertFalse(segs.isEmpty)
        let s = SleepStaging.summary(segs)

        // Asleep spans BOTH cores (120 + 100 epochs), not just one fragment.
        let bothCoresMin = Double((120 + 100) * Int(step)) / 60
        XCTAssertEqual(Double(s.minutes.asleep), bothCoresMin, accuracy: 40,
                       "stitched asleep covers both fragments, not just the latest")
        // One in-bed span per fragment; the 2 h gap is NOT counted as in-bed.
        let inBeds = segs.filter { $0.stage == .inBed }
        XCTAssertEqual(inBeds.count, 2, "one in-bed segment per fragment")
        let wallSpan = (segs.map(\.end).max()!).timeIntervalSince(segs.map(\.start).min()!)
        XCTAssertGreaterThan(wallSpan - s.inBed, 1.5 * 3600,
                             "the inter-fragment gap is excluded from in-bed")
        // Partition still holds across the stitch: in-bed ≈ asleep + awake.
        XCTAssertEqual(s.inBed, s.totalAsleep + s.awake, accuracy: Double(step) * 2)
    }

    /// A single contiguous night must be unchanged by the stitching path (one fragment ⇒ one in-bed
    /// segment, identical to the pre-stitch classifier).
    func testSingleFragmentNightUnchangedByStitch() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 52)); c += step }
        for _ in 0..<8   { recs.append(arec(c)); c += step }
        XCTAssertEqual(BulkSleep.contiguousFragments(recs).count, 1)
        let segs = SleepStaging.classify(from: recs)
        XCTAssertEqual(segs.filter { $0.stage == .inBed }.count, 1)
    }

    func testNoSleepBlockYieldsNoSegments() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<80 { recs.append(arec(c, motion: 0x18)); c += step }
        XCTAssertTrue(SleepStaging.classify(from: recs).isEmpty, "all-active -> no staging")
        XCTAssertTrue(SleepStaging.stageTotals([]).isEmpty)
        XCTAssertEqual(SleepStaging.totalAsleep([]), 0)
    }

    func testBulkSleepStagedSegmentsDelegatesToClassifier() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 50)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        XCTAssertEqual(BulkSleep.stagedSegments(from: recs), SleepStaging.classify(from: recs),
                       "BulkSleep.stagedSegments is a thin wrapper over SleepStaging.classify")
    }

    // MARK: - Issue #15 — all HealthKit sleep-analysis stage values (#15)

    /// `stagedSegments` must produce every stage value required by issue #15:
    /// `inBed`, `asleepCore` (light), `asleepDeep`, `asleepREM`, `awake`.
    /// HEALTHKIT_MAPPING.md: `HKCategoryType(.sleepAnalysis)` with these values.
    /// Uses a 5-cycle night (Deep troughs, REM peaks, brief awakenings) that exercises
    /// all four asleep stages plus the enclosing inBed span.
    func testStagedSegmentsProduceAllFiveHealthKitStages() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<8  { recs.append(arec(c)); c += step }               // sleep onset (awake)
        for _ in 0..<5 {
            for _ in 0..<10 { recs.append(vrec(c, hr: 57, hrv: 55)); c += step }   // Light/core
            for _ in 0..<8  { recs.append(vrec(c, hr: 50, hrv: 65)); c += step }   // Deep
            for _ in 0..<8  { recs.append(vrec(c, hr: 57, hrv: 55)); c += step }   // Light/core
            for _ in 0..<10 { recs.append(vrec(c, hr: 65, hrv: 40)); c += step }   // REM (elevated)
            for _ in 0..<2  { recs.append(arec(c, motion: 0x15)); c += step }      // brief Awake
        }
        for _ in 0..<8  { recs.append(arec(c)); c += step }               // wake-up (awake)

        let segs = BulkSleep.stagedSegments(from: recs)
        XCTAssertFalse(segs.isEmpty, "staged segments must be produced")

        let present = Set(segs.map(\.stage))
        XCTAssertTrue(present.contains(.inBed),      "#15: inBed span required")
        XCTAssertTrue(present.contains(.asleepCore),  "#15: asleepCore (light) required")
        XCTAssertTrue(present.contains(.asleepDeep),  "#15: asleepDeep required")
        XCTAssertTrue(present.contains(.asleepREM),   "#15: asleepREM required")
        XCTAssertTrue(present.contains(.awake),       "#15: awake required")
    }

    /// `SleepStage.allCases` must cover all five values expected by HEALTHKIT_MAPPING.md.
    /// This is a compile-time-checkable structural guard: if a new case is added (or one
    /// renamed), the test breaks, forcing the HealthKitWriter mapping to be updated too.
    func testSleepStageEnumCoversAllHealthKitValues() {
        let required: Set<SleepStage> = [.inBed, .asleepCore, .asleepDeep, .asleepREM, .awake]
        XCTAssertEqual(Set(SleepStage.allCases), required,
                       "SleepStage must cover exactly the 5 HKCategoryValueSleepAnalysis cases")
    }

    // MARK: - Dedup: SyncCursor gates re-writing the same night (#15)

    /// The `.sleep` SyncCursor must gate re-presenting the same night's staged segments.
    /// `pendingHealthSleep` in LocalStore uses `cursor.isNew(.sleep, segments.max(\.end))`
    /// — advance → not-new — so a second sync with the same night never double-writes.
    func testSleepCursorDedupsByMaxEndDate() {
        // Build a synthetic night and extract its max end date.
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 55)); c += step }
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let segs = BulkSleep.stagedSegments(from: recs)
        XCTAssertFalse(segs.isEmpty, "need staged segments for this test")
        guard let maxEnd = segs.map(\.end).max() else { return XCTFail("no end dates") }

        var cursor = SyncCursor()
        // Before any write: the night is "new".
        XCTAssertTrue(cursor.isNew(.sleep, maxEnd),
                      "fresh cursor: staged night is new (must be written)")

        // Simulate marking it written: advance the cursor past maxEnd.
        cursor.advance(.sleep, to: maxEnd)

        // Same or earlier end date: not new — dedup gate blocks a re-write.
        XCTAssertFalse(cursor.isNew(.sleep, maxEnd),
                       "after write: same night must not be written again (dedup)")

        // A genuinely new future night (maxEnd + 1 s) must still pass through.
        let nextNight = maxEnd.addingTimeInterval(1)
        XCTAssertTrue(cursor.isNew(.sleep, nextNight),
                      "next night is newer than cursor: must be written")
    }

    // MARK: - Personal (multi-night) baseline — Deep band anchoring (RingConn-aligned)

    /// The factory uses the MEDIAN of recent nights' deep-sleep HR, ignores non-positive entries
    /// (nights with no detected Deep), and needs ≥ `minNights` valid nights or it returns nil.
    func testPersonalBaselineFactory() {
        XCTAssertNil(SleepStaging.PersonalBaseline.fromRecentDeepHR([51, 52], minNights: 3),
                     "too few nights → no baseline (stay single-night)")
        XCTAssertNil(SleepStaging.PersonalBaseline.fromRecentDeepHR([0, 0, 51], minNights: 3),
                     "zeros (no-Deep nights) are filtered → too few valid → nil")
        // Odd count: sorted valid [51,51,52,75,102] → median 52, robust to the 75/102 outlier nights.
        XCTAssertEqual(SleepStaging.PersonalBaseline.fromRecentDeepHR([51, 75, 52, 51, 102])?.deepSleepHR,
                       52)
        // Even count → TRUE median (mean of the two central values), NOT an upper-median:
        // sorted [48,49,70,72] → (49+70)/2 = 59.5 (an upper-median would wrongly bias up to 70).
        XCTAssertEqual(SleepStaging.PersonalBaseline.fromRecentDeepHR([72, 48, 70, 49])?.deepSleepHR,
                       59.5)
    }

    /// The core win: a GLOBALLY-ELEVATED night (flat HR well above the person's norm) is read as mostly
    /// Deep by the single-night classifier (its own lowest epochs look "deep"), but a personal baseline
    /// anchored to the true deep HR (~50) recognises that 70 bpm is not deep for this person → not Deep.
    func testBaselineSuppressesDeepOnGloballyElevatedNight() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 70, hrv: 55)); c += step }   // flat, still, ELEVATED
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let noBaseline = SleepStaging.classify(from: recs)
        let withBaseline = SleepStaging.classify(from: recs,
            baseline: SleepStaging.PersonalBaseline(deepSleepHR: 50))   // ceiling 50+10 = 60 < 70
        XCTAssertGreaterThan(fraction(noBaseline, .asleepDeep), 0.5,
            "single-night: the flat block reads as Deep relative to its own distribution")
        XCTAssertLessThan(fraction(withBaseline, .asleepDeep), 0.05,
            "with a personal baseline, a 70-bpm night is not deep for a person whose deep HR is ~50")
        // The suppressed Deep must become LIGHT, not REM: a flat elevated night has remHR ≈ the flat HR,
        // so letting suppressed epochs fall through to the REM test would absurdly read the whole night
        // as REM. A calm, flat epoch is Light (REM needs elevation OR variability).
        XCTAssertGreaterThan(fraction(withBaseline, .asleepCore), 0.8,
            "baseline-suppressed Deep relabels to Light")
        XCTAssertLessThan(fraction(withBaseline, .asleepREM), 0.2,
            "a flat elevated night does not spuriously read as all-REM")
    }

    /// SAFETY: the baseline must be INERT on a normal night — when the night's Deep HR sits within the
    /// margin of the baseline (or below it), the ceiling never binds and the staging is byte-identical
    /// to the single-night classifier. Two cases: a matching baseline, and a clearly non-binding one.
    func testBaselineIsInertWhenItDoesNotBind() {
        var recs: [BulkRecord] = []
        var c: UInt32 = 0x0c220000
        for _ in 0..<12 { recs.append(arec(c)); c += step }
        for _ in 0..<120 { recs.append(vrec(c, hr: 50, hrv: 55)); c += step }   // normal calm low-HR night
        for _ in 0..<12 { recs.append(arec(c)); c += step }

        let single = SleepStaging.classify(from: recs)
        // Matching baseline (deep HR 50, ceiling 60 ≥ the night's 50 epochs) → no Deep removed.
        XCTAssertEqual(single, SleepStaging.classify(from: recs,
            baseline: SleepStaging.PersonalBaseline(deepSleepHR: 50)),
            "a baseline matching the night's deep HR changes nothing")
        // A higher baseline (ceiling well above all HR) is likewise inert.
        XCTAssertEqual(single, SleepStaging.classify(from: recs,
            baseline: SleepStaging.PersonalBaseline(deepSleepHR: 80)),
            "a non-binding baseline is byte-identical to the single-night classifier")
    }

    // MARK: - Night-scoping cap (the "no sleep recorded" regression, build 16)

    /// REGRESSION (2026-06-30, reproduced against a real device store): the all-day `0x03` channel fills
    /// the DAYTIME, and detection reads a sedentary worn day as "still" = sleep, so it can emit one long
    /// still block bridging daytime into the night. That block's MIDPOINT still reads "overnight", so
    /// `latestNightRecords` anchored on it (and chained back to the prior night), returned a >maxNightSpan
    /// window, `classify` stitched a >24 h window, and `RingSession.overnightStagedSegments`' overnight
    /// gate (midpoint must be night) discarded the WHOLE night → no summary persisted. The night-span cap
    /// must scope to ONE night. Built deterministically (Calendar.current for both construction and the
    /// overnight check) so it is timezone-robust.
    func testLatestNightRecordsCapsAllDayBridgedBlockToOneNight() {
        let cal = Calendar.current
        let wake = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        // 20 h of continuous still, low-HR epochs ending at wake — a sedentary day bridged into the night
        // (12:00 → 08:00). Midpoint ~22:00 is solidly overnight, so detection yields an anchor (the bug's
        // precondition: the bridged block reads "overnight" despite spanning the afternoon).
        let start = cal.date(byAdding: .hour, value: -20, to: wake)!
        XCTAssertGreaterThan(wake.timeIntervalSince(start), BulkSleep.maxNightSpan,
                             "precondition: the bridged block exceeds maxNightSpan")
        var c = UInt32(start.timeIntervalSince1970 - Double(Command.syncEpoch))
        var recs: [BulkRecord] = []
        for _ in 0 ..< Int(wake.timeIntervalSince(start) / 150) { recs.append(vrec(c, hr: 52, hrv: 55)); c += step }

        let scoped = BulkSleep.latestNightRecords(from: recs)
        guard let lo = scoped.map({ $0.date() }).min(), let hi = scoped.map({ $0.date() }).max() else {
            return XCTFail("scoping returned nothing")
        }
        // The window is capped to one night (≤ maxNightSpan + the ±30-min onset/wake margins), NOT the 20 h block.
        XCTAssertLessThanOrEqual(hi.timeIntervalSince(lo), BulkSleep.maxNightSpan + 3600,
            "a >maxNightSpan bridged block must be capped to one night, not returned whole")
        // And it keeps the LATEST data (the wake edge), so staging describes the most recent night.
        XCTAssertEqual(hi.timeIntervalSince(wake), 0, accuracy: 3600,
            "the scoped window ends at the latest night's wake")
        // The scoped night is overnight → the overnight gate accepts it → a summary WOULD persist.
        let inBeds = SleepStaging.classify(from: scoped).filter { $0.stage == .inBed }
        XCTAssertEqual(inBeds.count, 1, "one capped night → a single in-bed window, not a stitched >24 h span")
        XCTAssertTrue(SleepWindow.isOvernightBlock(start: inBeds[0].start, end: inBeds[0].end),
            "the capped night is overnight, so overnightStagedSegments persists it")
    }
}
