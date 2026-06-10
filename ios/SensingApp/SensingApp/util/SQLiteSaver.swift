
//
//  PreallocatedCSVBuffer.swift
//  SensingTrialApp
//
//  Created by Mashfiqui Rabbi on 03/31/26.
//

// This file is Singleton for every one to save data.

import Foundation
import SQLite3

enum DataType: Int {
    case dummy = -1
    case accelerometer = 0
    case gyroscope     = 1
    case heartRate     = 2
    // extend as needed
}

struct SensorSample {
    var timestamp: Double
    var dataType:  DataType
    var blob:      [UInt8]
}

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
    private var flushAfterThisCount: Int = 10000
    private let maxFileSizeMB: Double = 5  // 👈 change this threshold
    private let accessQueue = DispatchQueue(label: "com.sensingapp.sqlitesaver")
    
    
    private let buffer: CircularBufferSQLite

    // semaphoreEmpty — how many slots are free to write into
    // semaphoreFull  — how many slots are ready to be consumed
    private let semaphoreEmpty: DispatchSemaphore
    private let semaphoreFull:  DispatchSemaphore
    
    func configure(capacity: Int, flushAfterThisCount: Int) {
        self.capacity    = capacity
        self.flushAfterThisCount = flushAfterThisCount
    }
    
    init() {

        //if last file doesn't exist, then add a new file
        let filename = UserDefaults.standard.string(forKey: "dbFileName") ?? "sqlite_\(SQLiteSaver.currentTimestampString()).db"
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.databaseURL = docsURL.appendingPathComponent("to-be-processed").appendingPathComponent(filename)
        
        self.buffer         = CircularBufferSQLite(capacity: self.capacity)
        
        // semaphoreEmpty — how many slots are free to write into
        // semaphoreFull  — how many slots are ready to be consumed
        
        // "semaphoreEmpty": non-zero means there is some slots empty in the queue,
        //                   so producers can add to queue. Else, block
        // "semaphoreFull": non-zero means there is some slots full in the queue,
        //                   so consumer can take from the queue. Else, block
        self.semaphoreEmpty = DispatchSemaphore(value: self.capacity) // all slots free
        self.semaphoreFull  = DispatchSemaphore(value: 0)        // nothing to consume yet
        
        //  if !fileManager.fileExists(atPath: self.databaseURL.path){
        //       createNewDatabaseFile()
        //  }
        
        //store filename to default
        UserDefaults.standard.set(filename, forKey: "dbFileName")
        
        
        //We are opening file at the beginning
        //creating all the tables if they do not exist
        open()
        //defined in an extension
        createTables()
        //
        close()
        
        //start Consumer
        startConsumer()
    }
    
    private func createNewDatabaseFile() {
        let filename = "sqlite_\(SQLiteSaver.currentTimestampString()).db"
        let fileManager = FileManager.default
        let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.databaseURL =  docsURL.appendingPathComponent("to-be-processed").appendingPathComponent(filename)

        //--
        UserDefaults.standard.set(filename, forKey: "dbFileName")
        
        print("DB: New file created at: \(filename)")
        
        open()
        createTables()
        //close() -- Not closing as this files will be use
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
        guard let db else { return } //means database is already closed.
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

    /// Add one row — thread-safe via serial queue
    func addRow(timestamp: Double, dataType: DataType, blob: [UInt8], counter:Int = 0) {
        //sync or async
        //--- sync is here to wait
        //--- async will not wait
        //------- sync is needed if we close the database in one call
        //------- and trying to write it in another call
        //------- Note that we will call addrow in a loop.
        //------- The order insertion can be different from the order of call
        //------- "queue.sync" will ensure that from different threads, we will be protected
        //
        
        //Problem here is to keep the database open or close
        //
        accessQueue.sync {
            
            // Wait decreases semaphoreEmpty by 1.
            // semaphoreEmpty's initial value is circular buffer capacity
            // if semaphoreEmpty values is zero, the wait will lock
            // block if buffer is full — waits for consumer to free a slot
            semaphoreEmpty.wait()
            
            //figure out how add three values
            _ = buffer.enqueue(timestamp: timestamp, dataType: dataType, blob: blob)
            
            //Debug
            print("Producer: Queuing data #\(counter)")
            
            //signal will increase semaphoreFull
            //so any wait will be unlocked.-1
            semaphoreFull.signal()      // tell consumer a new sample is ready
        }
    }
    
    
    private func startConsumer() {
        let thread = Thread {  [weak self] in
            guard let self else { return }
            while true {
  
                //block until a sample is available
                //This will block until there is some data
                //This unblocked by producer (i.e., 'addRow')
                //
                //Waits until the queue has something in it)
                self.semaphoreFull.wait()
                
                let sample = self.accessQueue.sync {
                    self.buffer.dequeue()
                }
                
                
                
                if let sample {
                    
                    //Debug
                    print("Consumer: DeQueuing data")
                    
                    if db == nil {
                        //means database is not open.
                        open()
                    }

                    insertData(timestamp: sample.timestamp, dataType: sample.dataType, blob: sample.blob)
                    index += 1
                    
                    // auto flush when full
                    if index == flushAfterThisCount {
                        flushDataToDb()
                    }
                    
                    //signals is not full anymore
                    self.semaphoreEmpty.signal()
                }
            }
        }
        thread.name = "com.sensingapp.consumer"
        thread.qualityOfService = .utility
        thread.start()
    }
    
    /// Returns file size in MB, or 0 if the file doesn't exist yet.
    private func fileSizeMB(at url: URL) -> Double {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(bytes) / (1024 * 1024)
    }
    
    public func flushDataToDb(forceNewFile: Bool = false){
        print("DB: Flushing data to db (count: \(index))")
        flush()
        index = 0 //means no data to flush yet.
        
        // If the filesize is larger than "maxFileSizeMB", we create new file.
        if fileSizeMB(at: self.databaseURL) > maxFileSizeMB ||
            forceNewFile == true {
            
            if forceNewFile == false{
                print("DB: Starting a new file. Current \(self.databaseURL.lastPathComponent)  file size is too big: \(fileSizeMB(at: self.databaseURL))")
            }
            else{
                print("DB: Current file is \(self.databaseURL.lastPathComponent)  \(fileSizeMB(at: self.databaseURL)). Force creating a new file.")
            }
            
            close()
            createNewDatabaseFile()  // already calls open() + createTables() internally
        }
    }

    
    static func currentTimestampString() -> String {
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



final class CircularBufferSQLite {
    private var buffer: [SensorSample]
    private var readIndex  = 0
    private var writeIndex = 0
    private var count      = 0
    let capacity: Int
    
    //Todo: pre-allocate the buffer for bytes
 
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer   = Array(repeating: SensorSample(timestamp: -1, dataType: .dummy, blob: [UInt8]()), count: capacity)
    }
 
    var isEmpty: Bool { count == 0 }
    var isFull:  Bool { count == capacity }
 
    func enqueue(timestamp: Double, dataType: DataType, blob: [UInt8]) -> Bool {
        guard !isFull else { return false }
        buffer[writeIndex].timestamp = timestamp
        buffer[writeIndex].dataType = dataType
        buffer[writeIndex].blob = blob
        writeIndex = (writeIndex + 1) % capacity
        count += 1
        return true
    }
 
    func dequeue() -> SensorSample? {
        guard !isEmpty else { return nil }
        let sample = buffer[readIndex]
        //buffer[readIndex].timestamp = -1 //means free to enqueue, otherwise
        readIndex = (readIndex + 1) % capacity
        count -= 1
        return sample
    }
}
