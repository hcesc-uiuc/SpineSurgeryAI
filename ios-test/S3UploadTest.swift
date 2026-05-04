// S3UploadTest.swift
// Drop this into a new single-view SwiftUI Xcode project (iOS target).
// Run on simulator or device — tap the buttons in order to verify the full flow.

import SwiftUI
import Combine

// MARK: - Config
private let baseURL = "http://18.116.67.186"
private let presignURL = "\(baseURL)/api/noauth/uploads/presign"
private let completeURL = "\(baseURL)/api/noauth/uploads/complete"
private let participantID = "P0001"   // change to a real test participant

// MARK: - Models
private struct PresignResponse: Codable {
    let upload_id: String
    let key: String
    let url: String
    let headers: [String: String]
    let expires_in: Int
}

private struct CompleteResponse: Codable {
    let status: String
    let key: String?
    let error: String?
}

// MARK: - Uploader
private actor S3TestUploader {

    // Creates a small dummy CSV in the temp directory and uploads it.
    func runFullFlow(kind: String, log: @escaping (String) -> Void) async {
        log("--- Starting \(kind) upload flow ---")

        // 1. Write a dummy file to disk
        let filename = "\(kind)_test_\(Int(Date().timeIntervalSince1970)).csv"
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let csvContent = "timestamp,x,y,z\n0,0.1,0.2,0.3\n1,0.4,0.5,0.6\n"
        try? csvContent.write(to: tmpURL, atomically: true, encoding: .utf8)
        log("Created dummy file: \(filename) (\(csvContent.utf8.count) bytes)")

        // 2. Presign
        log("Step 1: Requesting presigned URL...")
        guard let presign = await requestPresign(filename: filename, kind: kind, log: log) else { return }
        log("  upload_id: \(presign.upload_id)")
        log("  key: \(presign.key)")

        // 3. PUT to S3
        log("Step 2: Uploading to S3...")
        let s3Success = await putToS3(presign: presign, fileURL: tmpURL, log: log)
        log("  S3 PUT success: \(s3Success)")

        // 4. Complete
        log("Step 3: Notifying server of result...")
        await notifyComplete(uploadID: presign.upload_id, success: s3Success, log: log)

        log("--- Done ---\n")
    }

    private func requestPresign(filename: String, kind: String, log: (String) -> Void) async -> PresignResponse? {
        guard let url = URL(string: presignURL) else {
            log("ERROR: invalid presign URL")
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "participantId": participantID,
            "filename": filename,
            "content_type": "text/csv",
            "kind": kind
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("  presign HTTP status: \(status)")
            if let raw = String(data: data, encoding: .utf8) {
                log("  presign response: \(raw)")
            }
            guard status == 201 else {
                log("ERROR: expected 201 from presign")
                return nil
            }
            return try JSONDecoder().decode(PresignResponse.self, from: data)
        } catch {
            log("ERROR presign: \(error)")
            return nil
        }
    }

    private func putToS3(presign: PresignResponse, fileURL: URL, log: (String) -> Void) async -> Bool {
        guard let s3URL = URL(string: presign.url) else {
            log("ERROR: invalid S3 URL")
            return false
        }
        var req = URLRequest(url: s3URL)
        req.httpMethod = "PUT"
        for (k, v) in presign.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("  S3 PUT HTTP status: \(status)")
            return status == 200
        } catch {
            log("ERROR S3 PUT: \(error)")
            return false
        }
    }

    private func notifyComplete(uploadID: String, success: Bool, log: (String) -> Void) async {
        guard let url = URL(string: completeURL) else {
            log("ERROR: invalid complete URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["upload_id": uploadID, "success": success]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            log("  complete HTTP status: \(status)")
            if let raw = String(data: data, encoding: .utf8) {
                log("  complete response: \(raw)")
            }
        } catch {
            log("ERROR complete: \(error)")
        }
    }
}

// MARK: - ViewModel
private class TestViewModel: ObservableObject {
    @Published var logs: String = "Tap a button to run a test.\n"
    @Published var isRunning = false

    private let uploader = S3TestUploader()

    func run(kind: String) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await uploader.runFullFlow(kind: kind) { line in
                DispatchQueue.main.async { [weak self] in
                    self?.logs += line + "\n"
                }
            }
            await MainActor.run { self.isRunning = false }
        }
    }

    func runAll() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            for kind in ["accel", "gyro", "hr"] {
                await uploader.runFullFlow(kind: kind) { line in
                    DispatchQueue.main.async { [weak self] in
                        self?.logs += line + "\n"
                    }
                }
            }
            await MainActor.run { self.isRunning = false }
        }
    }

    func clear() { logs = "" }
}

// MARK: - View
struct S3UploadTestView: View {
    @StateObject private var vm = TestViewModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("S3 Upload Test")
                .font(.headline)
                .padding(.top)

            HStack(spacing: 8) {
                ForEach(["accel", "gyro", "hr"], id: \.self) { kind in
                    Button(kind) { vm.run(kind: kind) }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isRunning)
                }
            }

            HStack(spacing: 8) {
                Button("Run All") { vm.runAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(vm.isRunning)

                Button("Clear") { vm.clear() }
                    .buttonStyle(.bordered)
                    .disabled(vm.isRunning)
            }

            if vm.isRunning {
                ProgressView("Running...")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.logs)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("logs")
                }
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)
                .onChange(of: vm.logs) { _ in
                    proxy.scrollTo("logs", anchor: .bottom)
                }
            }

            Spacer()
        }
        .padding(.bottom)
    }
}

// MARK: - App entry point (use this as your @main if making a standalone project)
// @main
// struct S3UploadTestApp: App {
//     var body: some Scene {
//         WindowGroup { S3UploadTestView() }
//     }
// }
