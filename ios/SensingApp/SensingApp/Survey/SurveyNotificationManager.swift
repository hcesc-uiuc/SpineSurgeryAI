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
