
//
//  LocationFileLogger.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 2/21/26.
//

import Foundation

class HKDataLogger {

    private var fileHandle: FileHandle
    // Base name for all log files — date will be appended
    private let filePrefix = "healthkit"
    // File manager used for all file system operations
    private let fileManager = FileManager.default
    
    init(){
        fileHandle = FileHandle()
    }
    
    func open() -> Bool{
        let todayFileName = fileName(for: Date())
        let todayFilePath = documentsURL.appendingPathComponent("to-be-processed").appendingPathComponent(todayFileName)
        
        if !fileManager.fileExists(atPath: todayFilePath.path) {
            fileManager.createFile(atPath: todayFilePath.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: todayFilePath.path) else {
            print("cannot create file")
            return false
        }
        self.fileHandle = handle
        self.fileHandle.seekToEndOfFile()
        return true
    }
    
    func writeLine(_ text: String) {
        if let data = (text + "\n").data(using: .utf8) {
            fileHandle.write(data)
        }
    }
    
    //closes the file
    func close() {
        fileHandle.closeFile()
    }
    
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
