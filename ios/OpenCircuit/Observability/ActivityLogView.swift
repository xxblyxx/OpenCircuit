import SwiftUI
import UIKit
import OpenCircuitKit

// User-reachable observability screen (#44): freshness timestamps, whether iOS is actually
// running our background tasks, and a bounded log of recent sync outcomes — so a silent failure
// (a throttled BGTask, a stalled ring) becomes visible instead of invisible.

private enum LogPeriod: String, CaseIterable, Identifiable {
    case day       = "1d"
    case threeDays = "3d"
    case week      = "7d"
    case all       = "All"
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .day:       return 86_400
        case .threeDays: return 3 * 86_400
        case .week:      return 7 * 86_400
        case .all:       return nil
        }
    }
    func cutoff(from now: Date = Date()) -> Date? {
        seconds.map { now.addingTimeInterval(-$0) }
    }
}

struct ActivityLogView: View {
    var session: RingSession?
    private let store = ObservabilityStore()
    @State private var records: [TaskRecord] = []
    @State private var metricRecords: [MetricRecord] = []
    @State private var alertRecords: [HealthAlertRecord] = []
    @State private var refreshStatus: UIBackgroundRefreshStatus = .available
    @State private var period: LogPeriod = .week
    @State private var shareItem: URL?
    @State private var showShare = false

    /// Rows shown per long-running section before the "Show all" toggle is needed.
    private static let collapsedRowCount = 5
    @State private var syncExpanded = false
    @State private var alertsExpanded = false
    @State private var metricsExpanded = false

    /// Newest-first, already period-filtered — the order every consumer (list rows and the
    /// share export) wants. Records are stored oldest-first, so the reverse lives here once
    /// instead of at every call site.
    private var filteredRecords: [TaskRecord] {
        guard let cutoff = period.cutoff() else { return Array(records.reversed()) }
        return Array(records.filter { $0.date >= cutoff }.reversed())
    }

    private var filteredMetricRecords: [MetricRecord] {
        guard let cutoff = period.cutoff() else { return Array(metricRecords.reversed()) }
        return Array(metricRecords.filter { $0.date >= cutoff }.reversed())
    }

    private var filteredAlertRecords: [HealthAlertRecord] {
        guard let cutoff = period.cutoff() else { return Array(alertRecords.reversed()) }
        return Array(alertRecords.filter { $0.date >= cutoff }.reversed())
    }

    /// Decode-sanity warnings worth surfacing here without opening Device Info: a firmware
    /// version different from the pinned/tested build, and any aggregate decode anomaly from
    /// the most recent drain (#decode-anomaly). Both are "this app might be reading the wrong
    /// bytes" signals, not "the ring/network is just being flaky" — distinct from the rest of
    /// this screen.
    private var decodeWarnings: [String] {
        var out: [String] = []
        if session?.firmwareInfo.hasFirmwareMismatch == true {
            out.append("Ring firmware (\(session?.firmwareInfo.version ?? "?")) differs from the "
                       + "tested build (\(FirmwareInfo.pinnedVersion)). Sensor byte offsets could differ.")
        }
        for anomaly in session?.lastSyncAnomalies ?? [] {
            switch anomaly {
            case .allZeroHRWhileWorn:
                out.append("Last sync had worn epochs but no valid heart rate decoded — possible format drift.")
            case .skinTempOutOfPhysicalRange:
                out.append("Recent skin-temperature readings were outside a plausible range for a sustained run.")
            }
        }
        return out
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(LogPeriod.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            if !decodeWarnings.isEmpty {
                Section("Decode health") {
                    ForEach(decodeWarnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Freshness") {
                timeRow("Last successful sync", store.lastSuccessfulSync)
                timeRow("Last Health write", store.lastHealthWrite)
            }

            Section("Background tasks") {
                timeRow("Last background run", store.bgLastRun)
                timeRow("Last scheduled", store.bgLastScheduled)
                LabeledContent("Background App Refresh", value: refreshStatusText)
                if refreshStatus != .available {
                    Text("iOS is limiting background activity. Turn on Settings ▸ General ▸ "
                         + "Background App Refresh so the ring can sync while the app is closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Background heart-rate runs at iOS's discretion (usually overnight while "
                     + "charging) and is best-effort — daytime background HR is not guaranteed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                if filteredRecords.isEmpty {
                    Text(period == .all ? "No background activity recorded yet."
                                       : "No activity in the last \(period.rawValue).")
                        .foregroundStyle(.secondary)
                } else {
                    collapsibleRows(filteredRecords, expanded: $syncExpanded) { recordRow($0) }
                }
            } header: {
                collapsibleHeader("Sync activity", count: filteredRecords.count, expanded: $syncExpanded)
            }

            // Body-vital alert decisions rank above metric plumbing: this is the only place a
            // wearer can see that an alert was WITHHELD, which is otherwise indistinguishable
            // from one that never triggered.
            Section {
                if filteredAlertRecords.isEmpty {
                    Text(period == .all ? "No health-alert decisions recorded yet."
                                       : "No health-alert decisions in the last \(period.rawValue).")
                        .foregroundStyle(.secondary)
                } else {
                    collapsibleRows(filteredAlertRecords, expanded: $alertsExpanded) { alertRecordRow($0) }
                    Text("Suppressed rows are decisions the app made NOT to notify you. They are "
                         + "kept so an over-eager filter is as visible as an over-eager alert.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                collapsibleHeader("Health alerts", count: filteredAlertRecords.count, expanded: $alertsExpanded)
            }

            Section {
                if filteredMetricRecords.isEmpty {
                    Text(period == .all ? "No metric-level capture diagnostics recorded yet."
                                       : "No metric events in the last \(period.rawValue).")
                        .foregroundStyle(.secondary)
                } else {
                    collapsibleRows(filteredMetricRecords, expanded: $metricsExpanded) { metricRecordRow($0) }
                }
            } header: {
                collapsibleHeader("Metric diagnostics", count: filteredMetricRecords.count, expanded: $metricsExpanded)
            }
        }
        .navigationTitle("Background activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { prepareShare() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = shareItem {
                ShareActivityView(url: url)
            }
        }
        .onAppear {
            records = store.records()
            metricRecords = store.metricRecords()
            alertRecords = store.healthAlertRecords()
            refreshStatus = UIApplication.shared.backgroundRefreshStatus
        }
    }

    private func prepareShare() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = ["=== OpenCircuit activity log (\(period.rawValue)) ===",
                               "Exported: \(df.string(from: Date()))", ""]

        lines.append("--- Sync activity (\(filteredRecords.count)) ---")
        for r in filteredRecords {
            let icon = r.success ? "✓" : "✗"
            let detail = r.detail.map { " — \($0)" } ?? ""
            lines.append("\(icon) [\(df.string(from: r.date))] \(kindLabel(r.kind))\(detail)")
        }

        lines.append("")
        lines.append("--- Health alerts (\(filteredAlertRecords.count)) ---")
        for r in filteredAlertRecords {
            let icon = r.fired ? "!" : "-"
            lines.append("\(icon) [\(df.string(from: r.date))] \(alertTitle(r)) — \(alertDetail(r))")
        }

        lines.append("")
        lines.append("--- Metric diagnostics (\(filteredMetricRecords.count)) ---")
        for r in filteredMetricRecords {
            lines.append("[\(df.string(from: r.date))] \(r.source): \(r.detail)")
        }

        let fileName = "opencircuit-log-\(period.rawValue)-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        shareItem = url
        showShare = true
    }

    /// Section header carrying the same expand/collapse control as the row list's trailing
    /// button. Lets you collapse a long section from the top without scrolling past it first.
    /// `Section("string")` styles its header for free (footnote, secondary color); a custom
    /// header view like this one doesn't inherit that automatically, so it's set explicitly to
    /// match the plain-string headers used elsewhere on this screen.
    private func collapsibleHeader(_ title: String, count: Int, expanded: Binding<Bool>) -> some View {
        HStack {
            Text("\(title) (\(count))")
            if count > Self.collapsedRowCount {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
                } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// Rows for one log section, capped to the newest `collapsedRowCount` until expanded.
    /// Generic over the record type so Sync / Alerts / Metrics share one collapse behaviour
    /// instead of tripling the prefix + toggle logic. `items` is expected already sorted in
    /// display order (newest first) — this only ever trims from the end.
    @ViewBuilder
    private func collapsibleRows<Item: Identifiable, Row: View>(
        _ items: [Item],
        expanded: Binding<Bool>,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        ForEach(expanded.wrappedValue ? items : Array(items.prefix(Self.collapsedRowCount))) { row($0) }
        if items.count > Self.collapsedRowCount {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(expanded.wrappedValue ? "Show fewer" : "Show all \(items.count)")
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    private func timeRow(_ label: String, _ date: Date?) -> some View {
        LabeledContent(label) {
            if let date {
                Text(date, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            } else {
                Text("never").foregroundStyle(.tertiary)
            }
        }
    }

    private func recordRow(_ record: TaskRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: record.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.success ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(kindLabel(record.kind)).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(record.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let detail = record.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kindLabel(_ kind: TaskRecord.Kind) -> String {
        switch kind {
        case .appRefresh: return "App refresh"
        case .processing: return "Processing"
        case .foreground: return "Foreground sync"
        case .cbWake: return "Bluetooth wake"
        case .sleepFocus: return "Sleep Focus sync"
        }
    }

    private func alertRecordRow(_ record: HealthAlertRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: record.fired ? "heart.circle.fill" : "bell.slash.fill")
                .foregroundStyle(record.fired ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(alertTitle(record)).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(record.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(alertDetail(record)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Human label for a logged decision. Decoded from the stored rawValue, so a row written by
    /// a future build with a case this one doesn't know still renders (as its raw string) rather
    /// than disappearing.
    private func alertTitle(_ record: HealthAlertRecord) -> String {
        guard let n = HealthNotification(rawValue: record.notification) else {
            return record.notification
        }
        switch n {
        case .highHR: return "High heart rate"
        case .lowSpO2: return "Low blood oxygen"
        case .elevatedHRInactive: return "Elevated heart rate while inactive"
        case .skinTempRise: return "Skin temperature rise"
        case .skinTempDrop: return "Skin temperature drop"
        case .skinTempFluctuationRise: return "Skin temperature fluctuation (rise)"
        case .skinTempFluctuationDrop: return "Skin temperature fluctuation (drop)"
        case .fever: return "Suspected fever"
        case .sedentaryReminder: return "Move reminder"
        case .wearReminder: return "Wear reminder"
        case .bedtimeReminder: return "Bedtime reminder"
        case .chargingComplete: return "Charging complete"
        case .headacheSigns: return "Overnight signals"
        }
    }

    /// One line of "what was decided and on what evidence". Every clause is omitted when its
    /// input is absent rather than printed as a zero — in this log 0 is a real measured value.
    /// Built once, not per row: `alertDetail` runs once per visible list row AND once per row in
    /// `prepareShare`'s export loop, and `DateFormatter` init (locale/calendar setup) is expensive
    /// enough to be worth hoisting — the same reason `prepareShare` builds its own `df` once
    /// up front rather than inside its loop.
    private static let alertReadingTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func alertDetail(_ record: HealthAlertRecord) -> String {
        var parts: [String] = [record.fired ? "notified" : "suppressed — \(reasonLabel(record.reason))"]
        if record.value > 0 {
            let unit = record.notification == HealthNotification.lowSpO2.rawValue ? "%" : " bpm"
            parts.append("\(Int(record.value.rounded()))\(unit)")
        }
        if let t = record.readingTime {
            parts.append("reading \(Self.alertReadingTimeFormatter.string(from: t))")
        }
        if record.runSize > 0 { parts.append("run \(record.runSize)") }
        if record.evidenceEpochs > 0 {
            parts.append("\(record.badEpochs)/\(record.evidenceEpochs) epochs bad")
        }
        if let e = record.evidenceSummary { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    private func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "gated.quietHours": return "quiet hours"
        case "gated.backoff": return "already alerted recently"
        case "noCorroboration": return "no second low reading to corroborate it"
        case "corroborationDisagrees": return "nearby low readings disagree"
        case "badEpochMajority": return "the ring was moving / not worn"
        default: return reason
        }
    }

    private func metricRecordRow(_ record: MetricRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.source).font(.subheadline.weight(.medium))
                Spacer()
                Text(record.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(record.detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var refreshStatusText: String {
        switch refreshStatus {
        case .available: return "On"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}
