//
//  RecoveryDay.swift
//  SensingApp
//
//  How far into the study a participant is, counted from the first time the
//  Home screen appeared (`journey_first_open_date`, written once there).
//
//  Extracted so Home and the Sensors tab cannot drift apart on the arithmetic.
//  The caller passes the day it is asking about rather than this reading
//  `Date()` itself: Home holds midnight-of-today in @State precisely so that
//  refreshing it re-renders the screen at a day rollover, and a helper that
//  read the clock directly would quietly defeat that.
//

import Foundation

enum RecoveryDay {

    /// 1-based day number as of `date`. Returns 1 when the anchor is unset, and
    /// never returns less than 1.
    static func day(asOf date: Date) -> Int {
        let firstOpen = UserDefaults.standard.double(forKey: "journey_first_open_date")
        guard firstOpen != 0 else { return 1 }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: firstOpen))
        let end = cal.startOfDay(for: date)
        return max(1, (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
    }
}
