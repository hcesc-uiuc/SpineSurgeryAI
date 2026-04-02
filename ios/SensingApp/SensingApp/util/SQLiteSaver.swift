
//
//  PreallocatedCSVBuffer.swift
//  SensingTrialApp
//
//  Created by Mashfiqui Rabbi on 03/31/26.
//

// This file is Singleton for every one to save data.

import Foundation
import SQLite3

final class SQLiteSaver {
    //    private var buffer: [String]
    //    private var index = 0
    //    private let capacity: Int
    //    private let fileURL: URL
    //    private var fileHandle: FileHandle?
    
    //
    static let shared = SQLiteSaver()
    private var databaseURL: URL = URL(fileURLWithPath: "")
    private(set) var db: OpaquePointer?
    private var index = 0
    private var capacity: Int = 10000
    private let maxFileSizeMB: Double = 5  // 👈 change this threshold
    
    enum DataType: Int {
        case accelerometer = 0
        case gyroscope     = 1
        case heartRate     = 2
        // extend as needed
    }
    
    struct DataBatch {
        let timestamp: Double
        let dataType:  DataType
        let blob:      Data
    }
    
    

    init(capacity: Int = 10_000) {

        //if last file doesn't exist, then add a new file
        let filename = UserDefaults.standard.string(forKey: "dbFileName") ?? "sqlite_\(currentTimestampString()).db"
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.databaseURL = docsURL.appendingPathComponent("to-be-processed").appendingPathComponent(filename)
        self.capacity = capacity
        
        if !fileManager.fileExists(atPath: self.databaseURL.path){
            createNewDatabaseFile()
        }
        
        //store filename to default
        UserDefaults.standard.set(filename, forKey: "dbFileName")
        
        open()
        //defined in an extension
        createTables()
    }
    
    private func createNewDatabaseFile() {
        let filename = "sqlite_\(currentTimestampString()).db"
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.databaseURL =  docsURL.appendingPathComponent("to-be-processed").appendingPathComponent(filename)
        
        //--
        UserDefaults.standard.set(filename, forKey: "dbFileName")
        
        open()
        createTables()
    }
    
    
    func open() {
        let path = self.databaseURL.path

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            print("❌ Failed to open DB at \(path): \(msg)")
            db = nil
            return
        }

        // Performance pragmas
        //        sqlite3_exec(db, "PRAGMA journal_mode = WAL;",  nil, nil, nil)
        //        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        //        sqlite3_exec(db, "PRAGMA foreign_keys = ON;",   nil, nil, nil)

        print("✅ Database opened at: \(path)")
    }
    
    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
        print("🔒 Database closed")
        
        //deleteWALFiles()  // then safe to delete
    }
    
    // MARK: - Helpers
    
    
    func deleteWALFiles() {
        let shmURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + "-shm")
        let walURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + "-wal")
        print(shmURL)
        print(walURL)

        for url in [shmURL, walURL] {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    print("🗑️ Deleted: \(url.lastPathComponent)")
                }
            } catch {
                print("❌ Failed to delete \(url.lastPathComponent): \(error)")
            }
        }
    }

    func lastError() -> String {
        guard let db else { return "No database connection" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// Add one row — overwrites oldest if full
    func addRow(timestamp: Double, dataType: DataType, blob: Data) {
        insertData(timestamp: timestamp, dataType: dataType, blob: blob)
        index += 1
        
        // auto flush when full
        if index == capacity {
            flush()
        }
        
        // If the filesize is larger than "maxFileSizeMB", we create new file.
        if fileSizeMB(at: self.databaseURL) > maxFileSizeMB {
            close()
            
            createNewDatabaseFile()
            
            
            open()
            createTables()
        }
    }
    
/// Returns file size in MB, or 0 if the file doesn't exist yet.
    private func fileSizeMB(at url: URL) -> Double {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(bytes) / (1024 * 1024)
    }

    
    func currentTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = TimeZone.current
        //formatter.timeZone = TimeZone(abbreviation: "UTC")
        return formatter.string(from: Date())
    }
    
    @discardableResult
    func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var errorMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMsg) == SQLITE_OK else {
            let msg = errorMsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMsg)
            print("❌ exec failed: \(msg)\nSQL: \(sql)")
            return false
        }
        return true
    }
}
