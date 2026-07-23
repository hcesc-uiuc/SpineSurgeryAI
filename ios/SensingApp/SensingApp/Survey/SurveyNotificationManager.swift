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

    /// Reschedule the local check-in reminder to match the coordinator-set
    /// survey schedule pulled from the server (ProfileStore.bootstrap):
    ///   • daily   → a repeating reminder every day at hour:minute
    ///   • weekly  → a repeating reminder only on `weeklyDay` (1=Sun…7=Sat)
    ///   • paused  → no reminder (cancelled)
    ///   • ended   → no reminder (cancelled)
    /// Also cancels if today's check-in is already complete. Uses the same
    /// "dailySurveyReminder" identifier so it always replaces the existing one.
    func applySchedule(cadence: SurveyCadence,
                       weeklyDay: Int?,
                       hour: Int = 20,
                       minute: Int = 0,
                       appState: AppState) {

        cancelReminder()

        // Nothing to schedule if the study is paused/ended or already done today.
        guard !appState.isCompletedToday else { return }

        switch cadence {
        case .paused, .ended:
            return
        case .daily:
            scheduleReminder(hour: hour, minute: minute, weekday: nil)
        case .weekly:
            // Default to Monday if the server hasn't specified a weekday.
            scheduleReminder(hour: hour, minute: minute, weekday: weeklyDay ?? 2)
        }
    }

    /// Core scheduler shared by the daily and weekly paths. When `weekday` is
    /// nil the trigger fires every day; otherwise only on that weekday.
    private func scheduleReminder(hour: Int, minute: Int, weekday: Int?) {
        let content = UNMutableNotificationContent()
        content.title = "Recovery Check-In"
        content.body = "Please complete your recovery check-in."
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        if let weekday { components.weekday = weekday }

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
        print("📅 Check-in reminder scheduled (weekday: \(weekday.map(String.init) ?? "daily"))")
    }

    // MARK: - Cancel Reminder

    func cancelReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(
                withIdentifiers: ["dailySurveyReminder"]
            )

        print("🛑 Reminder cancelled")
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
