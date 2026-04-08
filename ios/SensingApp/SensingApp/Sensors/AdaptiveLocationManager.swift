//
//  AdaptiveLocationManager.swift
//  SensingApp
//
//  Created by Mohammod Mashfiqui Rabbi Shuvo on 2/21/26.
//

import CoreLocation
import Foundation
internal import Combine

/*
 
 ```
 ╔══════════════════════════════════════════════════════════════════════╗
 ║                          YOUR APP STARTS                             ║
 ║                                                                      ║
 ║  LocationManager.shared created (singleton init runs once)           ║
 ║  └─ delegate = self                                                  ║
 ║  └─ allowsBackgroundLocationUpdates = true                           ║
 ║  └─ pausesLocationUpdatesAutomatically = true                        ║
 ║  └─ activityType = .fitness                                          ║
 ╚══════════════════════════════════════════════════════════════════════╝
                                │
                                ▼
 ╔══════════════════════════════════════════════════════════════════════╗
 ║                       PERMISSION FLOW                                ║
 ║                                                                      ║
 ║  requestPermission() called                                          ║
 ║         │                                                            ║
 ║         ▼                                                            ║
 ║  iOS shows dialog ──────────────────────────────────────────┐        ║
 ║                                                             │        ║
 ║  User taps:                                                 │        ║
 ║  ┌─────────────────┐  ┌─────────────────┐  ┌────────────┐  │        ║
 ║  │ Only While Using│  │  Allow Once     │  │ Don't Allow│  │        ║
 ║  └────────┬────────┘  └────────┬────────┘  └─────┬──────┘  │        ║
 ║           │                   │                  │          │        ║
 ║           ▼                   ▼                  ▼          │        ║
 ║    .authorizedWhenInUse  (foreground      .denied            │        ║
 ║           │               session)        │                  │        ║
 ║           │                   │           ▼                  │        ║
 ║           │                   │     showSettingsLink()       │        ║
 ║           │                   │     (deep link to Settings)  │        ║
 ║           ▼                   ▼                              │        ║
 ║       startTracking()    startTracking()                     │        ║
 ║                                                             │        ║
 ║  Later — iOS shows upgrade prompt ◀─────────────────────────┘        ║
 ║  "Change to Always Allow?"                                           ║
 ║         │                                                            ║
 ║         ▼                                                            ║
 ║  .authorizedAlways → startTracking() (now with background)          ║
 ╚══════════════════════════════════════════════════════════════════════╝
                                │
                                ▼
 ╔══════════════════════════════════════════════════════════════════════╗
 ║                    TRACKING — HIGH ACCURACY MODE                     ║
 ║                                                                      ║
 ║  desiredAccuracy = kCLLocationAccuracyBest  (GPS chip ON)            ║
 ║  distanceFilter  = 5m                                                ║
 ║                                                                      ║
 ║  GPS fix computed by iOS every ~1–5 seconds                          ║
 ║         │                                                            ║
 ║         │  Has user moved > 5m since last update?                   ║
 ║         ├── NO  → iOS holds the fix, does not call your code        ║
 ║         │                                                            ║
 ║         └── YES → didUpdateLocations fires ──────────────────────┐   ║
 ║                                                                   │   ║
 ║                   ┌───────────────────────────────────────────┐  │   ║
 ║                   │  For each location in locations array:    │  │   ║
 ║                   │                                           │◀─┘   ║
 ║                   │  1. Print timestamp + coords + accuracy   │       ║
 ║                   │                                           │       ║
 ║                   │  2. Calculate distance from lastLocation  │       ║
 ║                   │     if distance >= 10m AND mode==lowPower │       ║
 ║                   │     → upgrade to highAccuracy             │       ║
 ║                   │                                           │       ║
 ║                   │  3. Save as lastLocation                  │       ║
 ║                   │                                           │       ║
 ║                   │  4. Reset stationaryTimer (30s countdown) │       ║
 ║                   └───────────────────────────────────────────┘       ║
 ╚══════════════════════════════════════════════════════════════════════╝
                                │
                ┌───────────────┴────────────────┐
                │                                │
         Updates keep                    No update for 30s
         arriving (user moving)          (user stopped)
                │                                │
                ▼                                ▼
         [STAY IN HIGH                  stationaryTimer fires
          ACCURACY MODE]                         │
                                                ▼
 ╔══════════════════════════════════════════════════════════════════════╗
 ║                    TRACKING — LOW POWER MODE                         ║
 ║                                                                      ║
 ║  desiredAccuracy = kCLLocationAccuracyKilometer  (GPS chip OFF)      ║
 ║  distanceFilter  = 500m                                              ║
 ║                                                                      ║
 ║  Cell towers + WiFi triangulation only                               ║
 ║  App receives zero callbacks while user is stationary                ║
 ║  Battery impact: near zero                                           ║
 ║                                                                      ║
 ║  Two things can wake this mode back up:                              ║
 ║                                                                      ║
 ║  ┌─────────────────────────┐   ┌──────────────────────────────────┐  ║
 ║  │ USER MOVES 500m+        │   │ iOS AUTO-RESUME                  │  ║
 ║  │                         │   │                                  │  ║
 ║  │ iOS delivers a coarse   │   │ iOS motion sensors (accelero-    │  ║
 ║  │ cell/WiFi location      │   │ meter) detect movement and       │  ║
 ║  │                         │   │ call locationManagerDidResume    │  ║
 ║  │ didUpdateLocations fires │   │ UpdatesAutomatically            │  ║
 ║  │ distance >= 10m detected │   │                                  │  ║
 ║  │ currentMode == .lowPower │   │ We set currentMode = .highAccu- │  ║
 ║  │ → upgrade to highAccuracy│   │ racy immediately                 │  ║
 ║  └──────────────┬──────────┘   └────────────────┬─────────────────┘  ║
 ║                 └──────────────┬────────────────┘                    ║
 ╚══════════════════════════════════════════════════════════════════════╝
                                  │
                                  ▼
                     Back to HIGH ACCURACY MODE
                     GPS chip turns on again
                     distanceFilter drops to 5m
                     Cycle repeats indefinitely


 ╔══════════════════════════════════════════════════════════════════════╗
 ║               iOS AUTO-PAUSE (INDEPENDENT LAYER)                     ║
 ║                                                                      ║
 ║  Runs inside iOS itself — not affected by app being suspended        ║
 ║                                                                      ║
 ║  iOS motion sensors detect stationary                                ║
 ║         │                                                            ║
 ║         ▼                                                            ║
 ║  locationManagerDidPauseLocationUpdates fires                        ║
 ║  → print log                                                         ║
 ║  → no more callbacks until iOS detects movement                      ║
 ║         │                                                            ║
 ║  iOS motion sensors detect movement again                            ║
 ║         │                                                            ║
 ║         ▼                                                            ║
 ║  locationManagerDidResumeLocationUpdates fires                       ║
 ║  → currentMode = .highAccuracy                                       ║
 ║  → GPS turns back on                                                 ║
 ╚══════════════════════════════════════════════════════════════════════╝


 ╔══════════════════════════════════════════════════════════════════════╗
 ║                    WHO CALLS WHAT                                     ║
 ║                                                                      ║
 ║  YOUR CODE calls:                                                    ║
 ║  └─ requestPermission()          (from a button tap)                 ║
 ║  └─ startTracking()              (from didChangeAuthorization)       ║
 ║  └─ stopTracking()               (on denial or app teardown)         ║
 ║                                                                      ║
 ║  iOS calls automatically (you never call these):                     ║
 ║  └─ didChangeAuthorization       (permission dialog response)        ║
 ║  └─ didUpdateLocations           (new GPS/cell fix available)        ║
 ║  └─ didPauseLocationUpdates      (iOS detected stationary)           ║
 ║  └─ didResumeLocationUpdates     (iOS detected movement)             ║
 ║  └─ didFailWithError             (GPS unavailable / denied)          ║
 ╚══════════════════════════════════════════════════════════════════════╝
 
 
 */


// ObservableObject allows SwiftUI views to subscribe to changes.
// When @Published properties change, any view holding this object re-renders.
class AdaptiveLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    // Singleton — one instance manages location for the entire app lifetime.
    // Created once, never destroyed, ensuring CLLocationManager is always active.
    static let shared = AdaptiveLocationManager()

    // The CoreLocation engine. This is the object that talks directly
    // to the GPS chip, cell towers, and WiFi positioning system.
    private let locationManager = CLLocationManager()

    // @Published means SwiftUI views automatically re-render when this changes.
    // ContentView reads this to decide which UI state to show.
    // Must be updated on the main thread — UI updates require it.
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // The most recently received location point.
    // Stored so the next incoming location can be compared against it
    // to calculate how far the user has moved between updates.
    // nil until the very first location arrives.
    private var lastLocation: CLLocation?
    
    // Unix timestamp of when lastLocation was recorded.
    // Using timeIntervalSince1970 instead of a Timer so it
    // does not freeze when the app is suspended.
    private var lastLocationTime: TimeInterval = 0

    // If the user moves more than this many meters between two consecutive
    // location updates while in low power mode, we upgrade to high accuracy.
    private let movementThreshold: CLLocationDistance = 10
    
    // How far (meters) the user must move within the time window
    // to be considered still moving. Below this = stationary.
    private let stationaryDistanceThreshold: CLLocationDistance = 10

    // How long (seconds) without a location update before we consider
    // the user stationary and drop to low power mode.
    private let stationaryTimeThreshold: TimeInterval = 30

    // The countdown timer that triggers the switch to low power mode.
    // Restarted on every incoming location update.
    // Only fires if no location arrives for stationaryThreshold seconds.
    private var stationaryTimer: Timer?
    
    //private let locationLogger = LocationFileLogger()

    // The two operating modes of the adaptive location manager.
    // highAccuracy: GPS chip on, tight distance filter — used when user is moving.
    // lowPower: GPS chip off, cell/WiFi only, wide filter — used when stationary.
    enum TrackingMode {
        case highAccuracy
        case lowPower
    }

    // didSet fires automatically every time currentMode is assigned a new value.
    // This ensures applyMode() is always called on mode change,
    // keeping CLLocationManager config in sync with current mode.
    // The guard prevents redundant reconfiguration if mode is set to itself.
    private var currentMode: TrackingMode = .highAccuracy {
        didSet {
            guard oldValue != currentMode else { return }
            applyMode()
            print("📍 Mode switched to: \(currentMode)")
        }
    }

    // MARK: - Init

    // Private init enforces the singleton — no other part of the app
    // can accidentally create a second LocationManager instance.
    private override init() {
        super.init()

        // Register self as the delegate.
        // From this point, iOS will call methods on this object when
        // location events occur. You never call those methods manually.
        locationManager.delegate = self

        // Without this, didUpdateLocations stops being called the moment
        // the app goes to the background. This is the single most critical
        // setting for any background location tracking use case.
        locationManager.allowsBackgroundLocationUpdates = true

        // Displays the blue status bar pill when tracking in the background.
        // Required by Apple for apps using always-on location.
        // Hiding it risks App Store rejection.
        locationManager.showsBackgroundLocationIndicator = true

        // Allows iOS to pause location delivery when it determines the user
        // is stationary using its own motion sensors (accelerometer, gyroscope).
        // This runs inside iOS itself — not inside your app process —
        // so it works even when the app is fully suspended.
        locationManager.pausesLocationUpdatesAutomatically = true

        // Hints to iOS what kind of movement to expect.
        // iOS uses this to tune internal power optimizations and auto-pause logic.
        // .fitness = walking/running. Wrong type = bad pause decisions = wasted battery.
        locationManager.activityType = .fitness
        
        print("AdaptiveLocationManager init called")
    }

    // MARK: - Permission

    func requestPermission() {
        // Triggers the iOS permission dialog.
        // First call: shows "When In Use / Allow Once / Don't Allow".
        // Apple does not offer "Always Allow" on the first dialog.
        // Second call (after When In Use granted): iOS shows the upgrade prompt.
        // iOS controls the timing of the upgrade — you cannot force it.
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Start / Stop

    func startTracking() {
        // Always begin in high accuracy mode.
        // The didSet on currentMode calls applyMode() automatically,
        // configuring CLLocationManager before updates begin.
        currentMode = .highAccuracy

        // Tells CLLocationManager to start requesting location fixes.
        // From this point, didUpdateLocations will be called automatically
        // by iOS whenever a new fix is available and distanceFilter is met.
        locationManager.startUpdatingLocation()
        print("✅ Tracking started")
    }

    func stopTracking() {
        // Tells CLLocationManager to stop requesting fixes.
        // GPS chip may power down — iOS manages hardware lifecycle.
        locationManager.stopUpdatingLocation()

        // Cancel the stationary timer so it does not fire after tracking stops.
        stationaryTimer?.invalidate()
        stationaryTimer = nil
        print("🛑 Tracking stopped")
    }

    // MARK: - Geofence

    func startMonitoringRegion(center: CLLocationCoordinate2D,
                               radius: CLLocationDistance = 100,
                               identifier: String) {
        // Geofence monitoring is available even when the app is killed.
        // iOS wakes the app when the user enters or exits the region.
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            print("⚠️ Region monitoring not available on this device")
            return
        }

        let region = CLCircularRegion(center: center, radius: radius, identifier: identifier)
        region.notifyOnEntry = true
        region.notifyOnExit  = true

        locationManager.startMonitoring(for: region)
        print("📌 Started monitoring region: \(identifier) radius: \(radius)m")
    }

    func stopMonitoringRegion(identifier: String) {
        // Find the matching monitored region by identifier and stop it.
        // You can monitor up to 20 regions simultaneously per app.
        for region in locationManager.monitoredRegions {
            if region.identifier == identifier {
                locationManager.stopMonitoring(for: region)
                print("📌 Stopped monitoring region: \(identifier)")
            }
        }
    }

    // MARK: - Mode Application

    private func applyMode() {
        switch currentMode {

        case .highAccuracy:
            // kCLLocationAccuracyBest requests GPS hardware.
            // iOS uses GPS satellites + WiFi + cell for maximum precision (~5–10m).
            // The GPS radio is the primary battery consumer in location tracking.
            locationManager.desiredAccuracy = kCLLocationAccuracyBest

            // Only call didUpdateLocations when the user moves at least 5m.
            // Set below our 10m movement threshold so we never miss
            // a movement event that should trigger a mode decision.
            locationManager.distanceFilter = 5
            Logger.shared.append("Location: Mode set to high accuracy");

        case .lowPower:
            // Requesting kilometer accuracy tells iOS it can turn the GPS
            // chip off and rely on cell tower + WiFi triangulation only.
            // Accuracy drops to 500m–1km but battery impact is near zero.
            locationManager.desiredAccuracy = kCLLocationAccuracyKilometer

            // Only wake the app if the user moves 500m+.
            // Sitting in an office or home produces zero callbacks.
            locationManager.distanceFilter = 15
            Logger.shared.append("Location: Mode set to low accuracy");
        }
    }

    // MARK: - CLLocationManagerDelegate

    // Called automatically by iOS when:
    // - The user responds to the permission dialog
    // - The user changes permission in the Settings app
    // - The app launches and CoreLocation checks existing permission state
    // You never call this yourself.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        /*
         ## Why This Works Without a Button Tap

         The key insight is that `locationManagerDidChangeAuthorization` fires automatically
         on every app launch — not just when the user responds to a dialog. iOS calls it
         immediately after `locationManager.delegate = self` is set in your `init()`,
         reporting whatever the current permission state is.
         ```
         App launches
              │
              ▼
         LocationManager.init() runs
              │
              ▼
         locationManager.delegate = self
              │
              ▼ (iOS calls this automatically, right now)
         locationManagerDidChangeAuthorization fires
              │
              ├── .notDetermined → requestAlwaysAuthorization() → dialog appears
              │
              ├── .authorizedAlways → startTracking() immediately
              │
              ├── .authorizedWhenInUse → startTracking() immediately
              │
              └── .denied / .restricted → stopTracking()
         */
        
        // Always dispatch to main thread before touching @Published properties.
        // SwiftUI requires all state mutations that drive UI to happen on main.
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
        }

        switch manager.authorizationStatus {

        case .authorizedAlways:
            // Full background tracking available.
            // didUpdateLocations fires even when the app is suspended.
            print("✅ Always Allow granted — full background tracking active")
            startTracking()

        case .authorizedWhenInUse:
            // Foreground tracking only.
            // didUpdateLocations fires while app is in the foreground.
            // iOS will show the Always Allow upgrade prompt on its own schedule.
            print("⚠️ When In Use only — background tracking limited")
            startTracking()

        case .denied:
            // User explicitly denied permission.
            // requestAlwaysAuthorization() is silently ignored from now on.
            // The only recovery path is the Settings deep link.
            print("❌ Permission denied — direct user to Settings")
            stopTracking()

        case .restricted:
            // Device policy (parental controls, MDM) prevents location access.
            // Nothing you can do programmatically — inform the user.
            print("❌ Permission restricted by device policy")
            stopTracking()

        case .notDetermined:
            // The dialog has not been shown yet.
            // Wait — do not call startTracking() here.
            print("⏳ Permission not yet determined")
            //locationManager.requestAlwaysAuthorization()
            
        @unknown default:
            break
        }
    }

    // Called automatically by iOS every time a new location fix is ready
    // AND the user has moved more than distanceFilter meters since last delivery.
    // Fires in both foreground and background (when properly configured).
    // iOS may batch multiple locations into one call — always iterate all of them.
    // You never call this yourself.
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {

        // iOS may deliver multiple locations in one call when:
        // - The app was suspended and fixes were queued up
        // - The device was briefly in a tunnel or indoors
        // We process every location in order — oldest to newest.
        
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        
        for location in locations {

            // ISO8601 timestamp from the GPS fix itself —
            // this is when the position was computed, not when our code ran.
            // These can differ when the app was suspended and fixes were batched.
            let timestamp = ISO8601DateFormatter().string(from: location.timestamp)
            let now = Date().timeIntervalSince1970
            let timeString = formatter.string(from: location.timestamp)
            
            print("""
            📍 [\(timestamp)]
               lat:      \(location.coordinate.latitude)
               lng:      \(location.coordinate.longitude)
               accuracy: \(Int(location.horizontalAccuracy))m
               mode:     \(currentMode)
            """)
            
            let unixTime = Int64(location.timestamp.timeIntervalSince1970 * 1000)
            let entry = "\(unixTime), \(timeString),  \(location.coordinate.latitude),\(location.coordinate.longitude),\(Int(location.horizontalAccuracy))m, \(currentMode)"
            LocationFileLogger.shared.log(entry)

            
            if let last = lastLocation {

                // How far the user has moved since the last recorded position
                let distanceMoved = location.distance(from: last)

                // How long has elapsed since we recorded lastLocation
                let timeElapsed = now - lastLocationTime

                if distanceMoved >= stationaryDistanceThreshold {
                    // User has moved more than 10m — they are actively moving.
                    // Update the reference point and timestamp to this new position.
                    // Reset the clock — start measuring from here.
                    print("🏃 Moved \(Int(distanceMoved))m — user is moving")
                    let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
                    let entry = "\(unixTime)], 🏃 Moved \(Int(distanceMoved))m — user is moving"
                    Logger.shared.append(entry)
                    
                    
                    lastLocation = location
                    lastLocationTime = now

                    // If we were in low power mode, upgrade back to high accuracy
                    // now that movement has been confirmed.
                    if currentMode == .lowPower {
                        print("⬆️ Upgrading to high accuracy")
                        currentMode = .highAccuracy
                        let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
                        let entry = "\(unixTime)], ⬆️ Upgrading to high accuracy"
                        Logger.shared.append(entry)
                    }

                } else {
                    // User has NOT moved more than 10m since lastLocation.
                    // Check how long they have been within this radius.
                    // We do NOT update lastLocation or lastLocationTime here —
                    // we keep measuring elapsed time from the original reference point.
                    // This way timeElapsed keeps growing until movement is detected.

                    if timeElapsed >= stationaryTimeThreshold && currentMode == .highAccuracy {
                        // User has stayed within 10m for over 60 seconds.
                        // Switch to low power — GPS chip turns off.
                        
                        let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
                        let entry = "\(unixTime), 🧍 Within \(Int(distanceMoved))m for \(Int(timeElapsed))s — switching to low power"
                        Logger.shared.append(entry)
                        
                        currentMode = .lowPower
                    } else {
                        // Still within the time window — log how long they have been still
                        print("⏱️ Within \(Int(distanceMoved))m for \(Int(timeElapsed))s — still watching")
                        
                        let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
                        let entry = "\(unixTime), ⏱️ Within \(Int(distanceMoved))m for \(Int(timeElapsed))s — still watching"
                        Logger.shared.append(entry)
                    }
                }

            } else {
                // This is the very first location we have ever received.
                // Set it as the initial reference point and start the clock.
                print("📍 First location received — starting stationary watch")
                
                let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
                let entry = "\(unixTime), 📍 First location received — starting stationary watch"
                Logger.shared.append(entry)
                
                lastLocation = location
                lastLocationTime = now
            }
            
            
        }
    }

    // Called automatically by iOS when it decides to pause location delivery.
    // iOS makes this decision using its own motion sensors combined with
    // the activityType hint. Runs inside iOS — works even when app is suspended.
    // This is independent of your stationaryTimer — either can fire first.
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        print("⏸️ iOS auto-paused location — user is stationary")
        
        let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
        let entry = "\(unixTime), iOS auto-paused location — user is stationary"
        Logger.shared.append(entry)
        
        // No action needed — iOS will resume automatically when movement is detected.
        // The stationaryTimer may also have already fired at this point.
    }

    // Called automatically by iOS when its motion sensors detect movement
    // after an auto-pause. This is your signal to upgrade back to high accuracy
    // so you do not miss movement detail in the first moments of activity.
    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        print("▶️ iOS resumed location — user is moving again")
        
        let unixTime = Int64(Date().timeIntervalSince1970 * 1000)
        let entry = "\(unixTime), iOS resumed location — user is moving again"
        Logger.shared.append(entry)
        
        // Upgrade immediately — didSet triggers applyMode(), GPS turns back on.
        currentMode = .highAccuracy
    }

    // Called automatically by iOS when location cannot be determined.
    // Common causes: no GPS signal indoors, airplane mode, permission revoked mid-session.
    // You never call this yourself.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError else {
            print("❌ Unknown location error: \(error.localizedDescription)")
            return
        }

        switch clError.code {

        case .denied:
            // User revoked permission while the app was running.
            // Stop tracking — didChangeAuthorization will also fire
            // and handle the UI update via the @Published property.
            print("❌ Permission revoked mid-session — stopping tracking")
            stopTracking()

        case .locationUnknown:
            // Temporary inability to get a fix — indoors, tunnel, poor signal.
            // CLLocationManager keeps trying automatically. Just wait.
            print("⏳ Location temporarily unknown — waiting for signal")

        case .network:
            // Network-based location (cell/WiFi) is unavailable.
            // GPS may still work — CLLocationManager will fall back automatically.
            print("⚠️ Network location unavailable — falling back to GPS only")

        default:
            print("❌ Location error (\(clError.code.rawValue)): \(clError.localizedDescription)")
        }
    }

    // Called automatically by iOS when the user enters a monitored circular region.
    // Works even when the app is killed — iOS relaunches the app in the background
    // to deliver this event. The app gets a short window to handle it.
    // You never call this yourself.
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        print("🟢 Entered region: \(region.identifier)")

        // Upgrade to high accuracy when entering a region —
        // the user is likely at a point of interest and precise tracking matters.
        currentMode = .highAccuracy

        // Post a local notification so the user knows they entered the region,
        // even if the app is in the background.
        //postRegionNotification(title: "Arrived", body: "You entered: \(region.identifier)")
    }

    // Called automatically by iOS when the user exits a monitored circular region.
    // Same background relaunch behaviour as didEnterRegion.
    // You never call this yourself.
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        print("🔴 Exited region: \(region.identifier)")
        //postRegionNotification(title: "Departed", body: "You left: \(region.identifier)")
    }

    // Called automatically by iOS if region monitoring fails for a specific region.
    // Common cause: the app has reached the 20-region monitoring limit.
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                         withError error: Error) {
        print("❌ Region monitoring failed for \(region?.identifier ?? "unknown"): \(error.localizedDescription)")
    }
    
    
    // MARK: - Helpers

    //    private func postRegionNotification(title: String, body: String) {
    //        // Only post notifications if the user has granted notification permission.
    //        // This is a separate permission from location — request it at app launch
    //        // using UNUserNotificationCenter.current().requestAuthorization().
    //        let content = UNMutableNotificationContent()
    //        content.title = title
    //        content.body  = body
    //        content.sound = .default
    //
    //        let request = UNNotificationRequest(
    //            identifier: UUID().uuidString,
    //            content: content,
    //            trigger: nil  // nil = deliver immediately
    //        )
    //
    //        UNUserNotificationCenter.current().add(request) { error in
    //            if let error {
    //                print("❌ Notification error: \(error.localizedDescription)")
    //            }
    //        }
    //    }
}
