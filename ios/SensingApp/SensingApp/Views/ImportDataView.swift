//
//  ImportDataView.swift
//  SensingApp
//
//  DEBUG-only screen for loading sensor data from a file instead of editing
//  hardcoded values in code. Reached from the Debug tab; never shipped to
//  patients (the Debug tab itself is behind #if DEBUG).
//
//  There are two ways in, and this screen is the SECOND one:
//    1. Drop a file into the app's Documents folder over the Files app or
//       Finder, then reopen the app. No UI at all — the app picks it up on
//       foreground. This is the everyday path.
//    2. This screen, for picking a file from anywhere, checking what the
//       importer made of it before storing, and overriding the sensor when the
//       filename does not say.
//
//  The log at the bottom is not bookkeeping — it is the check that an import
//  actually landed. If you load a file and a screen still shows the old value,
//  the log says whether the import failed or the display is stale.
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

    @State private var loaded: [SensorImportInfo] = []
    @State private var log: [String] = []
    @State private var status: String?
    @State private var busy = false
    @State private var showClearConfirm = false

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
                      allowedContentTypes: [.commaSeparatedText, .plainText, .json, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { inspect(picked: url) }
        }
        .sheet(item: $preview) { p in confirmSheet(p) }
        .alert("Clear all imported data?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                SensorStatusStore.shared.clearAllImports()
                // Otherwise files still sitting in the Documents folder would
                // stay suppressed forever — they are unchanged, so the automatic
                // pickup would consider them already done.
                SensorFileImporter.forgetAutoIngestHistory()
                status = "Cleared. Screens fall back to live data."
                log.insert("Cleared all imported data", at: 0)
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every imported reading is dropped and the app goes back to live HealthKit and recorder data. Files in the Documents folder are left alone, and will be picked up again next time the app opens.")
        }
        .onAppear(perform: reload)
    }

    // MARK: - Cards

    private var sourceCard: some View {
        card("LOAD A FILE") {
            Text("The importer works out the shape of the file: comma, tab or semicolon separated, or JSON. It finds the timestamp column by probing, and the value column after it. Header optional. A file with no timestamps at all is read as bare readings, dated by the file itself.")
                .font(.journey(.caption))
                .foregroundStyle(muted)

            Text("The sensor is taken from the filename — heartratedata.csv, steps.csv, sleep.json — and you can override it on the next screen.")
                .font(.journey(.caption))
                .foregroundStyle(muted)

            Button { showFileImporter = true } label: {
                actionLabel("Choose a file…", icon: "doc.badge.plus")
            }
            .buttonStyle(.plain)

            Button {
                scannedFiles = SensorFileImporter.scanAllFolders()
                didScan = true
                if scannedFiles.isEmpty {
                    status = "No data files found in Documents, to-be-processed/ or processed/."
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                    Text("Scan on-device files")
                        .font(.journey(.subheadline, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(terracotta)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(terracotta.opacity(0.12)))
            }
            .buttonStyle(.plain)

            Text("Anything you drop into the app's Documents folder over Finder or the Files app is loaded automatically the next time the app opens — this screen is only needed to pick a file from elsewhere or to override the sensor. Scanning also finds the app's own recordings; importing one only reads it, and never disturbs the upload queue.")
                .font(.journey(.caption2))
                .foregroundStyle(muted.opacity(0.85))

            if let status {
                Text(status)
                    .font(.journey(.caption, weight: .medium))
                    .foregroundStyle(ink)
                    .padding(.top, 2)
            }
        }
    }

    private var scannedCard: some View {
        card("FOUND ON DEVICE") {
            ForEach(scannedFiles, id: \.path) { url in
                Button { inspect(picked: url, needsSecurityScope: false) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.journey(.footnote, weight: .medium))
                                .foregroundStyle(ink)
                            Text(scanSubtitle(for: url))
                                .font(.journey(.caption2))
                                .foregroundStyle(muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2).weight(.semibold))
                            .foregroundStyle(muted.opacity(0.6))
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadedCard: some View {
        card("SHOWING IMPORTED DATA") {
            if loaded.isEmpty {
                Text("Nothing imported. Every screen is showing live HealthKit and recorder data.")
                    .font(.journey(.caption))
                    .foregroundStyle(muted)
            } else {
                Text("These sensors show file data instead of live data, and keep doing so until cleared.")
                    .font(.journey(.caption2))
                    .foregroundStyle(muted.opacity(0.85))

                ForEach(loaded) { info in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.kind?.displayName ?? info.kindRaw)
                                .font(.journey(.subheadline, weight: .semibold))
                                .foregroundStyle(ink)
                            Text("\(info.filename) · \(info.rowCount) rows\(rangeText(info))")
                                .font(.journey(.caption2))
                                .foregroundStyle(muted)
                        }
                        Spacer()
                        if let kind = info.kind {
                            smallButton("Clear", destructive: true) {
                                SensorStatusStore.shared.clearImport(kind)
                                log.insert("Cleared \(kind.displayName)", at: 0)
                                reload()
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }

                Button { showClearConfirm = true } label: {
                    Text("Clear all")
                        .font(.journey(.footnote, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private var logCard: some View {
        card("LOG") {
            Text("Newest first. If a screen still shows an old value, check the newest entry actually landed.")
                .font(.journey(.caption2))
                .foregroundStyle(muted.opacity(0.85))
            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.journey(.caption))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    LabeledContent("Timestamp",
                                   value: p.timestampColumn.map { "column \($0 + 1)" } ?? "none found")
                    LabeledContent("Value", value: p.valueColumn.map { "column \($0 + 1)" } ?? "none found")
                    if p.usedFileDate {
                        Label("No timestamps in this file, so every row is dated from the file itself. Only the total or last reading is stored, so this is usually still fine.",
                              systemImage: "calendar.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    // "None found" is fine for a timestamp-only sensor and a
                    // silent disaster for a numeric one — the reading would
                    // import with no number at all. Say so plainly.
                    if p.valueColumn == nil && chosenKind.isNumeric {
                        Label("No numeric column was found. \(chosenKind.displayName) needs one — importing now would store a timestamp with no reading.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Sensor") {
                    Picker(p.detectedKind == nil ? "Sensor" : "Detected", selection: $chosenKind) {
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
                    if chosenKind.isCumulative {
                        Text("Adds up over a day, so the stored figure is the total for the newest day in the file — the same thing Apple Health reports.")
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

    /// Copies the picked file somewhere we reliably control, then reads it for a
    /// row count and date range. Nothing is stored at this stage.
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
                    var msg = "\(r.kind.displayName) ← \(r.filename): \(r.rowCount) rows"
                    if let value = r.storedValue { msg += ", showing \(value)" }
                    if r.skippedRows > 0 { msg += " (\(r.skippedRows) skipped)" }
                    status = msg
                    log.insert(msg, at: 0)
                case .failure(let error):
                    status = error.localizedDescription
                    log.insert("Failed: \(error.localizedDescription)", at: 0)
                }
                reload()
            }
        }
    }

    private func reload() {
        loaded = SensorStatusStore.shared.loadedImports()
    }

    /// Detected sensor plus the folder it came from — the scan covers Documents,
    /// to-be-processed/ and processed/, so the folder matters.
    private func scanSubtitle(for url: URL) -> String {
        let sensor = SensorKindMatcher.match(filename: url.lastPathComponent)?.displayName ?? "sensor not recognized"
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder == "Documents" ? sensor : "\(sensor) · \(folder)"
    }

    private func rangeText(_ info: SensorImportInfo) -> String {
        guard let min = info.dateMin, let max = info.dateMax else { return "" }
        return " · covers \(Self.day.string(from: min)) – \(Self.day.string(from: max))"
    }

    // MARK: - Small view helpers

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.journey(.caption, weight: .semibold))
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
            Text(text).font(.journey(.subheadline, weight: .semibold))
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
                .font(.journey(.caption2, weight: .semibold))
                .foregroundStyle(destructive ? .red : terracotta)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill((destructive ? Color.red : terracotta).opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

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
