//
//  CrashReporter.swift
//  SensingApp
//
//  Thin wrapper around Firebase Crashlytics so the rest of the app can add
//  breadcrumbs and report non-fatal errors without importing Crashlytics
//  everywhere. If Crashlytics is ever removed, this is the only file to change.
//
//  Crashlytics auto-initializes when FirebaseApp.configure() is called in
//  AppDelegate — there is nothing else to start up here.
//

import Foundation
import FirebaseCrashlytics

enum CrashReporter {

    /// Adds a breadcrumb to the next crash/non-fatal report.
    /// These logs are attached to crash reports so you can see the sequence
    /// of events leading up to a problem. Keep them free of personal data.
    static func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
        print("[Crashlytics] \(message)")
    }

    /// Records a non-fatal error to Crashlytics with optional context.
    /// Use this in catch blocks for things that fail but don't crash the app
    /// (failed uploads, auth refresh failures, sensor fetch errors, etc.).
    static func record(_ error: Error,
                       context: String? = nil,
                       info: [String: Any] = [:]) {
        if let context {
            Crashlytics.crashlytics().log("error in \(context): \(error.localizedDescription)")
        }
        var userInfo = info
        if let context { userInfo["context"] = context }

        let nsError = NSError(
            domain: "SensingApp",
            code: (error as NSError).code,
            userInfo: userInfo.merging([
                NSLocalizedDescriptionKey: error.localizedDescription,
                "underlying": String(describing: error)
            ]) { current, _ in current }
        )
        Crashlytics.crashlytics().record(error: nsError)
        print("[Crashlytics] recorded non-fatal: \(context ?? "")  \(error.localizedDescription)")
    }

    /// Records a non-fatal "soft" failure that isn't an Error value
    /// (e.g. an HTTP status check that returned a bad code).
    static func recordFailure(_ message: String,
                              context: String,
                              info: [String: Any] = [:]) {
        Crashlytics.crashlytics().log("\(context): \(message)")
        var userInfo = info
        userInfo["context"] = context
        userInfo[NSLocalizedDescriptionKey] = message
        let nsError = NSError(domain: "SensingApp", code: -1, userInfo: userInfo)
        Crashlytics.crashlytics().record(error: nsError)
        print("[Crashlytics] recorded failure: \(context)  \(message)")
    }

    /// Associates subsequent reports with a stable participant/user identifier.
    /// Helps correlate crashes to a specific research participant. The Apple
    /// user ID is an opaque, app-scoped value — not the person's Apple account.
    static func setParticipant(_ id: String) {
        Crashlytics.crashlytics().setUserID(id)
    }

    /// Clears the participant association (e.g. on logout).
    static func clearParticipant() {
        Crashlytics.crashlytics().setUserID("")
    }
}
