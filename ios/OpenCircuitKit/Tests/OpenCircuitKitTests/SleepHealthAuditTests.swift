import XCTest
@testable import OpenCircuitKit

/// Pure segment/overlap invariants behind "Audit Apple Health sleep" (DeviceInfoView) and
/// `desktop/sleep_reference_labels.py --audit-own` — the diagnostic that would have surfaced the
/// sleep-mirror duplicate bug on-device before it needed a manual sample dump
/// (#health-sleep-mirror-duplicates). No HealthKit here; `OwnSleepSample`/`SleepSegment` are plain
/// structs, so this runs on the CLI.
final class SleepHealthAuditTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func own(_ startMin: Double, _ endMin: Double, _ stage: SleepStage,
                     version: String = "1.0") -> OwnSleepSample {
        OwnSleepSample(start: base.addingTimeInterval(startMin * 60),
                      end: base.addingTimeInterval(endMin * 60), stage: stage, appVersion: version)
    }

    private func seg(_ startMin: Double, _ endMin: Double, _ stage: SleepStage) -> SleepSegment {
        SleepSegment(start: base.addingTimeInterval(startMin * 60),
                     end: base.addingTimeInterval(endMin * 60), stage: stage)
    }

    /// A night that matches exactly — the ordinary, healthy steady-state.
    private var cleanStored: [SleepSegment] {
        [seg(0, 480, .inBed), seg(0, 240, .asleepCore), seg(240, 480, .asleepDeep)]
    }
    private var cleanHealth: [OwnSleepSample] {
        [own(0, 480, .inBed), own(0, 240, .asleepCore), own(240, 480, .asleepDeep)]
    }

    func testExactMatchIsClean() {
        let result = SleepHealthAudit.compare(night: base, health: cleanHealth, stored: cleanStored)
        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.overlappingPairs, 0)
        XCTAssertEqual(result.healthSampleCount, result.storedSegmentCount)
    }

    /// A duplicated night — the exact ratchet symptom — must be flagged with overlapping pairs.
    func testDuplicatedNightIsNotCleanAndCountsOverlaps() {
        // Health holds the clean night's samples TWICE (the shape the ratchet bug produced).
        let polluted = cleanHealth + cleanHealth
        let result = SleepHealthAudit.compare(night: base, health: polluted, stored: cleanStored)
        XCTAssertFalse(result.isClean)
        XCTAssertEqual(result.healthSampleCount, cleanHealth.count * 2)
        XCTAssertEqual(result.storedSegmentCount, cleanStored.count)
        // Core and Deep each have one duplicate pair; inBed is excluded from the overlap count.
        XCTAssertEqual(result.overlappingPairs, 2)
    }

    func testDuplicationInflatesHealthMinutesButNotStored() {
        let polluted = cleanHealth + cleanHealth
        let result = SleepHealthAudit.compare(night: base, health: polluted, stored: cleanStored)
        XCTAssertEqual(result.healthMinutesByStage[.asleepCore], result.storedMinutesByStage[.asleepCore]! * 2)
        XCTAssertEqual(result.healthMinutesByStage[.asleepDeep], result.storedMinutesByStage[.asleepDeep]! * 2)
    }

    /// .inBed spans the whole night and legitimately overlaps every staged segment underneath it —
    /// that is the design (`SleepStaging`'s efficiency comment), not a bug the audit should flag.
    func testInBedEnvelopeExcludedFromOverlapCount() {
        let result = SleepHealthAudit.compare(night: base, health: cleanHealth, stored: cleanStored)
        XCTAssertEqual(result.overlappingPairs, 0, "the inBed/staged overlap must never be counted")
    }

    /// Two SEPARATE core-sleep runs later in the night, like a real multi-cycle night — not
    /// adjacent, not overlapping — must not be miscounted as duplicates.
    func testMultipleGenuineRunsOfTheSameStageAreNotOverlaps() {
        let stored = [
            seg(0, 600, .inBed),
            seg(0, 100, .asleepCore),
            seg(100, 200, .asleepDeep),
            seg(200, 300, .asleepCore),
        ]
        let health = [
            own(0, 600, .inBed), own(0, 100, .asleepCore),
            own(100, 200, .asleepDeep), own(200, 300, .asleepCore),
        ]
        let result = SleepHealthAudit.compare(night: base, health: health, stored: stored)
        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.overlappingPairs, 0)
    }

    func testAppVersionsCollectsDistinctVersions() {
        let health = [own(0, 240, .asleepCore, version: "1.0"), own(0, 240, .asleepCore, version: "1.1")]
        let result = SleepHealthAudit.compare(night: base, health: health, stored: [seg(0, 240, .asleepCore)])
        XCTAssertEqual(Set(result.appVersions), ["1.0", "1.1"])
    }

    func testEmptyHealthIsNotClean() {
        let result = SleepHealthAudit.compare(night: base, health: [], stored: cleanStored)
        XCTAssertFalse(result.isClean)
        XCTAssertEqual(result.healthSampleCount, 0)
        XCTAssertEqual(result.storedSegmentCount, cleanStored.count)
    }
}
