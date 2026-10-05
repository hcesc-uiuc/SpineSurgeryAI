//
//  FileSealing.swift
//  SensingApp
//
//  Helpers shared by every writer that hands files to the uploader (#74).
//

import Foundation

extension FileManager {
    /// Size of the file on disk right now, in bytes.
    ///
    /// URL.resourceValues caches what it reads on the URL, and off the main run
    /// loop that cache is never cleared. Writers polling their own file through
    /// it saw the first size forever and never rotated (600+ MB SensorKit CSVs).
    func currentSize(of url: URL) -> Int? {
        (try? attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    /// Renames a ".part" working file to its final name and returns that name.
    ///
    /// If the final name is already taken (an older build's file, or a reused
    /// file index), a unique suffix is added instead of failing: a failed seal
    /// leaves the data stuck as ".part", where nothing uploads it.
    @discardableResult
    func seal(_ part: URL) throws -> URL {
        let target = part.deletingPathExtension()                 // drops ".part"
        var sealed = target
        var attempt = 1
        while fileExists(atPath: sealed.path) {
            let base = target.deletingPathExtension().lastPathComponent
            sealed = target.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(attempt)")
                .appendingPathExtension(target.pathExtension)
            attempt += 1
        }
        try moveItem(at: part, to: sealed)
        return sealed
    }
}
