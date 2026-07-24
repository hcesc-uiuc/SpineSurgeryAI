//
//  UserProfile.swift
//  SensingApp
//
//  Created by Akarsh Ellore on 7/22/2026.
//
//  Synced, anonymous user profile.
//
//  PURPOSE:
//  Holds everything the app needs to restore a participant's progress on
//  any device — Instagram-style: sign in on a new phone and your day count,
//  calendar history, and check-in state come back. The profile is keyed by
//  the anonymous ParticipantID hash and contains NO name or other PII, so
//  the anonymity guarantees are preserved.
//
//  SPLIT-AUTHORITY SYNC:
//    Two different owners of truth, reconciled on every login:
//      • SERVER-authoritative — the study id (P01…) and the survey schedule
//        (daily / weekly / paused / ended). Coordinators set these on the web;
//        the phone PULLS them on every login and overwrites its local copy.
//        The phone never edits them.
//      • PHONE-authoritative — the first-open day anchor and the calendar of
//        completed check-ins. The phone owns these and PUSHES them up on
//        every mutation.
//    A brand-new device with no local copy first downloads the whole profile
//    (getuserprofile) and hydrates the on-device stores the UI reads
//    (first-open anchor, SQLite survey history, completion dates) so past
//    progress appears immediately.
//    Every failure is non-fatal — the app works offline and in demo mode and
//    self-heals when the backend is up.
//
//  SERVER CONTRACT (backend/app/PROFILE_API.md — the 4 endpoints):
//    GET  /api/getstudyid/<participant_id>        -> { "study_id": "P01" }
//    GET  /api/getuserprofile/<participant_id>    -> profile JSON | 404
//    GET  /api/getsurveystatus/<participant_id>   -> survey_schedule JSON | 404
//    POST /api/uploaduserprofile/<participant_id> -> { "status": "ok" }
//  Wire format is snake_case (handled by the key-conversion strategies).
//

import Foundation
internal import Combine

// MARK: - Model

struct UserProfile: Codable {
    /// Bump when the shape changes so old clients/servers can migrate.
    /// v2 (July 2026): added studyId, surveySchedule, sensorStatus.
    var schemaVersion: Int = 2

    /// Anonymous SHA-256 participant hash (ParticipantID.current). The join
    /// key for everything; the server maps it to a friendly study id.
    var participantId: String

    /// Server-assigned study id (e.g. "P01"). The server hands out the next
    /// available id the first time it sees a participant hash; the app only
    /// displays it (Settings) and never generates or edits it. nil until the
    /// server has answered getstudyid at least once.
    var studyId: String?

    /// The coordinator-issued study code entered at first sign-in, and when
    /// it was accepted. Used as the "this account is enrolled" marker.
    var enrollmentCode: String?
    var enrolledAt: Double?

    /// Unix timestamp of the first Home-screen open — anchors the "Day N"
    /// recovery counter (mirrors the journey_first_open_date UserDefaults key).
    /// Phone-authoritative.
    var firstOpenDate: Double?

    /// SERVER-authoritative check-in cadence. Coordinators set it on the web;
    /// the phone pulls it on every login (getsurveystatus) and reflects it in
    /// notifications, the check-in tab, and the Home card.
    var surveySchedule: SurveySchedule = SurveySchedule()

    var preferences: Preferences = Preferences()

    /// Calendar of completed check-ins. Completion state only — NOT the survey
    /// answers themselves. Phone-authoritative. (painScore is kept for the Home
    /// restore convenience and can be dropped later without a schema change.)
    var surveyHistory: [SurveyEntry] = []

    /// Latest "last recorded" values shown on the Sensors tab, mirrored so a
    /// new device can show recent per-sensor status without re-syncing raw
    /// sensor data. Display-only.
    ///
    /// TODO(issue-52): populate this from SensorStatusStore once that store
    /// lands on this branch, via ProfileStore.recordSensorStatus(_:). The
    /// field exists now so the profile shape matches the study spec and the
    /// backend contract is stable; it stays empty until wired.
    var sensorStatus: [SensorStatusSnapshot] = []

    /// Unix timestamp of the last local mutation (local-wins bookkeeping).
    var updatedAt: Double

    struct Preferences: Codable {
        /// Daily check-in reminder time. Carried in the profile so it can
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

// MARK: - Survey schedule (server-authoritative)

/// How often the participant is asked to complete a check-in. Set by study
/// coordinators on the web; the phone only reads it.
enum SurveyCadence: String, Codable {
    case daily      // a check-in every day
    case weekly     // once a week, on `weeklyDay`
    case paused     // temporarily no check-ins (e.g. a struggling participant)
    case ended      // study complete — check-ins stop permanently
}

struct SurveySchedule: Codable, Equatable {
    var cadence: SurveyCadence = .daily

    /// Calendar weekday for `weekly` cadence: 1 = Sunday … 7 = Saturday
    /// (matches Calendar.component(.weekday)). Ignored for other cadences.
    var weeklyDay: Int?

    /// Optional message from the coordinators (e.g. why the study is paused).
    var note: String?

    /// Server's last change time, for display / debugging.
    var updatedAt: Double?

    /// Whether a check-in should be requested from the participant today.
    /// `firstOpenDate` is used only to pick a sensible weekly day when the
    /// server has not specified one.
    func isCheckInDueToday(firstOpenDate: Double?, calendar: Calendar = .current) -> Bool {
        switch cadence {
        case .paused, .ended:
            return false
        case .daily:
            return true
        case .weekly:
            let today = calendar.component(.weekday, from: Date())
            return today == (weeklyDay ?? defaultWeeklyDay(firstOpenDate: firstOpenDate, calendar: calendar))
        }
    }

    /// Human-readable summary for the Settings card.
    var displayText: String {
        switch cadence {
        case .daily:  return "Daily"
        case .weekly: return "Weekly"
        case .paused: return "Paused"
        case .ended:  return "Study complete"
        }
    }

    private func defaultWeeklyDay(firstOpenDate: Double?, calendar: Calendar) -> Int {
        if let firstOpenDate {
            return calendar.component(.weekday, from: Date(timeIntervalSince1970: firstOpenDate))
        }
        return 2 // Monday fallback
    }
}

// MARK: - Sensor status snapshot (display-only)

/// One row of the Sensors tab's "last recorded" status, mirrored into the
/// profile so it can be shown on a freshly restored device.
struct SensorStatusSnapshot: Codable, Equatable {
    var kind: String      // SensorKind.rawValue (issue-52), e.g. "heartRate"
    var value: String?    // e.g. "72 bpm"; nil for timestamp-only sensors
    var date: Double      // Unix seconds of the last recording
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
    /// creates one). Views observe this for the Settings profile card,
    /// the check-in tab icon, and the Home check-in card.
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

    // MARK: - Schedule (server-authoritative) convenience

    /// The current check-in schedule, defaulting to daily until the server
    /// says otherwise.
    var surveySchedule: SurveySchedule { profile?.surveySchedule ?? SurveySchedule() }

    /// Whether a check-in is due from the participant today (drives the
    /// check-in tab icon and the Home check-in card).
    func isCheckInDueToday() -> Bool {
        surveySchedule.isCheckInDueToday(firstOpenDate: profile?.firstOpenDate)
    }

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
    /// local copy exists (fresh install / new device), then reconcile the
    /// server-authoritative fields (study id + schedule) which are pulled on
    /// EVERY login. Call once per session after authentication —
    /// MainAppView.onAppear.
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

        // Server-authoritative pulls, EVERY login. Failures leave the local
        // values untouched (server-wins only when the server actually answers).
        if let studyId = await fetchStudyId(participantId: participantId) {
            applyStudyId(studyId)
        }
        if let schedule = await fetchSurveyStatus(participantId: participantId) {
            applySchedule(schedule)
        }

        saveLocalFile()
        await pushToServer()

        // Reflect the (possibly updated) schedule in local notifications.
        refreshCheckInReminders(appState: appState)
    }

    // MARK: - Mutations (phone-authoritative: save locally, then push)

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

    /// Mirror the Sensors-tab "last recorded" lines into the profile.
    /// Display-only; see UserProfile.sensorStatus. Currently unused until the
    /// SensorStatusStore (issue-52) lands on this branch, then call this from
    /// the Sensors tab refresh.
    func recordSensorStatus(_ snapshots: [SensorStatusSnapshot]) {
        guard var current = profile, current.sensorStatus != snapshots else { return }
        current.sensorStatus = snapshots
        commit(current)
    }

    private func commit(_ updated: UserProfile) {
        var updated = updated
        updated.updatedAt = Date().timeIntervalSince1970
        profile = updated
        saveLocalFile()
        Task { await pushToServer() }
    }

    // MARK: - Applying server-authoritative fields

    private func applyStudyId(_ studyId: String) {
        guard var current = profile, current.studyId != studyId else { return }
        current.studyId = studyId
        current.updatedAt = Date().timeIntervalSince1970
        profile = current
    }

    private func applySchedule(_ schedule: SurveySchedule) {
        guard var current = profile, current.surveySchedule != schedule else { return }
        current.surveySchedule = schedule
        current.updatedAt = Date().timeIntervalSince1970
        profile = current
    }

    /// Re-arm the local check-in reminders to match the current schedule.
    /// Paused/ended queue nothing; weekly moves them to the weekly day.
    ///
    /// THE SINGLE OWNER of reminder scheduling — call this and nothing else.
    /// It is safe to call before any network round-trip: `profile` is loaded
    /// from the local file in init(), so at launch this already knows the last
    /// schedule the server gave us, and bootstrap simply re-runs it once the
    /// fresh schedule lands. Call sites: app launch (SensingAppApp), bootstrap,
    /// and after a successful survey submit (so today's reminder stops).
    func refreshCheckInReminders(appState: AppState) {
        let schedule = surveySchedule
        SurveyNotificationManager.shared.applySchedule(
            cadence: schedule.cadence,
            weeklyDay: schedule.weeklyDay,
            hour: profile?.preferences.reminderHour ?? 20,
            minute: profile?.preferences.reminderMinute ?? 0,
            appState: appState
        )
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

    /// GET /api/getstudyid/<hash> — the server assigns the next available
    /// study id for a new hash and returns the (existing or new) id.
    private func fetchStudyId(participantId: String) async -> String? {
        guard let authManager else { return nil }
        do {
            let data = try await authManager.authenticatedRequest(
                endpoint: "/api/getstudyid/\(participantId)"
            )
            let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return reply?["study_id"] as? String
        } catch {
            return nil
        }
    }

    /// GET /api/getsurveystatus/<hash> — the coordinator-set check-in schedule.
    /// Pulled on every login and overwrites the local schedule.
    private func fetchSurveyStatus(participantId: String) async -> SurveySchedule? {
        guard let authManager else { return nil }
        do {
            let data = try await authManager.authenticatedRequest(
                endpoint: "/api/getsurveystatus/\(participantId)"
            )
            return try Self.decoder.decode(SurveySchedule.self, from: data)
        } catch {
            // No schedule set / server unreachable / endpoint not deployed —
            // keep the local schedule (defaults to daily).
            return nil
        }
    }

    /// GET /api/getuserprofile/<hash> — the whole profile, used only when the
    /// device has no local copy (fresh install / new device).
    private func downloadFromServer(participantId: String) async -> UserProfile? {
        guard let authManager else { return nil }
        do {
            let data = try await authManager.authenticatedRequest(
                endpoint: "/api/getuserprofile/\(participantId)"
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

    /// POST /api/uploaduserprofile/<hash> — push the full profile. Any failure
    /// leaves lastSyncedAt untouched; the next mutation or launch retries.
    /// Demo mode reaches a server without this endpoint, so the
    /// {"status":"ok"} check keeps the sync row truthful.
    private func pushToServer() async {
        guard let authManager, let profile else { return }
        do {
            let encoded = try Self.encoder.encode(profile)
            guard let body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
            let data = try await authManager.authenticatedRequest(
                endpoint: "/api/uploaduserprofile/\(profile.participantId)",
                method: "POST",
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
