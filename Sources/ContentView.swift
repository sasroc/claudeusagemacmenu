import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var service: ClaudeService

    var body: some View {
        VStack(spacing: 0) {
            if service.needsLogin {
                LoginPromptView()
                    .environmentObject(service)
            } else if service.isLoading && service.usageData == nil {
                LoadingView()
            } else if let usage = service.usageData {
                UsageScrollView(usage: usage)
            } else {
                VStack(spacing: 10) {
                    Text("Could not load usage data")
                        .foregroundColor(.secondary)
                    Button("Retry") { service.refresh() }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity)
            }

            Divider()
            BottomToolbar()
                .environmentObject(service)
        }
        .frame(width: 380)
        .onAppear {
            // Only refresh if not already loading (avoids interrupting in-flight request)
            if !service.isLoading {
                service.refresh()
            }
        }
    }
}

// MARK: - Login Prompt

struct LoginPromptView: View {
    @EnvironmentObject var service: ClaudeService

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("Sign in to Claude")
                .font(.headline)
            Text("Sign in to your Claude account to view usage statistics.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Sign In") {
                service.showLoginWindow()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading usage data…")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Usage Scroll View

struct UsageScrollView: View {
    let usage: UsageData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Plan usage limits section
                SectionHeader(title: "Plan usage limits")

                if let pct = usage.sessionPercent {
                    UsageRowView(
                        title: "Current session",
                        subtitle: usage.sessionResetText.map { "Resets in \($0)" },
                        percent: pct,
                        tint: pct >= 90 ? .red : .accentColor
                    )
                }

                Divider()

                // Weekly limits section
                SectionHeader(title: "Weekly limits")

                Link("Learn more about usage limits",
                     destination: URL(string: "https://support.anthropic.com/en/articles/9797839")!)
                    .font(.caption)
                    .padding(.bottom, 2)

                if let pct = usage.weeklyPercent {
                    UsageRowView(
                        title: "All models",
                        subtitle: usage.weeklyResetText.map { "Resets \($0)" },
                        percent: pct,
                        tint: pct >= 90 ? .red : .accentColor
                    )
                }

                if let lastUpdated = usage.lastUpdatedText {
                    Text("Last updated: \(lastUpdated)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Extra usage section
                if usage.extraAmountSpent != nil || usage.extraPercent != nil {
                    Divider()
                    SectionHeader(title: "Extra usage")

                    let extraPct = usage.extraPercent ?? 0
                    let spentText = usage.extraAmountSpent.map { String(format: "$%.2f spent", $0) } ?? "Extra usage"
                    UsageRowView(
                        title: spentText,
                        subtitle: usage.extraResetText.map { "Resets \($0)" },
                        percent: extraPct,
                        tint: extraPct >= 100 ? .orange : .accentColor
                    )

                    if let limit = usage.monthlyLimit {
                        HStack {
                            Text("Monthly spend limit")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "$%.2f", limit))
                                .font(.subheadline)
                        }
                    }

                    if let balance = usage.currentBalance {
                        HStack {
                            Text("Current balance")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "$%.2f", balance))
                                .font(.subheadline)
                                .foregroundColor(balance < 0 ? .red : .primary)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

// MARK: - Usage Row

struct UsageRowView: View {
    let title: String
    let subtitle: String?
    let percent: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text("\(Int(percent))% used")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ProgressBar(value: percent / 100.0, tint: tint)
                .frame(height: 8)
        }
    }
}

// MARK: - Progress Bar

struct ProgressBar: View {
    let value: Double   // 0.0 – 1.0
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: geo.size.width, height: geo.size.height)

                RoundedRectangle(cornerRadius: 4)
                    .fill(tint)
                    .frame(width: max(0, min(geo.size.width * CGFloat(value), geo.size.width)),
                           height: geo.size.height)
            }
        }
    }
}

// MARK: - Bottom Toolbar

struct BottomToolbar: View {
    @EnvironmentObject var service: ClaudeService

    var body: some View {
        HStack(spacing: 8) {
            Button("Open Claude") {
                NSWorkspace.shared.open(URL(string: "https://claude.ai")!)
            }
            .buttonStyle(.borderless)

            Spacer()

            if service.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 20, height: 20)
            } else {
                Button {
                    service.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage data")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
