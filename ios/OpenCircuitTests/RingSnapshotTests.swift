import XCTest
@testable import OpenCircuit

/// `RingSnapshot` is the ONLY thing that crosses the App-Group process boundary in
/// docs/WIDGETS_HOME_SCREEN.md's design — the widget extension never touches the app's SwiftData
/// store, so a decode failure here is the widget's entire failure mode. These lock: (1) a normal
/// round trip, (2) that an OLDER payload (missing fields this version might not even know about
/// yet) still decodes rather than blanking the widget, and (3) the staleness / no-op rules the
/// writer and the widget faces both depend on.
final class RingSnapshotTests: XCTestCase {
    private let ref = Date(timeIntervalSince1970: 1_750_000_000)

    private func sample(lastSyncAt: Date? = nil, staleAfter: TimeInterval = 6 * 3_600) -> RingSnapshot {
        RingSnapshot(
            sleepScore: 82, sleepBand: "good", asleepMinutes: 434,
            stressScore: 28, stressBand: "relaxed",
            inBedStart: ref.addingTimeInterval(-8 * 3_600), inBedEnd: ref.addingTimeInterval(-30 * 60),
            sleepIsLastNight: true,
            stages: [StageSpan(start: ref.addingTimeInterval(-8 * 3_600), end: ref, stage: "asleepDeep")],
            steps: 6_412, stepsGoal: 8_000,
            activeKcal: 312, activeKcalGoal: 300,
            activityScore: 74, activityTier: "good",
            batteryPercent: 74, batteryCharging: false, batteryAsOf: ref,
            timeToEmptySeconds: 2.5 * 86_400, timeToFullSeconds: nil,
            lastSyncAt: lastSyncAt ?? ref, staleAfter: staleAfter)
    }

    // MARK: Round trip

    func testRoundTripPreservesEveryField() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RingSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: Forward/backward compatibility

    /// A payload written by an OLDER build that predates some of today's fields — e.g. a snapshot
    /// left in the App Group container across an app update — must still decode into something
    /// the widget can render, not throw and blank the face.
    func testMissingFieldsDecodeWithSafeDefaults() throws {
        let minimal = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RingSnapshot.self, from: minimal)
        XCTAssertNil(decoded.sleepScore)
        XCTAssertNil(decoded.steps)
        XCTAssertEqual(decoded.sleepIsLastNight, false)
        XCTAssertEqual(decoded.stages, [])
        XCTAssertEqual(decoded.batteryCharging, false)
        // A snapshot this corrupted/old must classify as STALE, never as fresh — `.distantPast`
        // is the safe direction to fail in.
        XCTAssertEqual(decoded.lastSyncAt, .distantPast)
        XCTAssertTrue(decoded.isStale(now: ref))
    }

    /// A payload written by a NEWER build with a field this version has never heard of. Plain
    /// `JSONDecoder` already ignores unrecognized keys, but this locks that the known fields
    /// alongside it still decode correctly rather than the whole document failing.
    func testUnknownExtraKeysAreIgnored() throws {
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sample()), options: []) as! [String: Any]
        json["aFieldFromTheFuture"] = "unrecognized"
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RingSnapshot.self, from: data)
        XCTAssertEqual(decoded.sleepScore, 82)
        XCTAssertEqual(decoded.steps, 6_412)
    }

    func testStageSpanDecodesMissingFieldsToDistantPastAndEmptyStage() throws {
        let minimal = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StageSpan.self, from: minimal)
        XCTAssertEqual(decoded.start, .distantPast)
        XCTAssertEqual(decoded.end, .distantPast)
        XCTAssertEqual(decoded.stage, "")
    }

    // MARK: Staleness

    func testIsStaleJustUnderThreshold() {
        let snap = sample(lastSyncAt: ref, staleAfter: 6 * 3_600)
        XCTAssertFalse(snap.isStale(now: ref.addingTimeInterval(6 * 3_600 - 1)))
    }

    func testIsStaleJustOverThreshold() {
        let snap = sample(lastSyncAt: ref, staleAfter: 6 * 3_600)
        XCTAssertTrue(snap.isStale(now: ref.addingTimeInterval(6 * 3_600 + 1)))
    }

    func testIsStaleExactlyAtThresholdIsNotYetStale() {
        // `isStale` uses `>`, not `>=` — the entry the writer/timeline schedules AT `staleAfter`
        // should be the moment it BECOMES stale, not one tick early.
        let snap = sample(lastSyncAt: ref, staleAfter: 6 * 3_600)
        XCTAssertFalse(snap.isStale(now: ref.addingTimeInterval(6 * 3_600)))
    }

    // MARK: hasSameDisplayValues (the writer's no-op guard)

    func testHasSameDisplayValuesIgnoresOnlyLastSyncAt() {
        let a = sample(lastSyncAt: ref)
        let b = sample(lastSyncAt: ref.addingTimeInterval(3_600))
        XCTAssertTrue(a.hasSameDisplayValues(as: b), "a later sync with IDENTICAL readings must no-op")
    }

    func testHasSameDisplayValuesDetectsARealChange() {
        let a = sample(lastSyncAt: ref)
        var b = sample(lastSyncAt: ref.addingTimeInterval(3_600))
        b.steps = (b.steps ?? 0) + 1
        XCTAssertFalse(a.hasSameDisplayValues(as: b))
    }
}
