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
    func insertData(timestamp: Double, dataType: DataType, blob: Data) -> Bool {
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
        blob.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 3,
                              ptr.baseAddress,
                              Int32(blob.count),
                              SQLITE_TRANSIENT)
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
