// Per-epoch QUALITY EVIDENCE for an SpO2 reading — the bytes the alert rule needs and the
// stored sample does not carry.
//
// WHY THIS FILE EXISTS. `StoredSample` holds `kind/start/end/value` and nothing else, so by the
// time the low-SpO2 alert evaluates, everything that would say whether the reading was TRUSTWORTHY
// is gone. It was never missing from the wire: the same 23-byte `0x4c` record that carries the
// SpO2 percentage in `[8]` also carries a confidence byte in `[6]`, a five-sample motion channel
// in `[10:15]`, and five 12-bit activity magnitudes in `[15:23)`. All three are decoded by
// `BulkRecord` already and fed to nothing.
//
// Rather than widen the SwiftData schema (which would touch the sample path #185 requires to stay
// byte-identical, and buy a migration), the evidence is recovered at ALERT TIME from the rolling
// `EpochArchive`. That is sound because of an arithmetic coincidence worth stating explicitly:
//
//     EpochArchive.retention        = 30 h
//     HealthNotificationCenter.instantLookback = 12 h
//
// The archive prunes at `newest − 30 h` where `newest ≤ now`, and the alert only ever considers
// readings at `≥ now − 12 h`, so EVERY bulk-derived reading the alert can see still has its raw
// record. The archive is a diagnostic convenience for everything else; for this it is complete.
//
// TWO POPULATIONS CANNOT RESOLVE, BY CONSTRUCTION, and the rule is built around that:
//   • live on-demand measurements (`RingSession.stopLiveMonitoring`) come from the `0x15` frame
//     and have no `0x4c` record at all;
//   • a sample from a ring whose archive is namespaced differently, or after a UserDefaults reset.
// See `SpO2AlertPolicy` for why a miss fails OPEN when corroboration is present.
//
// This type lives in the Kit and not the app target because three of the predicates it reads
// (`motionResolvesStillness`, `activityMagnitudesAreZero`, `ActivityPeriod.motionStillThreshold`)
// are module-internal — the app physically cannot see them.

import Foundation

/// What one epoch says about the trustworthiness of the SpO2 reading it carried.
///
/// Deliberately PLAIN VALUES with no byte offsets: the rule that consumes this must not learn the
/// wire format, so the layout can move without touching alert policy.
public struct SpO2Evidence: Equatable, Sendable {
    /// The ring's idle/unworn template (`BulkRecord.layout == .idle`).
    public let unworn: Bool
    /// `motionResolvesStillness` — the five 30-s sub-samples sit within `motionStillThreshold`
    /// of one another, i.e. the epoch on its OWN cannot express movement. FALSE means a step
    /// INSIDE the epoch, which is precisely the motion component a rolling floor cannot subtract.
    public let resolvesStillness: Bool
    /// `max − min` over `[10:15]`. Carried for the LOG, never gated on: the placeholder LEVEL is
    /// device- and posture-dependent (Gen-2 idles at `01`, Gen-3 at `0f` and drifts), so a
    /// threshold on the raw spread would be calibrated to one generation.
    public let motionSpread: Int
    /// `activityMagnitudesAreZero` (#195). LOGGED, NOT GATED in v1 — see `SpO2AlertPolicy`.
    public let magnitudesAllZero: Bool
    /// Byte `[6]`. LOGGED, NOT GATED in v1 — see `SpO2AlertPolicy`.
    public let confidence: Int?

    public init(unworn: Bool, resolvesStillness: Bool, motionSpread: Int,
                magnitudesAllZero: Bool, confidence: Int?) {
        self.unworn = unworn
        self.resolvesStillness = resolvesStillness
        self.motionSpread = motionSpread
        self.magnitudesAllZero = magnitudesAllZero
        self.confidence = confidence
    }

    /// One-line summary for the health-alert log / diagnostics bundle.
    public var summary: String {
        var parts = [unworn ? "unworn" : "worn", resolvesStillness ? "still" : "MOVING"]
        parts.append("spread=\(motionSpread)")
        parts.append("mags\(magnitudesAllZero ? "=0" : ">0")")
        if let confidence { parts.append("conf=\(confidence)") }
        return parts.joined(separator: " ")
    }
}

extension BulkRecord {
    /// Evidence for THIS epoch's SpO2 reading, or nil when the epoch carried none.
    ///
    /// Gated on `spo2Percent != nil` so the caller can never accidentally attribute an activity
    /// epoch's motion to a neighbouring reading — evidence and value come from the same record or
    /// from neither.
    public var spo2Evidence: SpO2Evidence? {
        guard spo2Percent != nil else { return nil }
        return SpO2Evidence(unworn: layout == .idle,
                            resolvesStillness: motionResolvesStillness,
                            motionSpread: Int((motion.max() ?? 0)) - Int((motion.min() ?? 0)),
                            magnitudesAllZero: activityMagnitudesAreZero,
                            confidence: confidence)
    }
}

/// Resolves a stored SpO2 sample's timestamp back to the epoch record that produced it.
public enum SpO2EvidenceIndex {

    /// How far from an exact epoch-second a sample may sit and still match: half an epoch.
    ///
    /// A bulk-derived sample is stamped with `BulkRecord.date(epoch:)`, so it normally lands on
    /// the key EXACTLY. The tolerance exists for samples that took a different route to the store
    /// (a re-stamped or rounded timestamp), and is deliberately under a full epoch so a reading can
    /// never adopt its NEIGHBOUR's motion evidence — which would be worse than having none.
    public static let matchTolerance = 75

    /// Build an epoch-second → evidence map from raw records.
    ///
    /// Integer-keyed on purpose. `date(epoch:)` is `syncEpoch + counter`, both `Int`, so a sample
    /// round-tripped through SwiftData's `Date` lands on exactly this key with no float drift.
    public static func build(_ records: [BulkRecord],
                             epoch: Int = Command.syncEpoch) -> [Int: SpO2Evidence] {
        var out: [Int: SpO2Evidence] = [:]
        out.reserveCapacity(records.count)
        for r in records {
            guard let e = r.spo2Evidence else { continue }
            out[Int(r.counter) + epoch] = e
        }
        return out
    }

    /// Exact key first, then the nearest entry within `tolerance`. Nil when nothing resolves.
    public static func lookup(_ index: [Int: SpO2Evidence], at time: Date,
                              tolerance: Int = matchTolerance) -> SpO2Evidence? {
        guard !index.isEmpty else { return nil }
        let key = Int(time.timeIntervalSince1970.rounded())
        if let hit = index[key] { return hit }
        // `tolerance <= 0` means EXACT MATCH ONLY and must not probe neighbours. The previous
        // `1...max(1, tolerance)` silently widened a caller's `0` into ±1s, so the parameter did
        // not mean what it said.
        guard tolerance > 0 else { return nil }
        for delta in 1...tolerance {
            if let hit = index[key - delta] ?? index[key + delta] { return hit }
        }
        return nil
    }
}
