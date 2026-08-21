import SwiftUI
import OpenCircuitKit

/// Clone of the RingConn Gen 2 "Sleep Stages" chart (#70): a timestamped hypnogram + time axis +
/// legend, a grayscale movement strip, and four per-stage stat rows with reference-range ticks.
/// Replaces the old proportional `stageBar`/`stageLegend` capsule and the height-coded
/// `movementSection` strip in `SleepCardView`.
///
/// #186 adds drag-to-scrub: press anywhere on the hypnogram and a callout above it reports the
/// time, sleep stage, and (when a nearby sample exists) HR / HRV / SpO₂ at that instant. The
/// callout lives in its own reserved lane rather than floating over the 120pt plot — `HeroCard`/
/// `HeroSparkline` (Design/LivelineCharts.swift) already learned that lesson: a floating
/// annotation over a short chart clips or covers the data it's explaining.
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
    /// Overnight HR/HRV/SpO₂ for the "Sleep HR" overlay AND the scrub callout. Empty disables the
    /// toggle rather than drawing an empty line (the samples backing it are pruned after
    /// `sampleRetentionDays`) — scrubbing still reports time + stage in that case.
    let vitals: SleepVitalsSeries
    let minutes: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int)

    /// Persisted (not view-local) so re-opening the Sleep tab doesn't forget the overlay was on —
    /// matches how `units.*` / `sleepSchedule.*` are stored in `SleepCardView`.
    @AppStorage("sleep.showHROverlay") private var showHR = false

    // MARK: Scrub state (#186)

    /// Whether the current touch is scrubbing the chart, mid-vertical-scroll (hands off), or idle.
    /// `@GestureState`, not `@State`: when the enclosing ScrollView takes over a simultaneous
    /// touch, SwiftUI may cancel this gesture without an `onEnded` callback, and `@GestureState`
    /// resets to `.idle` on cancellation too — so "lifting clears the callout" holds on every path
    /// with no manual bookkeeping.
    private enum DragPhase: Equatable {
        case idle
        case scrubbing(CGFloat)   // x, in the chart's local coordinate space
        case scrolling
    }
    @GestureState private var drag: DragPhase = .idle
    @State private var plotWidth: CGFloat = 0
    @State private var pillWidth: CGFloat = 0
    /// VoiceOver's position when stepping the chart with the adjustable action, independent of
    /// `drag` (a pointer gesture VoiceOver users don't perform).
    @State private var axIndex: Int?

    private static let movementEpochSeconds: TimeInterval = 150 // BulkRecord.epochSeconds

    /// How far before sleep onset the chart is allowed to draw, so a long awake-in-bed lead-in
    /// (phone, desk work, surfing) doesn't drag the whole night onto the x-axis the way the raw
    /// `.inBed` envelope used to (#XXX). Bounded rather than clipped flush to onset: an onset the
    /// classifier got badly wrong is still visible as an anomalous lead-in instead of disappearing
    /// off-chart, which is exactly the failure mode this change is about.
    private static let onsetLeadIn: TimeInterval = 30 * 60

    private var domain: (start: Date, end: Date)? {
        guard let inBedStart = segments.map(\.start).min(),
              let end = segments.map(\.end).max(), end > inBedStart else { return nil }
        // Anchor on sleep onset, not the in-bed envelope — a night with a long pre-sleep lead-in
        // should not draw that lead-in as if it were part of the sleep window (docs/SLEEP_AWAKE_RESOLUTION.md).
        // Falls back to the in-bed start when nothing is asleep yet (a live-staged night with no
        // asleep segment must still draw something).
        let start: Date
        if let onset = SleepStaging.sleepWindow(segments)?.onset {
            start = max(inBedStart, onset.addingTimeInterval(-Self.onsetLeadIn))
        } else {
            start = inBedStart
        }
        return (start, end)
    }

    /// `vitals` narrowed to the chart's own domain. `vitals.hr` is windowed on the night's in-bed
    /// span (`SleepCardView.vitals(_:)`), which can differ from this segment-derived domain on a
    /// live-staged night — scrubbing must only snap to samples that actually have an on-screen x.
    private var domainVitals: SleepVitalsSeries {
        guard let domain else { return .empty }
        return vitals.clamped(to: domain.start, end: domain.end)
    }

    private var shares: [SleepStageBreakdown.StageShare] { SleepStageBreakdown.breakdown(minutes) }

    /// WASO + awakening count, derived from `segments` on every render — nothing is stored
    /// (docs/SLEEP_AWAKENING_METRICS.md §2.1). Split out from the single pooled `awake` scalar
    /// `shares` reports, so a quiet pre-sleep/post-wake night and a fragmented one no longer look
    /// identical on the card.
    private var awakenings: SleepAwakenings { SleepAwakenings.from(segments: segments) }

    /// The `.awake` `StageShare` swapped from the pooled `minutes.awake` scalar to WASO alone —
    /// same denominator as every other stage share (`awake + rem + light + deep`), so all rows
    /// still sum to ~100%. See `statRows` for why: the pooled scalar is what read as "2 hours
    /// awake" while Whoop read 49 minutes (docs/SLEEP_AWAKE_RESOLUTION.md).
    private var wasoShare: SleepStageBreakdown.StageShare {
        let denom = Double(minutes.awake + minutes.rem + minutes.light + minutes.deep)
        let waso = awakenings.minutes.waso
        return .init(stage: .awake, minutes: waso, fraction: denom > 0 ? Double(waso) / denom : 0)
    }

    private var chartAccessibilitySummary: String {
        shares.map { share in
            let s = share.stage == .awake ? wasoShare : share
            return "\(stageDisplayName(s.stage)) \(SleepStageBreakdown.durationText(minutes: s.minutes))"
        }.joined(separator: ", ")
    }

    private var axStagedSegments: [SleepSegment] { stagedSegments(segments) }

    var body: some View {
        if let domain {
            VStack(alignment: .leading, spacing: 10) {
                header
                calloutLane
                HypnogramChart(segments: segments, domain: domain,
                               hr: showHR ? domainVitals.hr : [],
                               scrubDate: scrubReadout?.date)
                    .frame(height: 120)
                    .background(WidthReader(width: $plotWidth))
                    .contentShape(Rectangle())   // the ZStack is mostly empty space otherwise
                    .simultaneousGesture(scrubGesture)
                    .sensoryFeedback(trigger: scrubTick) { _, new in new.bucket == nil ? nil : .selection }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sleep stages over the night")
                    .accessibilityValue(axIndex.map(axReadout) ?? chartAccessibilitySummary)
                    .accessibilityHint("Swipe up or down to move through the night")
                    .accessibilityAdjustableAction(adjustAX)
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

    // MARK: Scrub gesture

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($drag) { value, state, _ in
                guard state != .scrolling else { return }
                // Once the touch is unambiguously a vertical page pan, hand off rather than
                // dragging the callout along with the scroll — the ScrollView is already panning
                // (this gesture runs simultaneously, never exclusively).
                let dx = abs(value.translation.width), dy = abs(value.translation.height)
                if dy > 12, dy > dx * 2 { state = .scrolling; return }
                state = .scrubbing(value.location.x)
            }
    }

    /// One instant's full read-out: the snapped time, its position on the domain, the covering
    /// stage, and any nearby HR/HRV/SpO₂. Shared by the drag callout and the VoiceOver adjustable
    /// action so the two can never report different numbers for "the same" moment.
    private struct ScrubReadout {
        let date: Date
        let fraction: Double
        let stage: SleepStage?
        let hr: Double?
        let hrv: Double?
        let spo2: Double?
    }

    private func readout(near date: Date) -> ScrubReadout {
        let hrTimes = domainVitals.hr.map(\.time)
        var snapped = date
        var hrValue: Double?
        if let idx = SleepScrub.nearestIndex(in: hrTimes, to: date) {
            // Real sample nearby — snap to it exactly, never interpolate.
            snapped = domainVitals.hr[idx].time
            hrValue = domainVitals.hr[idx].value
        } else if hrTimes.isEmpty {
            // No HR data for this night at all (aged past the 3-day window): round to the minute
            // rather than reporting a sub-second finger position as "the" time.
            snapped = roundedToMinute(date)
        }
        // else: HR data exists elsewhere tonight but this instant sits in a real gap — keep the
        // raw finger time and simply omit bpm below, rather than borrowing a distant sample.
        let stage = SleepScrub.stage(at: snapped, in: segments)
        let hrv = domainVitals.value(in: domainVitals.hrv, near: snapped)
        let spo2 = domainVitals.value(in: domainVitals.spo2, near: snapped)
        let fraction = domain.flatMap { SleepScrub.fraction(of: snapped, start: $0.start, end: $0.end) } ?? 0
        return ScrubReadout(date: snapped, fraction: fraction, stage: stage, hr: hrValue, hrv: hrv, spo2: spo2)
    }

    private var scrubReadout: ScrubReadout? {
        guard case .scrubbing(let x) = drag, let domain, plotWidth > 0 else { return nil }
        let f = Double(x / plotWidth)
        let rawDate = SleepScrub.date(atFraction: f, start: domain.start, end: domain.end)
        return readout(near: rawDate)
    }

    /// Identity of "which real sample the rule is on" — changes exactly when the snap moves, so
    /// `.sensoryFeedback` below ticks once per sample rather than once per drag event.
    private struct ScrubTick: Equatable { let bucket: TimeInterval?; let stage: SleepStage? }

    private var scrubTick: ScrubTick {
        guard let r = scrubReadout else { return ScrubTick(bucket: nil, stage: nil) }
        return ScrubTick(bucket: r.date.timeIntervalSince1970, stage: r.stage)
    }

    private func roundedToMinute(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
    }

    // MARK: Callout lane

    /// Reserved space above the chart, sized by an invisible worst-case pill so the chart below
    /// never jumps when the real callout appears — including at large Dynamic Type sizes, where
    /// the pill wraps taller.
    private var calloutLane: some View {
        ZStack(alignment: .topLeading) {
            calloutPillBody(time: "12:42 AM", hr: "188 bpm", stageName: "Deep Sleep",
                            hrv: "188ms HRV", spo2: "100% SpO₂")
                .opacity(0)
                .accessibilityHidden(true)
            if let r = scrubReadout {
                // Points at the UNCLAMPED position so a pill clamped to the card edge still shows
                // which instant it belongs to.
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1, height: 5)
                    .offset(x: plotWidth * CGFloat(r.fraction) - 0.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                calloutPillBody(time: Self.clock(r.date),
                                hr: (showHR ? r.hr : nil).map { "\(Int($0.rounded())) bpm" },
                                stageName: r.stage.map(stageDisplayName),
                                hrv: r.hrv.map { "\(Int($0.rounded()))ms HRV" },
                                spo2: r.spo2.map { "\(Int(($0 * 100).rounded()))% SpO₂" })
                    .fixedSize()
                    .background(WidthReader(width: $pillWidth))
                    .offset(x: clampedPillX(r.fraction))
                    .animation(nil, value: r.date)   // track the finger exactly, no lag
                    .accessibilityHidden(true)        // the chart element already voices this
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func clampedPillX(_ fraction: Double) -> CGFloat {
        guard plotWidth > 0 else { return 0 }
        let target = plotWidth * CGFloat(fraction) - pillWidth / 2
        return min(max(0, target), max(0, plotWidth - pillWidth))
    }

    @ViewBuilder
    private func calloutPillBody(time: String, hr: String?, stageName: String?,
                                 hrv: String?, spo2: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(time).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
            if hr == nil && stageName == nil {
                Text("No data").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 5) {
                    if let hr { Text(hr).foregroundStyle(Theme.hr) }
                    if hr != nil, stageName != nil { Text("·").foregroundStyle(.tertiary) }
                    if let stageName { Text(stageName).foregroundStyle(.primary) }
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
            }
            if hrv != nil || spo2 != nil {
                HStack(spacing: 5) {
                    if let hrv { Text(hrv).foregroundStyle(Theme.hrv) }
                    if hrv != nil, spo2 != nil { Text("·").foregroundStyle(.tertiary) }
                    if let spo2 { Text(spo2).foregroundStyle(Theme.spo2) }
                }
                .font(.caption2.weight(.medium)).monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        )
    }

    // MARK: VoiceOver stepping

    private func axReadout(_ i: Int) -> String {
        guard axStagedSegments.indices.contains(i) else { return chartAccessibilitySummary }
        let seg = axStagedSegments[i]
        let r = readout(near: seg.start.addingTimeInterval(seg.duration / 2))
        var parts = [Self.clock(seg.start), stageDisplayName(seg.stage)]
        if showHR, let hr = r.hr { parts.append("\(Int(hr.rounded())) beats per minute") }
        return parts.joined(separator: ", ")
    }

    private func adjustAX(_ direction: AccessibilityAdjustmentDirection) {
        let count = axStagedSegments.count
        guard count > 0 else { return }
        var i = axIndex ?? 0
        switch direction {
        case .increment: i = min(i + 1, count - 1)
        case .decrement: i = max(i - 1, 0)
        @unknown default: break
        }
        axIndex = i
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
        .disabled(vitals.hr.isEmpty)
        .opacity(vitals.hr.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Sleep HR overlay")
        .accessibilityValue(showHR ? "On" : "Off")
        .accessibilityHint(vitals.hr.isEmpty ? "No heart rate samples for this night" : "")
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
            // Deliberately no reference-range band (docs/SLEEP_AWAKENING_METRICS.md §2.2) — unlike
            // the stage shares below, there is no sourced population norm for awakening COUNT to
            // cite, and a made-up one would misrepresent this as validated the way it isn't.
            AwakeningsStatRow(awakenings: awakenings)
            // The "Awake" row uses WASO (`wasoShare`), not the pooled `minutes.awake` scalar that
            // used to headline this card: pooling pre-sleep latency + WASO + morning lie-in into
            // one number is what made a quiet 25-minute WASO night read as "2 hours awake"
            // (docs/SLEEP_AWAKE_RESOLUTION.md). `AwakeningsStatRow`'s own "Xm WASO" above is now
            // the SAME number, not a footnote to a different one.
            ForEach(shares, id: \.stage) { share in
                let displayed = share.stage == .awake ? wasoShare : share
                StageStatRow(share: displayed, name: stageDisplayName(displayed.stage),
                            color: stageColor(displayed.stage),
                            range: SleepStageBreakdown.referenceRange(for: displayed.stage))
            }
            // The two edges WASO deliberately excludes — same "always shown" reasoning as
            // `AwakeningsStatRow`'s zero-WASO case: a 0min "Falling asleep" is a real, reportable
            // measurement (fast sleep onset), not an absence of data.
            EdgeAwakeStatRow(title: "Falling asleep", minutes: awakenings.minutes.headAwake)
            EdgeAwakeStatRow(title: "Awake in bed (morning)", minutes: awakenings.minutes.tailAwake)
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

/// Real (non-`.inBed`) segments only, oldest as given — shared by the hypnogram's lane layout and
/// the VoiceOver stepping order so they can't disagree about what "segment 3" means.
private func stagedSegments(_ segments: [SleepSegment]) -> [SleepSegment] {
    segments.filter { $0.stage != .inBed }
}

// MARK: - Width measurement

/// Publishes the width SwiftUI actually laid the host view out at, via an invisible full-size
/// `GeometryReader` in the background. Used both for the chart's plot width (to place the scrub
/// rule/dot) and the callout pill's own width (to clamp it inside the card).
private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct WidthReader: View {
    @Binding var width: CGFloat
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
        }
        .onPreferenceChange(WidthPreferenceKey.self) { new in
            // Skip sub-pixel churn so it can't loop with SwiftUI's own layout pass.
            if abs(new - width) > 0.5 { width = new }
        }
    }
}

// MARK: - Hypnogram

/// Four-lane time-axis hypnogram (Awake / REM / Light / Deep, top to bottom — the reference
/// screenshot's legend order), with a hairline connector between temporally-adjacent segments in
/// different lanes so the shape reads as one continuous staircase rather than disconnected bars.
private struct HypnogramChart: View {
    let segments: [SleepSegment]
    let domain: (start: Date, end: Date)
    let hr: [SleepVitalsSeries.Sample]
    /// The scrub callout's current time, or nil when no touch is active — draws the vertical rule.
    let scrubDate: Date?

    private static let laneOrder: [SleepStage] = [.awake, .asleepREM, .asleepCore, .asleepDeep]
    private static let laneGap: CGFloat = 5

    private var staged: [SleepSegment] { stagedSegments(segments) }

    var body: some View {
        GeometryReader { geo in
            let laneHeight = max((geo.size.height - Self.laneGap * 3) / 4, 1)
            let totalSpan = domain.end.timeIntervalSince(domain.start)

            ZStack(alignment: .topLeading) {
                connectors(laneHeight: laneHeight, totalSpan: totalSpan)
                ForEach(Array(staged.enumerated()), id: \.offset) { _, seg in
                    if let lane = Self.laneOrder.firstIndex(of: seg.stage), totalSpan > 0 {
                        let leading = xPos(max(seg.start, domain.start), geo.size.width)
                        let trailing = xPos(min(seg.end, domain.end), geo.size.width)
                        let minWidth: CGFloat = seg.stage == .awake ? 2.5 : 1.5
                        let width = max(trailing - leading, minWidth)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(stageColor(seg.stage))
                            .frame(width: width, height: laneHeight)
                            .position(x: leading + width / 2, y: Self.laneY(lane, laneHeight) + laneHeight / 2)
                    }
                }
                if !hr.isEmpty {
                    HRLine(points: hr, domain: domain, scrubDate: scrubDate)
                }
                if let scrubDate, totalSpan > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: xPos(scrubDate, geo.size.width), y: geo.size.height / 2)
                }
            }
        }
    }

    private func xPos(_ d: Date, _ width: CGFloat) -> CGFloat {
        width * CGFloat(SleepScrub.fraction(of: d, start: domain.start, end: domain.end) ?? 0)
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
                        let x = xPos(cur.start, geo.size.width)
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
/// the full hypnogram rect, with a highlighted dot at the scrubbed sample when one is snapped.
private struct HRLine: View {
    let points: [SleepVitalsSeries.Sample]
    let domain: (start: Date, end: Date)
    let scrubDate: Date?

    var body: some View {
        GeometryReader { geo in
            let totalSpan = domain.end.timeIntervalSince(domain.start)
            let values = points.map(\.value)
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let span = max(maxV - minV, 1)
            let sorted = points.sorted { $0.time < $1.time }

            Path { path in
                for (i, p) in sorted.enumerated() {
                    guard totalSpan > 0 else { break }
                    let px = geo.size.width * CGFloat(p.time.timeIntervalSince(domain.start) / totalSpan)
                    let py = geo.size.height * (1 - CGFloat((p.value - minV) / span))
                    if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
                    else { path.addLine(to: CGPoint(x: px, y: py)) }
                }
            }
            .stroke(Theme.hr.opacity(0.85), lineWidth: 1.4)

            if let scrubDate, totalSpan > 0,
               let idx = SleepScrub.nearestIndex(in: sorted.map(\.time), to: scrubDate) {
                let p = sorted[idx]
                let px = geo.size.width * CGFloat(p.time.timeIntervalSince(domain.start) / totalSpan)
                let py = geo.size.height * (1 - CGFloat((p.value - minV) / span))
                Circle()
                    .fill(Theme.hr)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: 1.5))
                    .position(x: px, y: py)
            }
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
                                    if let frac = SleepScrub.fraction(of: t, start: domain.start, end: domain.end),
                                       frac >= 0, frac <= 1 {
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

// MARK: - Awakenings row

/// A single-line count + duration row, deliberately simpler than `StageStatRow` below: there is
/// no percent-of-night fraction to plot (a count isn't a share of the night) and no reference
/// range to cite (docs/SLEEP_AWAKENING_METRICS.md §2.2), so this skips the proportional track and
/// tick marks entirely rather than forcing awakening count into a shape built for stage
/// percentages.
private struct AwakeningsStatRow: View {
    let awakenings: SleepAwakenings

    private var wasoText: String {
        SleepStageBreakdown.durationText(minutes: awakenings.minutes.waso)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Awakenings").font(.subheadline.weight(.semibold))
            Text("\(awakenings.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.stageAwake)
            Spacer()
            // A zero here is a real, reportable measurement (docs/SLEEP_AWAKE_RESOLUTION.md §4.1
            // — this is precisely the number that was silently 0 on every traced night), so it is
            // always shown, never hidden behind an empty-state placeholder. `durationText` already
            // renders 0 minutes as "0min", so no separate zero-case branch is needed here.
            Text("\(wasoText) WASO")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Awakenings")
        .accessibilityValue("\(awakenings.count), \(wasoText) wake after sleep onset")
    }
}

// MARK: - Edge awake row

/// Sleep latency ("Falling asleep") and the morning lie-in ("Awake in bed (morning)") — the two
/// edges of the night the pooled `.awake` scalar used to hide inside a single number
/// (docs/SLEEP_AWAKE_RESOLUTION.md, docs/SLEEP_AWAKENING_METRICS.md §1). Same simplified shape as
/// `AwakeningsStatRow` above: neither quantity has a sourced population reference range, so this
/// skips the proportional track and tick marks `StageStatRow` draws.
private struct EdgeAwakeStatRow: View {
    let title: String
    let minutes: Int

    private var text: String { SleepStageBreakdown.durationText(minutes: minutes) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
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
    let hr: [SleepVitalsSeries.Sample] = stride(from: 0.0, to: end.timeIntervalSince(start), by: 150).map { off in
        .init(time: start.addingTimeInterval(off), value: Double.random(in: 48...76))
    }
    let hrv: [SleepVitalsSeries.Sample] = stride(from: 0.0, to: end.timeIntervalSince(start), by: 600).map { off in
        .init(time: start.addingTimeInterval(off), value: Double.random(in: 30...90))
    }
    let spo2: [SleepVitalsSeries.Sample] = stride(from: 0.0, to: end.timeIntervalSince(start), by: 900).map { off in
        .init(time: start.addingTimeInterval(off), value: Double.random(in: 0.94...0.99))
    }
    return ScrollView {
        SleepStagesSection(segments: segs, movementLevels: levels, movementWindowStart: start,
                           vitals: SleepVitalsSeries(hr: hr, hrv: hrv, spo2: spo2),
                           minutes: (461, 16, 225, 100, 120, 445))
            .padding()
    }
}

#Preview("No hypnogram") {
    SleepStagesSection(segments: [], movementLevels: [], movementWindowStart: nil,
                       vitals: .empty, minutes: (0, 0, 0, 0, 0, 0))
        .padding()
}

#Preview("Scrub — no HR samples") {
    // A night aged past the 3-day vitals window: the toggle disables, but the hypnogram and its
    // scrub (time + stage only) still work.
    let start = Calendar.current.date(bySettingHour: 23, minute: 10, second: 0, of: Date())!
    let end = start.addingTimeInterval(420 * 60)
    let stageDurations: [(SleepStage, TimeInterval)] = [
        (.awake, 5 * 60), (.asleepCore, 60 * 60), (.asleepDeep, 45 * 60), (.asleepREM, 30 * 60),
        (.asleepCore, 90 * 60), (.asleepDeep, 40 * 60), (.asleepREM, 50 * 60), (.asleepCore, 90 * 60),
    ]
    var t = start.addingTimeInterval(8 * 60)
    var segs: [SleepSegment] = [SleepSegment(start: start, end: end, stage: .inBed)]
    for (stage, dur) in stageDurations {
        segs.append(SleepSegment(start: t, end: t.addingTimeInterval(dur), stage: stage))
        t = t.addingTimeInterval(dur)
    }
    return ScrollView {
        SleepStagesSection(segments: segs, movementLevels: [], movementWindowStart: nil,
                           vitals: .empty, minutes: (420, 5, 180, 85, 80, 335))
            .padding()
    }
}
