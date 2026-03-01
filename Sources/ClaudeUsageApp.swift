import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var service = ClaudeService()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(service)
        } label: {
            MenuBarLabel(service: service)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var service: ClaudeService

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain")
            if let session = service.usageData?.sessionPercent {
                Text("\(Int(session))%")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }
}
