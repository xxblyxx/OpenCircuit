import SwiftData
import XCTest
import OpenCircuitKit
@testable import OpenCircuit

/// Regression coverage for the 2026-08-12 bug: a workout's continuous HR silently vanished from
/// LocalStore (and everything downstream — Goals/Trends/export) while still landing correctly in
/// Apple Health. `WorkoutSessionManager` deliberately defers this ingest until AFTER `writeWorkout`
/// banks the HealthKit active-energy credit; by then ordinary live-HR spot reads taken DURING the
/// workout have already advanced the `heartRate` ingest watermark PAST the workout's own samples,
/// so `ingest`'s recency-based SyncCursor read every one of them as stale and dropped the entire
/// workout with nothing in any log to show it. `ingestBackfill` replaces recency with identity
/// (`kind` + `start`) dedup for this one path, sidestepping the ordering conflict entirely.
///
/// All timestamps here are offsets from `Date()` (never raw `timeIntervalSince1970` epoch
/// numbers) so they stay well after the ring's own 2019-12-31 plausibility floor — see
/// `SyncCursorPlausibilityTests` for the same convention.
@MainActor
final class WorkoutHRBackfillIngestTests: XCTestCase {
    private func makeStore() throws -> LocalStore {
        let container = try ModelContainer(
            for: StoredSample.self, StoredCursor.self,
            StoredSleepSummary.self, StoredDaily.self, StoredNap.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return LocalStore(container.mainContext)
    }

    private func hr(_ value: Double, _ date: Date, end: Date? = nil) -> QuantitySample {
        QuantitySample(kind: .heartRate, start: date, end: end, value: value)
    }

    /// The actual bug, reproduced: two live-poll spot reads taken during and right after a workout
    /// already sit at/after the workout's end, advancing the `heartRate` ingest cursor past it.
    /// `ingest` would then drop the whole workout (this is the test that fails on `master`);
    /// `ingestBackfill` must store every sample regardless.
    func testBackfillSurvivesAWatermarkThatAlreadyPassedTheWorkout() throws {
        let store = try makeStore()
        let workoutStart = Date().addingTimeInterval(-3600)
        let workoutEnd = workoutStart.addingTimeInterval(38 * 60)

        // Live-poll spot reads land during/after the workout and advance the ordinary cursor
        // (mirrors WorkoutSessionManager's `endWorkoutHR()` + live monitoring continuing briefly).
        _ = try store.ingest([hr(91, workoutEnd.addingTimeInterval(-60)),
                              hr(90, workoutEnd)])

        // The workout's own continuous HR, entirely BEFORE that watermark.
        var workoutSamples: [QuantitySample] = []
        for offset in stride(from: 0, to: 38 * 60, by: 150) {
            let bpm: Double = 95 + Double(offset % 10)
            let sampleStart = workoutStart.addingTimeInterval(TimeInterval(offset))
            let sampleEnd = workoutStart.addingTimeInterval(TimeInterval(offset + 150))
            workoutSamples.append(hr(bpm, sampleStart, end: sampleEnd))
        }

        let inserted = try store.ingestBackfill(workoutSamples)
        XCTAssertEqual(inserted.count, workoutSamples.count)

        let stored = try store.samples(kind: .heartRate, from: workoutStart, to: workoutEnd)
        XCTAssertEqual(stored.count, workoutSamples.count)
    }

    /// Re-running the same backfill (retry, or the code path firing twice) must not duplicate rows.
    func testBackfillIsIdempotent() throws {
        let store = try makeStore()
        let start = Date().addingTimeInterval(-3600)
        var samples: [QuantitySample] = []
        for i in 0..<10 {
            samples.append(hr(Double(90 + i), start.addingTimeInterval(TimeInterval(i * 150))))
        }

        let first = try store.ingestBackfill(samples)
        XCTAssertEqual(first.count, 10)

        let second = try store.ingestBackfill(samples)
        XCTAssertEqual(second.count, 0, "re-running an identical backfill must insert nothing new")

        let stored = try store.samples(kind: .heartRate, from: start, to: start.addingTimeInterval(3600))
        XCTAssertEqual(stored.count, 10)
    }

    /// `ingestBackfill` must never read or advance the ORDINARY ingest `SyncCursor` — that's the
    /// entire point of the fix (a workout backfill runs deliberately "late," which a recency-based
    /// cursor can't tolerate). Confirmed by snapshotting the cursor before and after.
    func testBackfillNeverTouchesTheIngestCursor() throws {
        let store = try makeStore()
        let start = Date().addingTimeInterval(-7200)

        // Seed an ordinary cursor position, as a real session would have from prior syncs.
        _ = try store.ingest([hr(72, start.addingTimeInterval(-3600))])
        let before = try store.loadCursor()

        var workoutSamples: [QuantitySample] = []
        for i in 0..<5 {
            workoutSamples.append(hr(Double(95 + i), start.addingTimeInterval(TimeInterval(i * 150))))
        }
        _ = try store.ingestBackfill(workoutSamples)

        let after = try store.loadCursor()
        XCTAssertEqual(before, after, "ingestBackfill must not move the ordinary ingest cursor")
    }

    /// Chunked calls (as `WorkoutSessionManager` does, in batches of 64) with a duplicate `start`
    /// straddling a chunk boundary must not double-insert — each chunk's dedup fetch sees rows
    /// already committed by the previous chunk.
    func testChunkBoundaryDuplicateIsNotDoubleInserted() throws {
        let store = try makeStore()
        let start = Date().addingTimeInterval(-3600)
        let shared = hr(88, start.addingTimeInterval(150))

        let firstChunk = [hr(80, start), shared]
        let secondChunk = [shared, hr(90, start.addingTimeInterval(300))]

        let firstInserted = try store.ingestBackfill(firstChunk)
        XCTAssertEqual(firstInserted.count, 2)

        let secondInserted = try store.ingestBackfill(secondChunk)
        XCTAssertEqual(secondInserted.count, 1, "the shared sample must not be re-inserted")

        let stored = try store.samples(kind: .heartRate, from: start, to: start.addingTimeInterval(600))
        XCTAssertEqual(stored.count, 3)
    }

    /// `ingestBackfill` dedups by `(kind, start)` IDENTITY only — it never updates an existing
    /// row's `end`. This is a known, deliberate limitation (not a bug): the 2026-08-12 span fix
    /// (`HRSampleSpan.heldForward`) corrects a workout's spans BEFORE they're first persisted, so
    /// in normal operation every row is written once, correctly, and this never matters. It only
    /// matters for a day already recorded under the old 2 s-stamp bug — re-running the (buggy)
    /// old ingest path a second time would NOT repair it, which is exactly why a repair needs a
    /// dedicated one-shot migration rather than "just re-sync."
    func testIngestBackfillNeverUpdatesEndOnAnExistingRow() throws {
        let store = try makeStore()
        let start = Date().addingTimeInterval(-3600)

        let original = try store.ingestBackfill([hr(90, start, end: start.addingTimeInterval(2))])
        XCTAssertEqual(original.count, 1)

        // Same (kind, start), a materially different (larger, "corrected") end.
        let retry = try store.ingestBackfill([hr(90, start, end: start.addingTimeInterval(10))])
        XCTAssertEqual(retry.count, 0, "an existing (kind, start) row is skipped, not updated")

        let stored = try store.samples(kind: .heartRate, from: start, to: start.addingTimeInterval(20))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].end.timeIntervalSince(stored[0].start), 2, accuracy: 0.001,
                       "the original 2 s span survives unchanged")
    }

    /// Plausibility gating still applies: a 0-bpm placeholder and a pre-ring-epoch garbage
    /// timestamp are rejected exactly as `ingest` would reject them.
    func testImplausibleSamplesAreStillRejected() throws {
        let store = try makeStore()
        let start = Date().addingTimeInterval(-3600)
        let zeroExpected = hr(0, start)
        let ancientTimestamp = hr(90, Date(timeIntervalSince1970: 0))   // predates the ring's epoch floor
        let legit = hr(90, start.addingTimeInterval(150))

        let inserted = try store.ingestBackfill([zeroExpected, ancientTimestamp, legit])
        XCTAssertEqual(inserted.map(\.value), [90])
    }

    /// The workout's HR was already written to Apple Health directly via `HKWorkoutBuilder` before
    /// this backfill ever runs (see `WorkoutSessionManager.writeWorkout`). `pendingHealthSamples()`
    /// must NOT re-surface the backfilled samples as needing a Health write — that would be a
    /// second, duplicate write of energy Health already has. This is guaranteed by
    /// `ingestBackfill` never touching the `hk:` watermark that `pendingHealthSamples()` filters on.
    func testBackfilledSamplesAreNotResurfacedToHealthKit() throws {
        let store = try makeStore()
        let workoutStart = Date().addingTimeInterval(-3600)
        let workoutEnd = workoutStart.addingTimeInterval(38 * 60)

        // The HealthKit mirror watermark already sits PAST the workout, exactly as it would after
        // `writeWorkout` wrote the workout directly to Health and ordinary live polling advanced it.
        try store.markHealthWritten([hr(90, workoutEnd)])

        var workoutSamples: [QuantitySample] = []
        for offset in stride(from: 0, to: 38 * 60, by: 150) {
            let bpm: Double = 95 + Double(offset % 10)
            workoutSamples.append(hr(bpm, workoutStart.addingTimeInterval(TimeInterval(offset))))
        }
        _ = try store.ingestBackfill(workoutSamples)

        let pending = try store.pendingHealthSamples()
        let pendingInWorkoutWindow = pending.filter { $0.start >= workoutStart && $0.start <= workoutEnd }
        XCTAssertTrue(pendingInWorkoutWindow.isEmpty,
                      "backfilled workout HR must not be re-offered to the HealthKit mirror flush")
    }
}
