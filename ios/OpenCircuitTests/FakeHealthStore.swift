import HealthKit
@testable import OpenCircuit

/// In-memory `HealthStoring` fake for exercising `HealthKitWriter`'s sleep-mirror write/delete/
/// verify logic (#health-sleep-mirror-duplicates) without a real device or HealthKit entitlement.
///
/// `deleteObjects`/`ownSleepSamples` filter the in-memory `objects` array using the REAL
/// `NSPredicate` production code builds (`HKQuery.predicateForSamples`,
/// `HKQuery.predicateForObjects(with:)`), verified (throwaway probe test, since removed) to evaluate
/// correctly via `NSPredicate.evaluate(with:)` against a plain, never-saved `HKCategorySample` — so
/// this fake reuses HealthKit's own predicate semantics rather than a hand-rolled reimplementation
/// that could drift out of sync with what `deleteNightSleep` actually asks HealthKit to do.
///
/// `ownSleepSamples` returns everything in `objects` (a plain `HKCategorySample` never carries a
/// usable `sourceRevision` unless it passed through a REAL `HKHealthStore.save` — confirmed
/// empirically, throwaway probe test since removed — so this fake can't replicate `HKHealthStore`'s
/// bundle-identifier split at the sample level). Everything the fake holds is, BY CONSTRUCTION,
/// something a test put there via `save`, so treating it all as "own" is the correct fake semantic,
/// not an approximation. `externalSleepSamples` always returns `[]` — no sleep-mirror test currently
/// needs to simulate another app's overlapping sleep; add a separate seed method here first if one
/// ever does, rather than repurposing `objects`.
final class FakeHealthStore: HealthStoring {
    private(set) var objects: [HKObject] = []

    /// Queue of results for successive `deleteObjects` calls: `.success` deletes matching objects
    /// normally; `.failure` throws (simulating the transient/unknown HealthKit error the ratchet fix
    /// has to survive) WITHOUT deleting anything. Exhausted queue falls back to `.success`.
    var deleteOutcomes: [Result<Void, Error>] = []
    /// When true, a successful `deleteObjects` call still leaves ONE non-excluded matching object
    /// behind — simulates the OTHER failure mode verify-then-record guards against: a call that
    /// doesn't throw but doesn't fully apply either.
    var deleteLeavesOneStraggler = false
    private(set) var deleteCallCount = 0

    struct StubError: Error {}

    func save(_ object: HKObject) async throws { objects.append(object) }
    func save(_ objects: [HKObject]) async throws { self.objects.append(contentsOf: objects) }

    func deleteObjects(of objectType: HKObjectType, predicate: NSPredicate) async throws -> Int {
        deleteCallCount += 1
        if !deleteOutcomes.isEmpty, case .failure(let error) = deleteOutcomes.removeFirst() {
            throw error
        }
        var matching = objects.filter { object in
            guard let sample = object as? HKSample, sample.sampleType == objectType else { return false }
            return predicate.evaluate(with: object)
        }
        if deleteLeavesOneStraggler, !matching.isEmpty {
            matching.removeLast()   // leave it in `objects` — an incompletely-applied delete
        }
        let deletedIDs = Set(matching.map(\.uuid))
        objects.removeAll { deletedIDs.contains($0.uuid) }
        return matching.count
    }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { .sharingAuthorized }

    func requestAuthorization(toShare typesToShare: Set<HKSampleType>,
                              read typesToRead: Set<HKObjectType>) async throws {}

    func statusForAuthorizationRequest(toShare typesToShare: Set<HKSampleType>,
                                       read typesToRead: Set<HKObjectType>) async throws
        -> HKAuthorizationRequestStatus { .unnecessary }

    func ownSleepSamples(from start: Date, to end: Date?) async -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return objects.compactMap { $0 as? HKCategorySample }.filter { predicate.evaluate(with: $0) }
    }

    func externalSleepSamples(from start: Date, to end: Date?) async -> [HKCategorySample] { [] }

    func headacheSamples(since: Date) async -> [HKCategorySample] { [] }
}
