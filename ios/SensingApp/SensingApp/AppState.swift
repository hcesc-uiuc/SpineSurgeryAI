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

    // Whether a check-in is scheduled today now comes from the
    // server-authoritative survey schedule — read ProfileStore.shared
    // .isCheckInDueToday() from the (MainActor) views instead of a
    // hardcoded flag here.

    func markCompletedToday() { lastCompletedDate = todayString }
    func clearMissedDays() { missedDays.removeAll() }
}
