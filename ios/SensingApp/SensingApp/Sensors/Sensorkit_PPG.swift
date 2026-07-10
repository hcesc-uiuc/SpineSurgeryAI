//
//  Sensorkit_PPG.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 7/10/26.
//
//
//  SensorKit photoplethysmogram (PPG) fetcher for the paired Apple Watch.
//  Mirrors SensorKitGyroscopeFetcher: same singleton style, same
//  record/fetch/CSV lifecycle. PPG is Watch-only (no iPhone PPG sensor),
//  so device selection targets the Watch rather than the phone, similar
//  to SensorKitWristDetectionFetcher.
//
//  NOTE: PPG typically requires a restricted research entitlement (like
//  heart rate / ECG) separate from the general SensorKit entitlement —
//  confirm .photoplethysmogram is covered by your Apple approval.
//
//  NOTE: Only signalIdentifier, emitter, samplingFrequency, pinkNoise, and
//  whiteNoise on SRPhotoplethysmogramOpticalSample are confirmed against
//  Apple's docs. The actual raw PPG value + per-sample timestamp field
//  name(s) are NOT confirmed — Apple's docs are JS-rendered and search
//  snippets don't surface the full member list. Check Xcode Quick Help /
//  autocomplete on `optical.` and fill in the TODOs below before this
//  compiles cleanly. Given other batched SensorKit sensors expose an
//  array-of-readings per sample object, the raw waveform may live in a
//  nested array rather than a single scalar per SRPhotoplethysmogramOpticalSample.
//

import SensorKit
import CoreMotion
import Foundation

private struct PPGRow {
    // Timestamp derived from SRPhotoplethysmogramSample.startDate + optical.nanosecondsSinceStart
    let timestamp: Double

    // From SRPhotoplethysmogramSample (parent)
    let usage: String
    let temperatureCelsius: Double

    // From SRPhotoplethysmogramOpticalSample
    let signalIdentifier: Int
    let emitter: Int
    let activePhotodiodeIndexes: String   // comma-separated index list
    let samplingFrequencyHz: Double
    let nominalWavelengthNm: Double
    let effectiveWavelengthNm: Double
    let normalizedReflectance: Double
    let conditions: String                // comma-separated condition raw values

    // From SRPhotoplethysmogramOpticalSample.NoiseTerms (nil -> nan)
    let pinkNoise: Double
    let whiteNoise: Double
    let backgroundNoise: Double
    let backgroundNoiseOffset: Double
}

class SensorKitPPGFetcher: NSObject {
    static let shared = SensorKitPPGFetcher()

    private let reader = SRSensorReader(sensor: .photoplethysmogram)

    // Simple array buffer (not CircularBuffer — PPG rows aren't x/y/z shaped).
    private var buffer: [PPGRow] = []
    private let batchSize = 2000

    private var currentFileURL: URL
    private var fileHandle: FileHandle?
    private let maxFileSize: Int = 10 * 1024 * 1024  // 50 MB per file

    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: "sk_ppg_csv_file_index") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_ppg_csv_file_index") }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: "sk_ppg_last_fetch_end") }
        set { UserDefaults.standard.set(newValue, forKey: "sk_ppg_last_fetch_end") }
    }

    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        currentFileURL = documentsDir  // placeholder; set in openCurrentFile()
        buffer.reserveCapacity(batchSize)
        super.init()
        reader.delegate = self
    }

    // MARK: - Record / Fetch

    func startRecordingWithAuthorizationCheck() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-PPG: Sensorkit is not authorized, skipping")
            return
        }
        print("SK-PPG: Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecording() {
        print("SK-PPG: Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        let authKey = "sk_authorization_status"
        let raw = UserDefaults.standard.integer(forKey: authKey)
        let authorizationStatus = SRAuthorizationStatus(rawValue: raw) ?? .notDetermined

        if authorizationStatus != .authorized {
            print("SK-PPG: Sensorkit is not authorized, skipping")
            Logger.shared.append("SK-PPG: Sensorkit is not authorized, skipping")
            return
        } else {
            print("SK-PPG: Sensorkit is authorized, fetching devices")
            Logger.shared.append("SK-PPG: Sensorkit is authorized, fetching devices")
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
            print("SK-PPG: No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("SK-PPG: Fetching PPG from \(fetchStart) to \(fetchEnd)")
        reader.fetch(request)

        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV File Management

    private func csvFileName(index: Int) -> String {
        return "sensorkit_ppg_watch_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        let needsHeader = !FileManager.default.fileExists(atPath: currentFileURL.path)
        if needsHeader {
            let header = "timestamp_unix,usage,temperature_celsius,signal_identifier,emitter,active_photodiode_indexes,sampling_frequency_hz,nominal_wavelength_nm,effective_wavelength_nm,normalized_reflectance,conditions,pink_noise,white_noise,background_noise,background_noise_offset\n"
            try? header.write(to: currentFileURL, atomically: false, encoding: .utf8)
        }

        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()

        print("SK-PPG: CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-PPG: Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("SK-PPG: Rotated to file index \(fileIndex)")
            Logger.shared.append("SK-PPG: Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered Write

    private func bufferSample(
        timestamp: Double,
        usage: String,
        temperatureCelsius: Double,
        signalIdentifier: Int,
        emitter: Int,
        activePhotodiodeIndexes: String,
        samplingFrequencyHz: Double,
        nominalWavelengthNm: Double,
        effectiveWavelengthNm: Double,
        normalizedReflectance: Double,
        conditions: String,
        pinkNoise: Double,
        whiteNoise: Double,
        backgroundNoise: Double,
        backgroundNoiseOffset: Double
    ) {
        buffer.append(PPGRow(
            timestamp: timestamp,
            usage: usage,
            temperatureCelsius: temperatureCelsius,
            signalIdentifier: signalIdentifier,
            emitter: emitter,
            activePhotodiodeIndexes: activePhotodiodeIndexes,
            samplingFrequencyHz: samplingFrequencyHz,
            nominalWavelengthNm: nominalWavelengthNm,
            effectiveWavelengthNm: effectiveWavelengthNm,
            normalizedReflectance: normalizedReflectance,
            conditions: conditions,
            pinkNoise: pinkNoise,
            whiteNoise: whiteNoise,
            backgroundNoise: backgroundNoise,
            backgroundNoiseOffset: backgroundNoiseOffset
        ))
        if buffer.count >= batchSize {
            flushBuffer()
        }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty, let handle = fileHandle else { return }

        let rows = buffer
        buffer.removeAll(keepingCapacity: true)

        var csv = ""
        csv.reserveCapacity(rows.count * 48)
        for r in rows {
            csv += "\(String(format: "%.6f", r.timestamp))"
            csv += ",\(r.usage)"
            csv += ",\(String(format: "%.4f", r.temperatureCelsius))"
            csv += ",\(r.signalIdentifier)"
            csv += ",\(r.emitter)"
            csv += ",\(r.activePhotodiodeIndexes)"
            csv += ",\(String(format: "%.4f", r.samplingFrequencyHz))"
            csv += ",\(String(format: "%.4f", r.nominalWavelengthNm))"
            csv += ",\(String(format: "%.4f", r.effectiveWavelengthNm))"
            csv += ",\(String(format: "%.8f", r.normalizedReflectance))"
            csv += ",\(r.conditions)"
            csv += ",\(String(format: "%.8f", r.pinkNoise))"
            csv += ",\(String(format: "%.8f", r.whiteNoise))"
            csv += ",\(String(format: "%.8f", r.backgroundNoise))"
            csv += ",\(String(format: "%.8f", r.backgroundNoiseOffset))"
            csv += "\n"
        }

        if let data = csv.data(using: .utf8) {
            handle.write(data)
        }

        print("SK-PPG: Flushed \(rows.count) samples -> \(currentFileURL.lastPathComponent)")
        Logger.shared.append("SK-PPG: Flushed \(rows.count) samples -> \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flushBuffer()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate

extension SensorKitPPGFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("SK-PPG: SensorKit recording successfully started")
        Logger.shared.append("SK-PPG: SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("SK-PPG: SensorKit recording failed: \(error)")
        Logger.shared.append("SK-PPG: SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        print("SK-PPG: Fetch devices callback is called")
        for device in devices {
            print("SK-PPG: Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("SK-PPG: Device: \(device.name) — model: \(device.model)")
        }

        // PPG only exists on the paired Watch.
        let watchDevice = devices.first { $0.model.lowercased().contains("watch") }
            ?? devices.first

        guard let device = watchDevice else {
            print("SK-PPG: No SensorKit devices found")
            return
        }
        print("SK-PPG: Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("SK-PPG: fetchDevices failed: \(error)")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        didFetchResult result: SRFetchResult<AnyObject>
    ) -> Bool {
        guard let samples = result.sample as? [SRPhotoplethysmogramSample] else {
            return true
        }

        print("SK-PPG: Writing \(samples.count) PPG samples")
        Logger.shared.append("SK-PPG: Writing \(samples.count) PPG samples")

        for sample in samples {
            let usageStr = sample.usage.map { $0.rawValue }.joined(separator: "|")
            let tempCelsius = sample.temperature?.converted(to: .celsius).value ?? Double.nan

            for optical in sample.opticalSamples {
                let opticalTimestamp = sample.startDate
                    .addingTimeInterval(Double(optical.nanosecondsSinceStart) / 1_000_000_000)
                    .timeIntervalSince1970
                let photodiodeStr = optical.activePhotodiodeIndexes
                    .map { String($0) }.joined(separator: "|")
                let conditionsStr = optical.conditions
                    .map { $0.rawValue }.joined(separator: "|")
                let noiseTerms = optical.noiseTerms

                bufferSample(
                    timestamp: opticalTimestamp,
                    usage: usageStr,
                    temperatureCelsius: tempCelsius,
                    signalIdentifier: optical.signalIdentifier,
                    emitter: optical.emitter,
                    activePhotodiodeIndexes: photodiodeStr,
                    samplingFrequencyHz: optical.samplingFrequency.converted(to: .hertz).value,
                    nominalWavelengthNm: optical.nominalWavelength.converted(to: .nanometers).value,
                    effectiveWavelengthNm: optical.effectiveWavelength.converted(to: .nanometers).value,
                    normalizedReflectance: optical.normalizedReflectance ?? Double.nan,
                    conditions: conditionsStr,
                    pinkNoise: noiseTerms?.pinkNoise ?? Double.nan,
                    whiteNoise: noiseTerms?.whiteNoise ?? Double.nan,
                    backgroundNoise: noiseTerms?.backgroundNoise ?? Double.nan,
                    backgroundNoiseOffset: noiseTerms?.backgroundNoiseOffset ?? Double.nan
                )
            }
        }
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flushBuffer()
        fileHandle?.synchronizeFile()  // fsync to disk
        print("SK-PPG: Fetch complete")
        Logger.shared.append("SK-PPG: Fetch complete")
    }

    func sensorReader(
        _ reader: SRSensorReader,
        fetching fetchRequest: SRFetchRequest,
        failedWithError error: Error
    ) {
        print("SK-PPG: Fetch failed: \(error)")
        flushBuffer()
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("SK-PPG: SensorKit authorized")
        case .notDetermined: print("SK-PPG: SensorKit not determined")
        case .denied:        print("SK-PPG: SensorKit denied")
        @unknown default: break
        }
    }
}
