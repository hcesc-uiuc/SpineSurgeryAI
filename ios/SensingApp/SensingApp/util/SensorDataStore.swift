//
//  SensorDataStore.swift
//  SensingApp
//
//  Unified time-series store behind the Sensors tab and the Home stat tiles.
//
//  This is the "gather → store → render" pipeline: a sensor series can arrive from
//  an imported CSV today and from the on-phone recorders later, and every screen
//  reads the result the same way. Display precedence is:
//
//      1. active IMPORTED series   (wins until cleared — see ImportDataView)
//      2. real HealthKit/recorder stamp   (SensorStatusStore)
//      3. hardcoded sample fallback       (SensorStatusStore.sampleData)
//
//  Every rendered line carries its SOURCE ("from heartratedata.csv",
//  "from Apple Health", "from sample data") so a value can never quietly
//  masquerade as something it isn't.
//
//  STORAGE NOTE: this uses its OWN SQLite database in Application Support —
//  deliberately NOT SQLiteSaver, whose database lives in to-be-processed/ and
//  rotates to a fresh file every 5 MB. Anything stored there would eventually be
//  uploaded to S3 and then rotated away. Imported data must stay on the device
//  until someone explicitly presses "Send to database", so it needs a stable home
//  that the uploader never scans.
//

import Foundation
import SQLite3

nonisolated private enum SQL {
    /// Tells SQLite to copy bound strings rather than borrow them.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: - Per-sensor metadata

nonisolated extension SensorKind {

    /// Human name used in the import picker and the loaded-sensor list.
    var displayName: String {
        switch self {
        case .accelerometer:        return "Accelerometer"
        case .gyroscope:            return "Gyroscope"
        case .location:             return "Location"
        case .heartRate:            return "Heart Rate"
        case .heartRateVariability: return "Heart Rate Variability"
        case .steps:                return "Steps"
        case .distance:             return "Walking Distance"
        case .bloodOxygen:          return "Blood Oxygen"
        case .activeEnergy:         return "Active Energy"
        case .flights:              return "Flights Climbed"
        case .sleep:                return "Sleep"
        case .watchAccelerometer:   return "Watch Accelerometer"
        case .watchHeartPPG:        return "Watch Heart & PPG"
        case .ecg:                  return "ECG"
        case .wristTemperature:     return "Wrist Temperature"
        case .ambientLight:         return "Ambient Light"
        case .survey:               return "Recovery Check-in"
        }
    }

    /// Unit appended to a bare imported number ("72" → "72 bpm").
    /// nil = timestamp-only sensor: the file's value column is ignored and the
    /// row shows only when it was recorded.
    var unit: String? {
        switch self {
        case .heartRate:            return "bpm"
        case .heartRateVariability: return "ms"
        case .steps:                return "steps"
        case .distance:             return "km"
        case .bloodOxygen:          return "%"
        case .activeEnergy:         return "kcal"
        case .flights:              return "flights"
        case .sleep:                return "hr"
        default:                    return nil
        }
    }

    /// True when the sensor carries a numeric reading worth displaying.
    var isNumeric: Bool { unit != nil }

    /// Where a non-imported reading for this sensor genuinely comes from.
    var realSource: SensorSource {
        switch self {
        case .heartRate, .heartRateVariability, .steps, .distance,
             .bloodOxygen, .activeEnergy, .flights, .sleep:
            return .healthKit
        case .survey:
            return .checkIn
        default:
            return .recorder
        }
    }

    /// Render a raw number the way this sensor should read.
    func formatted(_ value: Double) -> String {
        guard let unit else { return "" }
        switch self {
        case .steps:
            let f = NumberFormatter()
            f.numberStyle = .decimal
            let n = f.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))"
            return "\(n) \(unit)"
        case .distance, .sleep:
            return String(format: "%.1f %@", value, unit)
        case .bloodOxygen:
            return "\(Int(value))\(unit)"          // no space before %
        default:
            return "\(Int(value)) \(unit)"
        }
    }
}

// MARK: - Model

nonisolated struct SensorReading {
    let date: Date
    let value: Double?
}

/// Where a displayed value came from. Drives the source line under every row.
nonisolated enum SensorSource {
    case healthKit
    case recorder
    case checkIn
    case imported(String)
    case sample

    var label: String {
        switch self {
        case .healthKit:          return "Apple Health"
        case .recorder:           return "this iPhone"
        case .checkIn:            return "your check-ins"
        case .imported(let name): return name
        case .sample:             return "sample data"
        }
    }
}

nonisolated struct SensorImportRecord: Identifiable {
    let id: Int64
    let kind: SensorKind
    let filename: String
    let rowCount: Int
    let importedAt: Date
    let dateMin: Date?
    let dateMax: Date?
    let isActive: Bool
}

/// The two lines a Sensors-tab row renders.
nonisolated struct SensorDisplay {
    let valueLine: String       // "Last recorded: 72 bpm · Jul 22 at 9:00 AM"
    let sourceLine: String?     // "from heartratedata.csv"
}

// MARK: - Store

nonisolated final class SensorDataStore: @unchecked Sendable {

    static let shared = SensorDataStore()

    private var db: OpaquePointer?
    /// Serializes every database access — imports run off the main thread.
    private let queue = DispatchQueue(label: "edu.uiuc.cs.hcesc.SensingApp.sensordatastore")

    private init() {
        open()
        createTables()
    }

    // MARK: Database lifecycle

    private var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent("sensor_data.sqlite")
    }

    private func open() {
        let url = databaseURL
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            print("❌ SensorDataStore: failed to open \(url.path)")
            db = nil
            return
        }
        // Health data at rest: unreadable until the user has unlocked once.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS sensor_imports (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                kind        TEXT    NOT NULL,
                filename    TEXT    NOT NULL,
                row_count   INTEGER NOT NULL DEFAULT 0,
                imported_at REAL    NOT NULL,
                date_min    REAL,
                date_max    REAL,
                active      INTEGER NOT NULL DEFAULT 0
            );
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS sensor_readings (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                kind      TEXT    NOT NULL,
                ts        REAL    NOT NULL,
                value     REAL,
                import_id INTEGER NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_sensor_readings ON sensor_readings(import_id, ts DESC);")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            print("❌ SensorDataStore exec failed: \(msg)")
            return false
        }
        return true
    }

    // MARK: - Import writing
    //
    // An import is built in three steps so a half-parsed file can never become
    // the visible series: begin (inactive) → append batches → finish (activate).

    /// Creates an inactive import row and returns its id.
    func beginImport(kind: SensorKind, filename: String) -> Int64? {
        queue.sync {
            guard let db else { return nil }
            let sql = "INSERT INTO sensor_imports (kind, filename, imported_at, active) VALUES (?, ?, ?, 0);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            _ = kind.rawValue.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQL.transient) }
            _ = filename.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQL.transient) }
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Appends a batch of readings inside one transaction. Called repeatedly by
    /// the streaming parser so a huge file never sits in memory.
    func appendBatch(_ readings: [SensorReading], kind: SensorKind, importID: Int64) {
        guard !readings.isEmpty else { return }
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            let sql = "INSERT INTO sensor_readings (kind, ts, value, import_id) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for r in readings {
                    _ = kind.rawValue.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQL.transient) }
                    sqlite3_bind_double(stmt, 2, r.date.timeIntervalSince1970)
                    if let v = r.value { sqlite3_bind_double(stmt, 3, v) } else { sqlite3_bind_null(stmt, 3) }
                    sqlite3_bind_int64(stmt, 4, importID)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    /// Makes the import the active series for its sensor, replacing whatever was
    /// active before. The previous import is KEPT (deactivated) so it can be
    /// restored and compared — that is what makes a silently-failed import visible.
    func finishImport(id: Int64, kind: SensorKind) {
        queue.sync {
            exec("""
                UPDATE sensor_imports SET
                    row_count = (SELECT COUNT(*) FROM sensor_readings WHERE import_id = \(id)),
                    date_min  = (SELECT MIN(ts)  FROM sensor_readings WHERE import_id = \(id)),
                    date_max  = (SELECT MAX(ts)  FROM sensor_readings WHERE import_id = \(id))
                WHERE id = \(id);
            """)
            exec("UPDATE sensor_imports SET active = 0 WHERE kind = '\(kind.rawValue)';")
            exec("UPDATE sensor_imports SET active = 1 WHERE id = \(id);")
        }
        pruneOldImports(kind: kind)
    }

    /// Discards a partially written import (parse failure / user cancel).
    func abortImport(id: Int64) {
        queue.sync {
            exec("DELETE FROM sensor_readings WHERE import_id = \(id);")
            exec("DELETE FROM sensor_imports  WHERE id = \(id);")
        }
    }

    /// Keeps only the most recent `keep` imports per sensor so repeated testing
    /// can't grow the database without bound.
    private func pruneOldImports(kind: SensorKind, keep: Int = 3) {
        queue.sync {
            exec("""
                DELETE FROM sensor_readings WHERE import_id IN (
                    SELECT id FROM sensor_imports
                    WHERE kind = '\(kind.rawValue)' AND active = 0
                    ORDER BY imported_at DESC LIMIT -1 OFFSET \(keep)
                );
            """)
            exec("""
                DELETE FROM sensor_imports
                WHERE kind = '\(kind.rawValue)' AND active = 0
                  AND id NOT IN (
                    SELECT id FROM sensor_imports
                    WHERE kind = '\(kind.rawValue)' AND active = 0
                    ORDER BY imported_at DESC LIMIT \(keep)
                  );
            """)
        }
    }

    // MARK: - Import management

    func activate(importID: Int64, kind: SensorKind) {
        queue.sync {
            exec("UPDATE sensor_imports SET active = 0 WHERE kind = '\(kind.rawValue)';")
            exec("UPDATE sensor_imports SET active = 1 WHERE id = \(importID);")
        }
    }

    func delete(importID: Int64) {
        queue.sync {
            exec("DELETE FROM sensor_readings WHERE import_id = \(importID);")
            exec("DELETE FROM sensor_imports  WHERE id = \(importID);")
        }
    }

    /// Drops every imported series; the app falls straight back to live data.
    func clearAllImports() {
        queue.sync {
            exec("DELETE FROM sensor_readings;")
            exec("DELETE FROM sensor_imports;")
        }
    }

    // MARK: - Reading

    private func fetchImports(where clause: String) -> [SensorImportRecord] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT id, kind, filename, row_count, imported_at, date_min, date_max, active
                FROM sensor_imports \(clause);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var out: [SensorImportRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let kindText = sqlite3_column_text(stmt, 1),
                      let kind = SensorKind(rawValue: String(cString: kindText)),
                      let nameText = sqlite3_column_text(stmt, 2) else { continue }
                out.append(SensorImportRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    kind: kind,
                    filename: String(cString: nameText),
                    rowCount: Int(sqlite3_column_int(stmt, 3)),
                    importedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    dateMin: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    dateMax: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                    isActive: sqlite3_column_int(stmt, 7) == 1
                ))
            }
            return out
        }
    }

    /// One entry per sensor currently showing imported data.
    func activeImports() -> [SensorImportRecord] {
        fetchImports(where: "WHERE active = 1 ORDER BY imported_at DESC")
    }

    /// Full audit trail, newest first — the staleness check.
    func importLog(limit: Int = 40) -> [SensorImportRecord] {
        fetchImports(where: "ORDER BY imported_at DESC LIMIT \(limit)")
    }

    func previousImports(for kind: SensorKind) -> [SensorImportRecord] {
        fetchImports(where: "WHERE kind = '\(kind.rawValue)' AND active = 0 ORDER BY imported_at DESC")
    }

    var hasImports: Bool { !activeImports().isEmpty }

    /// Newest reading of the active imported series, with its filename.
    func latestImported(for kind: SensorKind) -> (reading: SensorReading, filename: String)? {
        queue.sync {
            guard let db else { return nil }
            let sql = """
                SELECT r.ts, r.value, i.filename
                FROM sensor_readings r
                JOIN sensor_imports i ON i.id = r.import_id
                WHERE i.active = 1 AND i.kind = ?
                ORDER BY r.ts DESC LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            _ = kind.rawValue.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQL.transient) }

            guard sqlite3_step(stmt) == SQLITE_ROW, let nameText = sqlite3_column_text(stmt, 2) else { return nil }
            let reading = SensorReading(
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                value: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
            )
            return (reading, String(cString: nameText))
        }
    }

    /// Streams an import's readings oldest-first without loading them all at once.
    /// Used to write the CSV for "Send to database".
    func forEachReading(importID: Int64, _ body: (SensorReading) -> Void) {
        queue.sync {
            guard let db else { return }
            let sql = "SELECT ts, value FROM sensor_readings WHERE import_id = ? ORDER BY ts ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, importID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                body(SensorReading(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    value: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
                ))
            }
        }
    }

    // MARK: - Display (the precedence rule)

    /// Latest reading for a sensor from whichever source wins, plus that source.
    func resolved(for kind: SensorKind) -> (reading: SensorReading, source: SensorSource)? {
        if let (reading, filename) = latestImported(for: kind) {
            return (reading, .imported(filename))
        }
        guard let entry = SensorStatusStore.shared.entry(for: kind) else { return nil }
        let value = entry.value.flatMap(Self.numericValue(from:))
        return (SensorReading(date: entry.date, value: value),
                entry.isSample ? .sample : kind.realSource)
    }

    /// The two lines a Sensors-tab row shows.
    func display(for kind: SensorKind) -> SensorDisplay {
        guard let (reading, source) = resolved(for: kind) else {
            return SensorDisplay(valueLine: "No data recorded yet", sourceLine: nil)
        }
        let when = Self.timestampFormatter.string(from: reading.date)
        let valueLine: String
        if kind.isNumeric, let v = reading.value {
            valueLine = "Last recorded: \(kind.formatted(v)) · \(when)"
        } else {
            valueLine = "Last recorded: \(when)"
        }
        return SensorDisplay(valueLine: valueLine, sourceLine: "from \(source.label)")
    }

    /// Value + caption for a Home stat tile. The caption appears only when the
    /// reading is noteworthy — imported, or simply not from today — so live
    /// same-day HealthKit data keeps the clean, caption-free look and a stale
    /// import is impossible to mistake for a fresh one.
    ///
    /// The hardcoded sample table is deliberately NOT surfaced here. Unlike the
    /// Sensors tab, Home is not behind #if DEBUG — it ships. A patient whose
    /// HealthKit simply has no data must see "—", not "99,999 steps" with a
    /// small caption. Home therefore shows real or imported readings only.
    func homeTile(for kind: SensorKind) -> (value: Double, caption: String?)? {
        guard let (reading, source) = resolved(for: kind), let value = reading.value else { return nil }
        if case .sample = source { return nil }

        let isToday = Calendar.current.isDateInToday(reading.date)
        var caption: String?
        switch source {
        case .imported(let name):
            caption = isToday ? shortName(name) : "\(shortName(name)) · \(Self.shortDayFormatter.string(from: reading.date))"
        case .healthKit, .recorder, .checkIn:
            caption = isToday ? nil : Self.shortDayFormatter.string(from: reading.date)
        case .sample:
            caption = nil   // unreachable, filtered above
        }
        return (value, caption)
    }

    /// Tiles are narrow — keep the filename readable rather than complete.
    private func shortName(_ filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.count > 14 ? String(stem.prefix(13)) + "…" : stem
    }

    /// Pulls the number back out of a SensorStatusStore display string
    /// ("72 bpm" → 72, "8,420 steps" → 8420) so Home tiles can use real stamps.
    nonisolated private static func numericValue(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        var digits = ""
        for ch in cleaned {
            if ch.isNumber || ch == "." { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        return Double(digits)
    }

    // "Today at 3:45 PM", "Yesterday at 9:12 PM", "Jul 12, 2026 at 3:45 PM"
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    // "Jul 22" — compact enough for a stat tile caption.
    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
