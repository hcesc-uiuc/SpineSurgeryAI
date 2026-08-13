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
            print("Table ready: data_batches")
        }
    }
    
    // MARK: - Insert (single row)

    @discardableResult
    func insertData(timestamp: Double, dataType: DataType, blob: [UInt8]) -> Bool {
        
        // We already check for open
        //        guard let db else {
        //            print("insertData: no database connection")
        //            return false
        //        }

        //        let sql = "INSERT INTO data (timestamp, data_type, blob) VALUES (?, ?, ?);"
        //        var stmt: OpaquePointer?
        //
        //        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        //            print("insertData prepare failed: \(lastError())")
        //            return false
        //        }

        // Move to open
        // defer { sqlite3_finalize(stmt) }
        
        /*
         sqlite3_step: Executes the prepared statement one time. For an INSERT it writes the row
         to the WAL file and returns SQLITE_DONE. Think of it as "pull the trigger" — the statement
         actually runs here.

         sqlite3_reset: Rewinds the statement back to before step was called. It does not touch the
         database at all — it just moves the internal cursor back to the start so you can bind new
         values and step again. Nothing is undone, the row that was just inserted stays inserted.

         COMMIT: Flushes all the accumulated inserts from the WAL into the main database file and
         makes them permanent. Until you commit, all the step calls are held in a temporary
         transaction — fast to write but not yet durable. This is why batching inserts inside one
         transaction is so much faster; you pay the disk sync cost once instead of once per row.

         sqlite3_finalize: Destroys the compiled statement and frees its memory. The SQL parsing and
         compilation work done by prepare_v2 is thrown away. After this the statement pointer is invalid.
         */

        sqlite3_bind_double(insertStmt, 1, timestamp)
        sqlite3_bind_int(insertStmt,    2, Int32(dataType.rawValue))
        // [UInt8] is already 1 byte per element; withUnsafeBytes gives a
        // contiguous raw pointer valid only inside the closure — SQLite copies
        // the bytes immediately via SQLITE_TRANSIENT so this is safe.
        blob.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress, !blob.isEmpty else {
                sqlite3_bind_null(insertStmt, 3)
                return
            }
            sqlite3_bind_blob(insertStmt, 3, base, Int32(blob.count), SQLITE_TRANSIENT)
        }
        
        let stepResult = sqlite3_step(insertStmt) //Value written
        sqlite3_reset(insertStmt)   // just reset the insert string to input new values
        //        guard stepResult == SQLITE_DONE else {
        //            print("insertData step failed: \(lastError())")
        //            sqlite3_finalize(stmt)
        //            return false
        //        }

        return true
    }
    
    // MARK: - Flush (batch insert)
    /// Wraps multiple inserts in a single transaction for performance.
    /// Automatically called when buffer reaches `bufferLimit`.
    @discardableResult
    func flush(){
        // exec("COMMIT;")
        sqlite3_exec(db, "COMMIT", nil, nil, nil)  // matches the BEGIN earlier
        let rc = sqlite3_exec(db, "BEGIN", nil, nil, nil)
        if rc != SQLITE_OK {
            print("BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    // MARK: - sessions


}
