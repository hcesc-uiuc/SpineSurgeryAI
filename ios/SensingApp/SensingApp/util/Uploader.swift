//
//  Uploader.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 11/5/25.
//

import Foundation


struct Uploader {
    
    static let shared = Uploader()
    //static let UploadURL = "http://18.116.67.186/api/noauth/uploadfile"
    static let UploadURL = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws/api/noauth/uploadfile"
    //static let UploadURL = "http://18.116.67.186/api/noauth/uploadfile/accel"
    //    static let UploadURL = "https://rvsh5s5hg66ezcom2itcz7a27y0smcig.lambda-url.us-east-2.on.aws/api/noauth/uploadfile/accel"
    
    
    func uploadFolder() async {
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let toBeProcessedURL = documentsURL.appendingPathComponent("to-be-processed")
        let processedURL = documentsURL.appendingPathComponent("processed")
        
        let uploader = S3TestUploader()
        
        // Create the "processed" directory if it doesn't already exist
        if !fileManager.fileExists(atPath: processedURL.path) {
            try? fileManager.createDirectory(at: processedURL, withIntermediateDirectories: true)
        }
        
        //let file_prefixes = ["accelerometer_"] //, "log_"] //add more extension in future
        //let file_prefixes = ["log_"] //add more extension in future
        let file_prefixes = ["locations_", "accelerometer_", "healthkit_", "sqlite_", "sensorkit_"]
        //let kinds = ["location", "accelerometer", "healthkit"]
        let kinds = [
            "locations_": "loc",
            "accelerometer_": "accel",
            "healthkit_": "hk",
            "sqlite_": "other",
            "sensorkit_": "other",
        ]
        
        for file_prefix in file_prefixes {
            let matchingFiles = filesWithPrefix(in: toBeProcessedURL, prefix: file_prefix)
            let numberOfFiles = matchingFiles.count
            for (index, file) in matchingFiles.enumerated() {

                // Files a writer still owns never reach here: filesWithPrefix
                // returns sealed files only (see Uploader.isSealed). The old
                // "skip today's file" name check only ever matched locations_
                // and healthkit_, never sensorkit_, accelerometer_ or sqlite_.

                // A SensorKit CSV with only its header has nothing to upload yet;
                // leave it for the fetcher to append to.
                if file_prefix == "sensorkit_" && file.pathExtension == "csv" && !Uploader.hasDataRows(file) {
                    print("\(file.lastPathComponent) has no data rows yet, skipping")
                    continue
                }

                if let size = fileSize(from: file) {
                    let fileSizeInKB = Int(Double(size) / 1024)
                    print("\(index+1)/\(numberOfFiles) Uploading file: \(file.lastPathComponent); \(fileSizeInKB)KB")
                    
                    let kind = kinds[file_prefix]!
                    if kind == "accel" || kind == "other"{
                        //Direct S3 upload
                        let uploadSuccess = await uploader.runFullFlow(filenameURL: file, kind: kind)
                        if uploadSuccess {
                            // Move the file to "processed/" so it isn't re-uploaded on the next run
                            let destination = Uploader.processedDestination(for: file, in: processedURL)
                            do {
                                try fileManager.moveItem(at: file, to: destination)
                                print("     Moved \(file.lastPathComponent) -> processed/")
                            } catch {
                                print("     Failed to move \(file.lastPathComponent): \(error)")
                            }
                        }
                    }else{
                        //we will upload directly to the uploadFile link
                        let success = await uploadFile(fileURL: file)
                        if success {
                            // Move the file to "processed/" so it isn't re-uploaded on the next run
                            let destination = Uploader.processedDestination(for: file, in: processedURL)
                            do {
                                try fileManager.moveItem(at: file, to: destination)
                                print("     Moved \(file.lastPathComponent) -> processed/")
                            } catch {
                                print("     Failed to move \(file.lastPathComponent): \(error)")
                            }
                        }
                    }
                    
                    
                    //                    let success = await uploadFile(fileURL: file)
                    //                    if success {
                    //                        // Move the file to "processed/" so it isn't re-uploaded on the next run
                    //                        let destination = processedURL.appendingPathComponent(file.lastPathComponent)
                    //                        do {
                    //                            try fileManager.moveItem(at: file, to: destination)
                    //                            print("     Moved \(file.lastPathComponent) -> processed/")
                    //                        } catch {
                    //                            print("     Failed to move \(file.lastPathComponent): \(error)")
                    //                        }
                    //                    }
                }
            }
        }
    }
    
    
    // Returns true if the upload succeeded, false otherwise.
    func uploadFile(fileURL: URL) async -> Bool {
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            print("File \(fileURL.lastPathComponent) exists")
            // print("File full name: \(fileURL.absoluteString)")
        }else{
            print("File \(fileURL.lastPathComponent) does not exist")
            return false
        }
        
        let parameters = [
            [
                "key": "participantId",
                "value": ParticipantID.current,
                "type": "text"
            ],
            [
                "key": "file",
                "src": fileURL.path,
                "type": "file"
            ]
        ] as [[String: Any]]
        
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        var error: Error? = nil
        for param in parameters {
            if param["disabled"] != nil { continue }
            let paramName = param["key"]!
            body += Data("--\(boundary)\r\n".utf8)
            body += Data("Content-Disposition:form-data; name=\"\(paramName)\"".utf8)
            if param["contentType"] != nil {
                body += Data("\r\nContent-Type: \(param["contentType"] as! String)".utf8)
            }
            let paramType = param["type"] as! String
            if paramType == "text" {
                let paramValue = param["value"] as! String
                body += Data("\r\n\r\n\(paramValue)\r\n".utf8)
            } else {
                let paramSrc = param["src"] as! String
                let fileURL = URL(fileURLWithPath: paramSrc)
                if let fileContent = try? Data(contentsOf: fileURL) {
                    body += Data("; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8)
                    body += Data("Content-Type: \"content-type header\"\r\n".utf8)
                    body += Data("\r\n".utf8)
                    body += fileContent
                    body += Data("\r\n".utf8)
                }
            }
        }
        body += Data("--\(boundary)--\r\n".utf8);
        let postData = body
        
        guard let url = URL(string: Uploader.UploadURL) else {
            print("\(Uploader.UploadURL) does not exist")
            return false
        }
        var request = URLRequest(url: url,timeoutInterval: Double.infinity)
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = postData
        
        // Await the upload directly — no fire-and-forget Task needed since the caller is async
        
//        let task = URLSession.shared.dataTask(with: request) { data, response, error in
//            guard let data = data else {
//                print(String(describing: error))
//                return
//            }
//            print(String(data: data, encoding: .utf8)!)
//        }
//        task.resume()
        
        do {
            let (responseData, response) = try await upload(data: body, request: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                print("     Upload failed!")
                print("     \(response)")
                print("     \(responseData)")
                return false
            }else{
                print("     Upload success!")
                print("     Response code: \(status)")
                // print("     Data: \(responseData)")
                // As JSON (pretty printed)
                if let json = try? JSONSerialization.jsonObject(with: responseData),
                   let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let prettyStr = String(data: pretty, encoding: .utf8) {
                    print("JSON: \(prettyStr)")
                }
                return true
            }
        } catch {
            print("Upload failed: \(error)")
            return false
        }
        
    }
    
    
    
    
    ///
    /// Coded taken from Sami'r code.
    ///
    func uploadSurveyResults(payload: [String: Any]) async {
        
        guard let url = URL(string: Uploader.UploadURL) else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: jsonData)
            print("Upload success: \(response)")
        } catch {
            print("Upload error: \(error.localizedDescription)")
        }
    }
    
    
    //==========================
    //  Internal
    //==========================
    
    func upload(data: Data, request: URLRequest) async throws -> (Data, URLResponse) {
        // `upload(for:from:)` works with Data
        let (responseData, response) = try await URLSession.shared.data(
            for: request
        )
        return (responseData, response)
    }
    
    /// Where an uploaded file goes in processed/. Sensor files reuse names
    /// (e.g. sensorkit_pressure_phone_00000.csv until the size limit), so when
    /// the name is taken a timestamp is added instead of failing the move,
    /// which used to leave the file behind to be uploaded again every run.
    static func processedDestination(for file: URL, in processedDir: URL,
                                     now: Date = Date(),
                                     fileManager: FileManager = .default) -> URL {
        let plain = processedDir.appendingPathComponent(file.lastPathComponent)
        guard fileManager.fileExists(atPath: plain.path) else { return plain }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        let stamp = formatter.string(from: now)

        var candidate = processedDir.appendingPathComponent(ext.isEmpty ? "\(base)_\(stamp)" : "\(base)_\(stamp).\(ext)")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = "\(base)_\(stamp)_\(n)"
            candidate = processedDir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            n += 1
        }
        return candidate
    }

    /// True when a CSV has at least one non-empty line after its header.
    /// Reads only the first 64 KB.
    static func hasDataRows(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return !data.isEmpty }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.dropFirst().contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Sealed files with this prefix, oldest first. A writer still owning a file
    /// (a ".part" name, a SQLite sidecar, the open database) is never returned,
    /// so the uploader can never read or move a file that is being written.
    func filesWithPrefix(in directory: URL, prefix: String) -> [URL] {
        let fileManager = FileManager.default

        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            return fileURLs
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .filter { Uploader.isSealed($0) }
                // Oldest first: contentsOfDirectory has no order, so without this
                // the oldest file in a backlog can stay last forever.
                .sorted { (Uploader.modified($0) ?? .distantPast) < (Uploader.modified($1) ?? .distantPast) }

        } catch {
            print("Error reading directory: \(error)")
            return []
        }
    }

    static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// True when no writer owns this file any more.
    ///
    /// - ".part" is a writer's working file (see SensorKitFetcher.sealCurrentFile).
    /// - "-wal"/"-shm" belong to an open SQLite database and are meaningless alone.
    /// - dbFileName is the database the app is writing to right now.
    /// - Any other .db was closed by rotation (checkpoint + close), so it is sealed
    ///   at once — it is rotated right before each upload — unless a -wal is still
    ///   next to it, meaning rows not yet folded in (see foldLeftoverWALFiles).
    /// - `grace` covers writers that do not seal yet: they keep final names while
    ///   open, so a recently touched file is left alone.
    static func isSealed(_ url: URL,
                         now: Date = Date(),
                         grace: TimeInterval = 120,
                         defaults: UserDefaults = .standard) -> Bool {
        let name = url.lastPathComponent
        if url.pathExtension == SensorKitFetcher.partExtension { return false }
        if name.hasSuffix("-wal") || name.hasSuffix("-shm") { return false }
        if name == defaults.string(forKey: "dbFileName") { return false }
        if url.pathExtension == "db" {
            return !FileManager.default.fileExists(atPath: url.path + "-wal")
        }
        guard let modified = modified(url) else { return true }
        return now.timeIntervalSince(modified) > grace
    }
    
    func fileSize(from url: URL) -> Int? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize   // bytes
        } catch {
            print("Error: \(error)")
            return nil
        }
    }
    
    
    func getTodaysDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
    
    
}
