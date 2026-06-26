//
//  AppState.swift
//  SensingApp
//
//  Created by Samir Kurudi on 11/20/25.
//

import Foundation
internal import Combine


class AppState: ObservableObject {
    @Published var lastCompletedDate: String? = nil
    @Published var missedDays: [String] = []

    var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var isCompletedToday: Bool {
        lastCompletedDate == todayString
    }

    // TODO: Wire to the real survey schedule. Today every day has a check-in
    // (mirrors SurveyNotificationManager's daily 20:00 reminder). When the study
    // defines which days a survey actually pops up, drive this from that schedule
    // (e.g. a SurveySchedule service / per-day list) so the Home FAB greys out on
    // non-survey days. `true` = a survey is available today.
    var isSurveyScheduledToday: Bool { true }

    func markCompletedToday() { lastCompletedDate = todayString }
    func clearMissedDays() { missedDays.removeAll() }
}
