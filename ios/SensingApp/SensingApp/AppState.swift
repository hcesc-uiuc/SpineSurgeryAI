import Foundation
internal import Combine


class AppState: ObservableObject {
    @Published var lastCompletedDate: String? {
        didSet { UserDefaults.standard.set(lastCompletedDate, forKey: "lastCompletedDate") }
    }
    @Published var missedDays: [String] = []

    init() {
        self.lastCompletedDate = UserDefaults.standard.string(forKey: "lastCompletedDate")
    }

    var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var isCompletedToday: Bool {
        lastCompletedDate == todayString
    }

    // "Is a check-in scheduled today" lives in ProfileStore.isCheckInDueToday()
    // (server-set schedule), not here.

    func markCompletedToday() { lastCompletedDate = todayString }
    func clearMissedDays() { missedDays.removeAll() }
}
