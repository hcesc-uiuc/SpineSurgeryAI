//
//  ContentView.swift
//  s3uploadtest  —  Issue #69: S3 Upload Test Harness
//

import SwiftUI

struct ContentView: View {
    var body: some View { HarnessView() }
}

struct HarnessView: View {
    @StateObject private var runner = HarnessRunner()

    var body: some View {
        VStack(spacing: 12) {
            Text("S3 Upload Harness · #69")
                .font(.headline)
                .padding(.top)

            VStack(alignment: .leading, spacing: 4) {
                Text("Manifest URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…/test-fixtures/manifest.json", text: $runner.manifestURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(runner.isRunning)
                Text("Backend (from app code): \(S3UploadConfig.baseURL)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                Button("Run All") { runner.runAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(runner.isRunning)
                Button("Clear") { runner.clear() }
                    .buttonStyle(.bordered)
                    .disabled(runner.isRunning)
                if runner.isRunning { ProgressView().padding(.leading, 4) }
            }

            if !runner.results.isEmpty {
                List(runner.results) { result in
                    HStack(spacing: 10) {
                        Image(systemName: icon(result.outcome))
                            .foregroundStyle(color(result.outcome))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.filename)
                                .font(.system(.footnote, design: .monospaced))
                            Text("\(result.kind) · \(result.path)\(result.detail.isEmpty ? "" : " · \(result.detail)")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 220)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.log)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("log")
                }
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)
                .onChange(of: runner.log) { _, _ in
                    proxy.scrollTo("log", anchor: .bottom)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom)
    }

    private func icon(_ outcome: HarnessResult.Outcome) -> String {
        switch outcome {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed:  return "checkmark.circle.fill"
        case .failed:  return "xmark.circle.fill"
        }
    }

    private func color(_ outcome: HarnessResult.Outcome) -> Color {
        switch outcome {
        case .pending: return .secondary
        case .running: return .blue
        case .passed:  return .green
        case .failed:  return .red
        }
    }
}

#Preview {
    ContentView()
}
