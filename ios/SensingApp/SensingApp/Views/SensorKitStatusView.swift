//
//  SensorKitStatusView.swift
//  SensingApp
//
//  Issue #85: one screen that says, per SensorKit sensor, whether it is
//  authorized, fetching, writing files and getting them uploaded, plus whether
//  the upload background task is actually running.
//

import SwiftUI
import SensorKit
import BackgroundTasks

/// One SensorKit sensor as the app collects it.
struct SensorKitStatusSensor: Identifiable {
    let name: String
    let sensor: SRSensor
    let kind: SensorKind
    let filePrefix: String       // CSV name before the index, e.g. "sensorkit_gyro_phone"
    let lastFetchEndKey: String  // UserDefaults key, CF reference-date seconds
    var id: String { filePrefix }

    /// Every SensorKit sensor the app collects (registry and standalone fetchers).
    static let all: [SensorKitStatusSensor] = [
        .init(name: "Phone accelerometer", sensor: .accelerometer, kind: .accelerometer,
              filePrefix: "sensorkit_accel_phone", lastFetchEndKey: "sk_accel_phone_last_fetch_end"),
        .init(name: "Watch accelerometer", sensor: .accelerometer, kind: .watchAccelerometer,
              filePrefix: "sensorkit_accel_watch", lastFetchEndKey: "sk_accel_last_fetch_end"),
        .init(name: "Gyroscope", sensor: .rotationRate, kind: .gyroscope,
              filePrefix: "sensorkit_gyro_phone", lastFetchEndKey: "sk_gyro_last_fetch_end"),
        .init(name: "Watch worn", sensor: .onWristState, kind: .wristDetection,
              filePrefix: "sensorkit_wristdetection_watch", lastFetchEndKey: "sk_wrist_last_fetch_end"),
        .init(name: "Air pressure", sensor: .ambientPressure, kind: .pressure,
              filePrefix: "sensorkit_pressure_phone", lastFetchEndKey: "sk_pressure_last_fetch_end"),
        .init(name: "Calls", sensor: .phoneUsageReport, kind: .phoneUsage,
              filePrefix: "sensorkit_phoneusage_phone", lastFetchEndKey: "sk_phoneusage_last_fetch_end"),
        .init(name: "Messages", sensor: .messagesUsageReport, kind: .messagesUsage,
              filePrefix: "sensorkit_messages_phone", lastFetchEndKey: "sk_messages_last_fetch_end"),
        .init(name: "Typing", sensor: .keyboardMetrics, kind: .keyboard,
              filePrefix: "sensorkit_keyboard_phone", lastFetchEndKey: "sk_keyboard_last_fetch_end"),
        .init(name: "Sleep", sensor: .sleepSessions, kind: .watchSleep,
              filePrefix: "sensorkit_sleep_watch", lastFetchEndKey: "sk_sleep_last_fetch_end"),
        .init(name: "PPG", sensor: .photoplethysmogram, kind: .watchPPG,
              filePrefix: "sensorkit_ppg_watch", lastFetchEndKey: "sk_ppg_last_fetch_end"),
        .init(name: "Ambient light", sensor: .ambientLightSensor, kind: .ambientLight,
              filePrefix: "sensorkit_ambientlight_phone", lastFetchEndKey: "sk_ambientlight_last_fetch_end"),
        .init(name: "Phone use", sensor: .deviceUsageReport, kind: .deviceUsage,
              filePrefix: "sensorkit_deviceusage_phone", lastFetchEndKey: "sk_deviceusage_last_fetch_end"),
        .init(name: "Wrist temperature", sensor: .wristTemperature, kind: .wristTemperature,
              filePrefix: "sensorkit_wristtemp_watch", lastFetchEndKey: "sk_wristtemp_last_fetch_end"),
        .init(name: "Heart rate", sensor: .heartRate, kind: .watchHeartRate,
              filePrefix: "sensorkit_heartrate_watch", lastFetchEndKey: "sk_hr_last_fetch_end"),
    ]
}

/// What the phone knows about one sensor right now.
struct SensorKitStatusRow: Identifiable {
    let sensor: SensorKitStatusSensor
    let authorization: SRAuthorizationStatus
    let lastFetchEnd: Date?      // end of the last committed fetch window
    let newestSample: Date?      // newest sample seen in a fetch
    let waitingFiles: Int        // files in to-be-processed/ (sealed or not)
    let waitingBytes: Int
    let lastUploaded: Date?      // newest upload stamp in processed/
    var id: String { sensor.id }

    /// Samples arrive at least 24 h late (SensorKit embargo); after 3 days
    /// without a new one something is wrong.
    static let staleAfter: TimeInterval = 3 * 24 * 3600

    enum Verdict: String { case ok = "OK", stale = "Stale", noData = "No data", notAuthorized = "Not authorized" }

    func verdict(now: Date = Date()) -> Verdict {
        guard authorization == .authorized else { return .notAuthorized }
        guard let newestSample else { return .noData }
        return now.timeIntervalSince(newestSample) > Self.staleAfter ? .stale : .ok
    }

    static func load(_ sensor: SensorKitStatusSensor,
                     documents: URL,
                     defaults: UserDefaults = .standard,
                     fileManager: FileManager = .default) -> SensorKitStatusRow {
        let waiting = files(in: documents.appendingPathComponent("to-be-processed"),
                            prefix: sensor.filePrefix, fileManager: fileManager)
        let uploaded = files(in: documents.appendingPathComponent("processed"),
                             prefix: sensor.filePrefix, fileManager: fileManager)
        let fetchEnd = defaults.double(forKey: sensor.lastFetchEndKey)
        return SensorKitStatusRow(
            sensor: sensor,
            authorization: SRSensorReader(sensor: sensor.sensor).authorizationStatus,
            lastFetchEnd: fetchEnd > 0 ? Date(timeIntervalSinceReferenceDate: fetchEnd) : nil,
            newestSample: SensorStatusStore.shared.latest(for: sensor.kind)?.date,
            waitingFiles: waiting.count,
            waitingBytes: waiting.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) },
            lastUploaded: Uploader.lastUploaded(prefix: sensor.filePrefix)
                ?? uploaded.compactMap { Uploader.uploadedAt($0) }.max())
    }

    static func files(in dir: URL, prefix: String, fileManager: FileManager = .default) -> [URL] {
        let all = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(prefix + "_") }
    }
}

struct SensorKitStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SensorKitStatusRow] = []
    @State private var pendingTasks: [BGTaskRequest] = []
    @State private var windowHours = 24

    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var body: some View {
        NavigationStack {
            List {
                Section("Uploads") {
                    labeled("Last upload run", Uploader.lastRun.map(when) ?? "never")
                    labeled("Last run result", Uploader.lastRunSummary ?? "-")
                    labeled("Files waiting", "\(waitingTotal)")
                    labeled("Last SensorKit fetch", BackgroundScheduler.shared.lastUnlockedFetch
                        .map { "\(when($0.date)) (\($0.trigger))" } ?? "never")
                    if pendingTasks.isEmpty {
                        labeled("Background tasks", "none pending")
                    }
                    ForEach(pendingTasks, id: \.identifier) { task in
                        labeled(task.identifier.components(separatedBy: ".").last ?? task.identifier,
                                task.earliestBeginDate.map { "after " + when($0) } ?? "any time")
                    }
                }
                Section("Fetch totals over") {
                    Picker("Window", selection: $windowHours) {
                        Text("6 h").tag(6)
                        Text("24 h").tag(24)
                        Text("72 h").tag(72)
                    }
                    .pickerStyle(.segmented)
                }
                Section("SensorKit sensors") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.sensor.name).font(.headline)
                                Spacer()
                                Text(row.verdict().rawValue)
                                    .font(.caption.bold())
                                    .foregroundStyle(color(row.verdict()))
                            }
                            detail("Newest sample", row.newestSample.map(when) ?? "none")
                            detail("Fetched up to", row.lastFetchEnd.map(when) ?? "never")
                            detail("Waiting", "\(row.waitingFiles) file(s), \(ByteCountFormatter.string(fromByteCount: Int64(row.waitingBytes), countStyle: .file))")
                            detail("Last uploaded", row.lastUploaded.map(when) ?? "none kept")
                            detail("Last fetch", lastFetchText(row.sensor.kind))
                            detail("Last \(windowHours) h", windowText(row.sensor.kind))
                        }
                    }
                }
            }
            .navigationTitle("SensorKit status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh") { reload() } }
            }
            .onAppear(perform: reload)
        }
    }

    /// "Nov 8, 10:47 PM (relaunch): 1,240,000 rows, data Nov 6, 8:31 PM - Nov 7, 11:01 AM, stopped: caught up"
    private func lastFetchText(_ kind: SensorKind) -> String {
        guard let r = SensorRunLog.records(kind).last else { return "none recorded yet" }
        var text = "\(when(r.finishedAt)) (\(r.trigger)): \(SensorRunLog.describe(r))"
        if r.stopReason != "complete" { text += ", stopped: \(r.stopReason)" }
        return text
    }

    /// "3 run(s), 2,100,000 rows, data up to Nov 7, 11:01 AM"
    private func windowText(_ kind: SensorKind) -> String {
        let t = SensorRunLog.totals(kind, window: TimeInterval(windowHours) * 3600)
        guard t.runs > 0 else { return "no fetch finished" }
        let unit = SensorRunLog.records(kind).last?.unit ?? "samples"
        return "\(t.runs) run(s), \(t.samples.formatted(.number)) \(unit)"
            + (t.dataEnd.map { ", data up to \(when($0))" } ?? ", no data")
    }

    private var waitingTotal: Int {
        let dir = documents.appendingPathComponent("to-be-processed")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }

    private func reload() {
        rows = SensorKitStatusSensor.all.map { SensorKitStatusRow.load($0, documents: documents) }
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            DispatchQueue.main.async { pendingTasks = requests }
        }
    }

    private func when(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        Text("\(title): \(value)").font(.caption).foregroundStyle(.secondary)
    }

    private func color(_ verdict: SensorKitStatusRow.Verdict) -> Color {
        switch verdict {
        case .ok: return .green
        case .stale: return .orange
        case .noData, .notAuthorized: return .red
        }
    }
}
