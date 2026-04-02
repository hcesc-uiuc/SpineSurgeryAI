//
//  PermissionsFlowView.swift
//  SpineSurgeryUI
//
//  Created by UIUCSpineSurgey on 3/9/26.
//

import SwiftUI
import CoreMotion
import CoreLocation
import HealthKit
import UserNotifications

// MARK: - Permission Model

enum JourneyPermission: CaseIterable, Identifiable {
    case motion, location, health, notifications

    var id: Self { self }

    var icon: String {
        switch self {
        case .motion:        return "figure.walk.motion"
        case .location:      return "location.fill"
        case .health:        return "heart.fill"
        case .notifications: return "bell.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .motion:        return Color(red: 0.80, green: 0.65, blue: 0.58)
        case .location:      return Color(red: 0.42, green: 0.62, blue: 0.55)
        case .health:        return Color(red: 0.80, green: 0.35, blue: 0.38)
        case .notifications: return Color(red: 0.55, green: 0.48, blue: 0.75)
        }
    }

    var title: String {
        switch self {
        case .motion:        return "Motion & Activity"
        case .location:      return "Location Access"
        case .health:        return "Health Data"
        case .notifications: return "Reminders"
        }
    }

    var headline: String {
        switch self {
        case .motion:        return "Track your movement patterns"
        case .location:      return "Understand your daily activity"
        case .health:        return "Connect with your health metrics"
        case .notifications: return "Stay on top of your recovery"
        }
    }

    var explanation: String {
        switch self {
        case .motion:
            return "Your phone's motion sensors help us track walking patterns and physical activity during your recovery — giving your care team valuable insight into your progress."
        case .location:
            return "Location data helps us understand how much you're moving around day-to-day. This is used only for research purposes and is never shared outside the study."
        case .health:
            return "Connecting to Apple Health lets us read step counts, heart rate, and other metrics that paint a fuller picture of your recovery journey."
        case .notifications:
            return "We'll send gentle daily reminders for check-ins and surveys so nothing slips through the cracks. You can adjust notification timing in Settings."
        }
    }

    var buttonLabel: String { "Allow Access" }
    var stepLabel: String {
        switch self {
        case .motion:        return "Step 1 of 4"
        case .location:      return "Step 2 of 4"
        case .health:        return "Step 3 of 4"
        case .notifications: return "Step 4 of 4"
        }
    }
}

// MARK: - Permissions Flow Coordinator

struct PermissionsFlowView: View {
    @AppStorage("permissionsComplete") private var permissionsComplete = false
    @State private var currentIndex = 0
    @State private var showingDeniedAlert = false
    @State private var deniedPermissionName = ""
    @State private var cardAppeared = false

    private let permissions = JourneyPermission.allCases
    private let locationManager = CLLocationManager()
    private let healthStore = HKHealthStore()
    
    @State private var locationRequester: LocationPermissionRequester?
    var onComplete: () -> Void
    
    //MashToDo: Akarsh, at a high level, this file
    //needs a description on how different parts are called
    //at what sequence. Also, it is not clear if a
    //participant did not provide access in the first try
    //do we ask again next time they open/resume the app? 
    
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.95, blue: 0.91),
                    Color(red: 0.95, green: 0.91, blue: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress dots
                progressDots
                    .padding(.top, 60)
                    .padding(.bottom, 32)

                // Permission card
                if currentIndex < permissions.count {
                    permissionCard(for: permissions[currentIndex])
                        .id(currentIndex) // forces re-render + re-animation
                        .opacity(cardAppeared ? 1 : 0)
                        .offset(y: cardAppeared ? 0 : 30)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: cardAppeared)
                }

                Spacer()
            }
        }
        .onAppear { triggerCardAppear() }
        .alert("Permission Required", isPresented: $showingDeniedAlert) {
            Button("Open Settings") { openAppSettings() }
            Button("Try Again") { requestCurrentPermission() }
        } message: {
            Text("Journey needs \(deniedPermissionName) access to continue. Please allow it in Settings.")
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<permissions.count, id: \.self) { i in
                Capsule()
                    .fill(i <= currentIndex
                          ? Color(red: 0.42, green: 0.62, blue: 0.55)
                          : Color(red: 0.80, green: 0.70, blue: 0.66).opacity(0.4))
                    .frame(width: i == currentIndex ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentIndex)
            }
        }
    }

    // MARK: - Permission Card

    private func permissionCard(for permission: JourneyPermission) -> some View {
        VStack(spacing: 28) {

            // Icon
            ZStack {
                Circle()
                    .fill(permission.iconColor.opacity(0.15))
                    .frame(width: 100, height: 100)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [permission.iconColor, permission.iconColor.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)
                    .shadow(color: permission.iconColor.opacity(0.4), radius: 14, y: 6)

                Image(systemName: permission.icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }

            // Text
            VStack(spacing: 10) {
                Text(permission.stepLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                    .tracking(1.2)
                    .textCase(.uppercase)

                Text(permission.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))

                Text(permission.headline)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.62, blue: 0.55))

                Text(permission.explanation)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29).opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
            }

            // Allow button
            Button(action: requestCurrentPermission) {
                Text(permission.buttonLabel)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [permission.iconColor, permission.iconColor.opacity(0.80)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: permission.iconColor.opacity(0.35), radius: 10, y: 5)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95).opacity(0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.12), radius: 24, y: 10)
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Permission Requests

    private func isAlreadyGranted(_ permission: JourneyPermission) -> Bool {
        switch permission {
        case .motion:
            return CMMotionActivityManager.authorizationStatus() == .authorized
        case .location:
            let status = locationManager.authorizationStatus
            return status == .authorizedWhenInUse || status == .authorizedAlways
        case .health:
            return true // HealthKit always returns "authorized" from app's perspective
        case .notifications:
            // Can't check synchronously — let it proceed
            return false
        }
    }
    
    private func requestCurrentPermission() {
        guard currentIndex < permissions.count else { return }
        let permission = permissions[currentIndex]

        // If already authorized, just advance
        if isAlreadyGranted(permission) {
            advanceToNext()
            return
        }

        Task {
            let granted: Bool

            switch permission {
            case .motion:
                granted = await requestMotion()
            case .location:
                granted = await requestLocation()
            case .health:
                granted = await requestHealth()
            case .notifications:
                granted = await requestNotifications()
            }

            await MainActor.run {
                if granted {
                    advanceToNext()
                } else {
                    deniedPermissionName = permission.title
                    showingDeniedAlert = true
                }
            }
        }
    }

    private func advanceToNext() {
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if currentIndex + 1 >= permissions.count {
                permissionsComplete = true
                onComplete()
            } else {
                currentIndex += 1
                triggerCardAppear()
            }
        }
    }

    private func triggerCardAppear() {
        cardAppeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            cardAppeared = true
        }
    }

    // MARK: - Individual Permission Handlers

    private func requestMotion() async -> Bool {
        await withCheckedContinuation { continuation in
            guard CMMotionActivityManager.isActivityAvailable() else {
                continuation.resume(returning: true) // simulator — skip gracefully
                return
            }
            
            let manager = CMMotionActivityManager()
            
            // Start live updates — this is what reliably triggers the iOS prompt
            manager.startActivityUpdates(to: .main) { _ in }
            
            // Give iOS a moment to process the authorization response
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                manager.stopActivityUpdates()
                let status = CMMotionActivityManager.authorizationStatus()
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // In PermissionsFlowView — replace requestLocation()
    private func requestLocation() async -> Bool {
        await withCheckedContinuation { continuation in
            let requester = LocationPermissionRequester {
                continuation.resume(returning: $0)
                self.locationRequester = nil
            }
            self.locationRequester = requester // strong reference kept alive
            requester.request()
        }
    }
    
    private func requestHealth() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let types: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!
        ]
        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: nil, read: types) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Location Delegate Helper

// MARK: - Location Permission Requester

class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var completion: ((Bool) -> Void)?
    private var resumed = false

    init(completion: @escaping (Bool) -> Void) {
        self.manager = CLLocationManager()
        self.completion = completion
        super.init()
        self.manager.delegate = self
    }

    func request() {
        DispatchQueue.main.async {
            let status = self.manager.authorizationStatus
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.resume(true)
            case .denied, .restricted:
                self.resume(false)
            case .notDetermined:
                self.manager.requestWhenInUseAuthorization()
            @unknown default:
                self.resume(false)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            let status = manager.authorizationStatus
            guard status != .notDetermined else { return }
            self.resume(status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }

    private func resume(_ granted: Bool) {
        guard !resumed else { return }
        resumed = true
        completion?(granted)
        completion = nil
    }
}
