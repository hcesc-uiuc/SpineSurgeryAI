//
//  Untitled.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 7/10/26.
//
//
//  SensorKit heart rate fetcher (Apple Watch only — heart rate is not
//  sensed by the iPhone). Mirrors SensorKitGyroscopeFetcher's lifecycle
//  (record/fetch/CSV), but targets the paired Watch like
//  SensorKitWristDetectionFetcher, and buffers scalar samples instead of
//  x/y/z triplets, so it does not reuse CircularBuffer.
//
//  Samples arrive as CMHighFrequencyHeartRateData (CoreMotion), each with
//  a heartRate (BPM) and a confidence tier. Writes
//  sensorkit_heartrate_watch_*.csv.
//

import SensorKit
import CoreMotion
import Foundation

private struct HeartRateSample {
    let timestamp: Double
    let bpm: Double
    let confidence: Int  // raw CMHighFrequencyHeartRateDataConfidence value
}

class SensorKitHeartRateFetcher: NSObject {
    static let shared = SensorKitHeartRateFetcher()

    private let reader = SRSensorReader(sensor: .heartRate)

    // Simple array-backed buffer — heart rate arrives at low/irregular
    // rates (not 50Hz), so a lockless ring is unnecessary here.
    private var buffer: [HeartRateSample] = []
    private let batchSize = 100

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 10 * 1024 * 1024  // 50 MB per file

    // Heart-rate-specific UserDefaults keys so it never clobbers other fetchers'.
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_hr_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_hr_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_hr_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_hr_last_fetch_end") }
    }

    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        currentFileURL = documentsDir  // placeholder; set in openCurrentFile()
        super.init()
        reader.delegate = self
        buffer.reserveCapacity(batchSize)
    }

    // MARK: - Record / Fetch

    func startRecordingWithAuthorizationCheck() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-HR: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-HR: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-HR: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-HR: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-HR: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-HR: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-HR: Sensorkit is authorized, fetching devices")
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
            print("SK-HR: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-HR: Fetching heart rate from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_heartrate_watch_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "timestamp_unix,heart_rate_bpm,confidence\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-HR: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-HR: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-HR: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-HR: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered Write

    private func bufferSample(timestamp: Double, bpm: Double, confidence: Int) {
        buffer.append(HeartRateSample(timestamp: timestamp, bpm: bpm, confidence: confidence))
        if buffer.count >= batchSize {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty, let handle = fileHandle else { return }

        let samples = buffer
        buffer.removeAll(keepingCapacity: true)

        var csv = ""
        csv.reserveCapacity(samples.count * 32)
        for s in samples {
            csv += "\(String(format: "%.6f", s.timestamp)),\(String(format: "%.2f", s.bpm)),\(s.confidence)\n"
        }

        if let data = csv.data(using: .utf8) {
            handle.write(data)
        }

        print("SK-HR: Flushed \(samples.count) samples -> \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-HR: Flushed \(samples.count) samples -> \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitHeartRateFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-HR: SensorKit recording successfully started")
        Logger.shared.append("SK-HR: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-HR: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-HR: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-HR: Fetch devices callback is called")
        for device in devices {
            print("SK-HR: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-HR: Device: \(device.name) — model: \(device.model)")
        }

        // Heart rate is only sensed by the paired Apple Watch, not the iPhone.
        let watchDevice = devices.first { $0.model.lowercased().contains("watch") }

        guard let device = watchDevice else {
            print("SK-HR: No paired Apple Watch found in SensorKit devices")
            Logger.shared.append("SK-HR: No paired Apple Watch found in SensorKit devices")
            return
        }
        print("SK-HR: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-HR: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        guard let samples = result.sample as? [CMHighFrequencyHeartRateData] else {
            return true
        }

        print("SK-HR: Writing \(samples.count) samples of heart rate data")
        Logger.shared.append("SK-HR: Writing \(samples.count) samples of heart rate data")

        for sample in samples {
            guard let date = sample.date else { continue }
            let unixTime = date.timeIntervalSince1970
            bufferSample(
                timestamp: unixTime,
                bpm: sample.heartRate,
                confidence: sample.confidence.rawValue
            )
        }
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flushBuffer()
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-HR: Fetch complete")
        Logger.shared.append("SK-HR: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-HR: Fetch failed: \(error)")
        flushBuffer()
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-HR: SensorKit authorized")
        case .notDetermined: print("SK-HR: SensorKit not determined")
        case .denied:        print("SK-HR: SensorKit denied")
        @unknown default: break
        }
    }
}

