//
//  SQLiteSaver+Surveys.swift
//  SensingApp
//
//  Created by Samir Kurudi on 4/27/26.
//

//
//  SQLiteSaver+Surveys.swift
//  SensingApp
//
//  Adds a local surveys table so MonthlyProgressView can
//  display completion history without hitting the server.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_S = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteSaver {

    // MARK: - Table creation (call this inside createTables())
    // Add `createSurveysTable()` to your existing createTables() func in SQLiteSaver+Tables.swift

    func createSurveysTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS surveys (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp_unix  REAL    NOT NULL,
                date_string     TEXT    NOT NULL,
                pain_score      INTEGER,
                completed       INTEGER NOT NULL DEFAULT 1
            );
        """
        if exec(sql) {
            print("✅ Table ready: surveys")
        }
    }

    // MARK: - Insert

    @discardableResult
    func insertSurvey(painScore: Int?) -> Bool {
        guard let db else {
            print("❌ insertSurvey: no database connection")
            return false
        }

        let now = Date()
        let unix = now.timeIntervalSince1970
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: now)

        let sql = "INSERT INTO surveys (timestamp_unix, date_string, pain_score, completed) VALUES (?, ?, ?, 1);"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ insertSurvey prepare failed: \(lastError())")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, unix)
        dateStr.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT_S) }
        if let score = painScore {
            sqlite3_bind_int(stmt, 3, Int32(score))
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("❌ insertSurvey step failed: \(lastError())")
            return false
        }
        return true
    }

    // MARK: - Restore insert (profile sync)
    //
    // Insert a survey record for a PAST day — used by ProfileStore when
    // hydrating history downloaded from the study server onto a new device.
    // timestamp_unix is set to noon local time of the given day so month
    // range queries bucket it correctly.

    @discardableResult
    func insertSurvey(dateString: String, painScore: Int?, completed: Bool = true) -> Bool {
        guard let db else {
            print("❌ insertSurvey(dateString:): no database connection")
            return false
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: dateString) else {
            print("❌ insertSurvey(dateString:): bad date \(dateString)")
            return false
        }
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day

        let sql = "INSERT INTO surveys (timestamp_unix, date_string, pain_score, completed) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ insertSurvey(dateString:) prepare failed: \(lastError())")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, noon.timeIntervalSince1970)
        dateString.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT_S) }
        if let score = painScore {
            sqlite3_bind_int(stmt, 3, Int32(score))
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int(stmt, 4, completed ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            print("❌ insertSurvey(dateString:) step failed: \(lastError())")
            return false
        }
        return true
    }

    /// True when a survey row already exists for the given "yyyy-MM-dd" day.
    /// Keeps profile-restore hydration idempotent.
    func surveyExists(dateString: String) -> Bool {
        guard let db else { return false }

        let sql = "SELECT 1 FROM surveys WHERE date_string = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ surveyExists prepare failed: \(lastError())")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        dateString.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT_S) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Fetch for a given month

    struct SurveyRecord {
        let dateString: String   // "yyyy-MM-dd"
        let painScore: Int?
        let completed: Bool
    }

    func fetchSurveys(forMonth monthStart: Date) -> [SurveyRecord] {
        guard let db else { return [] }

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: monthStart)
        guard let start = cal.date(from: comps),
              let end   = cal.date(byAdding: .month, value: 1, to: start)
        else { return [] }

        let startUnix = start.timeIntervalSince1970
        let endUnix   = end.timeIntervalSince1970

        let sql = """
            SELECT date_string, pain_score, completed
            FROM surveys
            WHERE timestamp_unix >= ? AND timestamp_unix < ?
            ORDER BY timestamp_unix ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ fetchSurveys prepare failed: \(lastError())")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, startUnix)
        sqlite3_bind_double(stmt, 2, endUnix)

        var results: [SurveyRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dateStr   = String(cString: sqlite3_column_text(stmt, 0))
            let painScore = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                                ? nil
                                : Int(sqlite3_column_int(stmt, 1))
            let completed = sqlite3_column_int(stmt, 2) == 1
            results.append(SurveyRecord(dateString: dateStr, painScore: painScore, completed: completed))
        }
        return results
    }
}
