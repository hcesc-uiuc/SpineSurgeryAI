//
//  SQLiteSaver+Tables.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 3/31/26.
//
import Foundation
import SQLite3

// SQLITE_TRANSIENT is not exposed in Swift — define it manually
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension SQLiteSaver {

    // MARK: - Table Creation Entry Point
    
    

    func createTables() {
        createDataTables()
        createSurveysTable()   // ← add this
    }

    // MARK: - create data table
    private func createDataTables() {
        let sql = """
            CREATE TABLE IF NOT EXISTS data (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp    REAL NOT NULL,
                data_type    INTEGER NOT NULL,
                blob         BLOB    NOT NULL
            );
        """
        if exec(sql) {
            print("✅ Table ready: data_batches")
        }
    }
    
    // MARK: - Insert (single row)

    @discardableResult
    func insertData(timestamp: Double, dataType: DataType, blob: [UInt8]) -> Bool {
        guard let db else {
            print("❌ insertData: no database connection")
            return false
        }

        let sql = "INSERT INTO data (timestamp, data_type, blob) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("❌ insertData prepare failed: \(lastError())")
            return false
        }

        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, timestamp)
        sqlite3_bind_int(stmt,    2, Int32(dataType.rawValue))
        // [UInt8] is already 1 byte per element; withUnsafeBytes gives a
        // contiguous raw pointer valid only inside the closure — SQLite copies
        // the bytes immediately via SQLITE_TRANSIENT so this is safe.
        blob.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress, !blob.isEmpty else {
                sqlite3_bind_null(stmt, 3)
                return
            }
            sqlite3_bind_blob(stmt, 3, base, Int32(blob.count), SQLITE_TRANSIENT)
        }
        
        let stepResult = sqlite3_step(stmt)
        guard stepResult == SQLITE_DONE else {
            print("❌ insertData step failed: \(lastError())")
            sqlite3_finalize(stmt)
            return false
        }

        return true
    }
    
    // MARK: - Flush (batch insert)
    /// Wraps multiple inserts in a single transaction for performance.
    /// Automatically called when buffer reaches `bufferLimit`.
    @discardableResult
    func flush(){
        exec("COMMIT;")
    }

    // MARK: - sessions


}
