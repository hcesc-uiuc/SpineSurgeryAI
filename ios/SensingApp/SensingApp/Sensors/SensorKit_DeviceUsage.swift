//
//  SensorKit_DeviceUsage.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 7/10/26.
//
//  SensorKit device usage fetcher (SRSensor.deviceUsageReport).
//  Mirrors SensorKitGyroscopeFetcher: same singleton style, same
//  record/fetch/CSV lifecycle. Writes sensorkit_deviceusage_phone_*.csv.
//
//  Unlike accel/gyro, this sensor doesn't stream continuous x/y/z samples —
//  each fetch result is a single SRDeviceUsageReport summarizing an interval
//  (screen wakes, unlocks, per-category app/notification/web usage). So this
//  does NOT reuse CircularBuffer from SensorKit_AccelWatch.swift; it uses a
//  small local buffer of DeviceUsageSample instead.
//
//  NOTE: SRDeviceUsageReport's property names below (totalScreenWakes,
//  totalUnlocks, totalUnlockDuration, applicationUsageByCategory,
//  notificationUsageByCategory, webUsage) are per Apple's SensorKit headers
//  as of recent SDKs — verify against your Xcode version, this sensor's
//  surface has changed across iOS releases.
//

import SensorKit
import CoreMotion
import Foundation

private struct DeviceUsageSample {
    let reportStart: Double
    let reportEnd: Double
    let totalScreenWakes: Int
    let totalUnlocks: Int
    let totalUnlockDuration: Double
    let totalAppUsageSeconds: Double
    let totalNotifications: Int
    let totalWebUsageSeconds: Double
}

class SensorKitDeviceUsageFetcher: NSObject {
    static let shared = SensorKitDeviceUsageFetcher()

    private let reader = SRSensorReader(sensor: .deviceUsageReport)

    private var buffer: [DeviceUsageSample] = []
    private let batchSize = 200  // reports are low-frequency; small batch is fine

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 50 * 1024 * 1024  // 50 MB per file

    // Device-usage-specific UserDefaults keys so it never clobbers other fetchers.
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_deviceusage_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_deviceusage_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_deviceusage_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_deviceusage_last_fetch_end") }
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
            print("SK-DeviceUsage: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-DeviceUsage: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-DeviceUsage: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-DeviceUsage: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-DeviceUsage: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-DeviceUsage: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-DeviceUsage: Sensorkit is authorized, fetching devices")
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
            print("SK-DeviceUsage: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-DeviceUsage: Fetching device usage from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_deviceusage_phone_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "report_start,report_end,total_screen_wakes,total_unlocks,total_unlock_duration,total_app_usage_seconds,total_notifications,total_web_usage_seconds\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-DeviceUsage: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-DeviceUsage: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-DeviceUsage: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-DeviceUsage: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered Write

    private func bufferSample(_ sample: DeviceUsageSample) {
        buffer.append(sample)
        if buffer.count >= batchSize {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty, let handle = fileHandle else { return }

        let samples = buffer
        buffer.removeAll(keepingCapacity: true)

        var csv = ""
        csv.reserveCapacity(samples.count * 80)
        for s in samples {
            csv += "\(String(format: "%.6f", s.reportStart)),\(String(format: "%.6f", s.reportEnd)),\(s.totalScreenWakes),\(s.totalUnlocks),\(String(format: "%.3f", s.totalUnlockDuration)),\(String(format: "%.3f", s.totalAppUsageSeconds)),\(s.totalNotifications),\(String(format: "%.3f", s.totalWebUsageSeconds))\n"
        }

        if let data = csv.data(using: .utf8) {
            handle.write(data)
        }

        print("SK-DeviceUsage: Flushed \(samples.count) reports -> \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-DeviceUsage: Flushed \(samples.count) reports -> \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitDeviceUsageFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-DeviceUsage: SensorKit recording successfully started")
        Logger.shared.append("SK-DeviceUsage: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-DeviceUsage: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-DeviceUsage: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-DeviceUsage: Fetch devices callback is called")
        for device in devices {
            print("SK-DeviceUsage: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-DeviceUsage: Device: \(device.name) — model: \(device.model)")
        }

        // Device usage is reported for the iPhone itself (not a paired Watch).
        let phoneDevice = devices.first { $0.model.lowercased().contains("iphone") }
            ?? devices.first

        guard let device = phoneDevice else {
            print("SK-DeviceUsage: No SensorKit devices found")
            return
        }
        print("SK-DeviceUsage: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-DeviceUsage: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        // Unlike accel/gyro, each result is a single report, not an array.
        guard let report = result.sample as? SRDeviceUsageReport else {
            return true
        }

        let start = result.timestamp.toCFAbsoluteTime()
        let end = start + report.duration

        let totalAppSeconds = report.applicationUsageByCategory.values
            .reduce(0.0) { $0 + $1.reduce(0.0) { $0 + $1.usageTime } }
        let totalNotifications = report.notificationUsageByCategory.values
            .reduce(0) { $0 + $1.count }
        let totalWebSeconds = report.webUsageByCategory.values
            .reduce(0.0) { $0 + $1.reduce(0.0) { $0 + $1.totalUsageTime } }

        let sample = DeviceUsageSample(
            reportStart: start,
            reportEnd: end,
            totalScreenWakes: report.totalScreenWakes,
            totalUnlocks: report.totalUnlocks,
            totalUnlockDuration: report.totalUnlockDuration,
            totalAppUsageSeconds: totalAppSeconds,
            totalNotifications: totalNotifications,
            totalWebUsageSeconds: totalWebSeconds
        )

        print("SK-DeviceUsage: Buffering report at \(start) — wakes: \(sample.totalScreenWakes), unlocks: \(sample.totalUnlocks)")
        Logger.shared.append("SK-DeviceUsage: Buffering report at \(start)")

        bufferSample(sample)
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flushBuffer()
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-DeviceUsage: Fetch complete")
        Logger.shared.append("SK-DeviceUsage: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-DeviceUsage: Fetch failed: \(error)")
        flushBuffer()
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-DeviceUsage: SensorKit authorized")
        case .notDetermined: print("SK-DeviceUsage: SensorKit not determined")
        case .denied:        print("SK-DeviceUsage: SensorKit denied")
        @unknown default: break
        }
    }
}
