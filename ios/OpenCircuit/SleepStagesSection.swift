import SwiftUI
import OpenCircuitKit

/// Clone of the RingConn Gen 2 "Sleep Stages" chart (#70): a timestamped hypnogram + time axis +
/// legend, a grayscale movement strip, and four per-stage stat rows with reference-range ticks.
/// Replaces the old proportional `stageBar`/`stageLegend` capsule and the height-coded
/// `movementSection` strip in `SleepCardView`.
struct SleepStagesSection: View {
    /// The night's decoded hypnogram (from `LocalStore.hypnogram(night:)` or `liveSegments`).
    /// Includes the envelope `.inBed` segment; it's excluded from the per-time lanes below (it
    /// spans the WHOLE block and overlaps every other segment — same reason `SleepStaging.Summary`
    /// excludes it from sums) but still contributes to the chart's time domain.
    let segments: [SleepSegment]
    /// Per-2.5-min movement level (0/1/2), oldest→newest. No timestamps are stored, so index *i*
    /// is mapped to `movementWindowStart + i × 150s` — exact on a contiguous night, approximate on
    /// a stitched one.
    let movementLevels: [Int]
    let movementWindowStart: Date?
    /// Overnight HR samples for the "Sleep HR" overlay. Empty disables the toggle rather than
    /// drawing an empty line (the samples backing it are pruned after `sampleRetentionDays`).
    let hrPoints: [(Date, Double)]
    let minutes: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)

    @State private var showHR = false

    private static let movementEpochSeconds: TimeInterval = 150 // BulkRecord.epochSeconds

    private var domain: (start: Date, end: Date)? {
        guard let start = segments.map(\.start).min(),
              let end = segments.map(\.end).max(), end > start else { return nil }
        return (start, end)
    }

    private var shares: [SleepStageBreakdown.StageShare] { SleepStageBreakdown.breakdown(minutes) }

    private var chartAccessibilitySummary: String {
        shares.map { "\(stageDisplayName($0.stage)) \(SleepStageBreakdown.durationText(minutes: $0.minutes))" }
            .joined(separator: ", ")
    }

    var body: some View {
        if let domain {
            VStack(alignment: .leading, spacing: 10) {
                header
                HypnogramChart(segments: segments, domain: domain,
                               hrPoints: showHR ? hrPoints : [],
                               accessibilitySummary: chartAccessibilitySummary)
                    .frame(height: 120)
                axisRow(domain)
                legend
                MovementStrip(levels: movementLevels,
                             windowStart: movementWindowStart ?? domain.start,
                             domain: domain, epochSeconds: Self.movementEpochSeconds)
                statRows
            }
            .padding(.top, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Sleep Stages").font(.subheadline.weight(.semibold))
            Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            hrToggle
        }
    }

    private var hrToggle: some View {
        Button {
            showHR.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("Sleep HR").font(.caption.weight(.semibold))
                Capsule()
                    .fill(showHR ? Theme.hr : Color.secondary.opacity(0.25))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: showHR ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                            .shadow(color: .black.opacity(0.25), radius: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(hrPoints.isEmpty)
        .opacity(hrPoints.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Sleep HR overlay")
        .accessibilityValue(showHR ? "On" : "Off")
        .accessibilityHint(hrPoints.isEmpty ? "No heart rate samples for this night" : "")
    }

    /// 5 evenly quartered clock labels, first flush-leading / last flush-trailing / rest spread
    /// between (matches the reference screenshot's axis).
    private func axisRow(_ domain: (start: Date, end: Date)) -> some View {
        let labels = SleepStageBreakdown.axisLabels(start: domain.start, end: domain.end)
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, d in
                Text(Self.clock(d)).font(.caption2).foregroundStyle(.secondary)
                if i < labels.count - 1 { Spacer(minLength: 4) }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.awake, "Awake")
            legendItem(.asleepREM, "REM")
            legendItem(.asleepCore, "Light Sleep")
            legendItem(.asleepDeep, "Deep Sleep")
        }
    }

    private func legendItem(_ stage: SleepStage, _ name: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(stageColor(stage)).frame(width: 7, height: 7)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var statRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(shares, id: \.stage) { share in
                StageStatRow(share: share, name: stageDisplayName(share.stage),
                            color: stageColor(share.stage),
                            range: SleepStageBreakdown.referenceRange(for: share.stage))
            }
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
}

// MARK: - Shared stage styling

/// Sleep-stage display name in the reference screenshot's own wording.
private func stageDisplayName(_ stage: SleepStage) -> String {
    switch stage {
    case .awake: return "Awake"
    case .asleepREM: return "REM"
    case .asleepCore: return "Light Sleep"
    case .asleepDeep: return "Deep Sleep"
    case .inBed: return "In Bed"
    }
}

/// Sleep-stage color, shared by the hypnogram, legend, and stat rows so they can't drift apart.
private func stageColor(_ stage: SleepStage) -> Color {
    switch stage {
    case .awake: return Theme.stageAwake
    case .asleepREM: return Theme.stageREM
    case .asleepCore: return Theme.stageLight
    case .asleepDeep: return Theme.stageDeep
    case .inBed: return Color.secondary.opacity(0.25)
    }
}

// MARK: - Hypnogram

/// Four-lane time-axis hypnogram (Awake / REM / Light / Deep, top to bottom — the reference
/// screenshot's legend order), with a hairline connector between temporally-adjacent segments in
/// different lanes so the shape reads as one continuous staircase rather than disconnected bars.
private struct HypnogramChart: View {
    let segments: [SleepSegment]
    let domain: (start: Date, end: Date)
    let hrPoints: [(Date, Double)]
    let accessibilitySummary: String

    private static let laneOrder: [SleepStage] = [.awake, .asleepREM, .asleepCore, .asleepDeep]
    private static let laneGap: CGFloat = 5

    /// Real (non-inBed) segments only — `.inBed` is the whole-block envelope and would paint over
    /// every lane for the full width if drawn (see `SleepStagesSection.segments` doc).
    private var staged: [SleepSegment] { segments.filter { $0.stage != .inBed } }

    var body: some View {
        GeometryReader { geo in
            let laneHeight = max((geo.size.height - Self.laneGap * 3) / 4, 1)
            let totalSpan = domain.end.timeIntervalSince(domain.start)

            ZStack(alignment: .topLeading) {
                connectors(laneHeight: laneHeight, totalSpan: totalSpan)
                ForEach(Array(staged.enumerated()), id: \.offset) { _, seg in
                    if let lane = Self.laneOrder.firstIndex(of: seg.stage), totalSpan > 0 {
                        let leading = xPos(max(seg.start, domain.start), totalSpan, geo.size.width)
                        let trailing = xPos(min(seg.end, domain.end), totalSpan, geo.size.width)
                        let minWidth: CGFloat = seg.stage == .awake ? 2.5 : 1.5
                        let width = max(trailing - leading, minWidth)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(stageColor(seg.stage))
                            .frame(width: width, height: laneHeight)
                            .position(x: leading + width / 2, y: Self.laneY(lane, laneHeight) + laneHeight / 2)
                    }
                }
                if !hrPoints.isEmpty {
                    HRLine(points: hrPoints, domain: domain)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages over the night")
        .accessibilityValue(accessibilitySummary)
    }

    private func xPos(_ d: Date, _ totalSpan: TimeInterval, _ width: CGFloat) -> CGFloat {
        width * CGFloat(d.timeIntervalSince(domain.start) / totalSpan)
    }

    private static func laneY(_ index: Int, _ laneHeight: CGFloat) -> CGFloat {
        CGFloat(index) * (laneHeight + laneGap)
    }

    @ViewBuilder
    private func connectors(laneHeight: CGFloat, totalSpan: TimeInterval) -> some View {
        if staged.count > 1, totalSpan > 0 {
            ForEach(1..<staged.count, id: \.self) { i in
                let prev = staged[i - 1], cur = staged[i]
                if prev.stage != cur.stage,
                   let laneA = Self.laneOrder.firstIndex(of: prev.stage),
                   let laneB = Self.laneOrder.firstIndex(of: cur.stage) {
                    GeometryReader { geo in
                        let x = xPos(cur.start, totalSpan, geo.size.width)
                        let yTop = min(Self.laneY(laneA, laneHeight), Self.laneY(laneB, laneHeight)) + laneHeight / 2
                        let yBottom = max(Self.laneY(laneA, laneHeight), Self.laneY(laneB, laneHeight)) + laneHeight / 2
                        Rectangle()
                            .fill(Color.secondary.opacity(0.28))
                            .frame(width: 1.2, height: yBottom - yTop)
                            .position(x: x, y: (yTop + yBottom) / 2)
                    }
                }
            }
        }
    }
}

/// The optional "Sleep HR" overlay: a thin line scaled to the night's own HR min…max, drawn over
/// the full hypnogram rect.
private struct HRLine: View {
    let points: [(Date, Double)]
    let domain: (start: Date, end: Date)

    var body: some View {
        GeometryReader { geo in
            let totalSpan = domain.end.timeIntervalSince(domain.start)
            let values = points.map(\.1)
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let span = max(maxV - minV, 1)
            Path { path in
                let sorted = points.sorted { $0.0 < $1.0 }
                for (i, p) in sorted.enumerated() {
                    guard totalSpan > 0 else { break }
                    let px = geo.size.width * CGFloat(p.0.timeIntervalSince(domain.start) / totalSpan)
                    let py = geo.size.height * (1 - CGFloat((p.1 - minV) / span))
                    if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                    else { path.addLine(to: CGPoint(x: px, y: py)) }
                }
            }
            .stroke(Theme.hr.opacity(0.85), lineWidth: 1.4)
        }
    }
}

// MARK: - Movement strip

/// Grayscale Low/Moderate/High movement strip, positioned on the SAME time domain as the
/// hypnogram above it (not evenly distributed across the strip like the old `movementSection`).
private struct MovementStrip: View {
    let levels: [Int]
    let windowStart: Date
    let domain: (start: Date, end: Date)
    let epochSeconds: TimeInterval

    /// Mirrors the old `SleepCardView.movementSummary(_:)` wording exactly, just relocated.
    private var summary: String {
        let still = levels.filter { $0 == 0 }.count
        let moving = levels.count - still
        guard moving > 0 else { return "Still all night" }
        var runs = 0, inRun = false
        for l in levels {
            if l >= 1 { if !inRun { runs += 1; inRun = true } } else { inRun = false }
        }
        let lead = still >= moving ? "Mostly still" : "Restless"
        return "\(lead) · \(runs) restless period\(runs == 1 ? "" : "s")"
    }

    var body: some View {
        if !levels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Movement").font(.caption2).foregroundStyle(.secondary)
                GeometryReader { geo in
                    let totalSpan = domain.end.timeIntervalSince(domain.start)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                        if totalSpan > 0 {
                            ForEach(Array(levels.enumerated()), id: \.offset) { i, lvl in
                                if lvl > 0 {
                                    let t = windowStart.addingTimeInterval(Double(i) * epochSeconds)
                                    let frac = t.timeIntervalSince(domain.start) / totalSpan
                                    if frac >= 0, frac <= 1 {
                                        Rectangle()
                                            .fill(lvl >= 2 ? Color.secondary : Color.secondary.opacity(0.55))
                                            .frame(width: 2.5, height: geo.size.height)
                                            .position(x: geo.size.width * CGFloat(frac), y: geo.size.height / 2)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack(spacing: 14) {
                    moveLegendItem(Color.secondary.opacity(0.12), "Low")
                    moveLegendItem(Color.secondary.opacity(0.55), "Moderate")
                    moveLegendItem(Color.secondary, "High")
                }
            }
            .padding(.bottom, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Movement")
            .accessibilityValue(summary)
        }
    }

    private func moveLegendItem(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stage stat row

/// One percentage + duration row with a proportional track and the reference-range tick marks
/// bracketing "normal" — the small detail that makes the reference screenshot's bars read as
/// data, not decoration.
private struct StageStatRow: View {
    let share: SleepStageBreakdown.StageShare
    let name: String
    let color: Color
    let range: ClosedRange<Double>?

    private var percentText: String { String(format: "%.1f", share.fraction * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold))
                Text("\(percentText)%").font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Spacer()
                Text(SleepStageBreakdown.durationText(minutes: share.minutes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    if let range {
                        Capsule().fill(Color.secondary.opacity(0.15))
                            .frame(width: geo.size.width * CGFloat((range.upperBound - range.lowerBound) / 100))
                            .offset(x: geo.size.width * CGFloat(range.lowerBound / 100))
                    }
                    Capsule().fill(color)
                        .frame(width: max(geo.size.width * CGFloat(min(share.fraction, 1)), 2))
                    if let range {
                        tick(at: range.lowerBound, in: geo)
                        tick(at: range.upperBound, in: geo)
                    }
                }
            }
            .frame(height: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(percentText) percent, \(SleepStageBreakdown.durationText(minutes: share.minutes))")
    }

    private func tick(at pct: Double, in geo: GeometryProxy) -> some View {
        Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1.6)
            .offset(x: geo.size.width * CGFloat(pct / 100) - 0.8)
    }
}

// MARK: - Preview

#Preview("Reference night") {
    let start = Calendar.current.date(bySettingHour: 22, minute: 58, second: 0, of: Date())!
    let end = start.addingTimeInterval(488 * 60)
    let stageDurations: [(SleepStage, TimeInterval)] = [
        (.awake, 4 * 60), (.asleepCore, 12 * 60), (.asleepDeep, 35 * 60), (.asleepCore, 20 * 60),
        (.asleepREM, 15 * 60), (.awake, 3 * 60), (.asleepCore, 25 * 60), (.asleepDeep, 30 * 60),
        (.asleepCore, 15 * 60), (.asleepREM, 35 * 60), (.awake, 3 * 60), (.asleepCore, 30 * 60),
        (.asleepDeep, 20 * 60), (.asleepCore, 20 * 60), (.asleepREM, 40 * 60), (.awake, 3 * 60),
        (.asleepCore, 25 * 60), (.asleepDeep, 15 * 60), (.asleepREM, 20 * 60), (.asleepCore, 30 * 60),
        (.awake, 3 * 60), (.asleepCore, 48 * 60), (.asleepREM, 10 * 60),
    ]
    var t = start.addingTimeInterval(10 * 60)
    var segs: [SleepSegment] = [SleepSegment(start: start, end: end, stage: .inBed)]
    for (stage, dur) in stageDurations {
        segs.append(SleepSegment(start: t, end: t.addingTimeInterval(dur), stage: stage))
        t = t.addingTimeInterval(dur)
    }
    let epochCount = Int((end.timeIntervalSince(start)) / 150)
    let levels: [Int] = (0..<epochCount).map { i in
        let at = start.addingTimeInterval(Double(i) * 150)
        let nearAwake = segs.contains { $0.stage == .awake && abs($0.start.timeIntervalSince(at)) < 300 }
        return nearAwake ? Int.random(in: 1...2) : (Double.random(in: 0...1) < 0.04 ? 1 : 0)
    }
    let hr: [(Date, Double)] = stride(from: 0.0, to: end.timeIntervalSince(start), by: 300).map { off in
        (start.addingTimeInterval(off), Double.random(in: 48...76))
    }
    return ScrollView {
        SleepStagesSection(segments: segs, movementLevels: levels, movementWindowStart: start,
                           hrPoints: hr, minutes: (461, 16, 225, 100, 120, 445))
            .padding()
    }
}

#Preview("No hypnogram") {
    SleepStagesSection(segments: [], movementLevels: [], movementWindowStart: nil,
                       hrPoints: [], minutes: (0, 0, 0, 0, 0, 0))
        .padding()
}
