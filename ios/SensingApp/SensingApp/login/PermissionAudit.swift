//
//  PermissionAudit.swift
//  SensingApp
//
//  File checks to see if permissions are still given / approved by user
//  The card filter (PermissionsFlowView), the launch audit (AuthLoginView) and the foreground
//  audit (MainAppView) all use it, so any permission turned off re-shows its card.
//

import CoreMotion
import CoreLocation
import HealthKit
import UserNotifications
import SensorKit

enum PermissionAudit {

    static let notificationsFlagKey = "journey_notifications_authorized"
    static let sensorKitFlagKey = "sk_authorization_status"

    static func isGranted(_ permission: JourneyPermission) -> Bool {
        switch permission {
        case .motion:
            // No motion hardware (simulator) counts as granted.
            return !CMMotionActivityManager.isActivityAvailable()
                || CMMotionActivityManager.authorizationStatus() == .authorized
        case .location:
            return CLLocationManager().authorizationStatus == .authorizedAlways
        case .sensorKit:
            // Every required sensor, not just one (sleep sessions excluded, see registry).
            return SensorKitRegistry.missingSensors.isEmpty
        case .notifications:
            // Synchronous proxy, kept fresh by syncNotificationsFlag().
            return UserDefaults.standard.bool(forKey: notificationsFlagKey)
        case .health:
            // iOS hides read denials, so this can only tell "never asked".
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
            return HKHealthStore().authorizationStatus(for: stepType) != .notDetermined
        }
    }

    /// Shared by both audits. The sync pass runs first so a missing permission
    /// routes to the cards before MainAppView draws; the async pass refreshes
    /// the notifications flag and checks again.
    private static var everythingGranted: Bool {
        JourneyPermission.allCases.allSatisfy { isGranted($0) }
    }

    static func audit(onMissing: @escaping () -> Void) {
        #if !targetEnvironment(simulator)
        // All sensors on but the flag says otherwise (old "denied" left behind)
        if isGranted(.sensorKit),
           UserDefaults.standard.integer(forKey: sensorKitFlagKey) != SRAuthorizationStatus.authorized.rawValue {
            sensorKitDidBecomeGranted()
        }
        #endif
        if !everythingGranted { onMissing() }
        Task {
            await syncNotificationsFlag()
            if !everythingGranted { onMissing() }
        }
    }

    static func syncNotificationsFlag() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        UserDefaults.standard.set(status == .authorized || status == .provisional,
                                  forKey: notificationsFlagKey)
    }

    /// Call when the SensorKit card is passed. Mash's standalone readers gate on
    /// sk_authorization_status, and a re-enabled sensor needs recording restarted.
    static func sensorKitDidBecomeGranted() {
        UserDefaults.standard.set(SRAuthorizationStatus.authorized.rawValue, forKey: sensorKitFlagKey)
        SensorKitRegistry.startAllRecording(checkAuthorization: true)
    }
}

// MARK: - Participant-facing sensor names (SensorKit card)

extension SRSensor {
    var consentName: String {
        switch self {
        case .accelerometer:        return "Wrist movement"
        case .rotationRate:         return "Rotation"
        case .onWristState:         return "Watch wear time"
        case .ambientPressure:      return "Elevation"
        case .ambientLightSensor:   return "Ambient light"
        case .deviceUsageReport:    return "Phone usage"
        case .phoneUsageReport:     return "Phone calls"
        case .messagesUsageReport:  return "Messages"
        case .keyboardMetrics:      return "Keyboard"
        case .photoplethysmogram:   return "Pulse sensor"
        case .heartRate:            return "Heart rate"
        case .wristTemperature:     return "Wrist temperature"
        case .sleepSessions:        return "Sleep"
        default:                    return rawValue
        }
    }

    var consentDetail: String {
        switch self {
        case .accelerometer:        return "How your wrist moves, from Apple Watch"
        case .rotationRate:         return "How your device turns as you move"
        case .onWristState:         return "When your Apple Watch is being worn"
        case .ambientPressure:      return "Changes in elevation, like taking stairs"
        case .ambientLightSensor:   return "How bright your surroundings are"
        case .deviceUsageReport:    return "How often you use your phone but never what you do in apps"
        case .phoneUsageReport:     return "Number and length of calls but never who or what is said"
        case .messagesUsageReport:  return "Number of messages but never their content or contacts"
        case .keyboardMetrics:      return "Typing speed and accuracy but never what you type"
        case .photoplethysmogram:   return "Light-based pulse readings from Apple Watch"
        case .heartRate:            return "Heart rate from Apple Watch"
        case .wristTemperature:     return "Skin temperature from Apple Watch during sleep"
        case .sleepSessions:        return "When you sleep and for how long"
        default:                    return ""
        }
    }
}
