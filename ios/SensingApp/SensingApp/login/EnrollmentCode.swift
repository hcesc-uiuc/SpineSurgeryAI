//
//  EnrollmentCode.swift
//  SensingApp
//
//  Coordinator-issued study enrollment codes.
//
//  Random App Store users must not be able to join the study: at FIRST
//  sign-in the login screen asks for a 6-digit code handed out by the
//  study coordinators. Returning users on the same device are not asked
//  again (see ProfileStore.isEnrolled).
//
//  INTERIM CLIENT-SIDE VALIDATION:
//  The app currently runs in demo mode (SecureAuthManager.demoMode), so
//  login() returns before it ever reaches the server. That makes this local
//  check the ONLY thing gating enrollment today, even though the backend's
//  real gate is already built (auth/routes.py returns 403
//  invalid_enrollment_code against the enrollment_codes table).
//
//  HOW MUCH PROTECTION THE HASHING ACTUALLY GIVES: very little. Storing
//  digests instead of plaintext stops someone running `strings` on the
//  binary — and nothing more. A 6-digit code is a keyspace of one million,
//  so computing all 10^6 SHA-256 digests and matching them against the list
//  below takes well under a second on any laptop. Treat this as a barrier to
//  casual sign-ups, NOT as a secret. The real gate is the server's.
//
//  ⚠️ TWO PLACES TO UPDATE: a code must exist BOTH here and in the server's
//  enrollment_codes table (manage_enrollment_codes.py). A code added only on
//  the server is rejected on the phone before the request is ever made, so
//  the CLI appears broken. Removing this file's check is part of leaving
//  demo mode — see below.
//
//  To add a code:   echo -n 123456 | shasum -a 256
//  and append the hex digest to validCodeHashes — then add the same code
//  with `python manage_enrollment_codes.py add 123456`.
//
//  KNOWN LIMITS (accepted for the pilot):
//    • Codes are shared, reusable, and cannot be revoked without an
//      app update.
//    • A new device cannot know an Apple ID is already enrolled, so the
//      prompt reappears there until the backend can answer that lookup.
//  Server-side replacement: when demoMode goes false, delete validate()'s
//  hash check and let POST /auth/login be the sole authority — the code is
//  already sent (see SecureAuthManager.login) and 403 already maps to
//  AuthError.invalidEnrollmentCode.
//

import Foundation
import CryptoKit

enum EnrollmentGate {

    /// SHA-256 (lowercase hex) digests of the valid 6-digit codes.
    private static let validCodeHashes: Set<String> = [
        "31edb8a5cb6d54725aa4de0e6c08cb8eccaa3857929e3d1f1c1406b6eba3dd46",
        "e776c75105a3bfb8f814806f304c993882839bb6e844efc4837c657ddb609976",
        "9ff4a8311d44c753fa528f7f0d75a57ef5bc38103019e72ffaf5b5709a3db51a",
        "58009946159e95ee598cf5fe8bfa3161a5131354b46ed23ba09ef2d4962777d6",
        "b8ba2c7b82567dc3455a20c21f27bb54491ba9fd899e74aec5fa8662f574ae96",
        "731cb46a035c0b459db64138bf20070508c1634ceb9dfac990477d5cd1a66c40",
        "6b10910a1aa8275732b34f8724a0c0cc477e902b63f75d9b39d48eb921032749",
        "9fd8dbceed673e4d40877ec5a616f1f36689eec13255f35e2ff9a7420a3a716d",
        "96565866998f29b616dbe29c88756e224ca4d022238ad3952cb1a46dcdd2570a",
        "056d79ccd39c3e10b24f6d9093f1fc0f25336aac8f6995abc2db184f8d45f0e4"
    ]

    /// True when the entered text is one of the coordinator-issued codes.
    static func validate(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return false }
        return validCodeHashes.contains(sha256Hex(trimmed))
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
