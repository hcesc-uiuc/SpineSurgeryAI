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
    @Environment(\.dismiss) private var dismiss
    @State private var showingLogoutAlert = false
    @State private var showingPrivacySheet = false
    @State private var showingHelpSheet = false
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

                // Scrolls because at large Dynamic Type sizes the three cards
                // plus the log-out button no longer fit a single screen.
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(accentColor.opacity(0.15))
                                    .frame(width: 60, height: 60)
                                Image(systemName: "person.fill")
                                    .font(.system(.title))
                                    .foregroundStyle(accentColor)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("User")
                                    .font(.journey(.body, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                Text("Journey Study Participant")
                                    .font(.journey(.footnote))
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
                                    .font(.journey(.callout, weight: .semibold))
                            }
                            .foregroundStyle(Color(red: 0.75, green: 0.25, blue: 0.22))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(red: 0.75, green: 0.25, blue: 0.22).opacity(0.10))
                            )
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Settings")
            // This sheet used to be dismissible only by swiping down — which
            // its own Privacy and Help sub-sheets were not, so the app taught
            // two different exits. Every sheet now has a visible Done.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.journey(.callout, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                }
            }
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
        .preferredColorScheme(.light)
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
                                .font(.journey(.body, weight: .semibold))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            Text("Journey is a multi-institution research study of recovery after spine surgery. Your phone and watch help your care team understand how you're healing day to day.")
                                .font(.journey(.subheadline))
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
                                .font(.journey(.body, weight: .semibold))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            ForEach(["Motion & activity", "Location", "Health metrics (steps, heart rate, sleep)", "Daily check-in answers"], id: \.self) { item in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(red: 0.42, green: 0.62, blue: 0.55))
                                        .frame(width: 6, height: 6)
                                    Text(item)
                                        .font(.journey(.subheadline))
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
                                .font(.journey(.body, weight: .semibold))
                                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                            Text("Your data is used for research purposes only and is never sold or shared outside the study. You may withdraw at any time by contacting your study coordinator.")
                                .font(.journey(.subheadline))
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
                        .font(.journey(.callout, weight: .medium))
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
                                .font(.journey(.subheadline))
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
                                        .font(.journey(.subheadline, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                    Text("Contact details provided by your care team")
                                        .font(.journey(.footnote))
                                        .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
                                }
                                Spacer()
                            }
                            .padding(16)
                            Divider().padding(.leading, 16)
                            HStack {
                                Text("App version")
                                    .font(.journey(.subheadline))
                                    .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
                                Spacer()
                                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                                    .font(.journey(.subheadline))
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
                        .font(.journey(.callout, weight: .medium))
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
                    .font(.system(.callout))
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.journey(.callout))
                .foregroundStyle(Color(red: 0.28, green: 0.22, blue: 0.20))
            Spacer()
            if let trailingValue {
                Text(trailingValue)
                    .font(.journey(.subheadline))
                    .foregroundStyle(Color(red: 0.55, green: 0.47, blue: 0.44))
            }
            Image(systemName: "chevron.right")
                .font(.system(.footnote).weight(.medium))
                .foregroundStyle(Color(red: 0.75, green: 0.65, blue: 0.62))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
