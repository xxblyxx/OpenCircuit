// OpenCircuit's OWN sleep-stage samples, read back out of HealthKit — the audit instrument for
// docs/PENDING_VALIDATION.md's `sleep-health-mirror-idempotent` entry.
//
// WHY THIS EXISTS. `HealthKitWriter.mirrorSettledNight` delete-and-replaces a night's sleep in
// Apple Health whenever the staging changes, tracked by a signature in `MirroredNightOverlay`. If
// the delete half of that ever fails silently, Health keeps BOTH the old and the new copy, and the
// bookkeeping has no way to notice — the signature is what says "Health matches the stored
// hypnogram", and nothing before this ever checked that claim against Health itself. This is the
// read side of that check: it reads OUR OWN previously-written samples back, so an audit (or the
// mirror's own post-delete verification) can compare "what we believe we wrote" against "what
// Health actually holds".
//
// Deliberately separate from `ExternalSleepSample`, which is scoped to OTHER apps' samples for
// reference-label tuning — mixing the two would blur a doc-comment distinction that matters
// (`ExternalSleepSample`'s file header). `source` is dropped here (it is always this app's bundle);
// `appVersion` is kept instead, because it is what answers "are the extra copies old app versions
// (one-shot legacy debt) or the current version (an ongoing bug)?"

import Foundation

/// One `.sleepAnalysis` interval HealthKit attributes to OpenCircuit itself.
public struct OwnSleepSample: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: SleepStage
    /// `sourceRevision.version` at write time — the app version that wrote this exact sample, so a
    /// pile of duplicates can be told apart as "old build, already fixed" vs. "current build,
    /// still happening".
    public let appVersion: String

    public init(start: Date, end: Date, stage: SleepStage, appVersion: String) {
        self.start = start
        self.end = end
        self.stage = stage
        self.appVersion = appVersion
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

// MARK: - Codec

/// On-disk codec mirroring `ExternalSleepCodec`'s stance (narrow, explicitly-pinned, never trap /
/// never invent — drop only the one row that can't be read) so the pulled plist and a desktop
/// reader stay in lockstep with a Swift rename.
///
/// Format: JSON array of `[startEpochSeconds, endEpochSeconds, stageCode, appVersion]`, SAME stage
/// codes as `SleepHypnogramCodec`/`ExternalSleepCodec` (0=inBed 1=awake 2=core 3=deep 4=REM).
public enum OwnSleepCodec {
    private static let codeForStage: [SleepStage: Int] = [
        .inBed: 0, .awake: 1, .asleepCore: 2, .asleepDeep: 3, .asleepREM: 4
    ]
    private static let stageForCode: [Int: SleepStage] = [
        0: .inBed, 1: .awake, 2: .asleepCore, 3: .asleepDeep, 4: .asleepREM
    ]

    public static func encode(_ samples: [OwnSleepSample]) -> Data {
        let rows: [[AnyEncodableRow]] = samples.compactMap { s in
            guard let code = codeForStage[s.stage] else { return nil }
            let start = Int(s.start.timeIntervalSince1970.rounded())
            let end = Int(s.end.timeIntervalSince1970.rounded())
            guard end > start else { return nil }
            return [.int(start), .int(end), .int(code), .string(s.appVersion)]
        }
        return (try? JSONEncoder().encode(rows)) ?? Data()
    }

    public static func decode(_ data: Data) -> [OwnSleepSample] {
        guard !data.isEmpty,
              let rows = try? JSONDecoder().decode([[AnyEncodableRow]].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard row.count == 4,
                  case .int(let start) = row[0],
                  case .int(let end) = row[1],
                  case .int(let code) = row[2],
                  case .string(let version) = row[3],
                  let stage = stageForCode[code],
                  end > start
            else { return nil }
            return OwnSleepSample(start: Date(timeIntervalSince1970: TimeInterval(start)),
                                  end: Date(timeIntervalSince1970: TimeInterval(end)),
                                  stage: stage, appVersion: version)
        }
    }

    /// Same heterogeneous-cell shape as `ExternalSleepCodec.AnyEncodableRow`, kept private/local
    /// rather than shared: two codecs pinning their own wire format independently means a future
    /// change to one can never silently ripple into the other's stored bytes.
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
