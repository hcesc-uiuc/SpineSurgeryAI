//
//  HarnessRunner.swift
//  s3uploadtest  —  Issue #69: S3 Upload Test Harness
//
//  Purpose: reproduce the DEPLOYED app's upload behaviour with KNOWN input
//  data. The app records sensor files on-device and some uploads fail; this
//  harness removes the recording variable by pulling fixed fixture files from
//  an S3 prefix (listed by manifest.json) and replaying each one through the
//  SAME upload code the app uses (the vendored S3Uploader.swift / Uploader.swift):
//
//      accel, other  -> S3TestUploader.runFullFlow  (presign -> PUT -> complete)
//      loc,   hk     -> Uploader.shared.uploadFile  (multipart /uploadfile)
//
//  The kind routing mirrors Uploader.uploadFolder exactly, so whatever breaks
//  in the field breaks here too — but now against controlled inputs, with the
//  per-step HTTP statuses shown on screen.
//

import SwiftUI
import Foundation
import Combine

// MARK: - Models

/// One line of the manifest.json served from the S3 fixtures prefix.
/// `content_type` is informational only: the harness deliberately sends exactly
/// what the app sends (S3TestUploader hardcodes text/csv; uploadFile uses the
/// file's mimetype), so the reproduction stays faithful.
struct ManifestEntry: Codable, Identifiable {
    let filename: String
    let kind: String
    let contentType: String?
    let url: String

    var id: String { filename }

    enum CodingKeys: String, CodingKey {
        case filename, kind, url
        case contentType = "content_type"
    }
}

/// Result of replaying one fixture through the real upload path.
struct HarnessResult: Identifiable {
    enum Outcome { case pending, running, passed, failed }
    let id = UUID()
    let filename: String
    let kind: String
    let path: String        // "presign" or "multipart"
    var outcome: Outcome
    var detail: String
}

// MARK: - Runner

@MainActor
final class HarnessRunner: ObservableObject {

    @Published var manifestURL: String
    @Published var results: [HarnessResult] = []
    @Published var log: String = ""
    @Published var isRunning = false

    /// Kinds the app routes through the presigned-S3 path (everything else goes
    /// through the multipart /uploadfile path). Mirrors Uploader.uploadFolder.
    private static let presignKinds: Set<String> = ["accel", "other"]

    private let manifestKey = "issue69_manifest_url"

    init() {
        manifestURL = UserDefaults.standard.string(forKey: manifestKey)
            ?? "https://YOUR-BUCKET.s3.us-east-2.amazonaws.com/test-fixtures/manifest.json"
        // Deterministic test participant so backend rows from the harness are
        // easy to spot and purge. Uses the app's real hashing.
        ParticipantID.store(forAppleUserID: "issue69-harness")
    }

    func runAll() {
        guard !isRunning else { return }
        UserDefaults.standard.set(manifestURL, forKey: manifestKey)
        isRunning = true
        results = []
        log = ""
        Task {
            await run()
            isRunning = false
        }
    }

    func clear() {
        guard !isRunning else { return }
        results = []
        log = ""
    }

    private func append(_ line: String) { log += line + "\n" }

    private func run() async {
        append("Target backend: \(S3UploadConfig.baseURL)")
        append("Participant:    \(ParticipantID.current)")
        append("Manifest:       \(manifestURL)")
        append("")

        guard let entries = await fetchManifest() else {
            append("Aborted: could not load manifest.")
            return
        }
        append("Manifest listed \(entries.count) file(s).")
        append("")

        results = entries.map {
            HarnessResult(
                filename: $0.filename,
                kind: $0.kind,
                path: Self.presignKinds.contains($0.kind) ? "presign" : "multipart",
                outcome: .pending,
                detail: ""
            )
        }

        // Surface the vendored code's own print() step logs (presign / PUT /
        // complete HTTP statuses) on screen. Best-effort: pass/fail below is
        // authoritative regardless.
        let capture = StdoutCapture { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        capture.start()
        defer { capture.stop() }

        for (i, entry) in entries.enumerated() {
            results[i].outcome = .running
            append("[\(i + 1)/\(entries.count)] \(entry.filename)  (kind=\(entry.kind), path=\(results[i].path))")

            guard let localURL = await download(entry) else {
                results[i].outcome = .failed
                results[i].detail = "download failed"
                append("  => FAIL (download)")
                append("")
                continue
            }

            let ok: Bool
            if Self.presignKinds.contains(entry.kind) {
                ok = await S3TestUploader().runFullFlow(filenameURL: localURL, kind: entry.kind)
            } else {
                ok = await Uploader.shared.uploadFile(fileURL: localURL)
            }

            results[i].outcome = ok ? .passed : .failed
            results[i].detail = ok ? "ok" : "upload failed (see log)"
            append("  => \(ok ? "PASS" : "FAIL")")
            append("")
        }

        let passed = results.filter { $0.outcome == .passed }.count
        append("Done. \(passed)/\(results.count) passed.")
    }

    private func fetchManifest() async -> [ManifestEntry]? {
        guard let url = URL(string: manifestURL) else {
            append("ERROR: invalid manifest URL")
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                append("ERROR: manifest HTTP \(status)")
                return nil
            }
            return try JSONDecoder().decode([ManifestEntry].self, from: data)
        } catch {
            append("ERROR fetching manifest: \(error.localizedDescription)")
            return nil
        }
    }

    /// Download a fixture to the temp dir under its real filename, so the
    /// uploaded object key matches the fixture name.
    private func download(_ entry: ManifestEntry) async -> URL? {
        guard let url = URL(string: entry.url) else {
            append("  invalid file URL")
            return nil
        }
        do {
            let (tmp, response) = try await URLSession.shared.download(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                append("  download HTTP \(status)")
                return nil
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            append("  download error: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - stdout capture

/// Redirects C stdout (where the vendored uploaders' `print` output goes) into a
/// pipe so the real per-step logs appear in the on-screen log, while still
/// echoing to the Xcode console. Best-effort and self-contained; if attaching
/// fails, the harness results are unaffected.
final class StdoutCapture {
    private let pipe = Pipe()
    private var savedFD: Int32 = -1
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func start() {
        savedFD = dup(fileno(stdout))
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Echo back to the real console.
            if self.savedFD >= 0 {
                data.withUnsafeBytes { _ = write(self.savedFD, $0.baseAddress, data.count) }
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                self.onLine("    " + raw.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        if savedFD >= 0 {
            dup2(savedFD, fileno(stdout))
            close(savedFD)
            savedFD = -1
        }
    }
}
