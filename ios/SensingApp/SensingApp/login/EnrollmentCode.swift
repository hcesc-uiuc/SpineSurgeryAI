//
//  EnrollmentCode.swift
//  SensingApp
//
//  Coordinator-issued 6-digit codes gate account creation so random App Store
//  users can't join the study. The server is the only validator: /auth/login
//  answers 403 invalid_enrollment_code for a new account without a usable
//  code, and the login screen asks for one only then. Returning participants
//  are never asked, on any phone.
//
//  Codes are managed on the server: python manage_enrollment_codes.py add 123456
//

import Foundation

enum EnrollmentGate {

    /// Six digits after trimming. Only saves a round trip on obvious typos;
    /// whether the code is real is the server's call.
    static func isWellFormed(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 6 && trimmed.allSatisfy(\.isNumber)
    }
}
