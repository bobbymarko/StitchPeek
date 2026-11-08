import AppKit
import SwiftUI

/// Comment on what you're looking at. The window is captured the moment the sheet opens;
/// click the screenshot to drop numbered markers on the spots you mean, the way comment
/// pins work in design tools.
struct FeedbackSheet: View {
    let draft: FeedbackDraft

    @Environment(\.dismiss) private var dismiss
    @State private var kind: FeedbackKind = .problem
    @State private var text = ""
    @State private var includeScreenshot = true
    @State private var attachDesign = false
    @State private var marks: [CGPoint] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sentIssue: URL?

    private var token: FeedbackToken { FeedbackToken.shared }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending }

    var body: some View {
        Group {
            if let sentIssue {
                sentView(sentIssue)
            } else if !token.isConfigured {
                setupView
            } else {
                composeView
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    // MARK: Compose

    private var composeView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Send App Feedback").font(.title2.weight(.semibold))
                Text("For problems with StitchPeek itself. To mark up a design for the embroidery agent, use Markup in the viewer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Kind", selection: $kind) {
                ForEach(FeedbackKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if text.isEmpty {
                    Text(kind == .problem
                         ? "What's wrong, and what did you expect instead? The first line becomes the title."
                         : "What would make this better? The first line becomes the title.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            if let screenshot = draft.screenshot {
                Toggle("Include a screenshot of this window", isOn: $includeScreenshot)
                if includeScreenshot {
                    ScreenshotMarker(image: screenshot, marks: $marks)
                    Text(marks.isEmpty
                         ? "Click the screenshot to mark the spot you mean."
                         : "Click to add another marker; click a marker to remove it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let file = draft.context.designFileURL {
                Toggle("Attach \(file.lastPathComponent) so the design can be opened", isOn: $attachDesign)
            }

            DisclosureGroup("Details sent along") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(draft.context.items) { item in
                        GridRow {
                            Text(item.label).foregroundStyle(.secondary)
                            Text(item.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            }
            .font(.callout)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small).padding(.horizontal, 12)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
            }
        }
    }

    private func send() {
        guard let tokenValue = token.value else { return }
        isSending = true
        errorMessage = nil

        let client = FeedbackClient(token: tokenValue, repository: FeedbackConfig.repository)
        let folder = FeedbackComposer.folder()
        let screenshotPNG: Data? = includeScreenshot
            ? draft.screenshot.map { FeedbackCapture.annotated($0, marks: marks) }.flatMap(FeedbackCapture.png)
            : nil
        let designFile: (name: String, data: Data)? = attachDesign
            ? draft.context.designFileURL.flatMap { url in (try? Data(contentsOf: url)).map { (url.lastPathComponent, $0) } }
            : nil
        let title = FeedbackComposer.title(for: text, subject: draft.context.subject)
        let text = text
        let kind = kind
        let context = draft.context
        let markCount = marks.count

        Task {
            do {
                var screenshotURL: URL?
                if let screenshotPNG {
                    screenshotURL = try await client.upload(screenshotPNG, path: "\(folder)/screenshot.png", message: "Feedback screenshot")
                }
                var attached: (name: String, url: URL)?
                if let designFile {
                    let url = try await client.upload(designFile.data, path: "\(folder)/\(designFile.name)", message: "Feedback design file")
                    attached = (designFile.name, url)
                }
                let body = FeedbackComposer.body(
                    text: text,
                    kind: kind,
                    context: context,
                    markCount: screenshotURL == nil ? 0 : markCount,
                    screenshotURL: screenshotURL,
                    designFile: attached
                )
                sentIssue = try await client.createIssue(title: title, body: body, labels: ["feedback", kind.label])
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    // MARK: Sent

    private func sentView(_ issue: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Feedback sent").font(.title2.weight(.semibold))
            Text("It's in the queue as \(issue.lastPathComponent.isEmpty ? "an issue" : "issue #\(issue.lastPathComponent)").")
                .foregroundStyle(.secondary)
            HStack {
                Button("View on GitHub") { NSWorkspace.shared.open(issue) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feedback isn't set up on this Mac yet").font(.title2.weight(.semibold))
            Text("Feedback is sent to a private GitHub repository, and each Mac needs a token for it once. Add one in Settings → Feedback.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                SettingsLink {
                    Text("Open Settings…")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The captured window, with click-to-mark.
private struct ScreenshotMarker: View {
    let image: CGImage
    @Binding var marks: [CGPoint]

    private static let maximumMarks = 9

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 280)
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { location in
                                guard marks.count < Self.maximumMarks,
                                      geometry.size.width > 0, geometry.size.height > 0
                                else { return }
                                marks.append(CGPoint(
                                    x: location.x / geometry.size.width,
                                    y: location.y / geometry.size.height
                                ))
                            }
                        ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                            MarkerBadge(number: index + 1)
                                .position(x: mark.x * geometry.size.width, y: mark.y * geometry.size.height)
                                .onTapGesture { marks.remove(at: index) }
                                .help("Remove marker \(index + 1)")
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }
}

private struct MarkerBadge: View {
    let number: Int

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 4)
                .frame(width: 28, height: 28)
            Circle()
                .strokeBorder(Color(red: 0.9, green: 0.16, blue: 0.16), lineWidth: 2)
                .frame(width: 28, height: 28)
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(red: 0.9, green: 0.16, blue: 0.16)))
                .offset(x: 12, y: -12)
        }
        .contentShape(Circle())
    }
}
