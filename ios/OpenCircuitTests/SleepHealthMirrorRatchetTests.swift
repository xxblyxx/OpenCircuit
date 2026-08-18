import HealthKit
import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Exercises `HealthKitWriter.mirrorSettledNight`'s write→delete→verify cycle against a fake
/// `HealthStoring` (#health-sleep-mirror-duplicates) — the bug where the mirror recorded its
/// signature even when the delete failed. That silenced every future retry (the next flush's
/// `last?.signature == signature` short-circuit fired immediately) and let every subsequent
/// re-stage pile another full copy of the night on top of the one still stuck in Health. Measured
/// on-device: 4 of the 5 stored nights had accumulated copies this way — see
/// `docs/PENDING_VALIDATION.md` → `sleep-health-mirror-idempotent` for the sample dump that found it.
@MainActor
final class SleepHealthMirrorRatchetTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var cleanupStore: LocalStore!
    private var touchedNights: [Date] = []
    // Reference far from "now" and distinct from other suites' reference dates, so the
    // UserDefaults-backed MirroredNightOverlay/PendingSleepRepairStore keys these tests touch never
    // collide with another suite's.
    private let ref = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        cleanupStore = try makeStore()
    }

    override func tearDown() {
        for night in touchedNights {
            cleanupStore?.clearMirroredNight(night: night)
            cleanupStore?.clearPendingSleepRepair(night: night)
        }
        touchedNights = []
        containers.removeAll()
        super.tearDown()
    }

    private func at(_ hours: Double) -> Date { ref.addingTimeInterval(hours * 3600) }

    private func seg(_ startMin: Double, _ endMin: Double, _ stage: SleepStage, base: Date) -> SleepSegment {
        SleepSegment(start: base.addingTimeInterval(startMin * 60),
                     end: base.addingTimeInterval(endMin * 60), stage: stage)
    }

    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            StoredPeriodEntry.self, StoredDaytimeTemp.self, StoredStepSample.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return LocalStore(container.mainContext)
    }

    /// Seeds a card so `mirrorSettledNight`'s `sleepSummaryOverlapping` lookup resolves — same
    /// pattern as `SleepMirrorOverlapTests`. Returns the resolved night key (`startOfDay(inBedEnd)`,
    /// matching `SleepNightKey`) so the test can look up `mirroredNight`/`pendingSleepRepair` and so
    /// `tearDown` can clean up their UserDefaults-backed state.
    @discardableResult
    private func seedNight(_ store: LocalStore, inBedStart: Date, inBedEnd: Date) throws -> Date {
        let summary = SleepStaging.Summary(inBed: inBedEnd.timeIntervalSince(inBedStart),
                                           awake: 30 * 60, light: 5 * 3600, deep: 90 * 60, rem: 60 * 60)
        let night = Calendar.current.startOfDay(for: inBedEnd)
        try store.saveSleepSummary(summary, night: night, inBedStart: inBedStart, inBedEnd: inBedEnd,
                                   sleepOnset: inBedStart, sleepWake: inBedEnd)
        touchedNights.append(night)
        return night
    }

    // MARK: - Idempotency

    /// Health starts already holding TWO stale copies of the night (simulating the polluted state
    /// measured on-device). One `mirrorSettledNight` call must clean that down to exactly ONE copy —
    /// not add a third on top.
    func testMirrorCleansPreExistingDuplicatesDownToOneCopy() async throws {
        let inBedStart = at(0), inBedEnd = at(8)
        let store = try makeStore()
        try seedNight(store, inBedStart: inBedStart, inBedEnd: inBedEnd)
        let segments = [
            seg(0, 480, .inBed, base: inBedStart),
            seg(0, 240, .asleepCore, base: inBedStart),
            seg(240, 480, .asleepDeep, base: inBedStart),
        ]
        let fake = FakeHealthStore()
        let seeder = HealthKitWriter(store: fake)
        try await seeder.write(sleep: segments)   // simulate the pre-fix code's first duplicate
        try await seeder.write(sleep: segments)   // and a second
        XCTAssertEqual(fake.objects.count, segments.count * 2, "precondition: Health starts polluted")

        let writer = HealthKitWriter(store: fake)
        let outcome = await writer.mirrorSettledNight(local: store, segments: segments)
        guard case .wrote = outcome else { return XCTFail("expected .wrote, got \(outcome)") }
        XCTAssertEqual(fake.objects.count, segments.count,
                       "mirror must clean pre-existing duplicates down to exactly one copy")
    }

    // MARK: - The ratchet regression

    /// THE test that would have caught the shipped bug. A failed delete must not silence future
    /// retries: re-flushing the SAME (unchanged) staging must not re-enter the write path and add
    /// another copy.
    func testFailedDeleteBlocksSignatureAndRepeatFlushAddsNoThirdCopy() async throws {
        let inBedStart = at(0), inBedEnd = at(8)
        let store = try makeStore()
        let night = try seedNight(store, inBedStart: inBedStart, inBedEnd: inBedEnd)
        let stagingA = [seg(0, 480, .inBed, base: inBedStart), seg(0, 480, .asleepCore, base: inBedStart)]
        let stagingB = [
            seg(0, 480, .inBed, base: inBedStart),
            seg(0, 240, .asleepCore, base: inBedStart),
            seg(240, 480, .asleepDeep, base: inBedStart),
        ]
        let fake = FakeHealthStore()
        let writer = HealthKitWriter(store: fake)

        // First mirror: staging A, nothing to delete, succeeds and records the signature.
        let first = await writer.mirrorSettledNight(local: store, segments: stagingA)
        guard case .wrote = first else { return XCTFail("expected initial write, got \(first)") }
        XCTAssertEqual(fake.objects.count, stagingA.count)

        // Re-stage to B, with the delete THROWING once — the unknown HealthKit failure this exists
        // to survive.
        fake.deleteOutcomes = [.failure(FakeHealthStore.StubError())]
        let second = await writer.mirrorSettledNight(local: store, segments: stagingB)
        guard case .wroteNeedsRepair = second else { return XCTFail("expected .wroteNeedsRepair, got \(second)") }
        // Health now holds A's stale samples PLUS B's fresh ones — the delete never ran.
        XCTAssertEqual(fake.objects.count, stagingA.count + stagingB.count)
        XCTAssertNotEqual(store.mirroredNight(night: night)?.signature, HealthKitWriter.sleepSignature(stagingB),
                          "a failed delete must NOT record staging B's signature")
        XCTAssertNotNil(store.pendingSleepRepair(night: night), "a failed delete must leave a repair marker")

        // THE REGRESSION: flush again with the SAME (unchanged) staging B. Before the fix, `last`
        // was still A's (or nil), so this re-entered the write path and added a THIRD copy on top of
        // the stuck one. The fix's pending-repair guard must make this a no-op.
        let third = await writer.mirrorSettledNight(local: store, segments: stagingB)
        guard case .unchanged = third else {
            return XCTFail("a night with a pending repair for the SAME staging must not re-enter the "
                           + "write path, got \(third)")
        }
        XCTAssertEqual(fake.objects.count, stagingA.count + stagingB.count,
                       "must still be exactly one write's worth of stale (A) + one of fresh (B) — no third copy")
        // 2, not 3: the first mirror (staging A) issues its own no-op delete, the second (staging B)
        // issues the one that throws. The blocked THIRD call must not add a third.
        XCTAssertEqual(fake.deleteCallCount, 2, "the blocked re-entry must not even attempt another delete")
    }

    /// The companion to the regression test: once the delete genuinely succeeds, the drain closes
    /// the repair — clears the marker, records the signature, and cleans up the stale copy — WITHOUT
    /// ever re-writing (a re-write would be yet another duplicate; the fresh copy from the original
    /// write is already correct).
    func testDrainRetriesDeleteAloneAndClosesTheRepairOnceVerified() async throws {
        let inBedStart = at(0), inBedEnd = at(8)
        let store = try makeStore()
        let night = try seedNight(store, inBedStart: inBedStart, inBedEnd: inBedEnd)
        let stagingA = [seg(0, 480, .inBed, base: inBedStart), seg(0, 480, .asleepCore, base: inBedStart)]
        let stagingB = [
            seg(0, 480, .inBed, base: inBedStart),
            seg(0, 240, .asleepCore, base: inBedStart),
            seg(240, 480, .asleepDeep, base: inBedStart),
        ]
        let fake = FakeHealthStore()
        let writer = HealthKitWriter(store: fake)

        _ = await writer.mirrorSettledNight(local: store, segments: stagingA)
        fake.deleteOutcomes = [.failure(FakeHealthStore.StubError())]
        _ = await writer.mirrorSettledNight(local: store, segments: stagingB)
        XCTAssertNotNil(store.pendingSleepRepair(night: night), "precondition: a repair is pending")
        let beforeDrainCount = fake.objects.count

        // Now the delete succeeds. Drain WITHOUT going through mirrorSettledNight again.
        await writer.drainPendingSleepRepairs(local: store)

        XCTAssertNil(store.pendingSleepRepair(night: night), "a verified drain must clear the marker")
        XCTAssertEqual(store.mirroredNight(night: night)?.signature, HealthKitWriter.sleepSignature(stagingB),
                       "a verified drain must record B's signature")
        XCTAssertEqual(fake.objects.count, stagingB.count,
                       "the drain must remove staging A's stale copy, leaving only B — never re-write")
        XCTAssertLessThan(fake.objects.count, beforeDrainCount, "the stale copy must actually be gone")
    }

    /// A delete that doesn't throw but doesn't fully apply either (the "reported success but didn't"
    /// failure mode) must be treated the same as an outright throw: no signature, a repair marker.
    func testDeleteThatLeavesAStragglerIsNotTrustedEither() async throws {
        let inBedStart = at(0), inBedEnd = at(8)
        let store = try makeStore()
        let night = try seedNight(store, inBedStart: inBedStart, inBedEnd: inBedEnd)
        let stagingA = [seg(0, 480, .inBed, base: inBedStart), seg(0, 480, .asleepCore, base: inBedStart)]
        let stagingB = [
            seg(0, 480, .inBed, base: inBedStart),
            seg(0, 240, .asleepCore, base: inBedStart),
            seg(240, 480, .asleepDeep, base: inBedStart),
        ]
        let fake = FakeHealthStore()
        let writer = HealthKitWriter(store: fake)
        _ = await writer.mirrorSettledNight(local: store, segments: stagingA)

        fake.deleteLeavesOneStraggler = true
        let outcome = await writer.mirrorSettledNight(local: store, segments: stagingB)
        guard case .wroteNeedsRepair = outcome else { return XCTFail("expected .wroteNeedsRepair, got \(outcome)") }
        XCTAssertNotNil(store.pendingSleepRepair(night: night),
                        "a non-throwing delete that leaves a straggler must still be treated as unverified")
    }

    /// A staged segment that happens to fall inside a previously-mirrored nap window must not
    /// permanently block verification. `ownSleepCount` (production) EXCLUDES nap-window overlaps from
    /// its remaining count — the same scope `deleteNightSleep`'s predicate protects — so the expected
    /// count compared against it must be nap-filtered the same way. Before the fix this compared
    /// against the unfiltered `fresh.count`, so a night whose staging ever overlapped a nap could
    /// never verify clean and would burn every repair attempt into a permanently stuck marker
    /// (#health-sleep-mirror-duplicates, review finding 2a).
    func testSegmentOverlappingANapWindowStillVerifiesClean() async throws {
        let inBedStart = at(0), inBedEnd = at(8)
        let store = try makeStore()
        try seedNight(store, inBedStart: inBedStart, inBedEnd: inBedEnd)
        let segments = [
            seg(0, 480, .inBed, base: inBedStart),
            seg(0, 240, .asleepCore, base: inBedStart),
            seg(240, 480, .asleepDeep, base: inBedStart),
        ]
        // A nap this app already mirrored to Health, overlapping the first 30 minutes of the night —
        // excluded from `deleteNightSleep`'s predicate and from `ownSleepCount`'s verify count, so any
        // fresh sample landing inside it (the `.inBed` and first `.asleepCore` segments here both do)
        // must also be excluded from the EXPECTED count, not just the observed one.
        let nap = StoredNap(start: at(0), end: at(0.5), healthWritten: true)
        store.context.insert(nap)
        try store.context.save()

        let fake = FakeHealthStore()
        let writer = HealthKitWriter(store: fake)
        let outcome = await writer.mirrorSettledNight(local: store, segments: segments)
        guard case .wrote = outcome else {
            return XCTFail("a segment overlapping a nap window must still verify clean, got \(outcome)")
        }
    }

    // MARK: - Rebuild skips nights with nothing to write back

    func testRebuildNightSleepRefusesAnEmptyHypnogram() async {
        let fake = FakeHealthStore()
        let writer = HealthKitWriter(store: fake)
        let store = (try? makeStore())!
        let result = await writer.rebuildNightSleep(local: store, night: at(0), segments: [])
        XCTAssertNil(result, "an empty hypnogram must be refused, not delete Health data with nothing to write back")
        XCTAssertTrue(fake.objects.isEmpty, "nothing should have been written or deleted")
    }
}
