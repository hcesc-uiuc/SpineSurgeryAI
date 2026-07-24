//
//  NotificationManager.swift
//  SensingApp
//
//  Created by Samir Kurudi on 2/13/26.
//

//
//  NotificationManager.swift
//

import Foundation
import UserNotifications

final class SurveyNotificationManager {

    static let shared = SurveyNotificationManager()
    private init() {}

    // MARK: - Request Permission

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in

            if granted {
                print("✅ Notifications authorized")
            } else {
                print("❌ Notifications denied")
            }
        }
    }

    // MARK: - Schedule Daily Reminder

    /// DEPRECATED — do not call. Schedules a blind DAILY repeating reminder
    /// with no knowledge of the coordinator-set schedule, so it will nag a
    /// participant whose study is paused or ended, and its repeating trigger
    /// cannot skip a single day (see the note above applySchedule).
    ///
    /// Use `ProfileStore.shared.refreshCheckInReminders(appState:)` instead —
    /// it is the single owner of reminder scheduling and works from the cached
    /// schedule immediately at launch. Kept only so any out-of-tree caller
    /// still compiles.
    @available(*, deprecated, message: "Use ProfileStore.refreshCheckInReminders(appState:)")
    func scheduleDailyReminder(hour: Int = 20,
                               minute: Int = 0,
                               appState: AppState) {

        // Do not schedule if survey completed
        guard !appState.isCompletedToday else {
            cancelReminder()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Daily Recovery Check-In"
        content.body = "Please complete your surgery recovery survey."
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: true
        )

        let request = UNNotificationRequest(
            identifier: "dailySurveyReminder",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
        print("📅 Daily reminder scheduled")
    }

    // MARK: - Schedule From Survey Cadence (from web server)
    //
    // WHY THIS ISN'T ONE REPEATING TRIGGER
    //
    // The obvious implementation — a single `repeats: true` calendar trigger —
    // cannot skip a single occurrence. The only way to stop tonight's reminder
    // after the participant has already checked in is to cancel the request,
    // and cancelling a repeating request removes EVERY future occurrence, not
    // just today's. Since this is only re-armed when the app runs, a
    // participant who checked in and then relaunched lost their reminders
    // permanently — exactly the people who most need prompting.
    //
    // Instead we queue the next `dailyHorizon`/`weeklyHorizon` occurrences as
    // individual one-shot requests. Days that shouldn't fire are simply never
    // queued, and the window is re-armed on every launch and after every
    // submit, so it keeps rolling forward. iOS allows 64 pending notifications
    // per app; the horizons below stay well inside that.

    /// Identifier prefix for the queued one-shot check-in reminders.
    private static let reminderPrefix = "checkInReminder_"
    /// The old single repeating request. Still cancelled so installs upgrading
    /// from a previous build don't keep a stale reminder alive forever.
    private static let legacyIdentifier = "dailySurveyReminder"

    private static let dailyHorizon = 30    // days
    private static let weeklyHorizon = 8    // weeks

    /// Re-arm the local check-in reminders to match the coordinator-set survey
    /// schedule pulled from the server (ProfileStore):
    ///   • daily   → one reminder per day at hour:minute, for the next 30 days
    ///   • weekly  → one per week on `weeklyDay` (1=Sun…7=Sat), for 8 weeks
    ///   • paused  → nothing queued
    ///   • ended   → nothing queued
    /// Today is skipped when the check-in is already complete. Safe to call
    /// repeatedly — it always clears the queue first.
    func applySchedule(cadence: SurveyCadence,
                       weeklyDay: Int?,
                       hour: Int = 20,
                       minute: Int = 0,
                       appState: AppState) {

        // Read MainActor state up front; the pending-request lookup below
        // calls back on a background queue.
        let completedToday = appState.isCompletedToday

        clearQueuedReminders {
            switch cadence {
            case .paused, .ended:
                // Deliberately nothing queued — a paused or finished study
                // must not nag the participant.
                print("📅 Check-in reminders cleared (\(cadence.rawValue))")
            case .daily:
                self.queueReminders(on: self.upcomingDailyDates(hour: hour, minute: minute),
                                    completedToday: completedToday)
            case .weekly:
                // Default to Monday if the server hasn't specified a weekday.
                let day = weeklyDay ?? 2
                self.queueReminders(on: self.upcomingWeeklyDates(weekday: day, hour: hour, minute: minute),
                                    completedToday: completedToday)
            }
        }
    }

    /// Remove every queued check-in reminder (plus the legacy repeating one),
    /// then run `next` on the main actor.
    private func clearQueuedReminders(then next: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            var stale = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.reminderPrefix) }
            stale.append(Self.legacyIdentifier)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            DispatchQueue.main.async { next() }
        }
    }

    /// Fire dates for the next `dailyHorizon` days at hour:minute.
    private func upcomingDailyDates(hour: Int, minute: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<Self.dailyHorizon).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
    }

    /// Fire dates for the next `weeklyHorizon` occurrences of `weekday`.
    private func upcomingWeeklyDates(weekday: Int, hour: Int, minute: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Days until the next occurrence of `weekday` (0 when that is today).
        let currentWeekday = calendar.component(.weekday, from: today)
        let offsetToFirst = (weekday - currentWeekday + 7) % 7

        return (0..<Self.weeklyHorizon).compactMap { week in
            guard let day = calendar.date(byAdding: .day,
                                          value: offsetToFirst + week * 7,
                                          to: today) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
    }

    /// Queue a one-shot reminder for each date, skipping any that has already
    /// passed and today's if the check-in is already done.
    private func queueReminders(on dates: [Date], completedToday: Bool) {
        let calendar = Calendar.current
        let now = Date()
        let center = UNUserNotificationCenter.current()
        var queued = 0

        for date in dates {
            guard date > now else { continue }
            if completedToday && calendar.isDateInToday(date) { continue }

            let content = UNMutableNotificationContent()
            content.title = "Recovery Check-In"
            content.body = "Please complete your recovery check-in."
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            let request = UNNotificationRequest(
                identifier: Self.reminderPrefix + Self.identifierFormatter.string(from: date),
                content: content,
                trigger: trigger
            )
            center.add(request)
            queued += 1
        }

        print("📅 Queued \(queued) check-in reminder(s)")
    }

    private static let identifierFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Cancel Reminder

    /// Cancel every check-in reminder — the queued one-shots and the legacy
    /// repeating request. Used on logout/withdrawal; the schedule paths call
    /// clearQueuedReminders directly so they can re-arm in the same pass.
    func cancelReminder() {
        clearQueuedReminders { print("🛑 Check-in reminders cancelled") }
    }

    // MARK: - Test Notification (For Debugging)

    func sendTestNotification() {

        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.body = "This fires in 5 seconds."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 5,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }
}
