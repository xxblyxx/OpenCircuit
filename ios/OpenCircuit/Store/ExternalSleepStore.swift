import Foundation
import OpenCircuitKit

// Persists reference sleep labels read out of HealthKit (`ExternalSleepSample` — Whoop / Apple
// Watch intervals) so desktop analysis can reach them.
//
// WHY USERDEFAULTS, not SwiftData. Exactly `EpochArchiveStore`'s reasoning, plus one more: the
// desktop tooling already pulls `Library/Preferences/com.bly.opencircuit.plist` over USB
// (`desktop/device_alert_audit.py --pull`, `desktop/sleep_awake_trace.py --pull`), so landing here
// means the labels arrive through a path that already works rather than needing a second export
// mechanism. Small, schema-free, regenerable blob — the same shape as the epoch archive.
//
// ⚠️ REGENERABLE, NOT PRECIOUS. Everything here can be re-read from HealthKit at any time, so this
// store may be cleared freely. It is a CACHE for analysis, never a source of truth, and nothing in
// the shipping app's health pipeline reads it — deliberately: reference labels must not leak into
// the classifier they exist to evaluate.
struct ExternalSleepStore {
    private let defaults: UserDefaults
    private let samplesKey = "sleep.externalSamples"
    private let importedAtKey = "sleep.externalSamplesImportedAt"
    private let windowKey = "sleep.externalSamplesWindowDays"

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Replace the stored set. Whole-set replacement rather than merge: HealthKit is the system of
    /// record and a re-read is cheap, so merging would only risk retaining samples another app has
    /// since corrected or deleted.
    func save(_ samples: [ExternalSleepSample], windowDays: Int) {
        defaults.set(ExternalSleepCodec.encode(samples), forKey: samplesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: importedAtKey)
        defaults.set(windowDays, forKey: windowKey)
    }

    func load() -> [ExternalSleepSample] {
        guard let data = defaults.data(forKey: samplesKey) else { return [] }
        return ExternalSleepCodec.decode(data)
    }

    /// When the last import ran, or nil if never. Distinguishes "imported and found nothing"
    /// (a real, reportable outcome — see `readExternalSleepSamples`'s HONEST EMPTY note) from
    /// "never imported", which the sample count alone cannot.
    var lastImportedAt: Date? {
        let t = defaults.double(forKey: importedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The lookback the last import used, so a small result can be read against the window that
    /// produced it rather than assumed to be the whole history.
    var lastWindowDays: Int { defaults.integer(forKey: windowKey) }

    func clear() {
        defaults.removeObject(forKey: samplesKey)
        defaults.removeObject(forKey: importedAtKey)
        defaults.removeObject(forKey: windowKey)
    }
}
