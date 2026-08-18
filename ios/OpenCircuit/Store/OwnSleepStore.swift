import Foundation
import OpenCircuitKit

// Persists OpenCircuit's OWN sleep samples as read back from HealthKit by "Audit Apple Health
// sleep" (DeviceInfoView), so desktop analysis can reach them — same reasoning and same shape as
// `ExternalSleepStore`, whose header explains the USERDEFAULTS-over-SwiftData choice: the desktop
// tooling already pulls `Library/Preferences/com.bly.opencircuit.plist` over USB, so landing here
// means no second export mechanism is needed.
//
// ⚠️ REGENERABLE, NOT PRECIOUS — same stance as `ExternalSleepStore`. Everything here can be
// re-read from HealthKit at any time. It is a CACHE for the audit, never a source of truth, and
// nothing in the shipping health pipeline reads it.
struct OwnSleepStore {
    private let defaults: UserDefaults
    private let samplesKey = "sleep.ownSamples"
    private let auditedAtKey = "sleep.ownSamplesAuditedAt"

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Replace the stored set. Whole-set replacement, same reasoning as `ExternalSleepStore.save` —
    /// HealthKit is the system of record and a re-read is cheap.
    func save(_ samples: [OwnSleepSample]) {
        defaults.set(OwnSleepCodec.encode(samples), forKey: samplesKey)
        defaults.set(Date().timeIntervalSince1970, forKey: auditedAtKey)
    }

    func load() -> [OwnSleepSample] {
        guard let data = defaults.data(forKey: samplesKey) else { return [] }
        return OwnSleepCodec.decode(data)
    }

    /// When the last audit ran, or nil if never — same "distinguish never-run from found-nothing"
    /// reasoning as `ExternalSleepStore.lastImportedAt`.
    var lastAuditedAt: Date? {
        let t = defaults.double(forKey: auditedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    func clear() {
        defaults.removeObject(forKey: samplesKey)
        defaults.removeObject(forKey: auditedAtKey)
    }
}
