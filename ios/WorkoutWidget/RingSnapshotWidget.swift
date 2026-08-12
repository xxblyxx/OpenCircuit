// RingSnapshotWidget.swift — the Home Screen / Lock Screen widget (docs/WIDGETS_HOME_SCREEN.md).
//
// Reads the RingSnapshot the app wrote to the App Group container (Shared/RingSnapshot.swift) —
// nothing else. This file, and everything else in `WorkoutWidget/`, must NEVER import SwiftData,
// OpenCircuitKit, or CoreBluetooth: the widget process cannot see the app's SwiftData store (there
// is no code path here that could reach it), and it never talks to the ring directly — the app is
// the only process that ever does that. A missing/corrupt snapshot renders the "open the app"
// placeholder below, never a crash and never a guess dressed up as a reading.
//
// StaticConfiguration, no AppIntentConfiguration: one fixed layout per family, chosen by the user
// rather than made per-widget-instance configurable (docs/WIDGETS_HOME_SCREEN.md decision).

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct RingSnapshotEntry: TimelineEntry {
    let date: Date
    /// nil = no snapshot has ever landed in the App Group container (fresh install, or the app
    /// hasn't synced yet). Rendered as an explicit "open the app" face — never as zeros.
    let snapshot: RingSnapshot?
}

struct RingSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> RingSnapshotEntry {
        // A plausible SAMPLE snapshot, not real data — WidgetKit overlays its own redacted shimmer
        // on top of whatever this renders, so returning realistic shapes (not zeros/dashes) is what
        // makes the shimmer look like the real widget while it loads.
        RingSnapshotEntry(date: Date(), snapshot: .samplePlaceholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (RingSnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? .samplePlaceholder : RingSnapshotStore.read()
        completion(RingSnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RingSnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = RingSnapshotStore.read()
        var entries = [RingSnapshotEntry(date: now, snapshot: snapshot)]
        // A second entry at the exact moment this data crosses into "stale", so the face visibly
        // dims on its own even if the app never writes again (§4: "show the staleness" — no
        // hours-old reading may sit there looking as fresh as the moment it landed).
        if let snapshot {
            let staleAt = snapshot.lastSyncAt.addingTimeInterval(snapshot.staleAfter)
            if staleAt > now {
                entries.append(RingSnapshotEntry(date: staleAt, snapshot: snapshot))
            }
        }
        // `.atEnd`: WidgetKit asks for a new timeline after the last entry's date, and the app's
        // own `WidgetCenter.reloadAllTimelines()` (after every write) preempts that whenever fresh
        // data actually lands — this policy just backstops the staleness transition in between.
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

private extension RingSnapshot {
    static let samplePlaceholder = RingSnapshot(
        sleepScore: 82, sleepBand: "good", asleepMinutes: 434,
        stressScore: 28, stressBand: "relaxed",
        inBedStart: Date().addingTimeInterval(-8 * 3_600), inBedEnd: Date().addingTimeInterval(-30 * 60),
        sleepIsLastNight: true,
        stages: [],
        steps: 6_412, stepsGoal: 8_000,
        activeKcal: 312, activeKcalGoal: 300,
        activityScore: 74, activityTier: "good",
        batteryPercent: 74, batteryCharging: false, batteryAsOf: Date(),
        timeToEmptySeconds: 2.5 * 86_400, timeToFullSeconds: nil,
        lastSyncAt: Date(), staleAfter: 6 * 3_600)
}

// MARK: - Widget registration

struct RingSnapshotWidget: Widget {
    static let kind = "com.standardsoftwaresolutions.opencircuit.RingSnapshotWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: RingSnapshotProvider()) { entry in
            RingSnapshotEntryView(entry: entry)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName("OpenCircuit")
        .description("Last-known sleep, steps, and ring battery from your most recent sync.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular])
    }
}

// MARK: - Entry view: dispatches on family

struct RingSnapshotEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RingSnapshotEntry

    var body: some View {
        // Whole face deep-links into the app (existing `opencircuit://` scheme, Info.plist
        // CFBundleURLTypes) — there's nothing else here TO tap into; every number shown came from
        // the app's last sync, so "see more" always means "open OpenCircuit".
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall:
                    RingSnapshotSmallView(snapshot: snapshot, now: entry.date)
                case .systemMedium:
                    RingSnapshotMediumView(snapshot: snapshot, now: entry.date)
                case .systemLarge:
                    RingSnapshotLargeView(snapshot: snapshot, now: entry.date)
                case .accessoryCircular:
                    RingSnapshotCircularView(snapshot: snapshot)
                default:
                    RingSnapshotSmallView(snapshot: snapshot, now: entry.date)
                }
            } else {
                switch family {
                case .accessoryCircular:
                    RingSnapshotCircularEmptyView()
                default:
                    RingSnapshotEmptyView()
                }
            }
        }
        .widgetURL(URL(string: "opencircuit://"))
    }
}
