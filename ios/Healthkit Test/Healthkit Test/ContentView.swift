import SwiftUI

struct ContentView: View {
    @StateObject var manager = HealthManager()
    let dayOptions = [1, 2, 3, 5, 7, 14]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // The Dropdown Header
                HStack {
                    Text("Range: Last \(manager.selectedDaysBack) Days")
                        .font(.caption).bold()
                    Spacer()
                    Menu {
                        ForEach(dayOptions, id: \.self) { day in
                            Button("\(day) Days") {
                                manager.refreshWithNewRange(days: day)
                            }
                        }
                    } label: {
                        Label("Change Range", systemImage: "calendar.badge.clock")
                            .font(.caption)
                    }
                }
                .padding()
                .background(Color(.systemGray6))

                List(manager.trialData) { point in
                    Text(
                        formatRawString(
                            point,
                            unixStartStr: String(Int(point.startDate.timeIntervalSince1970)),
                            unixEndStr: String(Int(point.endDate.timeIntervalSince1970))
                        )
                    )
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Data Log (Last \(manager.selectedDaysBack) Days)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    func formatRawString(_ p: HealthManager.RawDataPoint, unixStartStr: String, unixEndStr: String) -> String {
        let dateStr = p.startDate.formatted(.dateTime.month().day().hour().minute().second())
        let metaStr = p.metadata.map { "\($0.key):\($0.value)" }.joined(separator: "|")
        
        return "[\(dateStr)] TYPE:\(p.type) | VAL:\(p.value)\(p.unit) | UNIX_START:\(unixStartStr) | UNIX_END:\(unixEndStr) | DUR:\(unixEndStr - unixStartStr)ms | SRC:\(p.sourceName) | BID:\(p.bundleID) | DEV:\(p.deviceName ?? "NA") | MOD:\(p.deviceModel ?? "NA") | SW:\(p.softwareVer ?? "NA") | ID:\(p.id.uuidString) | META:{\(metaStr)}"
    }
}
