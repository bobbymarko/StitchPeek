import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            UpdatesSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            FeedbackSettings()
                .tabItem { Label("App Feedback", systemImage: "text.bubble") }
        }
        .frame(width: 560)
    }
}

private struct UpdatesSettings: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        Form {
            LabeledContent("Installed version", value: Updater.currentVersion)
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            LabeledContent("Last checked") {
                Text(updater.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet this session")
            }
            HStack {
                Spacer()
                Button("Check Now") { updater.checkNow() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct FeedbackSettings: View {
    private var token: FeedbackToken { FeedbackToken.shared }
    @State private var entry = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Sends to", value: FeedbackConfig.repository)
                LabeledContent("Token") {
                    Text(token.isConfigured ? "Saved in this Mac's Keychain" : "Not set")
                        .foregroundStyle(token.isConfigured ? .primary : .secondary)
                }
            } footer: {
                Text("Help → Send App Feedback (⇧⌘F) files a StitchPeek problem there with your comment, a screenshot, and what was on screen, for the coding agents. Design markup for the embroidery agent doesn't use this — it's saved beside the design.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Paste a GitHub token", text: $entry)
                HStack {
                    if let tokenPage = FeedbackConfig.tokenSettingsURL {
                        Link("Create a token on GitHub…", destination: tokenPage)
                            .font(.callout)
                    }
                    Spacer()
                    if token.isConfigured {
                        Button("Remove", role: .destructive) {
                            token.remove()
                            status = "Token removed from this Mac."
                            statusIsError = false
                        }
                    }
                    Button("Test") { test() }
                        .disabled(!token.isConfigured || isTesting)
                    Button("Save") { save() }
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if let status {
                    Label(status, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .red : .green)
                        .font(.callout)
                }
            } header: {
                Text("Token")
            } footer: {
                Text("Use a fine-grained token with access to only \(FeedbackConfig.repository), and Issues and Contents set to Read and write. It's stored in the Keychain on this Mac only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func save() {
        do {
            try token.save(entry)
            entry = ""
            test()
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func test() {
        guard let value = token.value else { return }
        isTesting = true
        status = "Checking…"
        statusIsError = false
        Task {
            do {
                try await FeedbackClient(token: value, repository: FeedbackConfig.repository).verifyAccess()
                status = "Connected — feedback will go to \(FeedbackConfig.repository)."
                statusIsError = false
            } catch {
                status = error.localizedDescription
                statusIsError = true
            }
            isTesting = false
        }
    }
}
