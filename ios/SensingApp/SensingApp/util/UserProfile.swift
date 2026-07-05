//
//  UserProfile.swift
//  SensingApp
//
//  Synced, anonymous user profile.
//
//  PURPOSE:
//  Holds everything the app needs to restore a participant's progress on
//  any device — Instagram-style: sign in on a new phone and your day count,
//  calendar history, and check-in state come back. The profile is keyed by
//  the anonymous ParticipantID hash and contains NO name or other PII, so
//  the anonymity guarantees of the June 2026 rework are preserved.
//
//  STORAGE & SYNC (local-wins):
//    • Local copy: a JSON file in Application Support (file-protected,
//      NOT in Documents so it is never exposed via Finder file sharing).
//    • If a local copy exists it is always the source of truth.
//    • If there is no local copy (fresh install / new device), the app
//      tries to download the profile from the study server and hydrates
//      the on-device stores the UI reads (first-open anchor, SQLite survey
//      history, completion dates).
//    • Every local mutation saves the file immediately, then pushes the
//      whole profile to the server fire-and-forget. Failures are non-fatal
//      and retried on the next mutation or launch — so everything works
//      offline and in demo mode, and starts syncing when the backend is up.
//
//  SERVER CONTRACT (backend/app/PROFILE_API.md):
//    GET /api/profile/<participant_id>  -> profile JSON | 404
//    PUT /api/profile/<participant_id>  -> {"status": "ok"}
//  Wire format is snake_case (handled by the key-conversion strategies).
//

import Foundation
internal import Combine

// MARK: - Model

struct UserProfile: Codable {
    /// Bump when the shape changes so old clients/servers can migrate.
    var schemaVersion: Int = 1

    /// Anonymous SHA-256 participant hash (ParticipantID.current).
    var participantId: String

    /// The coordinator-issued study code entered at first sign-in, and when
    /// it was accepted. Used as the "this account is enrolled" marker.
    var enrollmentCode: String?
    var enrolledAt: Double?

    /// Unix timestamp of the first Home-screen open — anchors the "Day N"
    /// recovery counter (mirrors the journey_first_open_date UserDefaults key).
    var firstOpenDate: Double?

    var preferences: Preferences = Preferences()
    var surveyHistory: [SurveyEntry] = []

    /// Unix timestamp of the last local mutation (local-wins bookkeeping).
    var updatedAt: Double

    struct Preferences: Codable {
        /// Daily check-in reminder time. Currently fixed at 20:00 by
        /// SurveyNotificationManager; carried in the profile so it can
        /// become user-configurable and follow the user across devices.
        var reminderHour: Int = 20
        var reminderMinute: Int = 0
    }

    struct SurveyEntry: Codable, Equatable {
        var date: String        // "yyyy-MM-dd" local calendar day
        var painScore: Int?
        var completed: Bool
    }
}

// MARK: - Store

@MainActor
final class ProfileStore: ObservableObject {

    static let shared = ProfileStore()
    private init() {
        lastSyncedAt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        profile = readLocalFile()
    }

    /// The in-memory profile. nil until bootstrap() runs (or a mutation
    /// creates one). Views observe this for the Settings profile card.
    @Published private(set) var profile: UserProfile?

    /// When the profile last reached the server, nil if never.
    @Published private(set) var lastSyncedAt: Date?

    // Pending-enrollment UserDefaults keys. Enrollment happens at login,
    // BEFORE bootstrap has had a chance to download an existing profile,
    // so the accepted code is parked here and merged in during bootstrap —
    // creating the profile file at login would wrongly suppress the
    // new-device restore (local-wins would see a "local copy").
    private let pendingCodeKey = "journey_enrollment_code"
    private let pendingDateKey = "journey_enrollment_date"
    private let pendingPidKey  = "journey_enrollment_pid"

    private let lastSyncKey = "journey_profile_last_sync"
    private let firstOpenKey = "journey_first_open_date"

    private weak var authManager: SecureAuthManager?

    // MARK: - Enrollment

    /// True when this device already holds an enrolled profile (or a pending
    /// enrollment) for the given participant. Drives whether the login
    /// screen asks for a study code. NOTE: on a brand-new device this is
    /// false even for a returning user — the code prompt reappears until
    /// the backend can answer "does this account exist" (see PROFILE_API.md).
    func isEnrolled(participantId: String) -> Bool {
        if let profile, profile.participantId == participantId, profile.enrolledAt != nil {
            return true
        }
        if let stored = readLocalFile(), stored.participantId == participantId, stored.enrolledAt != nil {
            return true
        }
        return UserDefaults.standard.string(forKey: pendingPidKey) == participantId
            && UserDefaults.standard.string(forKey: pendingCodeKey) != nil
    }

    /// Record that a valid coordinator code was accepted at sign-in.
    /// Parked in UserDefaults and folded into the profile by bootstrap().
    func recordEnrollment(code: String, participantId: String) {
        let defaults = UserDefaults.standard
        defaults.set(code, forKey: pendingCodeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingDateKey)
        defaults.set(participantId, forKey: pendingPidKey)
    }

    // MARK: - Bootstrap

    /// Load the local profile, or restore it from the study server when no
    /// local copy exists (fresh install / new device). Call once per session
    /// after authentication — MainAppView.onAppear.
    func bootstrap(authManager: SecureAuthManager, appState: AppState) async {
        self.authManager = authManager

        let participantId = ParticipantID.current
        guard participantId != "unidentified" else { return }

        // Discard a leftover profile from a different account on this device.
        if let local = profile ?? readLocalFile(), local.participantId != participantId {
            profile = nil
            try? FileManager.default.removeItem(at: fileURL)
        }

        if profile == nil { profile = readLocalFile() }

        if profile == nil {
            // No local copy — try the server, hydrating the on-device stores
            // the UI reads so past progress appears immediately.
            if let remote = await downloadFromServer(participantId: participantId) {
                profile = remote
                hydrateDeviceStores(from: remote, appState: appState)
            } else {
                profile = UserProfile(
                    participantId: participantId,
                    updatedAt: Date().timeIntervalSince1970
                )
            }
        }

        mergePendingEnrollment()
        captureDeviceAnchors()
        saveLocalFile()
        await pushToServer()
    }

    // MARK: - Mutations (local-wins: save locally, then push)

    /// Called from HomeView when the Day-N anchor is first established.
    /// No-op until bootstrap has created the profile — bootstrap itself
    /// captures the anchor via captureDeviceAnchors(), so ordering is safe.
    func recordFirstOpen(_ timestamp: Double) {
        guard var current = profile, current.firstOpenDate == nil, timestamp != 0 else { return }
        current.firstOpenDate = timestamp
        commit(current)
    }

    /// Called from the survey submit success path.
    func recordSurveyCompletion(date: Date, painScore: Int?) {
        var current = profile ?? UserProfile(
            participantId: ParticipantID.current,
            updatedAt: Date().timeIntervalSince1970
        )
        let day = Self.dayFormatter.string(from: date)
        let entry = UserProfile.SurveyEntry(date: day, painScore: painScore, completed: true)
        if let index = current.surveyHistory.firstIndex(where: { $0.date == day }) {
            current.surveyHistory[index] = entry
        } else {
            current.surveyHistory.append(entry)
        }
        commit(current)
    }

    private func commit(_ updated: UserProfile) {
        var updated = updated
        updated.updatedAt = Date().timeIntervalSince1970
        profile = updated
        saveLocalFile()
        Task { await pushToServer() }
    }

    // MARK: - Restore hydration

    /// Write a downloaded profile's contents into the stores the UI already
    /// reads, so Home / Calendar / weekly strip restore without UI changes.
    private func hydrateDeviceStores(from remote: UserProfile, appState: AppState) {
        // Day-N anchor. The server value wins over any value set moments ago
        // on this fresh device — it is the participant's true study start.
        if let firstOpen = remote.firstOpenDate {
            UserDefaults.standard.set(firstOpen, forKey: firstOpenKey)
        }

        // Survey history → SQLite (Calendar tab + Home weekly strip) and
        // SurveyLocalStore (in-survey week header).
        var completedDays: [String] = []
        for entry in remote.surveyHistory where entry.completed {
            completedDays.append(entry.date)
            if !SQLiteSaver.shared.surveyExists(dateString: entry.date) {
                _ = SQLiteSaver.shared.insertSurvey(
                    dateString: entry.date,
                    painScore: entry.painScore
                )
            }
        }
        SurveyLocalStore.shared.mergeCompletedDates(completedDays, for: "default_user")

        // Today's check-in state (FAB icon / check-in card).
        let today = Self.dayFormatter.string(from: Date())
        if completedDays.contains(today) {
            appState.lastCompletedDate = today
        }
    }

    /// Fold device-side values that may have been set before the profile
    /// existed (fresh user path) into the profile.
    private func captureDeviceAnchors() {
        guard var current = profile else { return }
        let anchor = UserDefaults.standard.double(forKey: firstOpenKey)
        if current.firstOpenDate == nil, anchor != 0 {
            current.firstOpenDate = anchor
            current.updatedAt = Date().timeIntervalSince1970
            profile = current
        }
    }

    private func mergePendingEnrollment() {
        guard var current = profile else { return }
        let defaults = UserDefaults.standard
        guard
            current.enrolledAt == nil,
            let code = defaults.string(forKey: pendingCodeKey),
            defaults.string(forKey: pendingPidKey) == current.participantId
        else { return }
        current.enrollmentCode = code
        current.enrolledAt = defaults.double(forKey: pendingDateKey)
        current.updatedAt = Date().timeIntervalSince1970
        profile = current
    }

    // MARK: - Server sync

    private func downloadFromServer(participantId: String) async -> UserProfile? {
        guard let authManager else { return nil }
        do {
            let data = try await authManager.authenticatedRequest(
                endpoint: "/api/profile/\(participantId)"
            )
            let remote = try Self.decoder.decode(UserProfile.self, from: data)
            guard remote.participantId == participantId else { return nil }
            return remote
        } catch {
            // No server copy / server unreachable / endpoint not deployed yet —
            // all non-fatal, the app proceeds with a fresh local profile.
            return nil
        }
    }

    /// Push the full profile (local-wins: server just stores the latest).
    /// Any failure leaves lastSyncedAt untouched; the next mutation or
    /// launch retries. Demo mode reaches a server without this endpoint,
    /// so the {"status":"ok"} check keeps the sync row truthful.
    private func pushToServer() async {
        guard let authManager, let profile else { return }
        do {
            let encoded = try Self.encoder.encode(profile)
            guard let body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
            let data = try await authManager.authenticatedRequest(
                endpoint: "/api/profile/\(profile.participantId)",
                method: "PUT",
                body: body
            )
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard reply?["status"] as? String == "ok" else { return }
            lastSyncedAt = Date()
            UserDefaults.standard.set(lastSyncedAt, forKey: lastSyncKey)
        } catch {
            // Non-fatal — retried on the next mutation or launch.
        }
    }

    // MARK: - Local file

    private var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("user_profile.json")
    }

    private func readLocalFile() -> UserProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(UserProfile.self, from: data)
    }

    private func saveLocalFile() {
        guard let profile, let data = try? Self.encoder.encode(profile) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
