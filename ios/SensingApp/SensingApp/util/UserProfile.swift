//
//  UserProfile.swift
//  SensingApp
//
//  Created by Akarsh Ellore on 7/22/2026.
//
//  Synced, anonymous user profile (keyed by the ParticipantID hash, no PII).
//  Signing in on a new phone restores the day count, calendar and check-in state.
//
//  Split authority, reconciled on every login:
//    • SERVER owns the study id (P01…) and the survey schedule — pulled every
//      login, never edited by the phone.
//    • PHONE owns the first-open anchor and completed check-ins — pushed on
//      every change.
//  Every network failure is non-fatal; the app works offline and in demo mode.
//  Endpoints + JSON contract: backend/app/PROFILE_API.md (snake_case on the wire).
//

import Foundation
internal import Combine

// MARK: - Model

struct UserProfile: Codable, Equatable {
    /// v2 (July 2026): added studyId, surveySchedule, sensorStatus.
    var schemaVersion: Int = 2
    var participantId: String
    /// Server-assigned (e.g. "P01"); the app only displays it.
    var studyId: String?
    /// Accepted coordinator code; `enrolledAt` is the "enrolled" marker.
    var enrollmentCode: String?
    var enrolledAt: Double?
    /// Anchors "Day N" (mirrors the journey_first_open_date UserDefaults key).
    var firstOpenDate: Double?
    var surveySchedule: SurveySchedule = SurveySchedule()
    var preferences: Preferences = Preferences()
    /// Completion state only, never survey answers.
    var surveyHistory: [SurveyEntry] = []
    /// TODO: populate from SensorStatusStore via recordSensorStatus(_:).
    var sensorStatus: [SensorStatusSnapshot] = []
    var updatedAt: Double

    struct Preferences: Codable, Equatable {
        var reminderHour: Int = 20
        var reminderMinute: Int = 0
    }

    struct SurveyEntry: Codable, Equatable {
        var date: String        // "yyyy-MM-dd" local calendar day
        var painScore: Int?
        var completed: Bool
    }
}

// MARK: - Survey schedule (server-owned)

enum SurveyCadence: String, Codable {
    case daily, weekly, paused, ended
}

// `cadence` has a default but is still REQUIRED when decoding, on purpose: a
// 404 body must fail to decode rather than silently reset a paused participant
// to daily.
struct SurveySchedule: Codable, Equatable {
    var cadence: SurveyCadence = .daily
    /// Weekly cadence only: 1 = Sunday … 7 = Saturday.
    var weeklyDay: Int?
    var note: String?
    var updatedAt: Double?

    /// View bodies pass their `todayStart` rather than letting this read the clock.
    func isCheckInDueToday(firstOpenDate: Double?, on date: Date = Date(),
                           calendar: Calendar = .current) -> Bool {
        switch cadence {
        case .paused, .ended: return false
        case .daily:          return true
        case .weekly:
            return calendar.component(.weekday, from: date)
                == checkInWeekday(firstOpenDate: firstOpenDate, calendar: calendar)
        }
    }

    /// Single source for Home, the check-in tab and reminders. An out-of-range
    /// server value falls back to the first-open weekday (or Monday).
    func checkInWeekday(firstOpenDate: Double?, calendar: Calendar = .current) -> Int {
        if let weeklyDay, (1...7).contains(weeklyDay) { return weeklyDay }
        guard let firstOpenDate else { return 2 }
        return calendar.component(.weekday, from: Date(timeIntervalSince1970: firstOpenDate))
    }

    var displayText: String {
        switch cadence {
        case .daily:  return "Daily"
        case .weekly: return "Weekly"
        case .paused: return "Paused"
        case .ended:  return "Study complete"
        }
    }
}

/// One Sensors-tab "last recorded" row, mirrored for a restored device.
struct SensorStatusSnapshot: Codable, Equatable {
    var kind: String      // SensorKind.rawValue
    var value: String?
    var date: Double
}

// MARK: - Store

@MainActor
final class ProfileStore: ObservableObject {

    static let shared = ProfileStore()
    private init() {
        lastSyncedAt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        profile = readLocalFile()
    }

    /// Always mirrors the local file (loaded in init, saved on every commit).
    @Published private(set) var profile: UserProfile?
    @Published private(set) var lastSyncedAt: Date?

    // The accepted code is parked here at sign-in and merged in by bootstrap.
    // Creating the profile file at sign-in would make bootstrap skip the
    // server restore on a new phone.
    private let pendingCodeKey = "journey_enrollment_code"
    private let pendingDateKey = "journey_enrollment_date"
    private let pendingPidKey  = "journey_enrollment_pid"

    private let lastSyncKey  = "journey_profile_last_sync"
    private let firstOpenKey = "journey_first_open_date"

    private weak var authManager: SecureAuthManager?

    // MARK: - Schedule

    var surveySchedule: SurveySchedule { profile?.surveySchedule ?? SurveySchedule() }

    func isCheckInDueToday(on date: Date = Date()) -> Bool {
        surveySchedule.isCheckInDueToday(firstOpenDate: profile?.firstOpenDate, on: date)
    }

    // MARK: - Enrollment

    /// Whether the login screen can skip the code prompt. A brand-new phone
    /// always asks until the backend can answer "does this account exist".
    func isEnrolled(participantId: String) -> Bool {
        if let profile, profile.participantId == participantId, profile.enrolledAt != nil {
            return true
        }
        return UserDefaults.standard.string(forKey: pendingPidKey) == participantId
            && UserDefaults.standard.string(forKey: pendingCodeKey) != nil
    }

    func recordEnrollment(code: String, participantId: String) {
        let defaults = UserDefaults.standard
        defaults.set(code, forKey: pendingCodeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingDateKey)
        defaults.set(participantId, forKey: pendingPidKey)
    }

    // MARK: - Bootstrap

    /// Once per session after sign-in (MainAppView.onAppear): load the local
    /// profile or restore it from the server, then pull the server-owned fields.
    func bootstrap(authManager: SecureAuthManager, appState: AppState) async {
        self.authManager = authManager

        let participantId = ParticipantID.current
        guard participantId != "unidentified" else { return }

        // A different account's profile is still on this phone: drop it, along
        // with its "done today" flag and backup time.
        var switchedAccount = false
        if let local = profile, local.participantId != participantId {
            profile = nil
            try? FileManager.default.removeItem(at: fileURL)
            appState.lastCompletedDate = nil
            lastSyncedAt = nil
            UserDefaults.standard.removeObject(forKey: lastSyncKey)
            switchedAccount = true
        }

        if profile == nil {
            if let remote = await get(UserProfile.self, "/api/getuserprofile/\(participantId)"),
               remote.participantId == participantId {
                profile = remote
                hydrateDeviceStores(from: remote, appState: appState)
            } else {
                profile = UserProfile(participantId: participantId,
                                      updatedAt: Date().timeIntervalSince1970)
                // Upgrading from a build without profiles. Never after an account
                // switch: the device stores still hold the other account's days.
                if !switchedAccount { backfillHistoryFromDevice() }
            }
        }

        mergePendingEnrollment()
        captureFirstOpenAnchor()

        // Server-owned fields: only overwrite when the server actually answers.
        if let reply = await get(StudyIdReply.self, "/api/getstudyid/\(participantId)") {
            update { $0.studyId = reply.studyId }
        }
        if let schedule = await get(SurveySchedule.self, "/api/getsurveystatus/\(participantId)") {
            update { $0.surveySchedule = schedule }
        }

        saveLocalFile()
        // A failed push stays unsynced, so this still retries every launch.
        if hasUnsyncedChanges { await pushToServer() }
        refreshCheckInReminders(appState: appState)
    }

    // MARK: - Phone-owned changes (save + push)

    /// No-op until bootstrap creates the profile; bootstrap captures the anchor itself.
    func recordFirstOpen(_ timestamp: Double) {
        commit { if $0.firstOpenDate == nil && timestamp != 0 { $0.firstOpenDate = timestamp } }
    }

    func recordSurveyCompletion(date: Date, painScore: Int?) {
        if profile == nil {
            profile = UserProfile(participantId: ParticipantID.current,
                                  updatedAt: Date().timeIntervalSince1970)
        }
        let entry = UserProfile.SurveyEntry(date: Self.dayFormatter.string(from: date),
                                            painScore: painScore, completed: true)
        commit { profile in
            if let i = profile.surveyHistory.firstIndex(where: { $0.date == entry.date }) {
                profile.surveyHistory[i] = entry
            } else {
                profile.surveyHistory.append(entry)
            }
        }
    }

    /// Display-only; no callers yet.
    func recordSensorStatus(_ snapshots: [SensorStatusSnapshot]) {
        commit { $0.sensorStatus = snapshots }
    }

    /// The ONLY place reminders are scheduled (launch, bootstrap, after submit).
    /// Works offline: `profile` is loaded from disk in init.
    func refreshCheckInReminders(appState: AppState) {
        let schedule = surveySchedule
        SurveyNotificationManager.shared.applySchedule(
            cadence: schedule.cadence,
            weeklyDay: schedule.checkInWeekday(firstOpenDate: profile?.firstOpenDate),
            hour: profile?.preferences.reminderHour ?? 20,
            minute: profile?.preferences.reminderMinute ?? 0,
            appState: appState
        )
    }

    // MARK: - Editing helpers

    /// Applies `change`, stamping `updatedAt` only if something actually changed.
    @discardableResult
    private func update(_ change: (inout UserProfile) -> Void) -> Bool {
        guard var updated = profile else { return false }
        let before = updated
        change(&updated)
        guard updated != before else { return false }
        updated.updatedAt = Date().timeIntervalSince1970
        profile = updated
        return true
    }

    private func commit(_ change: (inout UserProfile) -> Void) {
        guard update(change) else { return }
        saveLocalFile()
        Task { await pushToServer() }
    }

    private var hasUnsyncedChanges: Bool {
        guard let profile else { return false }
        guard let lastSyncedAt else { return true }
        return profile.updatedAt > lastSyncedAt.timeIntervalSince1970
    }

    // MARK: - Device stores

    /// Writes a downloaded profile into the stores the UI already reads, so
    /// Home / Calendar / the weekly strip restore with no UI changes.
    private func hydrateDeviceStores(from remote: UserProfile, appState: AppState) {
        // The server's anchor wins: it is the participant's true study start.
        if let firstOpen = remote.firstOpenDate {
            UserDefaults.standard.set(firstOpen, forKey: firstOpenKey)
        }
        let completedDays = remote.surveyHistory.filter(\.completed).map(\.date)
        for entry in remote.surveyHistory where entry.completed {
            SQLiteSaver.shared.insertSurveyIfMissing(dateString: entry.date, painScore: entry.painScore)
        }
        SurveyLocalStore.shared.mergeCompletedDates(completedDays, for: "default_user")
        if completedDays.contains(Self.dayFormatter.string(from: Date())) {
            appState.markCompletedToday()
        }
    }

    /// Seeds history from check-ins made before this build (pain from SQLite).
    private func backfillHistoryFromDevice() {
        let days = Set(SurveyLocalStore.shared.completedSurveyDateStrings(for: "default_user"))
        guard !days.isEmpty else { return }

        let calendar = Calendar.current
        let months = Set(days.compactMap { Self.dayFormatter.date(from: $0) }
            .compactMap { calendar.dateInterval(of: .month, for: $0)?.start })
        var painByDay: [String: Int] = [:]
        for month in months {
            for record in SQLiteSaver.shared.fetchSurveys(forMonth: month) where record.completed {
                painByDay[record.dateString] = record.painScore
            }
        }
        update { profile in
            guard profile.surveyHistory.isEmpty else { return }
            profile.surveyHistory = days.sorted().map {
                UserProfile.SurveyEntry(date: $0, painScore: painByDay[$0], completed: true)
            }
        }
    }

    private func captureFirstOpenAnchor() {
        let anchor = UserDefaults.standard.double(forKey: firstOpenKey)
        update { if $0.firstOpenDate == nil && anchor != 0 { $0.firstOpenDate = anchor } }
    }

    private func mergePendingEnrollment() {
        let defaults = UserDefaults.standard
        guard let code = defaults.string(forKey: pendingCodeKey) else { return }
        let pid = defaults.string(forKey: pendingPidKey)
        let date = defaults.double(forKey: pendingDateKey)
        update { profile in
            guard profile.enrolledAt == nil, pid == profile.participantId else { return }
            profile.enrollmentCode = code
            profile.enrolledAt = date
        }
    }

    // MARK: - Server

    private struct StudyIdReply: Decodable { let studyId: String }

    /// GET + decode; nil on any failure (offline, 404, endpoint not deployed).
    private func get<T: Decodable>(_ type: T.Type, _ endpoint: String) async -> T? {
        guard let authManager,
              let data = try? await authManager.authenticatedRequest(endpoint: endpoint)
        else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    /// Only an exact {"status":"ok"} counts as synced (demo mode reaches a
    /// server without this endpoint). Failures retry on the next change/launch.
    private func pushToServer() async {
        guard let authManager, let profile,
              let encoded = try? Self.encoder.encode(profile),
              let body = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let data = try? await authManager.authenticatedRequest(
                  endpoint: "/api/uploaduserprofile/\(profile.participantId)",
                  method: "POST", body: body),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["status"] as? String == "ok"
        else { return }
        lastSyncedAt = Date()
        UserDefaults.standard.set(lastSyncedAt, forKey: lastSyncKey)
    }

    // MARK: - Local file (Application Support, not Documents, so file sharing can't see it)

    private var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
