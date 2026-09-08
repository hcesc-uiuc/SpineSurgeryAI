//
//  SensorKit_AmbientLight.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 7/10/26.
//

//
//  SensorKit_AmbientLight.swift
//  SensingApp
//
//  SensorKit ambient light fetcher for the iPhone.
//  Mirrors SensorKitGyroscopeFetcher: same singleton style, same
//  record/fetch/CSV lifecycle, reuses CircularBuffer-style buffering.
//  Writes sensorkit_ambientlight_phone_*.csv.
//
//  SensorKit records the sensor 24/7 at the OS level; you fetch data older
//  than the 24-hour embargo. startRecording() must be called or the OS keeps
//  no data. Ambient light samples come back as SRAmbientLightSample, not
//  CMRecordedAmbientLightData — no relation to CoreMotion's rotation/accel types.
//

import SensorKit
import Foundation

/* Local sample struct + ring buffer, mirrors CircularBuffer<AccelSample> usage
   in SensorKit_AccelWatch.swift but sized for ambient light's payload. */
private struct AmbientLightSample {
    let timestamp: Double
    let lux: Double
    let placement: Int
    let chromaX: Double
    let chromaY: Double
}

private final class AmbientLightCircularBuffer {
    private var storage: [AmbientLightSample]
    private(set) var count = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
    }

    var isFull: Bool { count >= capacity }

    func write(_ sample: AmbientLightSample) {
        storage.append(sample)
        count += 1
    }

    func drain() -> [AmbientLightSample] {
        return storage
    }

    func reset() {
        storage.removeAll(keepingCapacity: true)
        count = 0
    }
}

class SensorKitAmbientLightFetcher: NSObject {
    static let shared = SensorKitAmbientLightFetcher()

    private let reader = SRSensorReader(sensor: .ambientLightSensor)

    private var buffer: AmbientLightCircularBuffer
    private let batchSize = 2000

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 10 * 1024 * 1024  // 50 MB per file

    // Ambient-light-specific UserDefaults keys so it never clobbers other fetchers'.
    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_ambientlight_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_ambientlight_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_ambientlight_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_ambientlight_last_fetch_end") }
    }

    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        buffer = AmbientLightCircularBuffer(capacity: batchSize)
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
            print("SK-AmbientLight: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-AmbientLight: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-AmbientLight: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-AmbientLight: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-AmbientLight: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-AmbientLight: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-AmbientLight: Sensorkit is authorized, fetching devices")
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
            print("SK-AmbientLight: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-AmbientLight: Fetching ambient light from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_ambientlight_phone_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "timestamp_unix,lux,placement,chroma_x,chroma_y\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-AmbientLight: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-AmbientLight: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-AmbientLight: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-AmbientLight: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered Write

    private func bufferSample(timestamp: Double, lux: Double, placement: Int, chromaX: Double, chromaY: Double) {
        buffer.write(.init(timestamp: timestamp, lux: lux, placement: placement, chromaX: chromaX, chromaY: chromaY))
        if buffer.isFull {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard buffer.count > 0, let handle = fileHandle else { return }

        let samples = buffer.drain()
        buffer.reset()

        var csv = ""
        csv.reserveCapacity(samples.count * 48)
        for s in samples {
            csv += "\(String(format: "%.6f", s.timestamp)),\(String(format: "%.6f", s.lux)),\(s.placement),\(String(format: "%.6f", s.chromaX)),\(String(format: "%.6f", s.chromaY))\n"
        }

        if let data = csv.data(using: .utf8) {
            handle.write(data)
        }

        print("SK-AmbientLight: Flushed \(samples.count) samples -> \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-AmbientLight: Flushed \(samples.count) samples -> \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitAmbientLightFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-AmbientLight: SensorKit recording successfully started")
        Logger.shared.append("SK-AmbientLight: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-AmbientLight: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-AmbientLight: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-AmbientLight: Fetch devices callback is called")
        for device in devices {
            print("SK-AmbientLight: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-AmbientLight: Device: \(device.name) — model: \(device.model)")
        }

        // The iPhone's own ambient light sensor (not a paired Watch).
        let phoneDevice = devices.first { $0.model.lowercased().contains("iphone") }
            ?? devices.first

        guard let device = phoneDevice else {
            print("SK-AmbientLight: No SensorKit devices found")
            return
        }
        print("SK-AmbientLight: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-AmbientLight: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        guard let sample = result.sample as? SRAmbientLightSample else {
            return true
        }

        print("SK-AmbientLight: Writing ambient light sample")
        Logger.shared.append("SK-AmbientLight: Writing ambient light sample")

        /* SRFetchResult.timestamp is SRAbsoluteTime (CF reference date epoch);
           convert to Unix time by adding the CF-to-Unix offset. */
        let cfTime = result.timestamp.toCFAbsoluteTime()
        let unixTime = cfTime + kCFAbsoluteTimeIntervalSince1970
        let luxValue = sample.lux.converted(to: .lux).value
        /* placement is an enum (unknown/top/bottom/front/back etc.); store raw value */
        let placementRaw = sample.placement.rawValue
        let chroma = sample.chromaticity

        bufferSample(
            timestamp: unixTime,
            lux: luxValue,
            placement: placementRaw,
            chromaX: Double(chroma.x),
            chromaY: Double(chroma.y)
        )
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flushBuffer()
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-AmbientLight: Fetch complete")
        Logger.shared.append("SK-AmbientLight: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-AmbientLight: Fetch failed: \(error)")
        flushBuffer()
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-AmbientLight: SensorKit authorized")
        case .notDetermined: print("SK-AmbientLight: SensorKit not determined")
        case .denied:        print("SK-AmbientLight: SensorKit denied")
        @unknown default: break
        }
    }
}
