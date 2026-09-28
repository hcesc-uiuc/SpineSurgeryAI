//
//  SensorKitFetcher.swift
//  SensingApp
//
//  Generic base class for every SensorKit sensor. Owns the shared
//  record/fetch/CSV/upload-file lifecycle so concrete sensors only declare
//  their config and override rows(from:) to turn a fetch result into CSV lines.
//
//  Add a sensor: subclass this, pass the config in init, override rows(from:),
//  and add the instance to SensorKitRegistry.all. Nothing else changes.
//
//  SensorKit rules that all subclasses inherit:
//   - startRecording() must be called or the OS retains no data.
//   - Fetches respect the 24-hour embargo (window ends 25h in the past).
//   - Data only exists from when recording first started.
//
//  File rules (Issue #74):
//   - A CSV is only created once there is a row to write, so empty fetches
//     never produce header-only files.
//   - The fetch window only advances when a fetch completes; a failed fetch
//     is retried from the same start next time.
//

import SensorKit
import CoreMotion
import Foundation

/// Which device's data to fetch. Motion sensors (accel/rotationRate) can come
/// from the iPhone or a paired Watch; wrist/health sensors come from the Watch.
enum SensorKitDevicePreference {
    case iPhone
    case watch
    case any
}

class SensorKitFetcher: NSObject {

    /// The SensorKit sensor this fetcher reads. Used by SensorKitRegistry to
    /// build the authorization set.
    let sensor: SRSensor

    private let reader: SRSensorReader
    private let filePrefix: String      // e.g. "sensorkit_accel_phone"
    private let csvHeader: String       // e.g. "timestamp_unix,x,y,z"
    private let devicePreference: SensorKitDevicePreference
    private let logTag: String          // e.g. "SK-Accel"
    private let batchSize: Int
    private let maxFileSize: Int

    private let fileIndexKey: String
    private let lastFetchEndKey: String

    /// Extension marking a file this fetcher still owns; the uploader skips these.
    static let partExtension = "part"
    static let partSuffix = ".part"

    private var lineBuffer: [String] = []
    private var fileHandle: FileHandle?
    private var currentFileURL: URL
    private var pendingFetchEnd: Double?   // committed to lastFetchEnd on didCompleteFetch
    private var writeFailed = false        // a flush failed; do not commit the window
    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: fileIndexKey) }
        set { UserDefaults.standard.set(newValue, forKey: fileIndexKey) }
    }
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: lastFetchEndKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastFetchEndKey) }
    }

    init(sensor: SRSensor,
         filePrefix: String,
         csvHeader: String,
         devicePreference: SensorKitDevicePreference,
         logTag: String,
         fileIndexKey: String,
         lastFetchEndKey: String,
         batchSize: Int = 2000,
         maxFileSizeMB: Int = 50) {
        self.sensor           = sensor
        self.reader           = SRSensorReader(sensor: sensor)
        self.filePrefix       = filePrefix
        self.csvHeader        = csvHeader
        self.devicePreference = devicePreference
        self.logTag           = logTag
        self.fileIndexKey     = fileIndexKey
        self.lastFetchEndKey  = lastFetchEndKey
        self.batchSize        = batchSize
        self.maxFileSize      = maxFileSizeMB * 1024 * 1024
        self.currentFileURL   = documentsDir   // placeholder; set in openCurrentFile()
        super.init()
        reader.delegate = self
    }

    // MARK: - Subclass hook

    /// Turn one fetch result into zero or more CSV lines (no trailing newline).
    /// Override in each concrete sensor; the base returns nothing.
    func rows(from result: SRFetchResult<AnyObject>) -> [String] { [] }

    // MARK: - Authorization

    /// This sensor's own authorization status, as reported by SensorKit. A
    /// participant can allow or deny each sensor separately in Settings.
    var authorizationStatus: SRAuthorizationStatus { reader.authorizationStatus }

    private var isAuthorized: Bool { authorizationStatus == .authorized }

    // MARK: - Record / Fetch

    func startRecording() {
        print("\(logTag): Attempting to start sensor recording")
        reader.startRecording()
    }

    func startRecordingWithAuthorizationCheck() {
        guard isAuthorized else {
            print("\(logTag): Sensorkit is not authorized, skipping")
            return
        }
        print("\(logTag): Attempting to start sensor recording")
        reader.startRecording()
    }

    func fetchLatestData() {
        guard isAuthorized else {
            print("\(logTag): Sensorkit is not authorized, skipping")
            Logger.shared.append("\(logTag): Sensorkit is not authorized, skipping")
            return
        }
        print("\(logTag): Sensorkit is authorized, fetching devices")
        Logger.shared.append("\(logTag): Sensorkit is authorized, fetching devices")
        openCurrentFile()
        reader.fetchDevices()
    }

    private func fetchSamples(from device: SRDevice) {
        let now = Date()
        let fetchEnd = now.addingTimeInterval(-25 * 3600)  // respect 24hr embargo
        let fetchStart = lastFetchEnd > 0
            ? Date(timeIntervalSinceReferenceDate: lastFetchEnd)
            : now.addingTimeInterval(-48 * 3600)

        guard fetchStart < fetchEnd else {
            print("\(logTag): No new data window available yet")
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to   = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("\(logTag): Fetching from \(fetchStart) to \(fetchEnd)")
        pendingFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
        writeFailed = false
        reader.fetch(request)
    }

    private func pickDevice(from devices: [SRDevice]) -> SRDevice? {
        switch devicePreference {
        case .iPhone: return devices.first { $0.model.lowercased().contains("iphone") } ?? devices.first
        case .watch:  return devices.first { $0.model.lowercased().contains("watch") } ?? devices.first
        case .any:    return devices.first
        }
    }

    // MARK: - CSV file management

    private func csvFileName(index: Int) -> String {
        "\(filePrefix)_\(String(format: "%05d", index)).csv"
    }

    /// Points at the current CSV, which is written under a ".part" name so the
    /// uploader knows this fetcher still owns it. The file itself is created on
    /// the first flush that has rows (see write(_:)).
    private func openCurrentFile() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex) + Self.partSuffix)
        print("\(logTag): CSV file: \(currentFileURL.lastPathComponent)")
        Logger.shared.append("\(logTag): Current CSV file: \(currentFileURL.lastPathComponent)")
    }

    /// Closes the file and publishes it under its final name. After this the
    /// uploader owns it and the next flush starts a new ".part" file. Renaming
    /// is atomic, so the file is never half handed over.
    func sealCurrentFile() {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
        fileHandle = nil

        let path = currentFileURL.path
        guard currentFileURL.pathExtension == Self.partExtension,
              FileManager.default.fileExists(atPath: path) else { return }

        let sealed = currentFileURL.deletingPathExtension()   // drops ".part"
        do {
            try FileManager.default.moveItem(at: currentFileURL, to: sealed)
            fileIndex += 1                                    // next fetch writes its own file
            print("\(logTag): Sealed \(sealed.lastPathComponent)")
            Logger.shared.append("\(logTag): Sealed \(sealed.lastPathComponent)")
        } catch {
            print("\(logTag): Failed to seal \(currentFileURL.lastPathComponent): \(error)")
            Logger.shared.append("\(logTag): Failed to seal \(currentFileURL.lastPathComponent): \(error)")
        }
        openCurrentFile()
    }

    /// Appends text to the current CSV, creating it with the header first if it
    /// does not exist yet. Returns false when nothing could be written (a full
    /// disk, for example), so the caller can keep the rows and retry the window.
    @discardableResult
    private func write(_ text: String) -> Bool {
        if !FileManager.default.fileExists(atPath: currentFileURL.path) {
            fileHandle?.closeFile()
            fileHandle = nil
            do {
                try (csvHeader + "\n").write(to: currentFileURL, atomically: false, encoding: .utf8)
            } catch {
                print("\(logTag): Could not create \(currentFileURL.lastPathComponent): \(error)")
                return false
            }
        }
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: currentFileURL)
            fileHandle?.seekToEndOfFile()
        }
        guard let handle = fileHandle, let data = text.data(using: .utf8) else { return false }
        do {
            // The throwing API: the non-throwing write(_:) raises an uncatchable
            // Objective-C exception when the disk is full.
            try handle.write(contentsOf: data)
            return true
        } catch {
            print("\(logTag): Write failed: \(error)")
            Logger.shared.append("\(logTag): Write failed: \(error)")
            return false
        }
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileIndex += 1
            openCurrentFile()
            print("\(logTag): Rotated to file index \(fileIndex)")
            Logger.shared.append("\(logTag): Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered write

    private func buffer(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lineBuffer.append(contentsOf: lines)
        if lineBuffer.count >= batchSize { flush() }
    }

    private func flush() {
        guard !lineBuffer.isEmpty else { return }
        let lines = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)

        guard write(lines.joined(separator: "\n") + "\n") else {
            // Keep the rows and remember the failure: the fetch window must not
            // be committed, or this data is never fetched again.
            lineBuffer = lines + lineBuffer
            writeFailed = true
            return
        }
        print("\(logTag): Flushed \(lines.count) rows -> \(currentFileURL.lastPathComponent)")
        Logger.shared.append("\(logTag): Flushed \(lines.count) rows -> \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flush()
        fileHandle?.closeFile()
    }
}

// MARK: - SRSensorReaderDelegate (shared by all sensors)

extension SensorKitFetcher: SRSensorReaderDelegate {

    func sensorReaderWillStartRecording(_ reader: SRSensorReader) {
        print("\(logTag): SensorKit recording successfully started")
        Logger.shared.append("\(logTag): SensorKit recording successfully started")
    }

    func sensorReader(_ reader: SRSensorReader, startRecordingFailedWithError error: Error) {
        print("\(logTag): SensorKit recording failed: \(error)")
        Logger.shared.append("\(logTag): SensorKit recording failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        for device in devices {
            print("\(logTag): Device: \(device.name) — model: \(device.model)")
            Logger.shared.append("\(logTag): Device: \(device.name) — model: \(device.model)")
        }
        guard let device = pickDevice(from: devices) else {
            print("\(logTag): No SensorKit devices found")
            return
        }
        print("\(logTag): Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("\(logTag): fetchDevices failed: \(error)")
    }

    func sensorReader(_ reader: SRSensorReader,
                      fetching fetchRequest: SRFetchRequest,
                      didFetchResult result: SRFetchResult<AnyObject>) -> Bool {
        buffer(rows(from: result))   // subclass decides how to turn the result into lines
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flush()
        sealCurrentFile()               // hands the file to the uploader
        if let end = pendingFetchEnd, !writeFailed {
            lastFetchEnd = end
        } else if writeFailed {
            print("\(logTag): Rows could not be written, window will be retried")
            Logger.shared.append("\(logTag): Rows could not be written, window will be retried")
        }
        pendingFetchEnd = nil
        print("\(logTag): Fetch complete")
        Logger.shared.append("\(logTag): Fetch complete")
    }

    func sensorReader(_ reader: SRSensorReader,
                      fetching fetchRequest: SRFetchRequest,
                      failedWithError error: Error) {
        // Keep lastFetchEnd where it was so the next fetch retries this window.
        // Rows already flushed stay; a retry can repeat some of them.
        pendingFetchEnd = nil
        print("\(logTag): Fetch failed: \(error)")
        Logger.shared.append("\(logTag): Fetch failed, window will be retried: \(error)")
        flush()
        sealCurrentFile()               // a partial batch is still worth uploading
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("\(logTag): SensorKit authorized")
        case .notDetermined: print("\(logTag): SensorKit not determined")
        case .denied:        print("\(logTag): SensorKit denied")
        @unknown default: break
        }
    }
}
