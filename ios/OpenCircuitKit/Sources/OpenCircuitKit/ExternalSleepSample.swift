// Sleep-stage samples written to HealthKit by OTHER apps (Whoop, Apple Watch, …), read back as
// REFERENCE LABELS for our own staging.
//
// WHY THIS EXISTS. `SleepStaging` is tuned against night TOTALS and one Helio strap — the project
// has never had per-epoch labels (docs/RUNBOOK_SLEEP_GROUNDTRUTH.md is the plan to capture
// RingConn's own `sleepPhases`, and `desktop/captures/` is still empty). Meanwhile another wearable
// on the same wrist-night is already writing interval-level stages into HealthKit, and the user has
// authorized us to read them. Those intervals are the cheapest per-epoch reference available, and
// unlike RingConn's own hypnogram they come from an INDEPENDENT sensor — so where they disagree
// with us, the disagreement is informative rather than circular.
//
// ⚠️ REFERENCE, NOT GROUND TRUTH — and the distinction is load-bearing, not a disclaimer.
// A consumer wearable's hypnogram is an ESTIMATE. Independent PSG work puts wrist-actigraphy wake
// sensitivity in the 16–30 % range (measured on the `refs/noop` corpus, see
// docs/SLEEP_AWAKE_RESOLUTION.md §5), so fitting our thresholds to reproduce another vendor's
// labels inherits that vendor's errors as well as its strengths. These samples are for MEASURING
// AGREEMENT and for answering bounded questions ("can our pipeline represent a brief awakening at
// all, and does the ring's own signal co-locate with one?") — not for being copied.
//
// The `source` string is kept on every sample precisely so a later analysis can never silently pool
// two devices of different quality into one "truth" set.

import Foundation

/// One sleep-stage interval written to HealthKit by a named source app.
public struct ExternalSleepSample: Equatable, Sendable {
    /// The writing app's HealthKit source name, verbatim (`sourceRevision.source.name`) — e.g.
    /// "WHOOP", "Apple Watch". Never normalised: two sources must stay distinguishable.
    public let source: String
    public let start: Date
    public let end: Date
    public let stage: SleepStage

    public init(source: String, start: Date, end: Date, stage: SleepStage) {
        self.source = source
        self.start = start
        self.end = end
        self.stage = stage
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// True when this interval covers `date` (half-open, matching `SleepSegment` conventions).
    public func covers(_ date: Date) -> Bool { start <= date && date < end }
}

// MARK: - Codec

/// On-disk codec for a set of external samples, mirroring `SleepHypnogramCodec`'s stance: a narrow,
/// explicitly-pinned format rather than `Codable` over a live model type, so a future field rename
/// cannot silently invalidate what is already stored. Same robustness policy — never trap, never
/// invent, drop only the individual row it cannot read.
///
/// Format: JSON array of `[source, startEpochSeconds, endEpochSeconds, stageCode]`, with the SAME
/// stage codes `SleepHypnogramCodec` uses (0=inBed 1=awake 2=core 3=deep 4=REM) so the two stores
/// can be read by one desktop parser.
public enum ExternalSleepCodec {

    /// Wire code per stage. Stable — must never be renumbered (see `SleepHypnogramCodec`).
    private static let codeForStage: [SleepStage: Int] = [
        .inBed: 0, .awake: 1, .asleepCore: 2, .asleepDeep: 3, .asleepREM: 4
    ]
    private static let stageForCode: [Int: SleepStage] = [
        0: .inBed, 1: .awake, 2: .asleepCore, 3: .asleepDeep, 4: .asleepREM
    ]

    public static func encode(_ samples: [ExternalSleepSample]) -> Data {
        let rows: [[AnyEncodableRow]] = samples.compactMap { s in
            guard let code = codeForStage[s.stage] else { return nil }
            let start = Int(s.start.timeIntervalSince1970.rounded())
            let end = Int(s.end.timeIntervalSince1970.rounded())
            // Refuse to write a row `decode` would drop: a store whose written form disagrees with
            // its loaded form is worse than one that is simply smaller.
            guard end > start else { return nil }
            return [.string(s.source), .int(start), .int(end), .int(code)]
        }
        return (try? JSONEncoder().encode(rows)) ?? Data()
    }

    public static func decode(_ data: Data) -> [ExternalSleepSample] {
        guard !data.isEmpty,
              let rows = try? JSONDecoder().decode([[AnyEncodableRow]].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard row.count == 4,
                  case .string(let source) = row[0],
                  case .int(let start) = row[1],
                  case .int(let end) = row[2],
                  case .int(let code) = row[3],
                  let stage = stageForCode[code],
                  end > start
            else { return nil }
            return ExternalSleepSample(source: source,
                                       start: Date(timeIntervalSince1970: TimeInterval(start)),
                                       end: Date(timeIntervalSince1970: TimeInterval(end)),
                                       stage: stage)
        }
    }

    /// A heterogeneous JSON cell (the row is `[String, Int, Int, Int]`). Kept private to the codec:
    /// it exists only so the wire format can stay a compact positional array rather than growing
    /// four keys per row.
    enum AnyEncodableRow: Codable, Equatable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a string or int")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            }
        }
    }
}

// MARK: - Queries

public extension Array where Element == ExternalSleepSample {
    /// Just the AWAKE intervals — the ones our staging currently cannot produce at all, and so the
    /// only ones worth comparing first (docs/SLEEP_AWAKE_RESOLUTION.md).
    var awakeIntervals: [ExternalSleepSample] { filter { $0.stage == .awake } }

    /// Distinct source names present, sorted. Use before any analysis: pooling two vendors into one
    /// reference set is exactly the mistake `ExternalSleepSample.source` exists to prevent.
    var sources: [String] { Set(map(\.source)).sorted() }

    /// Samples from one source only.
    func from(source: String) -> [ExternalSleepSample] { filter { $0.source == source } }

    /// Samples overlapping `interval` at all (not merely contained), sorted by start.
    func overlapping(_ interval: DateInterval) -> [ExternalSleepSample] {
        filter { $0.start < interval.end && $0.end > interval.start }
            .sorted { $0.start < $1.start }
    }
}
