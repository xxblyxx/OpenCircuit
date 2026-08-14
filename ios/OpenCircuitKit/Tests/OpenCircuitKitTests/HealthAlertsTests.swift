import XCTest
@testable import OpenCircuitKit

/// SYNTHETIC-ONLY tests for the local health-alert engine: thresholds (#73), flag routing (#85),
/// quiet-hours DND, and the anti-spam de-dupe gate. No real health values.
final class HealthAlertsTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: h, minute: m))!
    }
    private func hr(_ bpm: Int, _ h: Int, _ m: Int = 0) -> HRSample { HRSample(bpm: bpm, start: at(h, m)) }

    // MARK: #73 threshold rules

    func testHighHRPicksWorstReading() {
        let s = [hr(80, 9), hr(125, 10), hr(140, 11), hr(90, 12)]
        let hit = HealthAlertEvaluator.highHR(s, thresholdBpm: 120)
        XCTAssertEqual(hit?.bpm, 140)
        XCTAssertNil(HealthAlertEvaluator.highHR([hr(80, 9), hr(100, 10)], thresholdBpm: 120))
    }

    // MARK: #73 low-SpO2 — corroboration + epoch-quality gate
    //
    // The rule these cover replaced a SINGLE-SAMPLE crossing that notified "Low blood oxygen
    // (80%)" while the wearer's hands were in water. Every test below is either a shape that must
    // still alert or a shape that must not; `testSingleIsolatedLowReadingNeverFires` and
    // `testTheDishesShapeIsSuppressed` are the two that pin the reported defect.

    /// Quiet, worn epoch — the evidence a genuine overnight reading carries.
    private var quietEpoch: SpO2Evidence {
        SpO2Evidence(unworn: false, resolvesStillness: true, motionSpread: 1,
                     magnitudesAllZero: true, confidence: 6)
    }

    /// A hand in motion: the five 30-s sub-samples step INSIDE the epoch, so it cannot resolve
    /// stillness. Modelled on the incident's own record (`14 40 11 33 8`, spread 32).
    private var movingEpoch: SpO2Evidence {
        SpO2Evidence(unworn: false, resolvesStillness: false, motionSpread: 32,
                     magnitudesAllZero: false, confidence: 3)
    }

    private var unwornEpoch: SpO2Evidence {
        SpO2Evidence(unworn: true, resolvesStillness: false, motionSpread: 0,
                     magnitudesAllZero: true, confidence: nil)
    }

    private func spo2(_ percent: Int, _ h: Int, _ m: Int = 0,
                      _ evidence: SpO2Evidence? = nil) -> SpO2Reading {
        SpO2Reading(percent: percent, time: at(h, m), evidence: evidence)
    }

    func testLowSpO2PicksWorstCorroboratedReading() {
        // 88 and 89 are five minutes apart and agree inside the tolerance, so the run is real and
        // the WORST of it is what gets reported — the half of the old behaviour that was correct.
        let r = [spo2(97, 2, 0, quietEpoch), spo2(88, 3, 0, quietEpoch),
                 spo2(89, 3, 5, quietEpoch), spo2(91, 4, 0, quietEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .fired)
        XCTAssertEqual(v.reading?.percent, 88)
        XCTAssertEqual(v.runSize, 2)
    }

    func testLowSpO2IgnoresPlaceholdersAndSubThresholdSeries() {
        let r = [spo2(97, 2, 0, quietEpoch), spo2(88, 3, 0, quietEpoch), spo2(89, 3, 5, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2([spo2(0, 2)], thresholdPercent: 90).outcome,
                       .noCandidate)
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 80).outcome, .noCandidate)
    }

    /// THE REGRESSION TEST for the reported defect: one reading, nothing near it, never fires.
    func testSingleIsolatedLowReadingNeverFires() {
        let v = HealthAlertEvaluator.lowSpO2([spo2(80, 19, 34, movingEpoch)], thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .noCorroboration)
        XCTAssertEqual(v.reading?.percent, 80)
        XCTAssertEqual(v.runSize, 1)
    }

    /// The incident, reproduced: an 80 % reading on a moving epoch with healthy readings either
    /// side at the all-day cadence.
    ///
    /// Reported as `.noCorroboration`, NOT `.corroborationDisagrees`: the 97/96 % neighbours are
    /// perfectly normal readings, not sub-threshold ones that disagree. There is simply nothing
    /// nearby that could corroborate a desaturation. Keeping those two cases distinct matters
    /// because `.corroborationDisagrees` is the population someone would mine to tune
    /// `agreementTolerance`, and healthy readings tell them nothing about it.
    func testTheDishesShapeIsSuppressed() {
        let r = [spo2(97, 19, 14, quietEpoch),
                 spo2(80, 19, 34, movingEpoch),
                 spo2(96, 19, 54, quietEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .noCorroboration)
        XCTAssertEqual(v.nearestNeighbourDelta, 17)
        XCTAssertEqual(v.runSize, 1)
    }

    func testTwoAgreeingLowReadingsAtTheSleepCadenceFire() {
        let r = [spo2(88, 3, 0, quietEpoch), spo2(86, 3, 5, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome, .fired)
    }

    /// ⚠️ THE TEST THAT WOULD HAVE CAUGHT THE WINDOW BEING SIZED TO THE SLEEP CADENCE.
    ///
    /// PROTOCOL.md §5.3's 300 s duty cycle is the SLEEP program (channel `0x00`). Daytime SpO2
    /// arrives on channel `0x03` at 20-30 minute spacing (§5.6.1). A 300 s window leaves every
    /// daytime reading structurally uncorroborated, which would silently reduce the whole feature
    /// to overnight-only — while every other test in this file still passed.
    func testDaytimeCadenceStillCorroborates() {
        let r = [spo2(88, 10, 0, quietEpoch), spo2(89, 10, 20, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome, .fired,
                       "20 min apart is the ORDINARY daytime cadence, not a coincidence")

        let sleepOnlyWindow = SpO2AlertPolicy(corroborationWindow: 300)
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90,
                                                    policy: sleepOnlyWindow).outcome,
                       .noCorroboration,
                       "documents the trap: a 300 s window deletes the daytime channel")
    }

    func testDisagreementBeyondToleranceSuppresses() {
        // 80 and 85 are both below the threshold but five points apart — not one event.
        let r = [spo2(80, 3, 0, quietEpoch), spo2(85, 3, 5, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome,
                       .corroborationDisagrees)
    }

    func testCorroboratorOutsideTheWindowDoesNotCount() {
        // corroborationWindow defaults to 2700 s (45 min) — MEASURED against a real export
        // (see the doc comment on `SpO2AlertPolicy.corroborationWindow`), so the boundary case
        // itself now corroborates. 90 min is comfortably past it either way.
        let r = [spo2(88, 3, 0, quietEpoch), spo2(89, 4, 30, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome,
                       .noCorroboration)
    }

    func testCorroboratorExactlyAtTheWindowBoundaryCounts() {
        // The comparison is `<=`, so a reading exactly at the window edge still corroborates —
        // pinned explicitly since the default constant sits at a measured, not arbitrary, value.
        let r = [spo2(88, 3, 0, quietEpoch), spo2(89, 3, 45, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome, .fired)
    }

    func testCorroboratorMustItselfCrossTheThreshold() {
        // 92 is within 2 points of 90, but it is not a low reading, so it corroborates nothing —
        // and because it is not sub-threshold, this is `.noCorroboration`, not a "disagreement".
        // Pinning the distinction: a delta INSIDE agreementTolerance must never be filed as a
        // tolerance failure, or the label actively misleads whoever tunes that constant.
        let r = [spo2(90, 3, 0, quietEpoch), spo2(92, 3, 5, quietEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .noCorroboration)
        XCTAssertEqual(v.nearestNeighbourDelta, 2, "inside tolerance — not a disagreement")
    }

    func testTwoLowReadingsThatDisagreeAreTheOnlyDisagreement() {
        // The genuine `.corroborationDisagrees` shape: BOTH readings are sub-threshold, but they
        // are five points apart, so they are not one event.
        let r = [spo2(80, 3, 0, quietEpoch), spo2(85, 3, 5, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome,
                       .corroborationDisagrees)
    }

    // MARK: the FRACTIONAL bad-epoch rule

    func testOneMovingEpochInAThreeEpochRunStillFires() {
        let r = [spo2(88, 3, 0, quietEpoch), spo2(87, 3, 5, movingEpoch), spo2(88, 3, 10, quietEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .fired, "1 of 3 bad is not a majority")
        XCTAssertEqual(v.evidenceEpochs, 3)
        XCTAssertEqual(v.badEpochs, 1)
    }

    func testOneMovingEpochOfTwoStillFires() {
        // Exactly half. The comparison is STRICT `>`, so this survives — the whole point of a
        // fractional rule is that one bad epoch cannot kill a genuine run.
        let r = [spo2(88, 3, 0, quietEpoch), spo2(87, 3, 5, movingEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .fired)
        XCTAssertEqual(v.badEpochs, 1)
        XCTAssertEqual(v.evidenceEpochs, 2)
    }

    func testBothEpochsMovingSuppresses() {
        // Two readings corrupted by the same sustained artifact — hands in water across both.
        let r = [spo2(80, 3, 0, movingEpoch), spo2(81, 3, 5, movingEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .badEpochMajority)
        XCTAssertEqual(v.badEpochs, 2)
    }

    func testUnwornEpochCountsAsBad() {
        let r = [spo2(80, 3, 0, unwornEpoch), spo2(81, 3, 5, unwornEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90).outcome,
                       .badEpochMajority)
    }

    // MARK: the evidence-lookup MISS policy

    func testNoEvidenceWithCorroborationFires() {
        // Live on-demand readings have no 0x4c record BY CONSTRUCTION. Corroboration carries them.
        let r = [spo2(88, 3, 0), spo2(89, 3, 5)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .fired)
        XCTAssertEqual(v.evidenceEpochs, 0, "a fired verdict on the fail-open path must SAY so")
    }

    func testNoEvidenceWithoutCorroborationSuppresses() {
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2([spo2(80, 3, 0)], thresholdPercent: 90).outcome,
                       .noCorroboration)
    }

    func testPartialEvidenceUsesTheResolvedDenominator() {
        // One epoch resolved and it was moving; the other never resolved. 1 of 1 is a majority —
        // the evidence we HAVE says artifact, and a miss must not dilute that toward "good".
        let r = [spo2(80, 3, 0, movingEpoch), spo2(81, 3, 5)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .badEpochMajority)
        XCTAssertEqual(v.evidenceEpochs, 1)
        XCTAssertEqual(v.badEpochs, 1)
    }

    // MARK: freshness

    func testCorroboratorsAreSearchedBEFORETheFreshnessBound() {
        // The trigger must be fresh; its SUPPORT need not be. A genuine run straddling the
        // last-fired watermark would otherwise be suppressed by the replay guard itself.
        let r = [spo2(89, 3, 0, quietEpoch), spo2(88, 3, 5, quietEpoch)]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90, notBefore: at(3, 2))
        XCTAssertEqual(v.outcome, .fired)
        XCTAssertEqual(v.reading?.percent, 88, "the pre-bound 89 supports it but cannot trigger it")
        XCTAssertEqual(v.runSize, 2)
    }

    func testAlreadyAlertedRunDoesNotReplay() {
        let r = [spo2(88, 3, 0, quietEpoch), spo2(89, 3, 5, quietEpoch)]
        XCTAssertEqual(HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90,
                                                    notBefore: at(3, 10)).outcome,
                       .noCandidate)
    }

    func testEveryNonFiringOutcomeIsNameableForTheLog() {
        // The log writes `outcome.rawValue` as its reason, so a case with no distinct value would
        // silently collapse two different decisions into one indistinguishable row.
        let all: [SpO2Verdict.Outcome] = [.fired, .noCandidate, .noCorroboration,
                                          .corroborationDisagrees, .badEpochMajority]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
    }

    /// ⚠️ REGRESSION TEST (code review, 2026-08-13): `lowSpO2` used to pick ONE trigger — the
    /// single global-worst reading in the window — and return whatever ITS verdict was, full
    /// stop. That silently masked a real desaturation: an isolated, numerically-worse artifact
    /// (no corroborator) would be chosen as the sole trigger, fail corroboration, and the pass
    /// would report a suppression for the WHOLE window — a genuinely corroborated event elsewhere
    /// in the same series never got its own turn at evaluation. This reproduces exactly that
    /// shape: a worse isolated artifact (80 %, moving, no neighbour) sits alongside a real,
    /// well-corroborated, quiet desaturation (88/86 %) far enough away in time that they cannot
    /// corroborate each other. The real event MUST still fire.
    func testAWorseIsolatedArtifactDoesNotMaskARealCorroboratedDesaturationElsewhereInTheWindow() {
        let r = [
            spo2(88, 2, 0, quietEpoch), spo2(86, 2, 5, quietEpoch),   // real, corroborated
            spo2(80, 8, 0, movingEpoch)                               // worse, isolated artifact
        ]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .fired)
        // 86 is the worse of the two real readings, so worst-first tries it before 88 — the
        // regression this guards is that the 80% artifact doesn't silence the pair AT ALL.
        XCTAssertEqual(v.reading?.percent, 86, "the WORST FIRING candidate, not the worst overall")
        XCTAssertEqual(v.runSize, 2)
    }

    /// ⚠️ REGRESSION TEST (code review, 2026-08-13): the app feeds this rule the union of the
    /// persisted store AND `RingSession.historySamples`, and those OVERLAP — `persist` runs before
    /// the alert pass and `historySamples` isn't cleared until the next drain, so every
    /// freshly-synced reading arrives twice. The old `min`-based rule was immune; a rule that
    /// COUNTS readings is not. This is the exact shape that broke: one quiet trigger plus a moving
    /// corroborator that got duplicated. Deduplicated (1 bad of 2) it fires; duplicated it was
    /// 2 bad of 3 → `.badEpochMajority`, i.e. whether a real desaturation alerted depended on sync
    /// timing. `HealthNotificationCenter` now dedupes by timestamp before calling in; this pins the
    /// rule's own behaviour on the deduplicated series so the guarantee is stated in one place.
    /// Duplicate readings reach the rule whenever the app evaluates right after a drain (the store
    /// copy plus the in-memory `historySamples` copy). `HealthNotificationCenter` now dedupes
    /// before calling in; this pins what duplication actually does to the rule, so the caller's
    /// obligation is documented by a test rather than only by a comment.
    ///
    /// ⚠️ NOTE WHAT IT DOES *NOT* DO. A duplicate can never manufacture corroboration: `evaluateOne`
    /// excludes everything sharing the trigger's timestamp, so a reading cannot corroborate itself.
    /// And a duplicated bad corroborator does not suppress a real event either — it can push ONE
    /// candidate over the bad fraction, but that candidate's duplicate is then tried as a trigger
    /// in its own right (worst-first) with its own copies excluded, and fires. What duplication
    /// genuinely corrupts is WHICH reading is reported: the alert lands on the 87 % corroborator
    /// instead of the worse 86 % trigger, so the notification, the log row and the export all name
    /// the wrong value and timestamp.
    func testDuplicationChangesWhichReadingIsReported() {
        let deduped = [spo2(86, 3, 0, quietEpoch), spo2(87, 3, 5, movingEpoch)]
        let clean = HealthAlertEvaluator.lowSpO2(deduped, thresholdPercent: 90)
        XCTAssertEqual(clean.outcome, .fired, "1 bad of 2 is exactly half — fires")
        XCTAssertEqual(clean.reading?.percent, 86, "the worst reading is what gets reported")

        // The pre-fix input: the moving 87% corroborator present twice, as the app used to supply
        // it (once from the store, once from the in-memory drain batch).
        let duplicated = [spo2(86, 3, 0, quietEpoch),
                          spo2(87, 3, 5, movingEpoch), spo2(87, 3, 5, movingEpoch)]
        let dirty = HealthAlertEvaluator.lowSpO2(duplicated, thresholdPercent: 90)
        XCTAssertEqual(dirty.outcome, .fired, "still fires — worst-first rescues it")
        XCTAssertEqual(dirty.reading?.percent, 87,
                       "but reports the WRONG reading: 86 was pushed over the bad fraction by a "
                       + "duplicate, so the milder 87 became the firing candidate")
    }

    /// The mirror image: when the worse reading is the one that's real, it still wins over a
    /// milder isolated artifact, because it is tried FIRST (worst-first) and fires immediately.
    func testAWorseRealDesaturationStillFiresAheadOfAMilderIsolatedArtifact() {
        let r = [
            spo2(80, 2, 0, quietEpoch), spo2(81, 2, 5, quietEpoch),   // real, corroborated, worse
            spo2(89, 8, 0, movingEpoch)                               // milder, isolated artifact
        ]
        let v = HealthAlertEvaluator.lowSpO2(r, thresholdPercent: 90)
        XCTAssertEqual(v.outcome, .fired)
        XCTAssertEqual(v.reading?.percent, 80)
    }

    func testElevatedHRInactiveSustained() {
        // 5 readings ≥100 spanning 10 min (epochs ~2.5 min apart) → fires on the last.
        let s = [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6), hr(106, 1, 9), hr(112, 1, 12)]
        let hit = HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100, minDuration: 10 * 60)
        XCTAssertEqual(hit?.bpm, 112)
    }

    func testElevatedHRInactiveTooShort() {
        // Elevated for only ~6 min → no fire.
        let s = [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6)]
        XCTAssertNil(HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100, minDuration: 10 * 60))
    }

    func testElevatedHRInactiveResetsBelowThreshold() {
        // A dip below threshold breaks the run; the later cluster is too short on its own.
        let s = [hr(105, 1, 0), hr(108, 1, 3), hr(70, 1, 6), hr(110, 1, 9), hr(112, 1, 12)]
        XCTAssertNil(HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100, minDuration: 10 * 60))
    }

    func testElevatedHRInactiveGapBreaksRun() {
        // Two elevated readings 30 min apart — gap exceeds maxGap, so not one continuous run.
        let s = [hr(110, 1, 0), hr(112, 1, 30)]
        XCTAssertNil(HealthAlertEvaluator.elevatedHRInactive(s, thresholdBpm: 100,
                                                             minDuration: 10 * 60, maxGap: 5 * 60))
    }

    func testEvaluateRespectsEnableFlags() {
        let highOnly = HealthAlertThresholds(highHREnabled: true, lowSpO2Enabled: false, elevatedHREnabled: false)
        let hits = HealthAlertEvaluator.evaluate(
            hr: [hr(130, 10)],
            spo2: [SpO2Reading(percent: 85, time: at(3))],
            inactiveHR: [],
            thresholds: highOnly).hits
        XCTAssertEqual(hits.map(\.notification), [.highHR])
    }

    func testEvaluateSuppressesReadingsAtOrBeforeLastFired() {
        let thresholds = HealthAlertThresholds(highHRBpm: 120,
                                               lowSpO2Percent: 90,
                                               elevatedHRBpm: 100)
        let oldInactiveRun = [hr(105, 1, 0), hr(108, 1, 3), hr(110, 1, 6),
                              hr(106, 1, 9), hr(112, 1, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: [hr(130, 2)],
            spo2: [SpO2Reading(percent: 85, time: at(2))],
            inactiveHR: oldInactiveRun,
            thresholds: thresholds,
            lastFired: [.highHR: at(3), .lowSpO2: at(3), .elevatedHRInactive: at(3)]).hits

        XCTAssertTrue(hits.isEmpty, "old threshold crossings must not replay after the backoff expires")
    }

    func testEvaluateAllowsFreshInactiveRunAfterLastFired() {
        let thresholds = HealthAlertThresholds(highHREnabled: false,
                                               lowSpO2Enabled: false,
                                               elevatedHRBpm: 100)
        let freshRun = [hr(105, 4, 0), hr(108, 4, 3), hr(110, 4, 6),
                        hr(106, 4, 9), hr(112, 4, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: [],
            spo2: [],
            inactiveHR: freshRun,
            thresholds: thresholds,
            lastFired: [.elevatedHRInactive: at(3)]).hits

        XCTAssertEqual(hits.map(\.notification), [.elevatedHRInactive])
        XCTAssertEqual(hits.first?.value, 112)
    }

    // MARK: Background-drain latency (30–60 min old timestamps) — de-dupe is the ONLY gate

    func testDrainLatencyOldHighHRCrossingFiresOnFirstSight() {
        // All-day HR arrives via an ~hourly background drain: the phone evaluates ONCE, right after
        // the drain, and the crossing's device timestamp is already ~45 min old on arrival. With the
        // 30-min device-timestamp freshness window removed, a not-yet-fired crossing must still alert
        // once — otherwise every legitimate background high-HR event in the older half of a drain is
        // permanently silenced.
        let thresholds = HealthAlertThresholds(highHRBpm: 120,
                                               lowSpO2Enabled: false,
                                               elevatedHREnabled: false)
        let hits = HealthAlertEvaluator.evaluate(
            hr: [hr(145, 9, 15)],   // ~45 min before the post-drain evaluation at ~10:00
            spo2: [],
            inactiveHR: [],
            thresholds: thresholds,
            lastFired: [:]).hits
        XCTAssertEqual(hits.map(\.notification), [.highHR])
        XCTAssertEqual(hits.first?.value, 145)
    }

    func testDrainLatencyOldSustainedRunFiresOnFirstSight() {
        // A sustained elevated-while-inactive run whose 10-min completion is ~40 min old on arrival.
        // The previous 40-min fetch window collapsed the 24h lookback to now-40min and silenced
        // exactly this run; over the restored wide window it must alert once.
        let thresholds = HealthAlertThresholds(highHREnabled: false,
                                               lowSpO2Enabled: false,
                                               elevatedHRBpm: 100,
                                               elevatedSustained: 10 * 60)
        let run = [hr(105, 9, 0), hr(108, 9, 3), hr(110, 9, 6), hr(106, 9, 9), hr(112, 9, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: [],
            spo2: [],
            inactiveHR: run,
            thresholds: thresholds,
            lastFired: [:]).hits
        XCTAssertEqual(hits.map(\.notification), [.elevatedHRInactive])
        XCTAssertEqual(hits.first?.value, 112)
    }

    func testDrainLatencyFiredCrossingDoesNotReplayOnNextDrain() {
        // Once a crossing has fired (its time recorded in `lastFired`), the next hourly drain
        // re-delivers the SAME hours-old samples. The per-notification `lastFired` filter — now the
        // entire stale-replay guard — must drop them so they don't post a second phone alert.
        let thresholds = HealthAlertThresholds(highHRBpm: 120,
                                               lowSpO2Enabled: false,
                                               elevatedHRBpm: 100,
                                               elevatedSustained: 10 * 60)
        let redeliveredHigh = [hr(145, 9, 15)]
        let redeliveredRun = [hr(105, 9, 0), hr(108, 9, 3), hr(110, 9, 6),
                              hr(106, 9, 9), hr(112, 9, 12)]
        let hits = HealthAlertEvaluator.evaluate(
            hr: redeliveredHigh,
            spo2: [],
            inactiveHR: redeliveredRun,
            thresholds: thresholds,
            lastFired: [.highHR: at(9, 15), .elevatedHRInactive: at(9, 12)]).hits
        XCTAssertTrue(hits.isEmpty, "already-fired crossings must not replay on the next drain")
    }

    // MARK: #144 activity gate (nonExercising)

    func testNonExercisingDropsHROverlappingSteps() {
        // A high HR concurrent with a stepping window is dropped; a high HR in a still window survives.
        let stepping = (at(10, 0), at(10, 20))          // 20-min walk
        let series = [hr(165, 10, 10),                  // during the walk → excluded
                      hr(122, 14, 0)]                   // still period → kept
        let filtered = HealthAlertEvaluator.nonExercising(series, activeIntervals: [stepping], pad: 10 * 60)
        XCTAssertEqual(filtered.map(\.bpm), [122])
    }

    func testNonExercisingExcludesRecoveryTail() {
        // A crossing within the `pad` recovery tail AFTER the walk ends is still excluded…
        let stepping = (at(10, 0), at(10, 20))
        let inTail = [hr(150, 10, 25)]                  // 5 min after the walk, inside the 10-min pad
        XCTAssertTrue(HealthAlertEvaluator.nonExercising(inTail, activeIntervals: [stepping], pad: 10 * 60).isEmpty)
        // …but beyond the pad it survives (recovery is over).
        let afterTail = [hr(150, 10, 35)]               // 15 min after → outside the 10-min pad
        XCTAssertEqual(HealthAlertEvaluator.nonExercising(afterTail, activeIntervals: [stepping], pad: 10 * 60).count, 1)
    }

    func testNonExercisingNoStepDataSuppressesNothing() {
        // Missing step data must NEVER silence a real crossing — empty intervals returns the series as-is.
        let series = [hr(165, 10, 10), hr(122, 14, 0)]
        XCTAssertEqual(HealthAlertEvaluator.nonExercising(series, activeIntervals: [], pad: 10 * 60), series)
    }

    func testNonExercisingGatedEvaluateOnlyAlertsStillCrossing() {
        // End-to-end: gate a mixed series then evaluate. The exercising 165 bpm is suppressed while the
        // still-period resting crossing (128 bpm, no concurrent steps) still fires exactly once (#144).
        let thresholds = HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
        let stepping = (at(10, 0), at(10, 20))
        let mixed = [hr(165, 10, 10),                   // exercising → suppressed
                     hr(128, 14, 0)]                    // resting crossing → alerts
        let gated = HealthAlertEvaluator.nonExercising(mixed, activeIntervals: [stepping])
        let hits = HealthAlertEvaluator.evaluate(hr: gated, spo2: [], inactiveHR: gated, thresholds: thresholds).hits
        XCTAssertEqual(hits.map(\.notification), [.highHR])
        XCTAssertEqual(hits.first?.value, 128)
    }

    // MARK: #144 activeStepIntervals — the production step-source path + day-wide fallback guard

    func testActiveStepIntervalsKeepsNarrowNonzeroWindows() {
        // A normal per-reading window (a few minutes, nonzero delta) becomes a gate interval.
        let w = [StepWindow(start: at(10, 0), end: at(10, 3), delta: 40)]
        let intervals = HealthAlertEvaluator.activeStepIntervals(w)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.0, at(10, 0))
        XCTAssertEqual(intervals.first?.1, at(10, 3))
    }

    func testActiveStepIntervalsDropsZeroDeltaWindow() {
        let w = [StepWindow(start: at(10, 0), end: at(10, 3), delta: 0)]
        XCTAssertTrue(HealthAlertEvaluator.activeStepIntervals(w).isEmpty)
    }

    func testActiveStepIntervalsExcludesDayWideFallbackWindow() {
        // SAFETY GUARD: a fresh-baseline / rollover reading records a day-wide [startOfDay, sampleDate]
        // window. It MUST NOT become a gate interval — otherwise it blankets the whole day.
        let dayWide = [StepWindow(start: at(0, 0), end: at(10, 15), delta: 900)]   // 10h15m fallback
        XCTAssertTrue(HealthAlertEvaluator.activeStepIntervals(dayWide).isEmpty,
                      "day-wide fallback window must not become a gate interval")
        // The boundary: a window exactly at the cap is kept; just over it is dropped.
        let atCap  = [StepWindow(start: at(10, 0), end: at(10, 30), delta: 5)]     // == 30 min
        let overCap = [StepWindow(start: at(10, 0), end: at(10, 31), delta: 5)]    // 31 min
        XCTAssertEqual(HealthAlertEvaluator.activeStepIntervals(atCap).count, 1)
        XCTAssertTrue(HealthAlertEvaluator.activeStepIntervals(overCap).isEmpty)
    }

    func testDayWideFallbackWindowCannotSuppressGenuineCrossing() {
        // End-to-end safety: a resting crossing at 08:30 (no narrow activity) must STILL fire even
        // when a day-wide fallback step window [00:00, 10:15] is present — the guard drops that window
        // so it can't blanket-suppress the morning (the catastrophic false-negative this guards).
        let thresholds = HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
        let steps = [StepWindow(start: at(0, 0), end: at(10, 15), delta: 900)]     // day-wide fallback only
        let intervals = HealthAlertEvaluator.activeStepIntervals(steps)
        let crossing = [hr(150, 8, 30)]                                            // resting, no concurrent steps
        let gated = HealthAlertEvaluator.nonExercising(crossing, activeIntervals: intervals)
        let hits = HealthAlertEvaluator.evaluate(hr: gated, spo2: [], inactiveHR: gated, thresholds: thresholds).hits
        XCTAssertEqual(hits.map(\.notification), [.highHR],
                       "a day-wide fallback window must never silence a real crossing")
    }

    func testNarrowWindowGateEngagesOnRealStepData() {
        // The gate DOES engage on real narrow windows (proving it's not a no-op): 165 bpm concurrent
        // with a 3-min stepping window is suppressed, while a resting 128 bpm in a still period fires.
        let thresholds = HealthAlertThresholds(highHRBpm: 120, lowSpO2Enabled: false, elevatedHREnabled: false)
        let steps = [StepWindow(start: at(10, 0), end: at(10, 3), delta: 60)]
        let intervals = HealthAlertEvaluator.activeStepIntervals(steps)
        let mixed = [hr(165, 10, 1),   // exercising → suppressed
                     hr(128, 14, 0)]   // resting crossing → alerts
        let gated = HealthAlertEvaluator.nonExercising(mixed, activeIntervals: intervals)
        let hits = HealthAlertEvaluator.evaluate(hr: gated, spo2: [], inactiveHR: gated, thresholds: thresholds).hits
        XCTAssertEqual(hits.map(\.notification), [.highHR])
        XCTAssertEqual(hits.first?.value, 128)
    }

    // MARK: #137 bedtime reminder bypasses the quiet-hours gate (caller-side split)

    func testBedtimeReminderBypassesQuietHoursWhileVitalsStayMuted() {
        // Reproduces the `evaluateReminders` split: `now` is 22:45 — inside BOTH the default
        // 22:00–07:00 quiet window AND a typical [22:30, 23:00) bedtime window. A body-vital alert
        // stays muted (no regression), while the bedtime reminder — gated with quiet DISABLED —
        // survives, and the anti-spam backoff still de-dupes it so it fires at most once per night.
        let gate = NotificationGate()
        let quiet = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        let now = at(22, 45)
        // Body-vital alert: still suppressed during quiet hours.
        XCTAssertTrue(gate.filter([.highHR], now: now, lastFired: [:], quietHours: quiet).isEmpty)
        // Bedtime reminder: gated with quiet disabled → fires even though `now` is inside quiet hours.
        XCTAssertEqual(gate.filter([.bedtimeReminder], now: now, lastFired: [:],
                                   quietHours: QuietHours(enabled: false)), [.bedtimeReminder])
        // Backoff still applies: a second eval later in the same window is suppressed (fires once/night).
        XCTAssertTrue(gate.filter([.bedtimeReminder], now: at(22, 50),
                                  lastFired: [.bedtimeReminder: now],
                                  quietHours: QuietHours(enabled: false)).isEmpty)
    }

    // MARK: #85 flag routing

    func testTempFeverRouting() {
        var flags = SkinTempBaseline.AnomalyFlags()
        flags.abnormalRise = true
        flags.fluctuationDrop = true
        let notifs = TempFeverNotifications.notifications(flags: flags, feverSuspected: true)
        XCTAssertEqual(Set(notifs), [.skinTempRise, .skinTempFluctuationDrop, .fever])
        XCTAssertTrue(TempFeverNotifications.notifications(flags: SkinTempBaseline.AnomalyFlags(),
                                                          feverSuspected: false).isEmpty)
    }

    func testFreshForNightDropsAlreadyNotifiedNight() {
        let night = TempFeverNotifications.dayKey(for: at(3), calendar: cal)   // this overnight's summary
        let cands: [HealthNotification] = [.skinTempFluctuationDrop, .fever]
        // Same night already notified for the fluctuation drop → drop it, keep the unnotified fever.
        let fresh = TempFeverNotifications.freshForNight(
            cands, night: night, lastNotifiedNight: [.skinTempFluctuationDrop: night])
        XCTAssertEqual(fresh, [.fever], "same night must not re-fire the same flag")
        // No prior night for either → both survive.
        XCTAssertEqual(TempFeverNotifications.freshForNight(cands, night: night, lastNotifiedNight: [:]),
                       cands)
    }

    func testFreshForNightReArmsOnNewerNight() {
        let lastNightDate = cal.startOfDay(for: at(3))
        let lastNight = TempFeverNotifications.dayKey(for: lastNightDate, calendar: cal)
        let newerNight = TempFeverNotifications.dayKey(
            for: cal.date(byAdding: .day, value: 1, to: lastNightDate)!, calendar: cal)
        let fresh = TempFeverNotifications.freshForNight(
            [.skinTempFluctuationDrop], night: newerNight,
            lastNotifiedNight: [.skinTempFluctuationDrop: lastNight])
        XCTAssertEqual(fresh, [.skinTempFluctuationDrop], "a new night's summary re-arms the alert")
        // A stale (older) recompute of a night we've moved past must not re-fire.
        XCTAssertTrue(TempFeverNotifications.freshForNight(
            [.skinTempFluctuationDrop], night: lastNight,
            lastNotifiedNight: [.skinTempFluctuationDrop: newerNight]).isEmpty)
    }

    func testDayKeyIsTimezoneStableAcrossWestwardTravel() {
        // The SAME night instant, keyed after westward travel (offset decreasing) between two syncs.
        // The old ledger stored `startOfDay(...).timeIntervalSince1970`, whose instant shifts later
        // under that travel and re-fires the duplicate; the yyyymmdd day key must stay put.
        var east = Calendar(identifier: .gregorian)
        east.timeZone = TimeZone(identifier: "America/New_York")!    // UTC-4 in June
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(identifier: "America/Los_Angeles")! // UTC-7 in June
        // 2026-06-17 12:00 UTC → 08:00 in ET, 05:00 in PT: same calendar day in both zones.
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let night = utc.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12))!
        XCTAssertEqual(TempFeverNotifications.dayKey(for: night, calendar: east),
                       TempFeverNotifications.dayKey(for: night, calendar: west),
                       "day key must be stable across timezone shifts of the same night")
        // Sanity: the discarded start-of-day instants really do differ across the two zones.
        XCTAssertNotEqual(east.startOfDay(for: night), west.startOfDay(for: night))
    }

    // MARK: Quiet hours (DND)

    func testQuietHoursWrapsMidnight() {
        let q = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(q.contains(at(23), calendar: cal))
        XCTAssertTrue(q.contains(at(2), calendar: cal))
        XCTAssertFalse(q.contains(at(12), calendar: cal))
        XCTAssertFalse(q.contains(at(7), calendar: cal), "end is exclusive")
    }

    func testQuietHoursDisabled() {
        let q = QuietHours(enabled: false, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertFalse(q.contains(at(2), calendar: cal))
    }

    // MARK: De-dupe / DND gate

    func testGateSuppressesDuringQuietHours() {
        let gate = NotificationGate()
        let q = QuietHours(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertFalse(gate.shouldFire(.highHR, now: at(2), lastFired: [:], quietHours: q, calendar: cal))
        XCTAssertTrue(gate.shouldFire(.highHR, now: at(12), lastFired: [:], quietHours: q, calendar: cal))
    }

    func testGateRenotifyBackoff() {
        let gate = NotificationGate(renotifyInterval: 2 * 3600)
        let last: [HealthNotification: Date] = [.lowSpO2: at(10)]
        let q = QuietHours(enabled: false)
        // 1h later — still inside backoff.
        XCTAssertFalse(gate.shouldFire(.lowSpO2, now: at(11), lastFired: last, quietHours: q, calendar: cal))
        // 3h later — backoff elapsed.
        XCTAssertTrue(gate.shouldFire(.lowSpO2, now: at(13), lastFired: last, quietHours: q, calendar: cal))
        // A DIFFERENT condition is independent.
        XCTAssertTrue(gate.shouldFire(.highHR, now: at(11), lastFired: last, quietHours: q, calendar: cal))
    }

    func testGateFilterStableOrder() {
        let gate = NotificationGate()
        let q = QuietHours(enabled: false)
        let out = gate.filter([.fever, .highHR, .lowSpO2], now: at(12), lastFired: [:],
                              quietHours: q, calendar: cal)
        // Returned in HealthNotification.allCases order: highHR, lowSpO2, …, fever.
        XCTAssertEqual(out, [.highHR, .lowSpO2, .fever])
    }
}
