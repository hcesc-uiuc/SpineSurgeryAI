//
//  SensorFileImporter.swift
//  SensingApp
//
//  Turns a data file into ONE stored reading per sensor (see SensorStatusStore).
//
//  ── Why this is deliberately tolerant ───────────────────────────────────────
//  We do not know what the incoming files look like. They may come from a study
//  coordinator's export, from another lab's tooling, or from the app's own
//  recordings — and those three already disagree about nearly everything. So
//  rather than specify a format and reject anything else, the importer works out
//  the shape of whatever it is handed:
//
//    • Delimiter    — comma, tab, semicolon, pipe, or whitespace, sniffed.
//    • Layout       — the timestamp is found by probing columns, not assumed to
//                     be column 0. The value is the first numeric column after
//                     it (or before it, or a column whose header says "value").
//    • Timestamps   — ISO 8601, "yyyy-MM-dd HH:mm:ss" and friends, US and
//                     European slash dates, and Unix epoch in seconds or ms.
//    • Header       — optional. A first line that does not parse as data is
//                     kept as column names and used to pick the value column.
//    • JSON         — an array of objects, an array of arrays, an array of bare
//                     numbers, or any of those wrapped in an envelope object.
//    • No timestamp — a file of bare readings still imports, stamped with the
//                     file's own modification date.
//
//  If a guess is wrong it is VISIBLE: the confirmation sheet shows which column
//  it picked for the timestamp and which for the value, before anything is
//  stored. That matters more than being clever — a silently wrong column looks
//  exactly like working software.
//
//  ── What gets stored ────────────────────────────────────────────────────────
//  Only the newest reading survives, because that is all any screen shows. For
//  cumulative sensors (steps, distance, energy, flights) the stored figure is
//  the TOTAL over the day of the newest row, matching how the live HealthKit
//  path reports the same metric. The file itself stays where it is and is never
//  modified, so it remains the archive if fuller history is ever wanted.
//
//  Reading streams in 64 KB chunks, so row count is not a memory concern.
//  (JSON is the exception — it is parsed whole, as JSON must be.)
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
/// single strategy for the rest of the file (trying every formatter on every
/// line of a 100k-row file would dominate the import time).
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
            // milliseconds from seconds (13 digits ≈ ms since 1970). The lower
            // bound keeps a plain reading like "72" from being read as a date.
            guard let n = Double(s), s.allSatisfy({ $0.isNumber || $0 == "." }), n > 100_000_000 else { return nil }
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        return [
            isoFull,
            isoPlain,
            fixed("yyyy-MM-dd'T'HH:mm:ss"),
            fixed("yyyy-MM-dd'T'HH:mm"),
            fixed("yyyy-MM-dd HH:mm:ss.SSS"),
            fixed("yyyy-MM-dd HH:mm:ss"),
            fixed("yyyy-MM-dd HH:mm"),
            fixed("yyyy-MM-dd"),
            fixed("yyyy/MM/dd HH:mm:ss"),
            fixed("yyyy/MM/dd"),
            fixed("MM/dd/yyyy HH:mm:ss"),
            fixed("MM/dd/yyyy HH:mm"),
            fixed("MM/dd/yyyy"),
            // Day-first, as most of the world outside the US writes it. Ordered
            // AFTER the US forms: the two are ambiguous for days 1–12 and this
            // is a US study, so the US reading wins a genuine tie.
            fixed("dd/MM/yyyy HH:mm:ss"),
            fixed("dd-MM-yyyy HH:mm:ss"),
            fixed("dd-MM-yyyy"),
            fixed("dd MMM yyyy HH:mm:ss"),
            fixed("dd MMM yyyy"),
            fixed("MMM d, yyyy HH:mm:ss"),
            fixed("MMM d, yyyy"),
            fixed("MMM d yyyy"),
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

// MARK: - Rows in, whatever the file looks like

/// A file reduced to rows of plain string fields, plus an optional header row.
/// CSV-ish text and JSON both arrive here, so everything downstream — column
/// probing, timestamp parsing, value selection — is written once.
nonisolated private struct RowStream {
    let header: [String]?
    /// Walks the rows. May be called only once.
    let forEachRow: ((_ fields: [String]) -> Void) -> Void
}

nonisolated private enum RowStreamBuilder {

    /// Field separators we will consider, in preference order. Whitespace is the
    /// last resort so that a single-column file still yields one field per line.
    private static let delimiters: [Character] = [",", "\t", ";", "|"]

    static func make(url: URL) throws -> RowStream {
        if let json = try jsonStream(url: url) { return json }
        return try delimitedStream(url: url)
    }

    // MARK: Delimited text

    private static func delimitedStream(url: URL) throws -> RowStream {
        let delimiter = try sniffDelimiter(url: url)
        // The header is only recognised as such downstream (a first line that
        // holds no timestamp); here we just hand the rows over in order.
        return RowStream(header: nil) { emit in
            guard let reader = try? LineReader(url: url) else { return }
            while let line = reader.next() {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                emit(split(line, by: delimiter))
            }
        }
    }

    /// Picks whichever candidate separator appears most consistently across the
    /// first few lines. Returns nil to mean "split on whitespace".
    private static func sniffDelimiter(url: URL) throws -> Character? {
        guard let reader = try? LineReader(url: url) else { throw SensorFileImporter.ImportError.unreadable }
        var counts: [Character: Int] = [:]
        var lines = 0
        while lines < 5, let line = reader.next() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            lines += 1
            for d in delimiters where line.contains(d) {
                counts[d, default: 0] += line.filter { $0 == d }.count
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func split(_ line: String, by delimiter: Character?) -> [String] {
        let parts: [Substring]
        if let delimiter {
            parts = line.split(separator: delimiter, omittingEmptySubsequences: false)
        } else {
            parts = line.split(whereSeparator: { $0.isWhitespace })
        }
        return parts.map {
            $0.trimmingCharacters(in: .whitespaces)
              .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    // MARK: JSON

    /// Recognises JSON by its first meaningful byte, then flattens it to rows.
    /// Returns nil when the file is not JSON, so the caller falls through to the
    /// delimited path.
    private static func jsonStream(url: URL) throws -> RowStream? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let head = handle.readData(ofLength: 64)
        try? handle.close()
        guard let first = head.first(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }),
              first == UInt8(ascii: "[") || first == UInt8(ascii: "{") else { return nil }

        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let array = firstArray(in: parsed) else { return nil }

        // Array of objects: sorted keys give a stable column order AND double as
        // the header row, which is what lets a "value" column be found by name.
        if let objects = array as? [[String: Any]] {
            let keys = Set(objects.prefix(50).flatMap(\.keys)).sorted()
            let rows = objects.map { object in keys.map { text(object[$0]) } }
            return RowStream(header: keys) { emit in rows.forEach(emit) }
        }
        if let arrays = array as? [[Any]] {
            let rows = arrays.map { $0.map(text) }
            return RowStream(header: nil) { emit in rows.forEach(emit) }
        }
        // A bare list of readings — one value per row, no timestamps.
        let rows = array.map { [text($0)] }
        return RowStream(header: nil) { emit in rows.forEach(emit) }
    }

    /// The payload array, whether it is the whole document or wrapped in an
    /// envelope like `{"data": [...]}`.
    private static func firstArray(in object: Any) -> [Any]? {
        if let array = object as? [Any] { return array }
        guard let dict = object as? [String: Any] else { return nil }
        // Deterministic: pick by sorted key, not by dictionary order.
        for key in dict.keys.sorted() {
            if let array = dict[key] as? [Any], !array.isEmpty { return array }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case .none, is NSNull: return ""
        case let other?: return String(describing: other)
        }
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
                    return "Found \(linesSeen) lines but no readable data in them. The first line was \u{201C}\(sample ?? "")\u{201D} — a row needs either a date/Unix time or a plain number."
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
        let timestampColumn: Int?   // nil = no timestamp column found in the file
        let valueColumn: Int?       // nil = no numeric column found
        /// True when the file carried no timestamps and the file's own
        /// modification date was used instead. Surfaced in the sheet, because it
        /// means every row shares one date.
        let usedFileDate: Bool
    }

    /// Result of a completed import.
    struct Result {
        let kind: SensorKind
        let filename: String
        let rowCount: Int
        let skippedRows: Int
        let storedValue: String?
        let storedDate: Date
    }

    /// What `scan` worked out about a file, without storing anything.
    private struct Scan {
        var timestampColumn: Int?
        var valueColumn: Int?
        var rowCount = 0
        var skippedRows = 0
        var dateMin: Date?
        var dateMax: Date?
        var usedFileDate = false
        var linesSeen = 0
        var firstLine: String?
    }

    /// Column names that mean "this is the reading", used when the file has a
    /// header. Checked before falling back to positional guessing.
    private static let valueHeaderWords = [
        "value", "reading", "measurement", "amount", "count", "qty", "quantity", "result"
    ]

    /// Walks the file once, handing every readable row to `onRow` as
    /// (timestamp, value).
    ///
    /// The timestamp is NOT assumed to be the first column. The app's own files
    /// disagree about shape — accelerometer writes `timestamp,x,y,z`, location
    /// writes six fields with no header at all — and arbitrary exports disagree
    /// further, so the layout is detected from the first row that actually reads
    /// as a date and reused from then on. Anything before that (a header, junk)
    /// is remembered so a failure can quote it back, and so its column names can
    /// be used to find the value.
    ///
    /// When no column anywhere in the file parses as a date, the whole file is
    /// re-read as bare readings stamped with the file's modification date rather
    /// than rejected.
    private static func scan(url: URL, onRow: ((Date, Double?) -> Void)?) throws -> Scan {
        let stream = try RowStreamBuilder.make(url: url)
        var parser = TimestampParser()
        var result = Scan()
        var header: [String]? = stream.header
        var pending: [(fields: [String], date: Date)] = []

        // Rows seen before the value column is known are held back, so that a
        // file whose first readings are blank still contributes them once a
        // later row reveals which column the value lives in. Bounded — see
        // valueProbeLimit.
        func flushPending() {
            guard let onRow else { pending.removeAll(); return }
            for item in pending {
                onRow(item.date, value(in: item.fields, valueColumn: result.valueColumn))
            }
            pending.removeAll()
        }

        stream.forEachRow { fields in
            result.linesSeen += 1
            if result.firstLine == nil { result.firstLine = fields.joined(separator: ",") }

            if result.timestampColumn == nil {
                // Probe each column until one reads as a timestamp. Doing so
                // also locks the parser onto that format, so later rows cost a
                // single attempt.
                for (i, field) in fields.enumerated() where parser.parse(field) != nil {
                    result.timestampColumn = i
                    break
                }
                guard result.timestampColumn != nil else {
                    // Not data — most likely the header. Keep its names.
                    if header == nil, result.linesSeen == 1 { header = fields }
                    return
                }
            }

            guard let column = result.timestampColumn, column < fields.count,
                  let date = parser.parse(fields[column]) else {
                result.skippedRows += 1
                return
            }

            // Value column: a header that names it wins; otherwise the first
            // numeric column after the timestamp, else before it. Keep probing
            // on later rows while it is still unknown rather than settling it
            // from the first data row alone — a file whose first reading
            // happened to be blank would otherwise resolve to the wrong column
            // (or to none), silently dropping every value in the file.
            if result.valueColumn == nil, result.rowCount < valueProbeLimit {
                result.valueColumn = pickValueColumn(fields: fields, header: header, timestampColumn: column)
            }

            result.rowCount += 1
            if result.dateMin == nil || date < result.dateMin! { result.dateMin = date }
            if result.dateMax == nil || date > result.dateMax! { result.dateMax = date }

            if result.valueColumn == nil, result.rowCount <= valueProbeLimit {
                pending.append((fields, date))
            } else {
                flushPending()
                onRow?(date, value(in: fields, valueColumn: result.valueColumn))
            }
        }
        flushPending()

        if result.rowCount > 0 { return result }

        // Nothing had a timestamp. Rather than reject the file, take it as a
        // list of bare readings and stamp them with the file's own date.
        if result.timestampColumn == nil, result.linesSeen > 0 {
            if let fallback = try? scanWithoutTimestamps(url: url, header: header, onRow: onRow),
               fallback.rowCount > 0 {
                var merged = fallback
                merged.linesSeen = result.linesSeen
                merged.firstLine = result.firstLine
                return merged
            }
        }
        throw ImportError.noValidRows(linesSeen: result.linesSeen, sample: result.firstLine)
    }

    /// Second pass for files with no timestamps at all: every numeric row counts,
    /// all stamped with the file's modification date.
    private static func scanWithoutTimestamps(url: URL,
                                              header: [String]?,
                                              onRow: ((Date, Double?) -> Void)?) throws -> Scan {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let stream = try RowStreamBuilder.make(url: url)
        var result = Scan()
        result.usedFileDate = true
        result.dateMin = stamp
        result.dateMax = stamp

        var isFirst = true
        stream.forEachRow { fields in
            // Skip a header line, which by definition holds no number.
            if isFirst {
                isFirst = false
                if header != nil, !fields.contains(where: { Double($0) != nil }) { return }
            }
            if result.valueColumn == nil {
                result.valueColumn = pickValueColumn(fields: fields, header: header, timestampColumn: nil)
            }
            guard let value = value(in: fields, valueColumn: result.valueColumn) else {
                result.skippedRows += 1
                return
            }
            result.rowCount += 1
            onRow?(stamp, value)
        }
        return result
    }

    private static func pickValueColumn(fields: [String], header: [String]?, timestampColumn: Int?) -> Int? {
        if let header {
            for (i, name) in header.enumerated() where i != timestampColumn && i < fields.count {
                let normalized = name.lowercased().filter { $0.isLetter }
                guard !normalized.isEmpty, valueHeaderWords.contains(where: { normalized.contains($0) }) else { continue }
                if Double(fields[i]) != nil { return i }
            }
        }
        if let timestampColumn {
            if let after = fields.indices.first(where: { $0 > timestampColumn && Double(fields[$0]) != nil }) { return after }
            return fields.indices.first { $0 < timestampColumn && Double(fields[$0]) != nil }
        }
        return fields.indices.first { Double(fields[$0]) != nil }
    }

    private static func value(in fields: [String], valueColumn: Int?) -> Double? {
        guard let valueColumn, valueColumn < fields.count else { return nil }
        return Double(fields[valueColumn])
    }

    /// How many data rows to keep probing for a value column before giving up
    /// and treating the file as timestamp-only. Bounded so a genuinely
    /// timestamp-only file (location, watch streams) does not pay the check on
    /// every one of its rows.
    private static let valueProbeLimit = 50

    // MARK: - Public entry points

    /// Reads the file to work out its shape and size WITHOUT storing anything.
    /// A second pass on import is cheap next to half-importing something the
    /// user then rejects.
    static func inspect(url: URL) throws -> Preview {
        let scanned = try scan(url: url, onRow: nil)
        let filename = url.lastPathComponent
        return Preview(url: url,
                       filename: filename,
                       detectedKind: SensorKindMatcher.match(filename: filename),
                       rowCount: scanned.rowCount,
                       skippedRows: scanned.skippedRows,
                       dateMin: scanned.dateMin,
                       dateMax: scanned.dateMax,
                       timestampColumn: scanned.timestampColumn,
                       valueColumn: scanned.valueColumn,
                       usedFileDate: scanned.usedFileDate)
    }

    /// Reduces the file to the one reading the app displays, and stores it.
    ///
    /// Cumulative sensors are summed over the day of their newest row, so an
    /// hourly step file reports a day total exactly as Apple Health does rather
    /// than reporting its last hour. Everything else keeps the newest reading.
    /// Timestamp-only sensors keep just the newest date.
    @discardableResult
    static func perform(url: URL, kind: SensorKind) throws -> Result {
        var newest: Date?
        var newestValue: Double?
        var dayTotals: [Date: Double] = [:]
        let calendar = Calendar.current

        let scanned = try scan(url: url) { date, value in
            // `>=`, not `>`: on a tie the LATER ROW IN THE FILE wins. This is
            // what makes a file with no timestamps work at all — every row there
            // carries the same file date, and `>` would freeze the very first
            // reading in place. It is also the right reading of a genuine
            // duplicate timestamp, since files are written in order.
            if newest == nil || date >= newest! {
                newest = date
                newestValue = value
            }
            if kind.isCumulative, kind.isNumeric, let value {
                dayTotals[calendar.startOfDay(for: date), default: 0] += value
            }
        }

        guard let storedDate = newest else {
            throw ImportError.noValidRows(linesSeen: scanned.linesSeen, sample: scanned.firstLine)
        }

        var numeric: Double?
        if kind.isNumeric {
            numeric = kind.isCumulative ? dayTotals[calendar.startOfDay(for: storedDate)] : newestValue
        }
        let text = numeric.map { kind.formatted($0) }
        let filename = url.lastPathComponent

        let info = SensorImportInfo(kindRaw: kind.rawValue,
                                    filename: filename,
                                    rowCount: scanned.rowCount,
                                    skippedRows: scanned.skippedRows,
                                    dateMin: scanned.dateMin,
                                    dateMax: scanned.dateMax,
                                    importedAt: Date())
        SensorStatusStore.shared.recordImport(kind,
                                              value: text,
                                              numeric: numeric,
                                              at: storedDate,
                                              info: info)

        return Result(kind: kind,
                      filename: filename,
                      rowCount: scanned.rowCount,
                      skippedRows: scanned.skippedRows,
                      storedValue: text,
                      storedDate: storedDate)
    }

    // MARK: - Finding files

    /// Extensions worth opening. Broad on purpose — the app's own location and
    /// HealthKit logs are `.txt`, and a csv-only filter made them invisible here.
    private static let dataExtensions: Set<String> = ["csv", "tsv", "txt", "json", "dat", "log"]

    /// Files a dev has dropped into the top level of Documents. This folder is
    /// exposed over Finder and the Files app (`UIFileSharingEnabled`), so
    /// dropping a file in is the no-UI way to load data.
    static func scanInbox() -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        return dataFiles(in: docs)
    }

    /// Everything importable on the device: the drop folder above, plus the
    /// app's OWN recordings in to-be-processed/ and processed/.
    ///
    /// Importing one of the app's recordings only READS it — the file is not
    /// moved or consumed, so the normal upload flow is unaffected.
    static func scanAllFolders() -> [URL] {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let folders = [docs,
                       docs.appendingPathComponent("to-be-processed"),
                       docs.appendingPathComponent("processed")]
        var found: [URL] = []
        for folder in folders { found.append(contentsOf: dataFiles(in: folder)) }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func dataFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var found: [URL] = []
        for entry in entries {
            guard dataExtensions.contains(entry.pathExtension.lowercased()) else { continue }
            // A zero-byte file has nothing to import and would only produce a
            // confusing error further down.
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { continue }
            found.append(entry)
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Automatic pickup

    /// Imports anything new sitting in the Documents drop folder, matching each
    /// file to a sensor by its NAME. Called on every foreground, so the flow is
    /// simply: drop a file in over Finder or the Files app, reopen the app, see
    /// it on the Sensors tab.
    ///
    /// Only the top level of Documents is auto-ingested — never
    /// to-be-processed/ or processed/. Those hold the app's own live recordings,
    /// and auto-importing them would pin every sensor to an imported value that
    /// then blocks the real stamps (imports win until cleared). Those folders
    /// stay reachable from the Debug tab, by hand.
    ///
    /// A file is ingested once per (size, modification date), so reopening the
    /// app does not re-import it, while dropping in a CHANGED file of the same
    /// name does. Files that fail are marked too — otherwise a broken file would
    /// be retried on every single foreground.
    ///
    /// Blocking file I/O: call from a background queue.
    @discardableResult
    static func autoIngestInbox() -> [String] {
        let defaults = UserDefaults.standard
        var messages: [String] = []

        for url in scanInbox() {
            guard let kind = SensorKindMatcher.match(filename: url.lastPathComponent) else { continue }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let fingerprint = "\(size)-\(Int(modified))"
            let key = "sensorAutoIngest_\(url.lastPathComponent)"
            guard defaults.string(forKey: key) != fingerprint else { continue }

            defaults.set(fingerprint, forKey: key)
            do {
                let result = try perform(url: url, kind: kind)
                messages.append("Loaded \(url.lastPathComponent) → \(kind.displayName) (\(result.rowCount) rows)")
            } catch {
                messages.append("Skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return messages
    }

    /// Lets a file be picked up again even though it has not changed — used by
    /// "Clear all", so that clearing does not permanently hide the files that
    /// are still sitting in the folder.
    static func forgetAutoIngestHistory() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sensorAutoIngest_") {
            defaults.removeObject(forKey: key)
        }
    }
}
