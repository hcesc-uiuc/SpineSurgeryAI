//
//  SensorKit_AccelWatch.swift
//  SensingApp
//
//  SensorKit accelerometer (iPhone). All logic lives in SensorKitFetcher;
//  this only declares the config and how to turn a fetch result into rows.
//  Writes sensorkit_accel_phone_*.csv.
//

import SensorKit
import CoreMotion

final class SensorKitAccelerometerFetcher: SensorKitFetcher {
    static let shared = SensorKitAccelerometerFetcher()

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SensorKit recording failed: \(error)")
        Logger.shared.append("SensorKit recording failed: \(error)")
    }
    
    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        
        
        print("SK: Fetch devices callback is called")
        
        // print all available devices
        for device in devices {
            print("SK: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK: Device: \(device.name) — model: \(device.model)")
        }
        
        // The iPhone's own accelerometer (not a paired Watch).
        let phoneDevice = devices.first { $0.model.lowercased().contains("iphone") }
            ?? devices.first

        guard let device = phoneDevice else {
            print("No SensorKit devices found")
            return
        }
        print("Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }
    
    func sensorReader(
        _ reader: SRSensorReader,
        fetchDevicesDidFailWithError error: Error
    ) {
        print("fetchDevices failed: \(error)")
    }
    
    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        
        /*
         
             didFetchResult called (once per batch)
                     ↓
             cast result.sample → [CMRecordedAccelerometerData]
                     ↓
             for each sample: convert startDate to Unix epoch
                     ↓
             extract acceleration (x, y, z)
                     ↓
             bufferSample(timestamp, x, y, z)
                     ↓
             buffer.count  == 1000?
                 YES → flushBuffer()
                 NO  → keep accumulating
         
         */
        
        guard let samples = result.sample as? [CMRecordedAccelerometerData] else {
            return true
        }
        
        print("SK: Writing \(samples.count) samples of accelerometer data")
        Logger.shared.append("SK: Writing \(samples.count) samples of accelerometer data")
        
        for accelSample in samples {
            let unixTime = accelSample.startDate.timeIntervalSince1970
            let accel = accelSample.acceleration

            bufferSample(
                timestamp: unixTime,
                x: Float(accel.x),
                y: Float(accel.y),
                z: Float(accel.z)
            )
        }

        // Sensors-tab freshness: stamp with the newest sample time in this batch.
        // (SensorKit data is ~24h embargoed, so this reflects when the watch
        // recorded it, not when we fetched it.)
        if let newest = samples.map(\.startDate).max() {
            SensorStatusStore.shared.record(.watchAccelerometer, at: newest)
        }
        return true
    }
    
    func sensorReader(
        _ reader: SRSensorReader,
        didCompleteFetch fetchRequest: SRFetchRequest
    ) {
        /*
         This is called, when all data fetch has ended.
         At this point, we will write everything that is in
         the buffer
         */
        flushBuffer()
        fileHandle?.synchronizeFile()  // fsync to disk
        print("Fetch complete. Files in documents:")
        Logger.shared.append("SK: Fetch complete. Files in documents")
        listCSVFiles()
    }
    
    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("Fetch failed: \(error)")
        flushBuffer()
    }
    
    func sensorReader(
        _ reader: SRSensorReader,
        didChange authorizationStatus: SRAuthorizationStatus
    ) {
        /*
         This is authorization
         It is called when the sensorkit
         Authorization is provided
         */
        switch authorizationStatus {
            case .authorized: print("SensorKit authorized")
            case .notDetermined: print("SensorKit not determined")
            case .denied: print("SensorKit denied")
        @unknown default: break
        }
    }
    
    // MARK: - Debug Helpers
    
    func listCSVFiles() {
        let toBeProcessedDir = documentsDir.appendingPathComponent("to-be-processed")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: toBeProcessedDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ))?.filter { $0.pathExtension == "csv" } ?? []
        
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("  \(url.lastPathComponent) — \(size / 1024) KB")
        }
    }
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

    // The accelerometer delivers a batch array per fetch result.
    override func rows(from result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedAccelerometerData] else { return [] }
        return samples.map { s in
            let a = s.acceleration
            return "\(String(format: "%.6f", s.startDate.timeIntervalSince1970)),"
                 + "\(String(format: "%.8f", a.x)),"
                 + "\(String(format: "%.8f", a.y)),"
                 + "\(String(format: "%.8f", a.z))"
        }
    }
}
