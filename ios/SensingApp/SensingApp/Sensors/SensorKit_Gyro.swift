//
//  SensorKit_Gyro.swift
//  SensingApp
//
//  SensorKit gyroscope (rotation rate) fetcher for the iPhone.
//  Mirrors SensorKitAccelerometerFetcher: same singleton style, same
//  record/fetch/CSV lifecycle, reuses CircularBuffer (defined in
//  SensorKit_AccelWatch.swift). Writes sensorkit_gyro_phone_*.csv.
//
//  SensorKit records the sensor 24/7 at the OS level; you fetch data older
//  than the 24-hour embargo. startRecording() must be called or the OS keeps
//  no data. Rotation rate is "the device's gyroscope" (Apple SDK header), and
//  the device here is the iPhone.
//

import SensorKit
import CoreMotion
import Foundation

class SensorKitGyroscopeFetcher: NSObject {
    static let shared = SensorKitGyroscopeFetcher()

    private let reader = SRSensorReader(sensor: .rotationRate)

    private var buffer: CircularBuffer
    private let batchSize = 2000

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 50 * 1024 * 1024  // 50 MB per file

    // Gyro-specific UserDefaults keys so it never clobbers the accelerometer's.
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_gyro_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_gyro_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_gyro_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_gyro_last_fetch_end") }
    }

    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        buffer = CircularBuffer(capacity: batchSize)
        currentFileURL = documentsDir  // placeholder; set in openCurrentFile()
        super.init()
        reader.delegate = self
    }

    // MARK: - Record / Fetch

    func startRecordingWithAuthorizationCheck() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-Gyro: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-Gyro: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-Gyro: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-Gyro: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-Gyro: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-Gyro: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-Gyro: Sensorkit is authorized, fetching devices")
            openCurrentFile()
            reader.fetchDevices()
        }
    }

    private func fetchSamples(from device: SRDevice) {
        let now = Date()
        let fetchEnd = now.addingTimeInterval(-25 * 3600)  // respect 24hr embargo

        let fetchStart: Date
        if lastFetchEnd > 0 {
            fetchStart = Date(timeIntervalSinceReferenceDate: lastFetchEnd)
        } else {
            fetchStart = now.addingTimeInterval(-48 * 3600)
        }

        guard fetchStart < fetchEnd else {
            print("SK-Gyro: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-Gyro: Fetching rotation rate from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_gyro_phone_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "timestamp_unix,x,y,z\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-Gyro: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-Gyro: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-Gyro: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-Gyro: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered Write

    private func bufferSample(timestamp: Double, x: Float, y: Float, z: Float) {
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

        print("SK-Gyro: Flushed \(samples.count) samples -> \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-Gyro: Flushed \(samples.count) samples -> \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitGyroscopeFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-Gyro: SensorKit recording successfully started")
        Logger.shared.append("SK-Gyro: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-Gyro: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-Gyro: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-Gyro: Fetch devices callback is called")
        for device in devices {
            print("SK-Gyro: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-Gyro: Device: \(device.name) — model: \(device.model)")
        }

        // The iPhone's own gyroscope (not a paired Watch).
        let phoneDevice = devices.first { $0.model.lowercased().contains("iphone") }
            ?? devices.first

        guard let device = phoneDevice else {
            print("SK-Gyro: No SensorKit devices found")
            return
        }
        print("SK-Gyro: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-Gyro: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        guard let samples = result.sample as? [CMRecordedRotationRateData] else {
            return true
        }

        print("SK-Gyro: Writing \(samples.count) samples of rotation rate data")
        Logger.shared.append("SK-Gyro: Writing \(samples.count) samples of rotation rate data")

        for sample in samples {
            let unixTime = sample.startDate.timeIntervalSince1970
            let rate = sample.rotationRate
            bufferSample(
                timestamp: unixTime,
                x: Float(rate.x),
                y: Float(rate.y),
                z: Float(rate.z)
            )
        }
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flushBuffer()
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-Gyro: Fetch complete")
        Logger.shared.append("SK-Gyro: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-Gyro: Fetch failed: \(error)")
        flushBuffer()
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-Gyro: SensorKit authorized")
        case .notDetermined: print("SK-Gyro: SensorKit not determined")
        case .denied:        print("SK-Gyro: SensorKit denied")
        @unknown default: break
        }
    }
}
