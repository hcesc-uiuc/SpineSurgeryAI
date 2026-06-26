//
//  SensorKit_AccelWatch.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 5/15/26.
//
/*
 SensorKit — The Critical Reality

 SensorKit is research-gated: it needs Apple's private entitlement
 (com.apple.developer.sensorkit.reader.allow), reviewed per study.

 The OS records the paired Apple Watch passively, 24/7. Your app does NOT
 record — it FETCHES historical data, and only data older than a 24-hour
 embargo. So this is a retrospective batch pipeline, never real-time:

   Apple Watch (records 24/7)
       ↓  [24hr embargo]
   iPhone SensorKit daemon
       ↓  SRSensorReader.fetch()  (async, via delegate callbacks)
   SensorKitFetcher subclass → CSV in Documents/to-be-processed/
       ↓
   Uploader → S3

 ──────────────────────────────────────────────────────────────────────────
 ARCHITECTURE

 `SensorKitFetcher` (below) is a reusable base class that owns everything
 generic to every SensorKit sensor: device selection, the embargo-aware
 time window, batched CSV writing, file rotation, and one-shot completion.

 To add a new sensor you subclass it and override exactly one method —
 `parse(_:)` — to turn that sensor's sample type into CSV lines. See
 `SensorKitAccelerometerFetcher` at the bottom for the full example; a new
 sensor is ~10 lines.
 */

import SensorKit
import CoreMotion
import Foundation

// ============================================================
// MARK: - SensorKitFetcher (reusable base)
// ============================================================

class SensorKitFetcher: NSObject {

    private let reader: SRSensorReader
    private let filePrefix: String     // e.g. "sensorkit_accel_watch"
    private let csvHeader: String      // e.g. "timestamp_unix,x,y,z"

    private let batchSize = 1000
    private let maxFileSize = 50 * 1024 * 1024   // 50 MB per CSV file

    // Pending CSV lines, flushed to disk in batches.
    private var lineBuffer: [String] = []

    private var fileHandle: FileHandle?
    private var currentFileURL: URL

    private let documentsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]

    // Per-sensor UserDefaults keys, so different sensors never clobber each
    // other's file index or fetch cursor.
    private var fileIndexKey: String    { "sk_\(filePrefix)_file_index" }
    private var lastFetchEndKey: String { "sk_\(filePrefix)_last_fetch_end" }

    private var fileIndex: Int {
        get { UserDefaults.standard.integer(forKey: fileIndexKey) }
        set { UserDefaults.standard.set(newValue, forKey: fileIndexKey) }
    }
    // Where the previous fetch left off (CoreFoundation reference time).
    private var lastFetchEnd: Double {
        get { UserDefaults.standard.double(forKey: lastFetchEndKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastFetchEndKey) }
    }

    // One-shot completion. SensorKit's fetch is fully asynchronous — the
    // result arrives via delegate callbacks long after fetchLatestData()
    // returns, so the CALLER must keep this object alive until `completion`
    // fires. finish(_:) guarantees it runs exactly once, on the main queue.
    private var fetchCompletion: ((Bool) -> Void)?
    private var didFinish = false

    init(sensor: SRSensor, filePrefix: String, csvHeader: String) {
        self.reader = SRSensorReader(sensor: sensor)
        self.filePrefix = filePrefix
        self.csvHeader = csvHeader
        self.currentFileURL = documentsDir   // placeholder; set in openCurrentFile()
        super.init()
        reader.delegate = self
        openCurrentFile()
    }

    // MARK: - Subclass hook

    /// Turn one fetch result into zero or more CSV lines (no trailing newline).
    /// Override this in each concrete sensor. The base returns nothing.
    func parse(_ result: SRFetchResult<AnyObject>) -> [String] { [] }

    // MARK: - Public entry point

    /// Begins an asynchronous fetch. `completion` runs exactly once when the
    /// fetch finishes, fails, or finds no new data. `true` = data fetched (or
    /// nothing new); `false` = error. The caller MUST retain this fetcher
    /// until `completion` fires.
    func fetchLatestData(completion: ((Bool) -> Void)? = nil) {
        self.fetchCompletion = completion
        self.didFinish = false
        reader.fetchDevices()
    }

    private func finish(_ success: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            let completion = self.fetchCompletion
            self.fetchCompletion = nil
            completion?(success)
        }
    }

    // MARK: - Fetch window (respects the 24hr embargo)

    private func fetchSamples(from device: SRDevice) {
        // now ──┐
        //       │ can't fetch (24hr embargo)
        // now-25h  ← fetchEnd (safe margin past embargo)
        //       │ fetchable window
        // lastFetchEnd (or now-48h on first run) ← fetchStart
        let now = Date()
        let fetchEnd = now.addingTimeInterval(-25 * 3600)
        let fetchStart: Date = lastFetchEnd > 0
            ? Date(timeIntervalSinceReferenceDate: lastFetchEnd)
            : now.addingTimeInterval(-48 * 3600)

        guard fetchStart < fetchEnd else {
            print("[\(filePrefix)] No new data window available yet")
            finish(true)   // nothing to do is still a successful run
            return
        }

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to   = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("[\(filePrefix)] Fetching \(fetchStart) → \(fetchEnd)")
        reader.fetch(request)

        // Advance the cursor so we never re-fetch this window.
        lastFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
    }

    // MARK: - CSV file management

    private func csvFileName(index: Int) -> String {
        "\(filePrefix)_\(String(format: "%05d", index)).csv"
    }

    private func openCurrentFile() {
        currentFileURL = documentsDir
            .appendingPathComponent("to-be-processed")
            .appendingPathComponent(csvFileName(index: fileIndex))

        if !FileManager.default.fileExists(atPath: currentFileURL.path) {
            try? (csvHeader + "\n").write(to: currentFileURL, atomically: false, encoding: .utf8)
        }
        fileHandle = try? FileHandle(forWritingTo: currentFileURL)
        fileHandle?.seekToEndOfFile()
        print("[\(filePrefix)] CSV file: \(currentFileURL.lastPathComponent)")
    }

    private func rotateFileIfNeeded() {
        guard let size = try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
        if size >= maxFileSize {
            fileHandle?.closeFile()
            fileIndex += 1
            openCurrentFile()
            print("[\(filePrefix)] Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered write

    private func buffer(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lineBuffer.append(contentsOf: lines)
        if lineBuffer.count >= batchSize { flush() }
    }

    private func flush() {
        guard !lineBuffer.isEmpty, let handle = fileHandle else { return }
        let csv = lineBuffer.joined(separator: "\n") + "\n"
        let count = lineBuffer.count
        lineBuffer.removeAll(keepingCapacity: true)
        if let data = csv.data(using: .utf8) { handle.write(data) }
        print("[\(filePrefix)] Flushed \(count) lines → \(currentFileURL.lastPathComponent)")
        rotateFileIfNeeded()
    }

    deinit {
        flush()
        fileHandle?.closeFile()
    }

    // MARK: - Debug helper

    func listCSVFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: documentsDir.appendingPathComponent("to-be-processed"),
            includingPropertiesForKeys: [.fileSizeKey]
        ))?.filter { $0.lastPathComponent.hasPrefix(filePrefix) } ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("  \(url.lastPathComponent) — \(size / 1024) KB")
        }
    }
}

// MARK: - SRSensorReaderDelegate (shared by all sensors)

extension SensorKitFetcher: SRSensorReaderDelegate {

    func sensorReader(_ reader: SRSensorReader, didFetch devices: [SRDevice]) {
        let watch = devices.first { $0.model.lowercased().contains("watch") } ?? devices.first
        guard let device = watch else {
            print("[\(filePrefix)] No SensorKit devices found")
            finish(true)   // no paired device is not an error; nothing to fetch
            return
        }
        print("[\(filePrefix)] Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("[\(filePrefix)] fetchDevices failed: \(error)")
        CrashReporter.record(error, context: "SensorKit.fetchDevices.\(filePrefix)")
        finish(false)
    }

    func sensorReader(_ reader: SRSensorReader,
                      fetching fetchRequest: SRFetchRequest,
                      didFetchResult result: SRFetchResult<AnyObject>) -> Bool {
        buffer(parse(result))   // subclass decides how to turn the result into lines
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        flush()
        fileHandle?.synchronizeFile()   // fsync to disk
        print("[\(filePrefix)] Fetch complete. Files:")
        listCSVFiles()
        finish(true)
    }

    func sensorReader(_ reader: SRSensorReader,
                      fetching fetchRequest: SRFetchRequest,
                      failedWithError error: Error) {
        print("[\(filePrefix)] Fetch failed: \(error)")
        CrashReporter.record(error, context: "SensorKit.fetch.\(filePrefix)")
        flush()
        finish(false)
    }

    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        switch authorizationStatus {
        case .authorized:    print("[\(filePrefix)] authorized")
        case .notDetermined: print("[\(filePrefix)] not determined")
        case .denied:        print("[\(filePrefix)] denied")
        @unknown default: break
        }
    }
}

// ============================================================
// MARK: - Accelerometer (concrete sensor)
// ============================================================
//
// A complete sensor is just: pick the SRSensor, name the file + header,
// and override parse(_:) for this sensor's sample type. That's it.
//
final class SensorKitAccelerometerFetcher: SensorKitFetcher {

    init() {
        super.init(
            sensor: .accelerometer,
            filePrefix: "sensorkit_accel_watch",
            csvHeader: "timestamp_unix,x,y,z"
        )
    }

    // The accelerometer is unusual: each result carries a *batch* of samples
    // (it's very high-frequency). Most other sensors deliver one sample per
    // result, so their parse() has no inner loop.
    override func parse(_ result: SRFetchResult<AnyObject>) -> [String] {
        guard let samples = result.sample as? [CMRecordedAccelerometerData] else { return [] }
        return samples.map { sample in
            let t = sample.startDate.timeIntervalSince1970
            let a = sample.acceleration
            return "\(String(format: "%.6f", t)),"
                 + "\(String(format: "%.8f", a.x)),"
                 + "\(String(format: "%.8f", a.y)),"
                 + "\(String(format: "%.8f", a.z))"
        }
    }
}
