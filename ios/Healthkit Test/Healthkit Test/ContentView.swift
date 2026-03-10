import SwiftUI

struct ContentView: View {
    @StateObject var manager = HealthManager()
    let dayOptions = [1, 2, 3, 5, 7, 14]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Header
                Image(systemName: "terminal.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                    .padding(.top)

                VStack(spacing: 8) {
                    Text("Data Extractor Active")
                        .font(.headline)
                    Text("Check the Xcode console for raw logs.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider().padding(.horizontal)

                // Filter Picker
                VStack(alignment: .leading) {
                    Text("LIVE CONSOLE FILTER").font(.caption2).bold().foregroundColor(.secondary)
                    Picker("Filter", selection: $manager.activeFilter) {
                        ForEach(HealthManager.DataFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal)

                // Action Button
                Menu {
                    ForEach(dayOptions, id: \.self) { day in
                        Button("\(day) Days") {
                            manager.refreshWithNewRange(days: day)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Refresh Last \(manager.selectedDaysBack) Days")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(manager.isProcessing ? Color.gray : Color.blue)
                    .cornerRadius(12)
                }
                .disabled(manager.isProcessing)
                .padding(.horizontal)

                if manager.isProcessing {
                    ProgressView("Streaming to Xcode...")
                }

                Spacer()
                
                Text("Ready for extraction")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .navigationTitle("HealthManager Control")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
