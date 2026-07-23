//
//  SettingsView.swift
//  SensingApp
//
//  Settings sheet. Extracted from MainAppView.swift (was MainAppView.SettingsView).
//

import SwiftUI

struct SettingsView: View {
    let accentColor: Color
    var onLogout: () -> Void
    @State private var showingLogoutAlert = false
    @State private var showingPrivacySheet = false
    @State private var showingHelpSheet = false

    // Synced user profile — drives the Study Profile card so participants
    // (and coordinators troubleshooting with them) can verify their account
    // and see whether their progress is backed up to the study server.
    @ObservedObject private var profileStore = ProfileStore.shared
    @AppStorage("journey_first_open_date") private var firstOpenTimestamp: Double = 0
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.91),
                        Color(red: 0.95, green: 0.91, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(accentColor.opacity(0.15))
                                .frame(width: 60, height: 60)
                            Image(systemName: "person.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(accentColor)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("User")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            Text("Journey Study Participant")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                        }
                        Spacer()
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                    )

                    studyProfileCard

                    VStack(spacing: 0) {
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            settingsRow(icon: "bell.fill", label: "Notifications", color: Color(red: 0.55, green: 0.48, blue: 0.75))
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 56)
                        Button { showingPrivacySheet = true } label: {
                            settingsRow(icon: "lock.fill", label: "Privacy", color: Color(red: 0.38, green: 0.55, blue: 0.75))
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 56)
                        Button { showingHelpSheet = true } label: {
                            settingsRow(icon: "questionmark.circle.fill", label: "Help & Support", color: Color(red: 0.42, green: 0.62, blue: 0.55))
                        }
                        .buttonStyle(.plain)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                            .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
                    )

                    Button(action: { showingLogoutAlert = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Log Out")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.75, green: 0.25, blue: 0.22).opacity(0.10))
                        )
                    }

                    Spacer()
                }
                .padding(24)
                }
            }
            .navigationTitle("Settings")
            .alert("Log Out", isPresented: $showingLogoutAlert) {
                Button("Log Out", role: .destructive) { onLogout() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to log out of Journey?")
            }
            .sheet(isPresented: $showingPrivacySheet) {
                privacySheet
            }
            .sheet(isPresented: $showingHelpSheet) {
                helpSheet
            }
        }
    }

    // MARK: - Study Profile card
    //
    // Read-only account summary backed by the synced UserProfile: lets a
    // participant confirm their enrollment restored correctly on any device,
    // and gives coordinators something concrete to check when troubleshooting.
    private var studyProfileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Study Profile")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            infoRow(icon: "person.text.rectangle", label: "Study ID", value: studyIdText,
                    color: Color(red: 0.80, green: 0.42, blue: 0.30))
            Divider().padding(.leading, 56)
            infoRow(icon: "number", label: "Participant code", value: participantCodeText,
                    color: Color(red: 0.80, green: 0.55, blue: 0.45))
            Divider().padding(.leading, 56)
            infoRow(icon: "calendar", label: "Joined study", value: joinedDateText,
                    color: Color(red: 0.42, green: 0.62, blue: 0.55))
            Divider().padding(.leading, 56)
            infoRow(icon: "figure.walk", label: "Recovery day", value: recoveryDayText,
                    color: Color(red: 0.55, green: 0.48, blue: 0.75))
            Divider().padding(.leading, 56)
            infoRow(icon: "clock.arrow.circlepath", label: "Check-in schedule", value: scheduleText,
                    color: Color(red: 0.50, green: 0.60, blue: 0.45))
            Divider().padding(.leading, 56)
            infoRow(icon: "checkmark.circle", label: "Check-ins completed", value: "\(checkInsCompleted)",
                    color: Color(red: 0.38, green: 0.55, blue: 0.75))
            Divider().padding(.leading, 56)
            infoRow(icon: "icloud", label: "Backup", value: syncStatusText,
                    color: Color(red: 0.60, green: 0.55, blue: 0.50))
                .padding(.bottom, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.10), radius: 12, y: 4)
        )
    }

    /// Short, human-readable slice of the anonymous participant hash —
    /// enough for a coordinator to match against the dashboard.
    private var participantCodeText: String {
        let pid = ParticipantID.current
        guard pid != "unidentified" else { return "—" }
        return pid.prefix(8).uppercased()
    }

    /// Server-assigned study id (e.g. "P01"), or a dash until the server
    /// has answered getstudyid.
    private var studyIdText: String {
        profileStore.profile?.studyId ?? "—"
    }

    /// Coordinator-set check-in cadence (Daily / Weekly / Paused / Study complete).
    private var scheduleText: String {
        (profileStore.profile?.surveySchedule ?? SurveySchedule()).displayText
    }

    private var joinedDateText: String {
        let timestamp = profileStore.profile?.enrolledAt
            ?? profileStore.profile?.firstOpenDate
            ?? (firstOpenTimestamp != 0 ? firstOpenTimestamp : nil)
        guard let timestamp else { return "—" }
        return Date(timeIntervalSince1970: timestamp)
            .formatted(.dateTime.month(.abbreviated).day().year())
    }

    private var recoveryDayText: String {
        guard firstOpenTimestamp != 0 else { return "Day 1" }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: firstOpenTimestamp))
        let today = cal.startOfDay(for: Date())
        let day = max(1, (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1)
        return "Day \(day)"
    }

    private var checkInsCompleted: Int {
        profileStore.profile?.surveyHistory.filter(\.completed).count ?? 0
    }

    private var syncStatusText: String {
        if let synced = profileStore.lastSyncedAt {
            return "Backed up \(synced.formatted(.relative(presentation: .named)))"
        }
        return "Saved on this device"
    }

    private func infoRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var privacySheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.91),
                        Color(red: 0.95, green: 0.91, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About This Study")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            Text("Journey is a multi-institution research study of recovery after spine surgery. Your phone and watch help your care team understand how you're healing day to day.")
                                .font(.system(size: 15, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                .lineSpacing(3)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What We Collect")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            ForEach(["Motion & activity", "Location", "Health metrics (steps, heart rate, sleep)", "Daily check-in answers"], id: \.self) { item in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(red: 0.42, green: 0.62, blue: 0.55))
                                        .frame(width: 6, height: 6)
                                    Text(item)
                                        .font(.system(size: 15, design: .rounded))
                                        .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your Data")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            Text("Your data is used for research purposes only and is never sold or shared outside the study. You may withdraw at any time by contacting your study coordinator.")
                                .font(.system(size: 15, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                .lineSpacing(3)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                        )
                    }
                    .padding(20)
                }
            }
            .navigationTitle("About This Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingPrivacySheet = false }
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var helpSheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.95, blue: 0.91),
                        Color(red: 0.95, green: 0.91, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Questions about the study or the app? Your study coordinator is happy to help.")
                                .font(.system(size: 15, design: .rounded))
                                .foregroundStyle(Color(red: 0.40, green: 0.32, blue: 0.29))
                                .lineSpacing(3)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                        )
                        VStack(spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Study coordinator")
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                    Text("Contact details provided by your care team")
                                        .font(.system(size: 13, design: .rounded))
                                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                }
                                Spacer()
                            }
                            .padding(16)
                            Divider().padding(.leading, 16)
                            HStack {
                                Text("App version")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                Spacer()
                                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                            }
                            .padding(16)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(red: 0.99, green: 0.97, blue: 0.95))
                                .shadow(color: Color(red: 0.60, green: 0.45, blue: 0.40).opacity(0.08), radius: 8, y: 3)
                        )
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Help & Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingHelpSheet = false }
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func settingsRow(icon: String, label: String, color: Color, trailingValue: String? = nil) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
            if let trailingValue {
                Text(trailingValue)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.75, green: 0.65, blue: 0.62))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
