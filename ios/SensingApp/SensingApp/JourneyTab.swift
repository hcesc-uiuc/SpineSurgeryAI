//
//  JourneyTab.swift
//  SensingApp
//
//  Tab metadata for the main TabView from MainAppView.swift.
//

import SwiftUI

enum JourneyTab: CaseIterable {
    case home, sensors, progress
#if DEBUG
    case debug
#endif
    
    var icon: String {
        switch self {
        case .home:     return "house.fill"
        case .sensors:  return "waveform"
        case .progress: return "calendar"
#if DEBUG
        case .debug:    return "ant.fill"
#endif
        }
    }
    
    var label: String {
        switch self {
        case .home:     return "Home"
        case .sensors:  return "Sensors"
        case .progress: return "Calendar"
#if DEBUG
        case .debug:    return "Debug"
#endif
        }
    }
    
    var accentColor: Color {
        switch self {
        case .home:     return Color(red: 0.42, green: 0.62, blue: 0.55) // sage green
        case .sensors:  return Color(red: 0.38, green: 0.55, blue: 0.75) // warm blue
        case .progress: return Color(red: 0.38, green: 0.55, blue: 0.75) // warm blue
#if DEBUG
        case .debug:    return Color(red: 0.55, green: 0.47, blue: 0.44) // muted brown
#endif
        }
    }
}
