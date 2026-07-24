//
//  ImportDataView.swift
//  SensingApp
//
//  DEBUG-only screen for loading sensor data from a CSV instead of editing
//  hardcoded values in code. Reached from the Debug tab; never shipped to
//  patients (the Debug tab itself is behind #if DEBUG).
//
//  The import log at the bottom is not bookkeeping — it is the check that an
//  import actually landed. If you load a new file and the screen still shows
//  yesterday's value, the log tells you whether the import silently failed or
//  the display is stale.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportDataView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var scannedFiles: [URL] = []
    @State private var didScan = false

    // Confirmation step — nothing is written until the user taps Import.
    @State private var preview: SensorFileImporter.Preview?
    @State private var chosenKind: SensorKind = .heartRate

    @State private var activeImports: [SensorImportRecord] = []
    @State private var log: [SensorImportRecord] = []
    @State private var status: String?
    @State private var busy = false
    @State private var showClearConfirm = false
    // Set while the "send to database" confirmation is up. Uploading writes into
    // the live study pipeline, so it asks first.
    @State private var pendingSend: SensorImportRecord?

    private let cream = Color(red: 0.99, green: 0.97, blue: 0.95)
    private let ink = Color(red: 0.28, green: 0.22, blue: 0.20)
    private let muted = Color(red: 0.55, green: 0.47, blue: 0.44)
    private let terracotta = Color(red: 0.80, green: 0.42, blue: 0.30)

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.95, blue: 0.91),
                                        Color(red: 0.95, green: 0.91, blue: 0.88)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        sourceCard
                        if !scannedFiles.isEmpty { scannedCard }
                        loadedCard
                        if !log.isEmpty { logCard }
                        Spacer().frame(height: 30)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                if busy {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView("Reading file…")
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 14).fill(cream))
                }
            }
            .navigationTitle("Imported Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { inspect(picked: url) }
        }
        .sheet(item: $preview) { p in confirmSheet(p) }
        .alert("Clear all imported data?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                SensorDataStore.shared.clearAllImports()
                status = "Cleared. Screens fall back to live data."
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every imported series is deleted and the app goes back to live HealthKit and recorder data.")
        }
        // Sending is not a preview step — it puts this file into the same queue
        // the recorders use, tagged with the real participant ID, so it asks first.
        .alert("Send to the live study database?",
               isPresented: Binding(get: { pendingSend != nil },
                                    set: { if !$0 { pendingSend = nil } }),
               presenting: pendingSend) { record in
            Button("Send", role: .destructive) {
                let target = record
                pendingSend = nil
                send(target)
            }
            Button("Cancel", role: .cancel) { pendingSend = nil }
        } message: { record in
            Text("""
                 \(record.filename) (\(record.rowCount) rows) will be uploaded to the real study pipeline, tagged with this device's participant ID — the same path recorder data takes. It is identifiable server-side only by its "healthkit_import_" filename prefix.

                 This also flushes everything else waiting in the upload queue.
                 """)
        }
        .onAppear(perform: reload)
    }

    // MARK: - Cards

    private var sourceCard: some View {
        card("LOAD A FILE") {
            Text("Expects `timestamp,value` per line, header optional. The sensor is detected from the filename — heartratedata.csv, steps.csv, sleep.csv.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(muted)

            Button { showFileImporter = true } label: {
                actionLabel("Import data file…", icon: "square.and.arrow.down")
            }
            Button {
                scannedFiles = SensorFileImporter.scanDocumentsFolder()
                didScan = true
                status = scannedFiles.isEmpty
                    ? "No .csv or .txt files found in Documents, to-be-processed/ or processed/."
                    : nil
            } label: {
                actionLabel("Scan on-device files", icon: "folder")
            }
            Text("Scans Documents, to-be-processed/ and processed/ for .csv and .txt — so it finds both files dropped in over Finder and the app's own recordings. Importing one only reads it; nothing is moved or consumed.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(muted.opacity(0.8))

            if let status {
                Text(status)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(terracotta)
            }
        }
    }

    private var scannedCard: some View {
        card("FOUND IN DOCUMENTS") {
            ForEach(scannedFiles, id: \.self) { url in
                Button { inspect(picked: url, needsSecurityScope: false) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(ink)
                            Text(scanSubtitle(for: url))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(muted)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var loadedCard: some View {
        card("LOADED SENSORS") {
            if activeImports.isEmpty {
                Text("Nothing imported. Every screen is showing live data, or the hardcoded sample table where there is none.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(muted)
            } else {
                ForEach(activeImports) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.kind.displayName)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(ink)
                            Spacer()
                            Text("\(record.rowCount) pts")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(muted)
                        }
                        Text(record.filename)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(muted)
                        Text("Imported \(Self.stamp.string(from: record.importedAt))\(rangeText(record))")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(muted.opacity(0.85))

                        HStack(spacing: 8) {
                            smallButton("Send to database") { pendingSend = record }
                            if let prev = SensorDataStore.shared.previousImports(for: record.kind).first {
                                smallButton("Restore previous") {
                                    SensorDataStore.shared.activate(importID: prev.id, kind: prev.kind)
                                    status = "Restored \(prev.filename)."
                                    reload()
                                }
                            }
                            smallButton("Delete", destructive: true) {
                                SensorDataStore.shared.delete(importID: record.id)
                                status = "Deleted \(record.filename)."
                                reload()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }

                Button(role: .destructive) { showClearConfirm = true } label: {
                    Text("Clear all imported data")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var logCard: some View {
        card("IMPORT LOG") {
            Text("Newest first. If a screen still shows an old value, check the newest entry actually landed.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(muted.opacity(0.85))
            ForEach(log) { record in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(record.isActive ? Color(red: 0.22, green: 0.60, blue: 0.45) : muted.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.stamp.string(from: record.importedAt))  \(record.filename)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(ink)
                        Text("\(record.kind.displayName) · \(record.rowCount) pts\(record.isActive ? " · showing now" : "")")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(muted)
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Confirmation

    private func confirmSheet(_ p: SensorFileImporter.Preview) -> some View {
        NavigationStack {
            Form {
                Section("File") {
                    LabeledContent("Name", value: p.filename)
                    LabeledContent("Rows", value: "\(p.rowCount)")
                    if p.skippedRows > 0 {
                        LabeledContent("Unreadable rows", value: "\(p.skippedRows)")
                    }
                    if let min = p.dateMin, let max = p.dateMax {
                        LabeledContent("Range", value: "\(Self.day.string(from: min)) – \(Self.day.string(from: max))")
                    }
                }
                // The timestamp is found by probing columns, not assumed to be
                // the first one — show what was picked so a wrong guess on an
                // unusual file is visible before anything is stored.
                Section("Columns detected") {
                    LabeledContent("Timestamp", value: "column \(p.timestampColumn + 1)")
                    LabeledContent("Value", value: p.valueColumn.map { "column \($0 + 1)" } ?? "none found")
                    // "None found" is fine for a timestamp-only sensor and a
                    // silent disaster for a numeric one — every reading would
                    // import with no number at all. Say so plainly.
                    if p.valueColumn == nil && chosenKind.isNumeric {
                        Label("No numeric column was found after the timestamp. \(chosenKind.displayName) needs one — importing now would store timestamps with no readings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Sensor") {
                    Picker("Detected", selection: $chosenKind) {
                        ForEach(SensorKind.allCases.sorted { $0.displayName < $1.displayName }, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    if p.detectedKind == nil {
                        Text("Filename didn't match a known sensor — pick one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !chosenKind.isNumeric {
                        Text("This sensor shows only a timestamp, so the value column is ignored.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Import") { performImport(p) }
                }
            }
            .navigationTitle("Confirm import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { preview = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Actions

    /// Copies the picked file somewhere we reliably control, then streams it for
    /// a row count and date range. Nothing is stored at this stage.
    private func inspect(picked url: URL, needsSecurityScope: Bool = true) {
        busy = true
        status = nil
        let scoped = needsSecurityScope && url.startAccessingSecurityScopedResource()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            busy = false
            status = "Could not read that file: \(error.localizedDescription)"
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        Task.detached {
            let result = Result { try SensorFileImporter.inspect(url: tmp) }
            await MainActor.run {
                busy = false
                switch result {
                case .success(let p):
                    chosenKind = p.detectedKind ?? .heartRate
                    preview = p
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    private func performImport(_ p: SensorFileImporter.Preview) {
        let kind = chosenKind
        preview = nil
        busy = true
        Task.detached {
            let result = Result { try SensorFileImporter.perform(url: p.url, kind: kind) }
            await MainActor.run {
                busy = false
                switch result {
                case .success(let r):
                    var msg = "Imported \(r.rowCount) rows into \(r.kind.displayName)."
                    if let replaced = r.replacedRowCount { msg += " Replaced a \(replaced)-point series." }
                    if r.skippedRows > 0 { msg += " \(r.skippedRows) rows skipped." }
                    status = msg
                case .failure(let error):
                    status = error.localizedDescription
                }
                reload()
            }
        }
    }

    private func send(_ record: SensorImportRecord) {
        busy = true
        Task {
            let message = await SensorDataExporter.sendToDatabase(record)
            await MainActor.run {
                busy = false
                status = message
            }
        }
    }

    private func reload() {
        activeImports = SensorDataStore.shared.activeImports()
        log = SensorDataStore.shared.importLog()
    }

    /// Detected sensor plus the folder it came from — the scan now covers
    /// Documents, to-be-processed/ and processed/, so the folder matters.
    private func scanSubtitle(for url: URL) -> String {
        let sensor = SensorKindMatcher.match(filename: url.lastPathComponent)?.displayName ?? "sensor not recognized"
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder == "Documents" ? sensor : "\(sensor) · \(folder)"
    }

    private func rangeText(_ record: SensorImportRecord) -> String {
        guard let min = record.dateMin, let max = record.dateMax else { return "" }
        return " · covers \(Self.day.string(from: min)) – \(Self.day.string(from: max))"
    }

    // MARK: - Small view helpers

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(muted)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(cream)
                        .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                )
        }
    }

    private func actionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(terracotta))
    }

    private func smallButton(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(destructive ? .red : terracotta)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill((destructive ? Color.red : terracotta).opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}

// Lets the confirmation step drive a `.sheet(item:)`.
extension SensorFileImporter.Preview: Identifiable {
    public var id: String { url.path }
}
