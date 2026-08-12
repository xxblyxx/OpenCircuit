// RingSnapshotViews.swift — the four widget faces (systemSmall/Medium/Large/accessoryCircular)
// plus the shared empty-state and colour/format helpers. See RingSnapshotWidget.swift for the
// provider + registration; docs/WIDGETS_HOME_SCREEN.md §5 for the layout table.
//
// STALENESS (§4): every face except `accessoryCircular` dims its values + shows an amber
// timestamp once `snapshot.isStale(now:)`. The circular face gates on `sleepIsLastNight` instead
// — a last-night score being nine hours old is correct, not stale; see RingSnapshot.swift's doc
// on that field for why the two faces disagree on purpose.

import WidgetKit
import SwiftUI

// MARK: - Small (sleep score hero + steps + battery)

struct RingSnapshotSmallView: View {
    let snapshot: RingSnapshot
    let now: Date

    var body: some View {
        let stale = snapshot.isStale(now: now)
        VStack(alignment: .leading, spacing: 4) {
            Text("OPENCIRCUIT")
                .font(.system(size: 9).weight(.semibold))
                .foregroundStyle(.secondary)

            if snapshot.sleepIsLastNight, let score = snapshot.sleepScore {
                Text("\(score)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.sleepTierColor(snapshot.sleepBand))
                VStack(alignment: .leading, spacing: 0) {
                    Text("sleep score").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        if let label = WidgetPalette.sleepTierLabel(snapshot.sleepBand) {
                            Text(label)
                        }
                        if let minutes = snapshot.asleepMinutes {
                            Text("· \(WidgetFormat.duration(minutes))")
                        }
                    }
                    .font(.system(size: 10).weight(.medium))
                    .foregroundStyle(.secondary)
                }
            } else {
                Spacer(minLength: 2)
                Text("No night synced").font(.system(size: 12).weight(.medium)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 12) {
                if let steps = snapshot.steps {
                    labelRow(systemImage: "figure.walk", text: steps.formatted())
                }
                if let battery = snapshot.batteryPercent {
                    labelRow(systemImage: WidgetFormat.batteryIcon(battery), text: "\(battery)%",
                             tint: WidgetPalette.batteryColor(percent: battery, charging: snapshot.batteryCharging))
                }
            }
            .opacity(stale ? 0.55 : 1)

            FreshnessCaption(snapshot: snapshot, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func labelRow(systemImage: String, text: String, tint: Color = .primary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(text).font(.system(size: 14).weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Medium (all six metrics)

struct RingSnapshotMediumView: View {
    let snapshot: RingSnapshot
    let now: Date

    var body: some View {
        let stale = snapshot.isStale(now: now)
        // ZStack(alignment:) pins FreshnessCaption's frame to the bottom-trailing corner — this
        // only works because the caption is now a plain (non-live) Text that measures to exactly
        // its glyphs; see FreshnessCaption's doc comment for why the earlier live-text version
        // defeated this corner-pin no matter which container held it.
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RingMetricColumn(title: "Sleep",
                                     value: snapshot.sleepIsLastNight ? snapshot.sleepScore.map(String.init) : nil,
                                     sub: nil,
                                     color: WidgetPalette.sleepTierColor(snapshot.sleepBand),
                                     progress: snapshot.sleepIsLastNight
                                        ? WidgetFormat.fraction(snapshot.sleepScore.map(Double.init), goal: 100) : nil,
                                     ringColor: WidgetPalette.sleepRing)
                    RingMetricColumn(title: "Stress",
                                     value: snapshot.sleepIsLastNight ? snapshot.stressScore.map(String.init) : nil,
                                     sub: nil,
                                     color: WidgetPalette.stressColor(snapshot.stressBand))
                    RingMetricColumn(title: "Activity",
                                     value: snapshot.activityScore.map(String.init),
                                     sub: nil,
                                     color: WidgetPalette.activityTierColor(snapshot.activityTier),
                                     progress: WidgetFormat.fraction(snapshot.activityScore.map(Double.init), goal: 100),
                                     ringColor: WidgetPalette.activityRing)
                }
                .opacity(stale ? 0.55 : 1)
                Divider()
                HStack(spacing: 8) {
                    RingMetricColumn(title: "Steps",
                                     value: snapshot.steps.map { $0.formatted() },
                                     sub: nil,
                                     color: WidgetPalette.steps,
                                     progress: WidgetFormat.fraction(snapshot.steps.map(Double.init),
                                                                      goal: snapshot.stepsGoal.map(Double.init)),
                                     ringColor: WidgetPalette.steps)
                    RingMetricColumn(title: "Active kcal",
                                     value: snapshot.activeKcal.map { Int($0).formatted() },
                                     sub: nil,
                                     color: WidgetPalette.energy,
                                     progress: WidgetFormat.fraction(snapshot.activeKcal, goal: snapshot.activeKcalGoal),
                                     ringColor: WidgetPalette.energy)
                    RingMetricColumn(title: "Battery",
                                     value: snapshot.batteryPercent.map { "\($0)%" },
                                     sub: WidgetFormat.batterySub(snapshot),
                                     color: WidgetPalette.batteryColor(percent: snapshot.batteryPercent,
                                                                       charging: snapshot.batteryCharging))
                }
                .opacity(stale ? 0.55 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            FreshnessCaption(snapshot: snapshot, now: now, size: 10)
        }
    }
}

// MARK: - Large (six metrics + last night's stage bar)

struct RingSnapshotLargeView: View {
    let snapshot: RingSnapshot
    let now: Date

    var body: some View {
        let stale = snapshot.isStale(now: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OPENCIRCUIT").font(.system(size: 10).weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                FreshnessCaption(snapshot: snapshot, now: now)
            }
            HStack(spacing: 10) {
                RingMetricColumn(title: "Sleep",
                                 value: snapshot.sleepIsLastNight ? snapshot.sleepScore.map(String.init) : nil,
                                 sub: snapshot.sleepIsLastNight ? WidgetPalette.sleepTierLabel(snapshot.sleepBand) : "—",
                                 color: WidgetPalette.sleepTierColor(snapshot.sleepBand),
                                 progress: snapshot.sleepIsLastNight
                                    ? WidgetFormat.fraction(snapshot.sleepScore.map(Double.init), goal: 100) : nil,
                                 ringColor: WidgetPalette.sleepRing,
                                 ringSize: 36, ringLineWidth: 5)
                RingMetricColumn(title: "Stress",
                                 value: snapshot.sleepIsLastNight ? snapshot.stressScore.map(String.init) : nil,
                                 sub: snapshot.sleepIsLastNight ? WidgetPalette.stressLabel(snapshot.stressBand) : "—",
                                 color: WidgetPalette.stressColor(snapshot.stressBand))
                RingMetricColumn(title: "Activity",
                                 value: snapshot.activityScore.map(String.init),
                                 sub: WidgetPalette.activityTierLabel(snapshot.activityTier),
                                 color: WidgetPalette.activityTierColor(snapshot.activityTier),
                                 progress: WidgetFormat.fraction(snapshot.activityScore.map(Double.init), goal: 100),
                                 ringColor: WidgetPalette.activityRing,
                                 ringSize: 36, ringLineWidth: 5)
            }
            .opacity(stale ? 0.55 : 1)
            HStack(spacing: 10) {
                RingMetricColumn(title: "Steps",
                                 value: snapshot.steps.map { $0.formatted() },
                                 sub: snapshot.stepsGoal.map { "of \($0.formatted())" },
                                 color: WidgetPalette.steps,
                                 progress: WidgetFormat.fraction(snapshot.steps.map(Double.init),
                                                                  goal: snapshot.stepsGoal.map(Double.init)),
                                 ringColor: WidgetPalette.steps,
                                 ringSize: 36, ringLineWidth: 5)
                RingMetricColumn(title: "Active kcal",
                                 value: snapshot.activeKcal.map { Int($0).formatted() },
                                 sub: snapshot.activeKcalGoal.map { "of \(Int($0))" },
                                 color: WidgetPalette.energy,
                                 progress: WidgetFormat.fraction(snapshot.activeKcal, goal: snapshot.activeKcalGoal),
                                 ringColor: WidgetPalette.energy,
                                 ringSize: 36, ringLineWidth: 5)
                RingMetricColumn(title: "Battery",
                                 value: snapshot.batteryPercent.map { "\($0)%" },
                                 sub: WidgetFormat.batterySub(snapshot),
                                 color: WidgetPalette.batteryColor(percent: snapshot.batteryPercent,
                                                                   charging: snapshot.batteryCharging))
            }
            .opacity(stale ? 0.55 : 1)

            if snapshot.sleepIsLastNight, let start = snapshot.inBedStart, let end = snapshot.inBedEnd, end > start {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(start, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Text("Last night").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Text(end, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    HypnogramBar(stages: snapshot.stages, windowStart: start, windowEnd: end)
                        .opacity(stale ? 0.55 : 1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Proportional stage bar across `[windowStart, windowEnd]`. Empty `stages` (no hypnogram
/// persisted for the credited night) renders as a flat track — never a fabricated shape.
private struct HypnogramBar: View {
    let stages: [StageSpan]
    let windowStart: Date
    let windowEnd: Date

    var body: some View {
        GeometryReader { geo in
            let total = max(windowEnd.timeIntervalSince(windowStart), 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                ForEach(Array(stages.enumerated()), id: \.offset) { _, span in
                    let clampedStart = max(span.start, windowStart)
                    let clampedEnd = min(span.end, windowEnd)
                    let width = clampedEnd.timeIntervalSince(clampedStart) / total
                    if width > 0 {
                        Rectangle()
                            .fill(WidgetPalette.stageColor(span.stage))
                            .frame(width: max(geo.size.width * width, 1))
                            .offset(x: geo.size.width * (clampedStart.timeIntervalSince(windowStart) / total))
                    }
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Lock Screen circular (sleep score only — see staleness note at top of file)

struct RingSnapshotCircularView: View {
    let snapshot: RingSnapshot

    var body: some View {
        if snapshot.sleepIsLastNight, let score = snapshot.sleepScore {
            Gauge(value: Double(score), in: 0...100) {
                Image(systemName: "bed.double.fill")
            } currentValueLabel: {
                Text("\(score)")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(WidgetPalette.sleepTierColor(snapshot.sleepBand))
        } else {
            RingSnapshotCircularEmptyView()
        }
    }
}

struct RingSnapshotCircularEmptyView: View {
    var body: some View {
        Gauge(value: 0, in: 0...100) {
            Image(systemName: "bed.double.fill")
        } currentValueLabel: {
            Text("—")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(.secondary)
    }
}

// MARK: - No snapshot yet (fresh install, or the App Group hasn't received a write)

struct RingSnapshotEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.hexagongrid").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Open OpenCircuit").font(.system(size: 12).weight(.semibold))
            Text("Sync with your ring to see it here")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared pieces

/// One metric's number + title + optional sub-line, plus an optional goal ring on its leading
/// edge — reused by the medium and large faces so the two layouts can never drift into showing
/// the same metric two different ways. `progress == nil` (no goal, e.g. Stress/Battery, or a
/// missing value) still reserves the ring's width as blank space rather than collapsing it, so
/// every number in a row starts at the same x whether or not its column has a ring.
private struct RingMetricColumn: View {
    let title: String
    let value: String?
    let sub: String?
    let color: Color
    /// Fraction toward goal, already clamped to 0...1 by `WidgetFormat.fraction`. `nil` ⇒ no ring
    /// drawn (Stress/Battery, or a missing value) — never a fabricated 0%-filled ring.
    var progress: Double? = nil
    var ringColor: Color = .secondary
    var ringSize: CGFloat = 29
    var ringLineWidth: CGFloat = 4

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let progress {
                GoalRing(fraction: progress, color: ringColor, size: ringSize, lineWidth: ringLineWidth)
            } else {
                Color.clear.frame(width: ringSize, height: ringSize)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                if let sub, !sub.isEmpty {
                    Text(sub).font(.system(size: 8)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(progress.map { "\(value ?? "—"), \(Int($0 * 100)) percent" } ?? (value ?? "no data"))
    }
}

/// Plain goal ring for the medium/large faces — a scaled-down, static copy of the Activity tab's
/// `GoalsCardView.goalRing` (7pt stroke, 15% track, round cap, 12 o'clock start): widget target has
/// no access to the app's SwiftUI source, and a widget face is a static render anyway, so this
/// drops that view's animation and its centre percent/checkmark (a plain ring was asked for).
private struct GoalRing: View {
    let fraction: Double          // already clamped to 0...1 by WidgetFormat.fraction
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// "Synced 4 min ago", turning amber past `staleAfter` — the one thing every face except
/// `accessoryCircular` always shows, per §4: no reading may sit on the face looking as fresh as the
/// moment it landed.
///
/// Deliberately a plain `Text(String)`, NOT `Text(_:style:.relative)`. Live relative-time Text
/// reserves width for the WIDEST value it could grow into ("Synced 59 min ago" vs "Synced 4 min
/// ago"), not the glyphs it's showing right now — so on the medium/large faces, whose corner-pin
/// (ZStack(.bottomTrailing) / a header Spacer()) assumes the view's frame matches its glyphs, the
/// caption rendered against the LEFT edge of its own oversized frame instead of the corner.
/// Wrapping it in `.fixedSize(horizontal: true, ...)` to fight that was tried and is WORSE: it
/// blanks the entire widget face (all three families), because that modifier forces an ideal-width
/// measurement WidgetKit's live-text rendering can't satisfy. Precomputing the string via
/// `WidgetFormat.relativeSince` sidesteps both — a plain string measures to exactly its glyphs, so
/// the corner-pin just works. The cost is the caption no longer ticks live; the provider
/// (`RingSnapshotWidget.swift`) advances it on a coarse timeline instead.
private struct FreshnessCaption: View {
    let snapshot: RingSnapshot
    let now: Date
    /// Text size; the warning triangle stays one point smaller, matching the original 7/8 ratio.
    /// Defaults to the small/large faces' size — the medium face passes a larger override.
    var size: CGFloat = 8

    var body: some View {
        let stale = snapshot.isStale(now: now)
        HStack(spacing: 3) {
            if stale { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: size - 1)) }
            Text("Synced \(WidgetFormat.relativeSince(snapshot.lastSyncAt, now: now))")
        }
        .font(.system(size: size))
        .foregroundStyle(stale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
    }
}

// MARK: - Colour + format helpers (widget target has no access to the app's Design/Theme.swift)

enum WidgetPalette {
    static let background = Color(uiColor: .systemBackground)
    static let steps = Color.green
    static let energy = Color.orange
    // Fixed goal-ring colours, matching the Activity tab's Daily Goals rings
    // (GoalsCardView.swift's goalRing call sites) — deliberately NOT the tier colour, which the
    // number keeps. Steps/energy double as both number and ring colour already, above.
    static let sleepRing = Color.purple
    static let activityRing = Color.blue

    // Sleep / activity tiers share OpenCircuitKit's cut-offs (SleepScore.Tier / ActivityScore.Tier
    // raw values: "excellent"/"good"/"needsImprovement") but the widget can't import the Kit to
    // read them as an enum, so it matches the raw String directly. An unrecognized string (a
    // future tier case) falls through to the neutral `.secondary` / no label — never a crash.
    static func sleepTierColor(_ raw: String?) -> Color {
        switch raw {
        case "excellent": return .green
        case "good": return .teal
        case "needsImprovement": return .orange
        default: return .secondary
        }
    }
    static func sleepTierLabel(_ raw: String?) -> String? {
        switch raw {
        case "excellent": return "Excellent"
        case "good": return "Good"
        case "needsImprovement": return "Fair"
        default: return nil
        }
    }
    static func activityTierColor(_ raw: String?) -> Color {
        switch raw {
        case "excellent": return .green
        case "good": return .teal
        case "needsImprovement": return .orange
        default: return .secondary
        }
    }
    static func activityTierLabel(_ raw: String?) -> String? {
        switch raw {
        case "excellent": return "Excellent"
        case "good": return "Good"
        case "needsImprovement": return "Keep moving"
        default: return nil
        }
    }
    static func stressColor(_ raw: String?) -> Color {
        switch raw {
        case "relaxed": return .green
        case "normal": return .teal
        case "medium": return .orange
        case "high": return .red
        default: return .secondary
        }
    }
    static func stressLabel(_ raw: String?) -> String? {
        switch raw {
        case "relaxed": return "Relaxed"
        case "normal": return "Normal"
        case "medium": return "Medium"
        case "high": return "High"
        default: return nil
        }
    }
    /// `SleepStage.rawValue` → hypnogram-bar colour (deeper = darker), mirroring the "deeper sleep
    /// reads darker" convention common to hypnogram charts. Any unrecognized stage (a future case,
    /// or a decode default) renders as the same neutral track as `inBed`, never a wrong-looking bar.
    static func stageColor(_ raw: String) -> Color {
        switch raw {
        case "asleepDeep": return .indigo
        case "asleepCore": return .indigo.opacity(0.55)
        case "asleepREM": return .teal
        case "awake": return .secondary.opacity(0.5)
        default: return .secondary.opacity(0.15)   // inBed, or unrecognized
        }
    }
    static func batteryColor(percent: Int?, charging: Bool) -> Color {
        guard let percent else { return .secondary }
        if charging { return .green }
        return percent <= 20 ? .red : .primary
    }
}

enum WidgetFormat {
    /// Mirrors `OpenCircuitKit.GoalProgress.fraction` (unreachable from this Kit-free target):
    /// clamped to 0...1, `nil` when either input is missing or the goal isn't positive. Kept
    /// identical so a widget ring can never disagree with the same ring on the Activity tab.
    /// `nil` in ⇒ no ring drawn (`RingMetricColumn` treats `nil` as a blank slot) — never a
    /// fabricated 0%-filled ring for a value the app hasn't computed.
    static func fraction(_ current: Double?, goal: Double?) -> Double? {
        guard let current, let goal, goal > 0 else { return nil }
        return min(max(current / goal, 0), 1)
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h\(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// "4 min ago" / "2 hr ago" / "3 d ago" — coarse on purpose. `FreshnessCaption` shows this
    /// instead of live relative-time `Text` (see its doc comment), and the provider only refreshes
    /// the timeline every 15 min, so rounding tighter than that would imply false precision.
    static func relativeSince(_ date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        return "\(hours / 24) d ago"
    }

    static func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Battery sub-line for the medium/large faces: charging state, else time-to-empty, else
    /// nothing — never a guess when neither is known.
    static func batterySub(_ snapshot: RingSnapshot) -> String? {
        if snapshot.batteryCharging { return "charging" }
        if let tte = snapshot.timeToEmptySeconds, tte > 0 {
            return "~\(durationFromSeconds(tte)) left"
        }
        return nil
    }

    private static func durationFromSeconds(_ seconds: TimeInterval) -> String {
        let totalMin = Int(seconds / 60)
        let d = totalMin / 1_440
        let h = (totalMin % 1_440) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return "\(h)h" }
        return "\(max(totalMin, 1))m"
    }
}
