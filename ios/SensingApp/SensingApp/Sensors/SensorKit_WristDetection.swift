//
//  SensorKit_WristDetection.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 7/8/26.
//
//  SensorKit "on-wrist" detection fetcher for the paired Apple Watch.
//  Mirrors SensorKitGyroscopeFetcher: same singleton style, same
//  record/fetch/CSV lifecycle. Writes sensorkit_wristdetection_watch_*.csv.
//
//  Two differences from accel/gyro worth calling out:
//
//  1. This is event-driven, not a continuous stream. SensorKit only emits a
//     new SRWristDetection sample when the on/off-wrist state changes (or
//     periodically re-confirms it) — on the order of a handful of events a
//     day, not 50Hz. So there's no CircularBuffer/batchSize here: each
//     sample is written straight to disk as it arrives. Batching by count
//     the way accel/gyro do would mean a wrist-off event could sit
//     unflushed in memory for days waiting for a buffer that never fills.
//
//  2. It tracks the Apple Watch, not the iPhone — wrist detection is
//     meaningless for a device that isn't worn. Device selection below
//     looks for "watch" in the model string instead of "iphone".
//
//  Same rules as the other SensorKit fetchers still apply: startRecording()
//  must be called or the OS keeps no data, and fetches must respect the
//  24-hour embargo (fetch windows here end 25h in the past for margin).
//

import SensorKit
import Foundation

class SensorKitWristDetectionFetcher: NSObject {
    static let shared = SensorKitWristDetectionFetcher()

    private let reader = SRSensorReader(sensor: .onWristState)

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 5 * 1024 * 1024  // 5 MB per file

    // Wrist-detection-specific UserDefaults keys so it never clobbers accel/gyro.
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_wrist_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_wrist_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_wrist_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_wrist_last_fetch_end") }
    }

    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
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
            print("SK-Wrist: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-Wrist: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-Wrist: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-Wrist: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-Wrist: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-Wrist: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-Wrist: Sensorkit is authorized, fetching devices")
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
            print("SK-Wrist: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-Wrist: Fetching wrist detection from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_wristdetection_watch_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "timestamp_unix,on_wrist,wrist_location,crown_orientation\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-Wrist: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-Wrist: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-Wrist: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-Wrist: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Write

    // No ring buffer / batching — see header comment. Every sample is
    // written immediately; fileHandle.synchronizeFile() in
    // didCompleteFetch() fsyncs whatever accumulated during the fetch.
    private func writeSample(timestamp: Double, onWrist: Bool, wristLocation: String, crownOrientation: String) {
        guard let handle = fileHandle else { return }

        let row = "\(String(format: "%.6f", timestamp)),\(onWrist ? 1 : 0),\(wristLocation),\(crownOrientation)\n"
        if let data = row.data(using: .utf8) {
            handle.write(data)
        }

        rotateFileIfNeeded()
    }

    deinit {
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitWristDetectionFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-Wrist: SensorKit recording successfully started")
        Logger.shared.append("SK-Wrist: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-Wrist: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-Wrist: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-Wrist: Fetch devices callback is called")
        for device in devices {
            print("SK-Wrist: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-Wrist: Device: \(device.name) — model: \(device.model)")
        }

        // The paired Apple Watch, not the iPhone.
        let watchDevice = devices.first { $0.model.lowercased().contains("watch") }
            ?? devices.first

        guard let device = watchDevice else {
            print("SK-Wrist: No SensorKit devices found")
            return
        }
        print("SK-Wrist: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-Wrist: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        // Unlike accel/gyro (which deliver a batch array per callback),
        // SRWristDetection arrives as one sample per didFetchResult call.
        guard let sample = result.sample as? SRWristDetection else {
            return true
        }

        let unixTime = Date(timeIntervalSinceReferenceDate: result.timestamp.toCFAbsoluteTime())
            .timeIntervalSince1970

        let location: String
        switch sample.wristLocation {
        case .left:       location = "left"
        case .right:      location = "right"
        @unknown default: location = "unknown"
        }

        let crown: String
        switch sample.crownOrientation {
        case .left:       crown = "left"
        case .right:      crown = "right"
        @unknown default: crown = "unknown"
        }

        print("SK-Wrist: onWrist=\(sample.onWrist) location=\(location) crown=\(crown)")
        Logger.shared.append("SK-Wrist: onWrist=\(sample.onWrist) location=\(location) crown=\(crown)")

        writeSample(timestamp: unixTime, onWrist: sample.onWrist, wristLocation: location, crownOrientation: crown)
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-Wrist: Fetch complete")
        Logger.shared.append("SK-Wrist: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-Wrist: Fetch failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-Wrist: SensorKit authorized")
        case .notDetermined: print("SK-Wrist: SensorKit not determined")
        case .denied:        print("SK-Wrist: SensorKit denied")
        @unknown default: break
        }
    }
}
