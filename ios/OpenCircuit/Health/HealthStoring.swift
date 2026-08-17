import Foundation
import HealthKit

/// The slice of `HKHealthStore` `HealthKitWriter` actually calls. Exists so tests can inject a fake
/// store and exercise the sleep-mirror write/verify/delete logic (the ratchet fix, #health-sleep-
/// mirror-duplicates) without a real device or HealthKit entitlement — `HKHealthStore` itself
/// can't be driven deterministically in a unit test (auth is always `.notDetermined` in the test
/// target, and `save`/`deleteObjects` need a granted, on-device store).
///
/// `ownSleepSamples`/`externalSleepSamples` stand in for `HKSampleQuery` + `HKHealthStore.execute(_:)`
/// directly — NOT because those don't exist on `HKHealthStore`, but for two reasons together:
///   1. `HKSampleQuery`'s results handler is private API: nothing outside HealthKit can construct
///      one and later invoke it, so a fake `execute(_ query: HKQuery)` has no way to call back into
///      whatever completion closure production code attached. Abstracting one level higher — "give
///      me the matching samples" — sidesteps that entirely.
///   2. The own-vs-other-app SPLIT (`sourceRevision.source.bundleIdentifier == Bundle.main...`)
///      cannot be faked at the sample level: a plain `HKCategorySample` that never passed through a
///      real `HKHealthStore.save` has an EMPTY `sourceRevision` (verified empirically — throwaway
///      probe test, since removed — `sourceRevision.source.bundleIdentifier` comes back `""`, not
///      `Bundle.main.bundleIdentifier`, even within the SAME process that constructed it). So the
///      split has to happen inside the store implementation, where `HKHealthStore`'s conformance can
///      still do the real bundle-identifier comparison against genuinely-saved samples, while a fake
///      can answer "own" from its own bookkeeping (everything `save()` put there) instead.
///
/// `HKHealthStore`'s conformance below runs the exact same `HKSampleQuery` construction
/// `HealthKitWriter` used to build inline before this seam existed, just packaged as methods.
/// Empirically verified (throwaway probe test, since removed) that `HKQuery.predicateForSamples`/
/// `predicateForObjects` DO evaluate correctly via `NSPredicate.evaluate(with:)` against a plain,
/// never-saved `HKObject` — so `deleteObjects` in a fake stays a real predicate evaluation, not a
/// hand-rolled reimplementation that could drift out of sync with what `deleteNightSleep` actually
/// asks HealthKit to do.
///
/// Every other method here is implemented by `HKHealthStore` already with a matching signature, so
/// that half of the conformance is free — no wrapper, no behavior change for the real app.
protocol HealthStoring: AnyObject {
    func save(_ object: HKObject) async throws
    func save(_ objects: [HKObject]) async throws
    func deleteObjects(of objectType: HKObjectType, predicate: NSPredicate) async throws -> Int
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    func requestAuthorization(toShare typesToShare: Set<HKSampleType>,
                             read typesToRead: Set<HKObjectType>) async throws
    func statusForAuthorizationRequest(toShare typesToShare: Set<HKSampleType>,
                                       read typesToRead: Set<HKObjectType>) async throws -> HKAuthorizationRequestStatus
    /// OUR OWN `.sleepAnalysis` samples with `startDate`/`endDate` overlapping `[start, end)`
    /// (`end == nil` means open-ended), sorted by `startDate` ascending. Mirrors the HONEST EMPTY
    /// stance the callers document: a denied read and "nothing there" both come back `[]`.
    func ownSleepSamples(from start: Date, to end: Date?) async -> [HKCategorySample]
    /// Same window, OTHER apps' `.sleepAnalysis` samples only — `readExternalSleepSamples`'s
    /// reference-label read.
    func externalSleepSamples(from start: Date, to end: Date?) async -> [HKCategorySample]
    /// Same shape as the two above, for `.headache` (`readHeadacheSamples`, which does its own
    /// own/external split downstream rather than needing two separate queries).
    func headacheSamples(since: Date) async -> [HKCategorySample]
}

extension HKHealthStore: HealthStoring {
    func ownSleepSamples(from start: Date, to end: Date?) async -> [HKCategorySample] {
        guard let ownBundleID = Bundle.main.bundleIdentifier else { return [] }
        let all = await categorySamples(HKCategoryType(.sleepAnalysis), from: start, to: end)
        return all.filter { $0.sourceRevision.source.bundleIdentifier == ownBundleID }
    }

    func externalSleepSamples(from start: Date, to end: Date?) async -> [HKCategorySample] {
        guard let ownBundleID = Bundle.main.bundleIdentifier else { return [] }
        let all = await categorySamples(HKCategoryType(.sleepAnalysis), from: start, to: end)
        return all.filter { $0.sourceRevision.source.bundleIdentifier != ownBundleID }
    }

    func headacheSamples(since: Date) async -> [HKCategorySample] {
        await categorySamples(HKCategoryType(.headache), from: since, to: nil)
    }

    private func categorySamples(_ type: HKCategoryType, from start: Date, to end: Date?) async -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(keyPath: \HKSample.startDate, ascending: true)]
            ) { _, result, _ in
                cont.resume(returning: (result as? [HKCategorySample]) ?? [])
            }
            self.execute(query)
        }
    }
}
