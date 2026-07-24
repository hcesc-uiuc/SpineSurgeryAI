//
//  SensorFileImporter.swift
//  SensingApp
//
//  Turns a CSV file into a stored sensor series (see SensorDataStore).
//
//  File shape — `timestamp,value`, one reading per line, header optional:
//
//      timestamp,value
//      2026-07-22T09:00:00,68
//      2026-07-23T09:00:00,71
//
//  Values are BARE NUMBERS; the unit comes from the sensor (SensorKind.unit),
//  so heart rate renders as "72 bpm" and Home tiles get a usable number without
//  parsing text back out of a string. Timestamp-only sensors (accelerometer,
//  location, watch streams, survey) may omit the value column entirely.
//
//  Everything here streams: the file is read in 64 KB chunks and inserted in
//  batches, so a 100k-row export never sits in memory.
//

import Foundation

// MARK: - Buffered line reader

/// Reads a text file line by line in fixed chunks. Holds at most one chunk plus
/// the current partial line, regardless of file size.
nonisolated private final class LineReader {
    private let handle: FileHandle
    private var buffer = [UInt8]()
    private var pos = 0
    private var atEOF = false
    private let chunkSize = 64 * 1024

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func next() -> String? {
        while true {
            if let nl = buffer[pos...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = decode(buffer[pos..<nl])
                pos = nl + 1
                return line
            }
            if atEOF {
                guard pos < buffer.count else { return nil }
                let line = decode(buffer[pos...])
                pos = buffer.count
                return line
            }
            // Drop the consumed prefix before pulling the next chunk, so the
            // buffer stays bounded instead of growing to the size of the file.
            if pos > 0 {
                buffer.removeFirst(pos)
                pos = 0
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { atEOF = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    private func decode(_ bytes: ArraySlice<UInt8>) -> String {
        var slice = bytes
        if slice.last == UInt8(ascii: "\r") { slice = slice.dropLast() }   // CRLF files
        return String(decoding: slice, as: UTF8.self)
    }
}

// MARK: - Timestamp parsing

/// Sniffs the timestamp format from the first row that parses, then reuses that
/// single strategy for the rest of the file (trying ten formatters per line on a
/// 100k-row file would dominate the import time).
nonisolated private struct TimestampParser {
    private var locked: ((String) -> Date?)?

    mutating func parse(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let locked { return locked(s) }
        for strategy in Self.strategies {
            if let date = strategy(s) {
                locked = strategy
                return date
            }
        }
        return nil
    }

    private static func fixed(_ format: String) -> (String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return { f.date(from: $0) }
    }

    private static let strategies: [(String) -> Date?] = {
        let isoFull: (String) -> Date? = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return { f.date(from: $0) }
        }()
        let isoPlain: (String) -> Date? = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return { f.date(from: $0) }
        }()
        let epoch: (String) -> Date? = { s in
            // Only treat bare digits as epoch, and use the magnitude to tell
            // milliseconds from seconds (13 digits ≈ ms since 1970).
            guard let n = Double(s), s.allSatisfy({ $0.isNumber || $0 == "." }), n > 100_000_000 else { return nil }
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        return [
            isoFull,
            isoPlain,
            fixed("yyyy-MM-dd'T'HH:mm:ss"),
            fixed("yyyy-MM-dd'T'HH:mm"),
            fixed("yyyy-MM-dd HH:mm:ss"),
            fixed("yyyy-MM-dd HH:mm"),
            fixed("yyyy-MM-dd"),
            fixed("MM/dd/yyyy HH:mm:ss"),
            fixed("MM/dd/yyyy HH:mm"),
            fixed("MM/dd/yyyy"),
            epoch
        ]
    }()
}

// MARK: - Filename → sensor recognition

nonisolated enum SensorKindMatcher {

    /// Aliases per sensor. Matched against the filename with all punctuation
    /// stripped, so "heartratedata.csv", "heart_rate.csv" and "HR-jul24.csv"
    /// all resolve to .heartRate.
    private static let aliases: [SensorKind: [String]] = [
        .heartRateVariability: ["heartratevariability", "heartratevar", "hrvsdnn", "sdnn", "hrv"],
        .heartRate:            ["heartrate", "pulse", "bpm", "hr"],
        .steps:                ["stepcount", "stepstaken", "walking", "steps", "step"],
        .distance:             ["distancewalkingrunning", "walkingdistance", "distance"],
        .bloodOxygen:          ["oxygensaturation", "bloodoxygen", "oxygen", "spo2"],
        .activeEnergy:         ["activeenergyburned", "activeenergy", "energyburned", "calories", "kcal"],
        .flights:              ["flightsclimbed", "flights", "stairs"],
        .sleep:                ["sleepanalysis", "sleep"],
        .watchAccelerometer:   ["watchaccelerometer", "watchaccel"],
        .watchHeartPPG:        ["watchheartppg", "watchheart", "ppg"],
        .wristTemperature:     ["wristtemperature", "wristtemp"],
        .ambientLight:         ["ambientlight", "lux"],
        .accelerometer:        ["accelerometer", "accel"],
        .gyroscope:            ["gyroscope", "gyro"],
        .location:             ["coordinates", "location", "gps"],
        .ecg:                  ["electrocardiogram", "ecg", "ekg"],
        .survey:               ["painscore", "checkin", "survey"]
    ]

    /// Longest aliases first, so "heartratevariability" can never be captured by
    /// the shorter "heartrate".
    private static let ordered: [(alias: String, kind: SensorKind)] = {
        aliases.flatMap { kind, list in list.map { (alias: $0, kind: kind) } }
               .sorted { $0.alias.count > $1.alias.count }
    }()

    static func match(filename: String) -> SensorKind? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let normalized = stem.filter { $0.isLetter || $0.isNumber }
        return ordered.first { normalized.contains($0.alias) }?.kind
    }
}

// MARK: - Importer

nonisolated enum SensorFileImporter {

    enum ImportError: LocalizedError {
        case unreadable
        /// Nothing importable was found. Carries what we DID see so the message
        /// can tell "this file is just a header" apart from "these timestamps
        /// are in a format I don't read" — those need very different fixes.
        case noValidRows(linesSeen: Int, sample: String?)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Could not read that file."
            case .noValidRows(let linesSeen, let sample):
                switch linesSeen {
                case 0:
                    return "That file is empty."
                case 1:
                    return "That file has one line and no data rows — it looks like a header on its own: \u{201C}\(sample ?? "")\u{201D}"
                default:
                    return "No readable timestamp found in \(linesSeen) lines. The first line was \u{201C}\(sample ?? "")\u{201D} — a column needs to hold a date or a Unix time."
                }
            }
        }
    }

    /// What the confirmation sheet shows before anything is written.
    struct Preview {
        let url: URL
        let filename: String
        let detectedKind: SensorKind?
        let rowCount: Int
        let skippedRows: Int
        let dateMin: Date?
        let dateMax: Date?
        let timestampColumn: Int    // 0-based, as detected
        let valueColumn: Int?       // nil = no numeric column after the timestamp
    }

    /// Result of a completed import.
    struct Result {
        let kind: SensorKind
        let filename: String
        let rowCount: Int
        let skippedRows: Int
        let replacedRowCount: Int?     // rows in the series this one replaced, if any
    }

    /// Walks the file once, handing every readable row to `onRow`.
    ///
    /// The timestamp is NOT assumed to be the first column. The app's own files
    /// disagree about shape — accelerometer writes `timestamp,x,y,z`, location
    /// writes six fields with no header at all — and arbitrary exports disagree
    /// further, so the layout is detected from the first row that actually reads
    /// as a date and reused from then on. Anything before that (a header, junk)
    /// is remembered so a failure can quote it back.
    private static func stream(url: URL, onRow: (Date, Double?) -> Void) throws -> Layout {
        guard let reader = try? LineReader(url: url) else { throw ImportError.unreadable }

        var parser = TimestampParser()
        var tsCol: Int?
        var valCol: Int?
        var rows = 0, skipped = 0, linesSeen = 0
        var firstLine: String?
        var minDate: Date?, maxDate: Date?

        while let line = reader.next() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            linesSeen += 1
            if firstLine == nil { firstLine = line }
            let fields = splitFields(line)

            if tsCol == nil {
                // Probe each column until one reads as a timestamp. The parser
                // locks onto that format, so later rows cost one attempt.
                for (i, field) in fields.enumerated() where parser.parse(field) != nil {
                    tsCol = i
                    // Value = the first numeric column AFTER the timestamp.
                    valCol = fields.indices.first { $0 > i && Double(fields[$0]) != nil }
                    break
                }
                guard tsCol != nil else { continue }   // header or unreadable line
            }

            guard let column = tsCol, column < fields.count,
                  let date = parser.parse(fields[column]) else {
                skipped += 1
                continue
            }
            rows += 1
            if minDate == nil || date < minDate! { minDate = date }
            if maxDate == nil || date > maxDate! { maxDate = date }
            onRow(date, valCol.flatMap { $0 < fields.count ? Double(fields[$0]) : nil })
        }

        guard rows > 0, let column = tsCol else {
            throw ImportError.noValidRows(linesSeen: linesSeen, sample: firstLine)
        }
        return Layout(timestampColumn: column, valueColumn: valCol,
                      rowCount: rows, skippedRows: skipped,
                      dateMin: minDate, dateMax: maxDate)
    }

    /// What `stream` worked out about a file.
    struct Layout {
        let timestampColumn: Int
        let valueColumn: Int?
        let rowCount: Int
        let skippedRows: Int
        let dateMin: Date?
        let dateMax: Date?
    }

    /// Reads the file to work out its shape and size WITHOUT writing anything.
    /// A second pass on import is cheap next to half-importing something the
    /// user then rejects.
    static func inspect(url: URL) throws -> Preview {
        let layout = try stream(url: url) { _, _ in }
        let filename = url.lastPathComponent
        return Preview(url: url,
                       filename: filename,
                       detectedKind: SensorKindMatcher.match(filename: filename),
                       rowCount: layout.rowCount,
                       skippedRows: layout.skippedRows,
                       dateMin: layout.dateMin,
                       dateMax: layout.dateMax,
                       timestampColumn: layout.timestampColumn,
                       valueColumn: layout.valueColumn)
    }

    /// Streams the file into the store as a new active series for `kind`,
    /// replacing (but retaining) whatever was active for that sensor before.
    static func perform(url: URL, kind: SensorKind) throws -> Result {
        let store = SensorDataStore.shared
        let replaced = store.activeImports().first { $0.kind == kind }
        let filename = url.lastPathComponent

        guard let importID = store.beginImport(kind: kind, filename: filename) else {
            throw ImportError.unreadable
        }

        var batch: [SensorReading] = []
        batch.reserveCapacity(batchSize)

        do {
            let layout = try stream(url: url) { date, value in
                // Timestamp-only sensors ignore the value column entirely.
                batch.append(SensorReading(date: date, value: kind.isNumeric ? value : nil))
                if batch.count >= batchSize {
                    store.appendBatch(batch, kind: kind, importID: importID)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            store.appendBatch(batch, kind: kind, importID: importID)
            store.finishImport(id: importID, kind: kind)
            return Result(kind: kind,
                          filename: filename,
                          rowCount: layout.rowCount,
                          skippedRows: layout.skippedRows,
                          replacedRowCount: replaced?.rowCount)
        } catch {
            // Never leave a half-written series behind as the visible data.
            store.abortImport(id: importID)
            throw error
        }
    }

    private static let batchSize = 5_000

    /// Minimal CSV field split — good enough for the `timestamp,value` shape,
    /// tolerating quotes and stray spaces.
    private static func splitFields(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
              .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    // MARK: - Folder scan

    /// Data files the app can offer to import: anything dropped into the top
    /// level of Documents over Finder, plus the app's OWN recordings sitting in
    /// to-be-processed/ and processed/.
    ///
    /// `.txt` counts as well as `.csv` — the app writes its location and
    /// HealthKit logs as .txt, and a csv-only filter made the app's own data
    /// invisible here.
    static func scanDocumentsFolder() -> [URL] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }

        let extensions: Set<String> = ["csv", "txt"]
        let folders: [URL] = [docs,
                              docs.appendingPathComponent("to-be-processed"),
                              docs.appendingPathComponent("processed")]

        var found: [URL] = []
        for folder in folders {
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for entry in entries {
                guard extensions.contains(entry.pathExtension.lowercased()) else { continue }
                // A zero-byte file has nothing to import and would only produce
                // a confusing error further down.
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0 else { continue }
                found.append(entry)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Send to database

/// Pushes an imported series through the REAL upload path — it writes a CSV into
/// `to-be-processed/` and lets `Uploader` carry it to S3/Lambda, exactly as
/// recorder data travels. Nothing here runs automatically: imported data stays on
/// the device until someone presses the button, so a demo file can never quietly
/// become study data.
nonisolated enum SensorDataExporter {

    /// `healthkit_` prefix so `Uploader.uploadFolder()` picks the file up.
    /// The name ends in a TIME, not a bare date, because the uploader skips any
    /// file whose name ends with today's `yyyy-MM-dd` (it assumes such a file is
    /// still open for writing) — a date-suffixed name would never upload.
    private static func filename(for record: SensorImportRecord) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "healthkit_import_\(record.kind.rawValue)_\(f.string(from: Date())).csv"
    }

    /// Streams the stored series out to a CSV in the upload queue.
    static func writeToUploadQueue(_ record: SensorImportRecord) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent("to-be-processed")
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let url = folder.appendingPathComponent(filename(for: record))

        let stamp = ISO8601DateFormatter()
        var csv = "timestamp,sensor,value\n"
        SensorDataStore.shared.forEachReading(importID: record.id) { reading in
            let value = reading.value.map { String($0) } ?? ""
            csv += "\(stamp.string(from: reading.date)),\(record.kind.rawValue),\(value)\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes the file, then runs the normal uploader pass.
    /// Note this flushes the WHOLE upload queue, not just this file — that is
    /// the production behaviour, which is the point of exercising it.
    static func sendToDatabase(_ record: SensorImportRecord) async -> String {
        do {
            let url = try writeToUploadQueue(record)
            await Uploader.shared.uploadFolder()
            return "Queued \(url.lastPathComponent) (\(record.rowCount) rows) and ran the uploader."
        } catch {
            return "Failed to queue: \(error.localizedDescription)"
        }
    }
}
