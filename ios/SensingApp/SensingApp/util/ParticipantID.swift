//
//  ParticipantID.swift
//  SensingApp
//
//  Anonymous participant identifier.
//
//  The app never stores or uploads the patient's name or Apple account.
//  Instead every piece of collected data is tagged with a stable
//  SHA-256 hash of Apple's per-app user identifier (credential.user).
//  This keeps each participant's data correctly linked in the backend
//  WITHOUT revealing who they are:
//    • Deterministic — the same Apple ID always maps to the same bucket
//      (across reinstalls and devices), so data links correctly.
//    • One-way — the patient cannot be recovered from the hash.
//    • The raw Apple identifier is never uploaded; only this hash leaves
//      the device.
//

import Foundation
import CryptoKit

enum ParticipantID {

    /// UserDefaults key holding the current participant hash.
    private static let storageKey = "journey_participant_id"

    /// SHA-256 (lowercase hex) of the given Apple user identifier.
    static func hash(_ appleUserID: String) -> String {
        let digest = SHA256.hash(data: Data(appleUserID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the participant hash from the Apple user ID and persist it so
    /// every uploader can stamp it on outgoing data. Call once at login.
    static func store(forAppleUserID appleUserID: String) {
        UserDefaults.standard.set(hash(appleUserID), forKey: storageKey)
    }

    /// The current participant hash, or a neutral placeholder if login has
    /// not happened yet. Read by all upload paths.
    static var current: String {
        UserDefaults.standard.string(forKey: storageKey) ?? "unidentified"
    }
}
