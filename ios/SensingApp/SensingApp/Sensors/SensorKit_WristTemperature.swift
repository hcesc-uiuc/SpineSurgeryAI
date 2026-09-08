//
//  SensorKit_WristTemperature.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 7/10/26.
//
//
//  SensorKit wrist temperature fetcher for the paired Apple Watch.
//  Mirrors SensorKitGyroscopeFetcher's record/fetch/CSV lifecycle. Unlike
//  gyro/accel, wrist temperature is low-rate (nightly readings, not 50Hz),
//  so no circular buffer is used — samples are written straight to disk on
//  each fetch callback. Device targeting follows SensorKitWristDetectionFetcher
//  (Watch, not iPhone), since wrist temperature is a Watch-only sensor.
//
//  NOTE: verify CMRecordedWristTemperatureData's exact property names against
//  the SensorKit/CoreMotion headers in Xcode — confirm via autocomplete before
//  building; this mirrors the CMRecordedRotationRateData shape but temperature
//  sensor metadata (measurement context, e.g. sleep) may differ by iOS version.
//
//  SensorKit records 24/7 at the OS level; you fetch data older than the
//  24-hour embargo. startRecording() must be called or the OS keeps no data.
//  Requires SRSensor.wristTemperature entitlement + NSSensorKitUsageDetail
//  entry, same approval gate as onWristState.
//

import SensorKit
import CoreMotion
import Foundation

class SensorKitWristTemperatureFetcher: NSObject {
    static let shared = SensorKitWristTemperatureFetcher()

    private let reader = SRSensorReader(sensor: .wristTemperature)

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 50 * 1024 * 1024  // 50 MB per file

    // Wrist-temp-specific UserDefaults keys so it never clobbers other fetchers.
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_wristtemp_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_wristtemp_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_wristtemp_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_wristtemp_last_fetch_end") }
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
            print("SK-WristTemp: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-WristTemp: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-WristTemp: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-WristTemp: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-WristTemp: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-WristTemp: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-WristTemp: Sensorkit is authorized, fetching devices")
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
            print("SK-WristTemp: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-WristTemp: Fetching wrist temperature from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_wristtemp_watch_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "timestamp_unix,temperature_celsius\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-WristTemp: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-WristTemp: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-WristTemp: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-WristTemp: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Direct Write (low sample rate — no buffering needed)

    private func writeSample(timestamp: Double, celsius: Double) {
        guard let handle = fileHandle else { return }
        let line = "\(String(format: "%.6f", timestamp)),\(String(format: "%.4f", celsius))\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        rotateFileIfNeeded()
    }

    deinit {
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitWristTemperatureFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-WristTemp: SensorKit recording successfully started")
        Logger.shared.append("SK-WristTemp: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-WristTemp: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-WristTemp: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-WristTemp: Fetch devices callback is called")
        for device in devices {
            print("SK-WristTemp: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-WristTemp: Device: \(device.name) — model: \(device.model)")
        }

        // Wrist temperature is Watch-only; target the paired Watch, not the phone.
        let watchDevice = devices.first { $0.model.lowercased().contains("watch") }
            ?? devices.first

        guard let device = watchDevice else {
            print("SK-WristTemp: No SensorKit devices found")
            return
        }
        print("SK-WristTemp: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-WristTemp: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        guard let session = result.sample as? SRWristTemperatureSession else {
            return true
        }

        let allTemps = Array(session.temperatures)
        print("SK-WristTemp: Writing \(allTemps.count) samples of wrist temperature data")
        Logger.shared.append("SK-WristTemp: Writing \(allTemps.count) samples of wrist temperature data")

        for sample in allTemps {
            let unixTime = sample.timestamp.timeIntervalSince1970
            // .value is a Measurement<UnitTemperature>; convert to Celsius for
            // consistent storage regardless of the device's reporting unit.
            let celsius = sample.value.converted(to: .celsius).value
            writeSample(timestamp: unixTime, celsius: celsius)
        }
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-WristTemp: Fetch complete")
        Logger.shared.append("SK-WristTemp: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-WristTemp: Fetch failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-WristTemp: SensorKit authorized")
        case .notDetermined: print("SK-WristTemp: SensorKit not determined")
        case .denied:        print("SK-WristTemp: SensorKit denied")
        @unknown default: break
        }
    }
}
