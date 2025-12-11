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

    func markCompletedToday() { lastCompletedDate = todayString }
    func clearMissedDays() { missedDays.removeAll() }
}
