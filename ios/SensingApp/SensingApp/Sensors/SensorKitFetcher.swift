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
    private let fetchChunk: TimeInterval   // longest window asked for in one fetch

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
    private var stamp: SensorKitStamp       // newest sample time → SensorStatusStore
    private var currentDevice: SRDevice?   // device of the running fetch, for the next chunk
    private var currentRequest: SRFetchRequest?   // callbacks for any other request are stale
    private var chunksThisRun = 0
    private var bytesThisRun = 0
    private var rowsThisRun = 0            // rows in committed chunks
    private var chunkRows = 0              // rows of the chunk being fetched
    private var isFetching = false         // a run (all its chunks) is in progress
    private var fetchStartedAt = Date.distantPast

    /// A run is in progress (one that never called back stops counting after 30 min).
    var isRunning: Bool { isFetching && Date().timeIntervalSince(fetchStartedAt) <= 30 * 60 }

    /// When this sensor last finished a run without failing (caught up or
    /// stopped by a limit). BackgroundScheduler's hourly limit waits until
    /// every sensor has one in the last hour, so a failed gyroscope run is
    /// retried even if the cheap sensors succeeded.
    var lastSuccessfulRun: Date? {
        let t = UserDefaults.standard.double(forKey: lastFetchEndKey + "_run_ok")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    private func recordSuccessfulRun() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastFetchEndKey + "_run_ok")
    }

    /// Records how much of the current file belongs to completed chunks. If
    /// the size cannot be read, the previous value stays: recording 0 would
    /// later delete committed chunks.
    private func recordCommittedSize() {
        let key = Self.committedBytesKey(for: currentFileURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: currentFileURL.path) {
            UserDefaults.standard.set(0, forKey: key)
        } else if let size = FileManager.default.currentSize(of: currentFileURL) {
            UserDefaults.standard.set(size, forKey: key)
        }
    }

    /// UserDefaults key holding how many bytes of a ".part" file belong to
    /// committed chunks. Anything after that is a chunk that never completed;
    /// it is cut off on failure, or at the next launch if the app was killed.
    static func committedBytesKey(for partName: String) -> String { "sk_committed_bytes:\(partName)" }

    /// Cuts a ".part" file back to its committed bytes (deleting it if none).
    /// Returns false if it no longer holds anything.
    @discardableResult
    static func trimToCommitted(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        let key = committedBytesKey(for: url.lastPathComponent)
        guard defaults.object(forKey: key) != nil else { return true }
        let committed = UInt64(max(0, defaults.integer(forKey: key)))
        if committed == 0 {
            try? FileManager.default.removeItem(at: url)
            defaults.removeObject(forKey: key)
            return false
        }
        // Never grow the file (truncating past the end pads it with zeros)
        let size = UInt64(FileManager.default.currentSize(of: url) ?? 0)
        if committed < size {
            do {
                let h = try FileHandle(forWritingTo: url)
                try h.truncate(atOffset: committed)
                try h.close()
            } catch {
                // Keep the key so the next launch tries again
                Logger.shared.append("Could not cut \(url.lastPathComponent) back to \(committed) bytes: \(error)")
                return true
            }
        }
        defaults.removeObject(forKey: key)
        return true
    }

    /// Stops one run from chaining forever (the 250 MB limit usually comes first).
    static let maxChunksPerRun = 200

    /// Shortest window worth a fetch.
    static let minWindow: TimeInterval = 5 * 60

    /// One run stops chaining after writing this much, or when the phone has
    /// less than minFreeBytes left. Catching up a week of gyroscope is ~1 GB;
    /// later runs continue once uploads have caught up.
    static let maxBytesPerRun = 250 * 1024 * 1024
    static let minFreeBytes: Int64 = 1024 * 1024 * 1024

    static func shouldChain(chunks: Int, bytesThisRun: Int, freeBytes: Int64?) -> Bool {
        guard chunks < maxChunksPerRun, bytesThisRun < maxBytesPerRun else { return false }
        if let freeBytes, freeBytes < minFreeBytes { return false }
        return true
    }
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
         kind: SensorKind,
         filePrefix: String,
         csvHeader: String,
         devicePreference: SensorKitDevicePreference,
         logTag: String,
         fileIndexKey: String,
         lastFetchEndKey: String,
         batchSize: Int = 2000,
         maxFileSizeMB: Int = 50,
         fetchChunkHours: Double = 6) {
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
        self.fetchChunk       = fetchChunkHours * 3600
        self.currentFileURL   = documentsDir   // placeholder; set in openCurrentFile()
        self.stamp            = SensorKitStamp(kind)
        self.stamp.recordsRunOnSave = false    // runs are recorded in finishRun below
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
        // A second run on top of one in progress would share pendingFetchEnd
        // and could commit a window before its rows are written.
        // A run that never called back (the app was suspended mid-fetch) stops
        // counting after 30 min.
        guard !isFetching || Date().timeIntervalSince(fetchStartedAt) > 30 * 60 else {
            print("\(logTag): Fetch already running, skipping")
            Logger.shared.append("\(logTag): Fetch already running, skipping")
            return
        }
        isFetching = true
        fetchStartedAt = Date()
        print("\(logTag): Sensorkit is authorized, fetching devices")
        Logger.shared.append("\(logTag): Sensorkit is authorized, fetching devices")
        openCurrentFile()
        chunksThisRun = 0
        bytesThisRun = 0
        rowsThisRun = 0
        reader.fetchDevices()
    }

    /// The next window to fetch, at most `chunk` long, or nil if nothing new is
    /// out of the 24 h embargo yet. A big window (a high-rate sensor, or days
    /// behind) can take longer than iOS lets the app run; it then never
    /// completes, lastFetchEnd never moves, and every run re-reads the same
    /// start. Short chunks each commit on their own.
    static func nextWindow(lastFetchEnd: Double, now: Date,
                           chunk: TimeInterval) -> (from: Date, to: Date)? {
        let limit = now.addingTimeInterval(-25 * 3600)    // respect 24hr embargo
        let oldest = now.addingTimeInterval(-7 * 24 * 3600) // SensorKit keeps 7 days
        let start = lastFetchEnd > 0
            ? max(Date(timeIntervalSinceReferenceDate: lastFetchEnd), oldest)
            : now.addingTimeInterval(-48 * 3600)
        // Less than 5 min new: wait. Otherwise a caught-up sensor keeps finding
        // the few seconds the embargo moved during its last chunk.
        guard limit.timeIntervalSince(start) >= minWindow else { return nil }
        return (start, min(start.addingTimeInterval(chunk), limit))
    }

    private func fetchSamples(from device: SRDevice) {
        currentDevice = device
        guard let window = Self.nextWindow(lastFetchEnd: lastFetchEnd, now: Date(), chunk: fetchChunk) else {
            print("\(logTag): No new data window available yet")
            isFetching = false
            recordSuccessfulRun()
            return
        }
        let (fetchStart, fetchEnd) = window
        // Everything in the file now belongs to committed chunks
        recordCommittedSize()

        let request = SRFetchRequest()
        request.device = device
        request.from = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchStart.timeIntervalSinceReferenceDate)
        request.to   = SRAbsoluteTime.fromCFAbsoluteTime(_cf: fetchEnd.timeIntervalSinceReferenceDate)

        print("\(logTag): Fetching from \(fetchStart) to \(fetchEnd)")
        Logger.shared.append("\(logTag): Fetching \(fetchStart.formatted(date: .abbreviated, time: .shortened)) - \(fetchEnd.formatted(date: .omitted, time: .shortened))")
        pendingFetchEnd = fetchEnd.timeIntervalSinceReferenceDate
        writeFailed = false
        chunkRows = 0
        currentRequest = request
        reader.fetch(request)
    }

    private func freeDiskBytes() -> Int64? {
        try? documentsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
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

        do {
            let sealed = try FileManager.default.seal(currentFileURL)
            UserDefaults.standard.removeObject(forKey: Self.committedBytesKey(for: currentFileURL.lastPathComponent))
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
            bytesThisRun += data.count
            return true
        } catch {
            print("\(logTag): Write failed: \(error)")
            Logger.shared.append("\(logTag): Write failed: \(error)")
            return false
        }
    }

    /// Drops the rows of the chunk that did not complete, then hands what was
    /// committed to the uploader. A retry fetches that chunk again in full, so
    /// keeping its partial rows would only upload them twice.
    private func discardUncommittedChunk() {
        lineBuffer.removeAll(keepingCapacity: true)
        fileHandle?.closeFile()
        fileHandle = nil
        if Self.trimToCommitted(currentFileURL) {
            sealCurrentFile()
        } else {
            openCurrentFile()
        }
    }

    private func rotateFileIfNeeded() {
        guard let size = FileManager.default.currentSize(of: currentFileURL) else { return }
        if size >= maxFileSize {
            // Seal, not just switch files: a full file left as ".part" is never uploaded.
            sealCurrentFile()
            print("\(logTag): Rotated to file index \(fileIndex)")
            Logger.shared.append("\(logTag): Rotated to file index \(fileIndex)")
        }
    }

    // MARK: - Buffered write

    private func buffer(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lineBuffer.append(contentsOf: lines)
        chunkRows += lines.count
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
        // No rotation here: a chunk stays in one file so it can be cut off
        // whole if it fails. didCompleteFetch rotates between chunks.
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
            isFetching = false
            return
        }
        print("\(logTag): Using device: \(device.name) (\(device.model))")
        fetchSamples(from: device)
    }

    func sensorReader(_ reader: SRSensorReader, fetchDevicesDidFailWithError error: Error) {
        print("\(logTag): fetchDevices failed: \(error)")
        isFetching = false
    }

    func sensorReader(_ reader: SRSensorReader,
                      fetching fetchRequest: SRFetchRequest,
                      didFetchResult result: SRFetchResult<AnyObject>) -> Bool {
        guard fetchRequest === currentRequest else { return false }   // stale: stop it
        buffer(rows(from: result))   // subclass decides how to turn the result into lines
        stamp.saw(result)
        return true
    }

    func sensorReader(_ reader: SRSensorReader, didCompleteFetch fetchRequest: SRFetchRequest) {
        guard fetchRequest === currentRequest else {
            Logger.shared.append("\(logTag): Ignored completion of an abandoned fetch")
            return
        }
        currentRequest = nil
        flush()
        fileHandle?.synchronizeFile()   // rows on disk before the window is committed
        if writeFailed {
            print("\(logTag): Rows could not be written, window will be retried")
            Logger.shared.append("\(logTag): Rows could not be written, window will be retried")
            pendingFetchEnd = nil
            isFetching = false
            discardUncommittedChunk()
            finishRun(stopReason: "write failed", failed: true)
            return
        }
        if let end = pendingFetchEnd {
            // Size first: if the app dies between the two, the chunk is kept
            // and fetched again (duplicates), never cut off after its window
            // moved on (loss).
            recordCommittedSize()
            lastFetchEnd = end
            rowsThisRun += chunkRows
            chunkRows = 0
        }
        pendingFetchEnd = nil
        stamp.save()
        rotateFileIfNeeded()            // between chunks only, see flush()

        // More to catch up on: fetch the next chunk into the same file. If iOS
        // suspends the app meanwhile, only that chunk is fetched again.
        chunksThisRun += 1
        let free = freeDiskBytes()
        let more = Self.nextWindow(lastFetchEnd: lastFetchEnd, now: Date(), chunk: fetchChunk) != nil
        if more, let device = currentDevice,
           Self.shouldChain(chunks: chunksThisRun, bytesThisRun: bytesThisRun, freeBytes: free) {
            // Not from inside this callback: SensorKit does not document
            // starting a fetch from didCompleteFetch.
            DispatchQueue.main.async { self.fetchSamples(from: device) }
            return
        }

        isFetching = false
        recordSuccessfulRun()
        sealCurrentFile()               // hands the file to the uploader
        let reason = Self.stopReason(caughtUp: !more, chunks: chunksThisRun,
                                     bytesThisRun: bytesThisRun, freeBytes: free)
        print("\(logTag): Fetch complete (\(chunksThisRun) chunk(s), stopped: \(reason))")
        finishRun(stopReason: reason, failed: false)
    }

    /// Records this run (SensorRunLog, shown on the status screen) and logs
    /// one summary line for it.
    private func finishRun(stopReason: String, failed: Bool) {
        let r = stamp.finishRun(samples: rowsThisRun, unit: "rows", chunks: chunksThisRun,
                                megabytes: bytesThisRun / 1_000_000,
                                stopReason: stopReason, failed: failed)
        Logger.shared.append("\(logTag): \(failed ? "Fetch failed" : "Fetch complete") (\(r.trigger)): "
            + "\(r.chunks ?? 0) chunk(s), \(SensorRunLog.describe(r)), \(r.megabytes ?? 0) MB, "
            + "stopped: \(stopReason), \(freeSpaceText())")
    }

    /// Why a run stopped chaining, for the log.
    static func stopReason(caughtUp: Bool, chunks: Int, bytesThisRun: Int, freeBytes: Int64?) -> String {
        if caughtUp { return "caught up" }
        if chunks >= maxChunksPerRun { return "chunk limit" }
        if bytesThisRun >= maxBytesPerRun { return "250 MB run limit" }
        if let freeBytes, freeBytes < minFreeBytes { return "low storage" }
        return "no device"
    }

    private func freeSpaceText() -> String {
        guard let free = freeDiskBytes() else { return "free space unknown" }
        return "\(free / 1_000_000) MB free"
    }

    func sensorReader(_ reader: SRSensorReader,
                      fetching fetchRequest: SRFetchRequest,
                      failedWithError error: Error) {
        guard fetchRequest === currentRequest else {
            Logger.shared.append("\(logTag): Ignored failure of an abandoned fetch")
            return
        }
        currentRequest = nil
        // Keep lastFetchEnd where it was so the next fetch retries this window,
        // and drop this chunk's rows so the retry does not duplicate them.
        pendingFetchEnd = nil
        isFetching = false
        print("\(logTag): Fetch failed: \(error)")
        Logger.shared.append("\(logTag): Fetch failed after \(chunksThisRun) chunk(s), window will be retried: \(error)")
        discardUncommittedChunk()
        finishRun(stopReason: "failed: \((error as NSError).localizedDescription)", failed: true)
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
