

//
//  Untitled.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 5/15/26.
//


/*
 SensorKit Accelerometer — The Critical Reality
 
 Before any code: SensorKit is research-gated. We cannot use it in a normal
 App Store app.
 
 Access to SensorKit data is limited to research uses and requires a private
 entitlement, which Apple reviews separately for each study. You must:

 Submit a research proposal to sensorkitrequest@apple.com
 Obtain IRB/Ethics Board approval
 
 Receive a development entitlement first (for testing on limited devices), then a
 distribution entitlement (for TestFlight/App Store)

 Once a participant has agreed to SensorKit permissions, you receive data after a 24-hour embargo.
 Some SensorKit data is batched daily, so if you miss that day's upload, it could be an additional
 day before data is received.
 
 This means SensorKit is not suitable for real-time or same-day data access — it's a retrospective
 batch pipeline for approved research studies.
 
 
 
 The architecutre:
 
 Apple Watch (OS records 24/7 accelerometer passively)
         ↓  [24hr embargo]
 iPhone SensorKit daemon
         ↓  [SRSensorReader.fetch()]
 Your iOS app delegate callbacks (SRFetchResult per sample)
         ↓
 SQLite / your storage layer
 
 
 SensorKit runs entirely on iPhone — your app fetches data from
 the paired Watch via the iPhone's SensorKit daemon. You never
 write a watchOS extension for this.
 
 */


import SensorKit
import CoreMotion
import Foundation

class SensorKitAccelerometerFetcher: NSObject {
    static let shared = SensorKitAccelerometerFetcher()
    
    private let reader = SRSensorReader(sensor: .accelerometer)
    
    // Buffer for batched CSV writes
    // private var buffer: [(timestamp: Double, x: Float, y: Float, z: Float)] = []
    private var buffer: CircularBuffer
    private let batchSize = 2000
    
    // CSV file management
    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 50 * 1024 * 1024  // 50 MB per file
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_csv_file_index") }
    }
    
    // Track last fetch window
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_accel_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_accel_last_fetch_end") }
    }
    
    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
    
    override init() {
        /*
         SRSensorReader(sensor: .accelerometer) is created
                 ↓
         reader.delegate = self  ← all callbacks come back to this class?? Why?
                 ↓
         openCurrentFile()  ← opens/creates the current CSV file
         */
        buffer = CircularBuffer(capacity: batchSize)
        currentFileURL = documentsDir  // placeholder; set in openCurrentFile()
        super.init()
        reader.delegate = self
        
    }
    
    // MARK: - Fetch
    
    func startRecordingWithAuthorizationCheck(){
        
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined
        
        if authorizationStatus != .authorized {
            print("SK: Sensorkit is not authorized, skipping")
            return
        }
        
        print("SK: Attempting to start sensor recording")
        reader.startRecording()
    }
    
    func startRecording(){
        /*
         
         */
        print("SK: Attempting to start sensor recording")
        reader.startRecording()
    }
    
    func fetchLatestData() {
        /*
         fetchLatestData()
                 ↓
         reader.fetchDevices()  ← asks SensorKit: what devices are available?
                 ↓
                [async] didFetch devices: [SRDevice]  ← delegate callback (this callback will call the fetchSamples for watch)
                 ↓
                picks the Apple Watch device
                 ↓
         fetchSamples(from: device)
        */
        //check authroization status
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined
        
        if authorizationStatus != .authorized {
            print("SK: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK: Sensorkit is not authorized, skipping")
            return
        }else{
            print("SK: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK: Sensorkit is authorized, fetching devices")
            openCurrentFile()
            reader.fetchDevices()
        }
        
        
    }
    
    private func fetchSamples(from device: SRDevice) {
        /*
         
             now
              │
              │  ← can't fetch (24hr embargo enforced by OS)
              │
             now - 25hr  ← fetchEnd (safe margin past the embargo)
              │
              │  ← this window is fetchable
              │
             lastFetchEnd  ← fetchStart (where last fetch left off)
                or
             now - 48hr  ← fetchStart if this is the very first fetch
             
             lastFetchEnd is stored in UserDefaults, so across app launches and background wakes,
             we never re-fetch data we already have.
             
             After computing the window, both times are converted to SRAbsoluteTime (Core Foundation
             reference time, not Unix time) before being set on the SRFetchRequest.
         
        */
        
        
        let now = Date()
        let fetchEnd = now.addingTimeInterval(-25 * 3600)  // respect 24hr embargo
        
        let fetchStart: Date
        if lastFetchEnd > 0 {
            fetchStart = Date(timeIntervalSinceReferenceDate: lastFetchEnd)
        } else {
            //if we do not have any record of lastFetch, we get data from
            //the last 48 hours
            fetchStart = now.addingTimeInterval(-48 * 3600)
        }
        
        guard fetchStart < fetchEnd else {
            // if fetchEnd >= fetchStart, then we have
            // nothing to fetch or record.
            print("No new data window available yet")
            return
        }
        
        // Request fetch for a time range.
        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(
            _cf: fetchStart.timeIntervalSinceReferenceDate
        )
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(
            _cf: fetchEnd.timeIntervalSinceReferenceDate
        )
        
        print("Fetching accelerometer from \(fetchStart) to \(fetchEnd)")
        
        // Once reader.fetch(request) is called, SensorKit streams
        // results one sample at a time through the delegate
        // didFetchResult will be called.
        
        reader.fetch(request)
        
        // The fetchEnd is not the current time. It is (currentTime-25) hours
        // We cannot fetech data in realtime for SensorKit
        // We have to wait.
        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }
    
    // MARK: - CSV File Management
    
    private func csvFileName(index: Int) -> String {
        return "sensorkit_accel_phone_\(String(format: "%05d", index)).csv"
    }
    
    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(
                csvFileName(index: fileIndex)
        )
        
        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        
        if needsHeader {
            // Create file with CSV header
            let header = "timestamp_unix,x,y,z\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }
        
        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()
        
        print("CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK: Current CSV file: \(currentFileURL.lastPathComponent)")
    }
    
    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else { return }
        
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("Rotated to file index \(fileIndex)")
            Logger.shared.append("SK: Rotated to file index \(fileIndex)")
        }
    }
    
    // MARK: - Buffered Write
    
    private func bufferSample(timestamp: Double, x: Float, y: Float, z: Float) {
        
        //buffer.append((timestamp, x, y, z))
        //        if buffer.count >= batchSize {
        //            flushBuffer()
        //        }
        
        buffer.write(.init(timestamp: timestamp, x: x, y: y, z: z))
        if buffer.isFull {
            flushBuffer()
        }
    }
    
    private func flushBuffer() {
        guard buffer.count > 0, let handle = fileHandle else { return }
                
        let samples = buffer.drain()
        buffer.reset()
        
        var csv = ""
        csv.reserveCapacity(samples.count * 40)
        
        for s in samples {
            csv += "\(String(format: "%.6f", s.timestamp)),\(String(format: "%.8f", s.x)),\(String(format: "%.8f", s.y)),\(String(format: "%.8f", s.z))\n"
        }
        
        if let data = csv.data(using: .utf8) {
            handle.write(data)
        }
        
        print("Flushed \(samples.count) samples → \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK: Flushed \(samples.count) samples → \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }
    
    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitAccelerometerFetcher: SRSensorReaderDelegate {
    
    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK: SensorKit recording successfully started")
        Logger.shared.append("SK: SensorKit recording successfully started")
    }

    init() {
        super.init(
            sensor: .accelerometer,
            filePrefix: "sensorkit_accel_phone",
            csvHeader: "timestamp_unix,x,y,z",
            devicePreference: .iPhone,
            logTag: "SK-Accel",
            fileIndexKey: "sk_csv_file_index",
            lastFetchEndKey: "sk_accel_last_fetch_end"
        )
    }

    // The accelerometer delivers a batch array per fetch result.
    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedAccelerometerData] else { return [] }

        // Sensors-tab freshness: newest sample time in this batch (data is ~24h embargoed).
        if let newest = samples.map(\.startDate).max() {
            SensorStatusStore.shared.record(.watchAccelerometer, at: newest)
        }

struct CircularBuffer {
    
    struct Sample {
        var timestamp: Double
        var x: Float
        var y: Float
        var z: Float
    }
    
    private var storage: [Sample]
    private var writeIndex: Int = 0
    private(set) var count: Int = 0
    let capacity: Int
    
    init(capacity: Int) {
        self.capacity = capacity
        // Preallocate all slots upfront — no reallocation ever
        self.storage = Array(
            repeating: Sample(timestamp: 0, x: 0, y: 0, z: 0),
            count: capacity
        )
    }
    
    mutating func write(_ sample: Sample) {
        storage[writeIndex] = sample
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }
    
    var isFull: Bool { count == capacity }
    
    // Returns samples in insertion order (oldest → newest)
    func drain() -> [Sample] {
        guard count > 0 else { return [] }
        if count < capacity {
            // Buffer not yet full: data sits at indices 0..<count
            return Array(storage[0..<count])
        } else {
            // Buffer full: writeIndex points at the oldest slot
            return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
        }
    }
    
    mutating func reset() {
        writeIndex = 0
        count = 0
        // storage stays allocated — slots will be overwritten on next writes
    }
}



