//
//  LocationFileLogger.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 2/21/26.
//

import Foundation

class LocationFileLogger {

    static let shared = LocationFileLogger()
    
    // Base name for all log files — date will be appended
    private let filePrefix = "locations"
    
    // File manager used for all file system operations
    private let fileManager = FileManager.default

    // MARK: - Public

    func log(_ text: String) {
        let filePath = resolveFilePath()
        append(text: text, to: filePath)
    }

    // MARK: - File Resolution

    private func resolveFilePath() -> URL {
        let todayFileName = fileName(for: Date())
        let todayFilePath = documentsURL.appendingPathComponent("to-be-processed").appendingPathComponent(todayFileName)

        if fileManager.fileExists(atPath: todayFilePath.path) {
            // File for today already exists — append to it
            print("📄 Using existing file: \(todayFileName)")
            return todayFilePath
        }

        // File for today does not exist — create a new one
        // Any previous date files are left untouched in the documents directory
        print("📄 Creating new file: \(todayFileName)")
        fileManager.createFile(atPath: todayFilePath.path, contents: nil)
        return todayFilePath
    }

    // MARK: - Write

    private func append(text: String, to url: URL) {
        // Add a newline after each entry so records are separated
        let entry = text + "\n"

        guard let data = entry.data(using: .utf8) else {
            print("❌ Failed to encode log entry")
            return
        }

        if fileManager.fileExists(atPath: url.path) {
            do {
                // Open a file handle to the existing file.
                // Writing via handle appends to the end without
                // loading the entire file into memory first —
                // important for large log files over time.
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()  // move cursor to end before writing
                handle.write(data)
                handle.closeFile()
                print("✅ Appended to: \(url.lastPathComponent)")
            } catch {
                print("❌ Failed to append: \(error.localizedDescription)")
            }
        } else {
            // File was deleted between resolveFilePath() and here —
            // write directly as a fresh file
            do {
                try data.write(to: url, options: .atomic)
                print("✅ Created and wrote to: \(url.lastPathComponent)")
            } catch {
                print("❌ Failed to write new file: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    // Builds a file name using today's date.
    // Example output: locations_2026-02-21.txt
    private func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(filePrefix)_\(formatter.string(from: date)).txt"
    }

    // The app's Documents directory — persists across app launches.
    // Files here are visible in the Files app if UIFileSharingEnabled
    // is set to true in Info.plist.
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
