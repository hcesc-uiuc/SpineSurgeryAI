
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
    var counter: Int
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
    /*
     private(set): anyone can read db, only this type can write it.
     External code can do `pipeline.db` but not `pipeline.db = something`.

     OpaquePointer: Swift's wrapper for a C pointer to an unknown type.
     SQLite is a C library — its sqlite3* handle points to an internal
     struct Swift has no definition for. Rather than importing it as a
     real type, Swift holds the address as OpaquePointer ("I have a
     pointer, I don't know what's inside"). You pass it to C functions
     like sqlite3_exec(db, ...) and they know what to do with it.

     ?: Optional — the handle is nil before sqlite3_open succeeds.
     If opening fails you hold nil instead of a garbage pointer.
     Forces the rest of the code to check non-nil before using it.
     */
    private(set) var db: OpaquePointer?
    /*
     OpaquePointer?: holds the compiled SQL statement handle returned
     by sqlite3_prepare_v2. Like db, it's a C pointer to an internal
     SQLite struct Swift can't see into — so OpaquePointer again.

     nil until sqlite3_prepare_v2 runs successfully. Once prepared,
     you reuse this same compiled statement on every insert by calling
     sqlite3_reset(insertStmt) instead of re-preparing each time.

     Must be finalized with sqlite3_finalize(insertStmt) in deinit
     to avoid a memory leak — SQLite holds resources for it until
     you explicitly release it.
     */
    var insertStmt: OpaquePointer?
    private var index = 0
    //100Hz will fill for 3600 seconds=60 minutes of data. 100*3600 = 360,000
    //We sometimes have to write hours of cached data.
    private var capacity: Int = 120000
    private var flushAfterThisCount: Int = 120000
    private let maxFileSizeMB: Double = 5  // change this threshold
    private let accessQueue = DispatchQueue(label: "com.sensingapp.sqlitesaver")
    
    
    private let buffer: CircularBufferSQLite

    // semaphoreEmpty — how many slots are free to write into
    // semaphoreFull  — how many slots are ready to be consumed
    private let semaphoreEmpty: DispatchSemaphore
    private let semaphoreFull:  DispatchSemaphore
    private var semaphoreEmptyCount: Int
    private var semaphoreFullCount: Int
    
    func configure(capacity: Int, flushAfterThisCount: Int) {
        //self.capacity    = capacity
        //self.flushAfterThisCount = flushAfterThisCount
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
        self.semaphoreEmptyCount = self.capacity
        self.semaphoreFullCount = 0
        
        //  if !fileManager.fileExists(atPath: self.databaseURL.path){
        //       createNewDatabaseFile()
        //  }
        
        //store filename to default
        UserDefaults.standard.set(filename, forKey: "dbFileName")
        
        
        //We are opening file at the beginning
        //creating all the tables if they do not exist
        open()
        //defined in an extension. Only created tables it does not exist
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
        prepareInsertStatement()
        //close() -- Not closing as this files will be use
    }
    
    
    func open() {
        let path = self.databaseURL.path
        
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            print("Failed to open DB at \(path): \(msg)")
            db = nil
            return
        }

        // Performance pragmas
        
        // You are already using WAL mode (PRAGMA journal_mode = WAL).
        // In WAL mode every sqlite3_step() that completes successfully is
        // already durable on disk — the data is in the WAL file (.wal) and
        // will be recovered automatically on the next open even if the app
        // crashes immediately after.
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;",  nil, nil, nil)
        // With synchronous = NORMAL SQLite syncs at the most critical moments
        // — enough to survive a crash, though not a power loss mid-write.
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;",   nil, nil, nil)
        
        
        /*
         defer runs its block when the enclosing scope exits — whether
         that's a normal return, an early return, or a thrown error.

         sqlite3_finalize releases the memory SQLite allocated for the
         compiled statement. Without it, every call that prepares a
         statement leaks resources.

         Placing it immediately after sqlite3_prepare_v2 succeeds means
         you can never forget to clean up — no matter how many early
         returns or error paths follow, finalize is guaranteed to run.
         */
        // defer { sqlite3_finalize(insertStmt) }
        
        print("Database opened at: \(path)")
    }
    
    func prepareInsertStatement(){
        let sql = "INSERT INTO data (timestamp, data_type, blob) VALUES (?, ?, ?);"
        sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil)
        
        let rc = sqlite3_exec(db, "BEGIN", nil, nil, nil)
        if rc != SQLITE_OK {
            print("BEGIN failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    func close() {
        guard let db else { return } //means database is already closed.
        
        // sqlite3_close does two things:
        //
        // 1. Flushes any pending in-memory state to the WAL file
        // 2. Releases the file lock so other processes can access the db
        //
        // It does not move data from disk to some safer place — the data is
        // already on disk after each successful sqlite3_step.
        //
        sqlite3_finalize(insertStmt)
        sqlite3_close(db)
        self.db = nil
        print("Database closed")
        
        deleteWALFiles()  // then safe to delete
    }
    
    // MARK: - Helpers
    
    
    func deleteWALFiles() {
        let shmURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + "-shm")
        let walURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + "-wal")
        // print(shmURL)
        // print(walURL)

        for url in [shmURL, walURL] {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    print("Deleted: \(url.lastPathComponent)")
                }
            } catch {
                print("Failed to delete \(url.lastPathComponent): \(error)")
            }
        }
        
        //Todo: We should delete any remaining WAL files?
        //  Think, we should open all the related SQL files to make sure
        //  The WAL's are merged?
    }

    func lastError() -> String {
        guard let db else { return "No database connection" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// Add one row — thread-safe via serial queue
    func addRow(timestamp: Double, dataType: DataType, blob: [UInt8], counter:Int = 0) {
        // Wait OUTSIDE the serial queue to avoid priority inversion.
        // If semaphoreEmpty.wait() were inside accessQueue.sync, a high-QoS
        // caller would hold the queue lock while blocking on the utility-QoS
        // consumer to signal — that is a priority inversion.
        // By waiting first, we only enter the queue once a slot is guaranteed free.
        
        semaphoreEmpty.wait()
        semaphoreEmptyCount = max(0, semaphoreEmptyCount - 1)
        
        accessQueue.sync {
            _ = buffer.enqueue(timestamp: timestamp, dataType: dataType, blob: blob, counter: counter)
            print("Producer: Queuing data #\(counter)")
        }
        
        semaphoreFullCount = min(capacity, semaphoreFullCount + 1)
        semaphoreFull.signal()
        
        // "semaphoreEmpty": non-zero means there is some slots empty in the queue,
        //                   so producers can add to queue. Else, block.
        //                   wait decreases value, signal increase values
        // "semaphoreFull": non-zero means there is some slots full in the queue,
        //                   so consumer can take from the queue. Else, block
        
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
                
                //note everytime a new producer
                //call happened, semaphoreFull incremented.
                //We will inititally wait if queue is empty
                self.semaphoreFull.wait()
                semaphoreFullCount = max(0, semaphoreFullCount - 1)
                
                
                let sample = self.accessQueue.sync {
                    self.buffer.dequeue()
                }
                
                // sample will be nil if buffer is empty
                // (See code below)
                if let sample {
                    
                    if db == nil {
                        //means database is not open.
                        open()
                        prepareInsertStatement()
                    }
                    
                    //Debug
                    print("Consumer: DeQueuing data #\(sample.counter), index \(index)")
                    insertData(timestamp: sample.timestamp, dataType: sample.dataType, blob: sample.blob)
                    index += 1
                    
                    // auto flush when full
                    if index == flushAfterThisCount {
                        flushDataToDb()
                    }
                    
                }
                
                semaphoreEmptyCount = min(capacity, semaphoreEmptyCount + 1)
                self.semaphoreEmpty.signal()
                
                /*
                //we are clearing out the buffer entirely.
                //Otherwise, it becomes slow when buffer is full
                //One sample is consumed, one is filled producers.
                //There is a lot lock unlock happening at the same
                //time.
                var sampleReadFromQueue = 0
                
                while self.buffer.isEmpty == false {
                    
                    let sample = self.accessQueue.sync {
                        self.buffer.dequeue()
                    }
                    
                    // sample will be nil if buffer is empty
                    // (See code below)
                    if let sample {
                        
                        if db == nil {
                            //means database is not open.
                            open()
                        }
                        
                        //Debug
                        print("Consumer: DeQueuing data #\(sample.counter)")
                        insertData(timestamp: sample.timestamp, dataType: sample.dataType, blob: sample.blob)
                        index += 1
                        
                        // auto flush when full
                        if index == flushAfterThisCount {
                            flushDataToDb()
                        }
                        
                    }
                    
                    sampleReadFromQueue = sampleReadFromQueue + 1
                }
                
                
                
                //signals is not full anymore
                for _ in 0..<sampleReadFromQueue {
                    // if i < sampleReadFromQueue - 1{
                    //
                    // }
                    if semaphoreFullCount > 0 {
                        //This is because when zero, it will the outer wait will stop
                        //This consumer.
                        self.semaphoreFull.wait()
                        semaphoreFullCount = max(0, semaphoreFullCount - 1)
                    }

                    //calling it the number of time we got a sample.
                    semaphoreEmptyCount = min(capacity, semaphoreEmptyCount + 1)
                    self.semaphoreEmpty.signal()
                }
                 print("sampleReadFromQueue: \(sampleReadFromQueue)")
                */
                /*
                print("bufferElementCount: \(buffer.count)")
                print("semaphoreFullCount: \(semaphoreFullCount)")
                print("semaphoreEmptyCount: \(semaphoreEmptyCount)")
                print("Capacity: \(capacity)" )
                 */
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
        print("File size \(fileSizeMB(at: self.databaseURL)), \(self.databaseURL.lastPathComponent)")
        if fileSizeMB(at: self.databaseURL) > maxFileSizeMB ||
            forceNewFile == true {
            
            if forceNewFile == false{
                print("DB: Starting a new file. Current \(self.databaseURL.lastPathComponent)  file size is too big: \(fileSizeMB(at: self.databaseURL))")
            }
            else{
                print("DB: Current file is \(self.databaseURL.lastPathComponent)  \(fileSizeMB(at: self.databaseURL)) MB. Force creating a new file.")
            }
            
            close()
            createNewDatabaseFile()  // already calls open() + createTables() + insertPreage internally
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
            print("exec failed: \(msg)\nSQL: \(sql)")
            return false
        }
        return true
    }
}



final class CircularBufferSQLite {
    private var buffer: [SensorSample]
    private var readIndex  = 0
    private var writeIndex = 0
    public var count      = 0
    let capacity: Int
    
    //Todo: pre-allocate the buffer for bytes
 
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer   = Array(repeating: SensorSample(timestamp: -1, dataType: .dummy, blob: [UInt8](), counter: 0), count: capacity)
    }
 
    var isEmpty: Bool { count == 0 }
    var isFull:  Bool { count == capacity }
 
    func enqueue(timestamp: Double, dataType: DataType, blob: [UInt8], counter: Int) -> Bool {
        guard !isFull else { return false }
        buffer[writeIndex].timestamp = timestamp
        buffer[writeIndex].dataType = dataType
        buffer[writeIndex].blob = blob
        buffer[writeIndex].counter = counter
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
