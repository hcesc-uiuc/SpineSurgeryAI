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
                print("Notifications authorized")
            } else {
                print("Notifications denied")
            }
        }
    }

    // MARK: - Check-in reminders (owned by ProfileStore.refreshCheckInReminders)
    //
    // One-shot reminders for the next 30 days / 8 weeks, NOT one repeating
    // trigger: a repeating request can't skip a single day, so cancelling
    // tonight's after a check-in killed every future reminder. Re-armed on
    // launch and after each submit, so the window keeps rolling forward.

    private static let reminderPrefix = "checkInReminder_"
    /// The old repeating request; still cleared for installs upgrading from it.
    private static let legacyIdentifier = "dailySurveyReminder"

    /// Clears the queue, then queues reminders for the schedule
    /// (paused/ended queue nothing). Skips today if it's already done.
    func applySchedule(cadence: SurveyCadence,
                       weeklyDay: Int,
                       hour: Int = 20,
                       minute: Int = 0,
                       appState: AppState) {
        // Read MainActor state now; the clear calls back on a background queue.
        let completedToday = appState.isCompletedToday

        clearQueuedReminders {
            switch cadence {
            case .paused, .ended:
                print("Check-in reminders cleared (\(cadence.rawValue))")
            case .daily:
                self.queueReminders(on: self.upcomingDates(startOffset: 0, stepDays: 1, count: 30,
                                                           hour: hour, minute: minute),
                                    completedToday: completedToday)
            case .weekly:
                let today = Calendar.current.component(.weekday, from: Date())
                self.queueReminders(on: self.upcomingDates(startOffset: (weeklyDay - today + 7) % 7,
                                                           stepDays: 7, count: 8,
                                                           hour: hour, minute: minute),
                                    completedToday: completedToday)
            }
        }
    }

    /// Cancels every check-in reminder (used on logout).
    func cancelReminder() {
        clearQueuedReminders { print("Check-in reminders cancelled") }
    }

    private func clearQueuedReminders(then next: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale + [Self.legacyIdentifier])
            DispatchQueue.main.async { next() }
        }
    }

    /// `count` fire dates at hour:minute, `stepDays` apart, starting `startOffset` days from today.
    private func upcomingDates(startOffset: Int, stepDays: Int, count: Int,
                               hour: Int, minute: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).compactMap { i in
            guard let day = calendar.date(byAdding: .day, value: startOffset + i * stepDays, to: today)
            else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
    }

    /// Skips dates already past, and today's if the check-in is done.
    private func queueReminders(on dates: [Date], completedToday: Bool) {
        let calendar = Calendar.current
        let now = Date()
        var queued = 0

        for date in dates where date > now && !(completedToday && calendar.isDateInToday(date)) {
            let content = UNMutableNotificationContent()
            content.title = "Recovery Check-In"
            content.body = "Please complete your recovery check-in."
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: Self.reminderPrefix + Self.identifierFormatter.string(from: date),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            ))
            queued += 1
        }
        print("Queued \(queued) check-in reminder(s)")
    }

    private static let identifierFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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
