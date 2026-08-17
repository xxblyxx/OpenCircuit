// Gate for mirroring a night's sleep to Apple Health.
//
// WHY. With periodic overnight draining (HistoryDrainCadence) the staged night GROWS as epochs
// arrive — so writing a still-in-progress night on each drain would lay down samples for a night
// that hasn't finished being staged. Defer the write until the night is "settled": its latest
// segment ended far enough in the past that it won't advance again (the sleeper is up).
//
// NOTE: what happens once a night IS settled is `HealthKitWriter.mirrorSettledNight`, not a forward
// watermark — it delete-and-replaces the night whenever its staging signature changes, so a later,
// fuller re-stage reaches Health too. (`LocalStore.pendingHealthSleep`/`markSleepWritten` are the
// OLD forward-only watermark this superseded; they are dead code, kept only so an existing store
// doesn't need a destructive migration.) This file's gate is only "is it time to look at this night
// at all", not "has it already been written".
//
// Pure (no Apple frameworks / no HealthKit) so it unit-tests on the CLI.

import Foundation

public enum SleepHealthGate {

    /// How long after the last staged epoch a night is considered done growing. One epoch is 150 s,
    /// and a drain can lag a few minutes, so 20 min comfortably clears "the block might still extend"
    /// without holding a finished night back into the next day.
    public static let settleMargin: TimeInterval = 20 * 60

    /// Whether the night ending at `latestSegmentEnd` is settled enough to mirror to Health.
    /// `nil` (no segments) is never settled. `now`/`margin` injected for testability.
    public static func isSettled(latestSegmentEnd: Date?,
                                 now: Date,
                                 margin: TimeInterval = settleMargin) -> Bool {
        guard let end = latestSegmentEnd else { return false }
        return end <= now.addingTimeInterval(-margin)
    }

    /// Whether a night is safe to mirror now. Ordinary drains still require the quiet margin above;
    /// an authoritative finalization signal (Sleep Focus ended) may write immediately. A finalization
    /// signal never fabricates sleep: real segments are still required. If the ring subsequently
    /// contributes a small tail, that is a genuine staging change — `mirrorSettledNight`'s signature
    /// check picks it up on the next flush and delete-and-replaces the night, same as any re-stage.
    public static func isReadyToWrite(latestSegmentEnd: Date?,
                                      now: Date,
                                      finalized: Bool,
                                      margin: TimeInterval = settleMargin) -> Bool {
        guard latestSegmentEnd != nil else { return false }
        return finalized || isSettled(latestSegmentEnd: latestSegmentEnd, now: now, margin: margin)
    }
}
