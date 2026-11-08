import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import Security
import StitchKit
import UniformTypeIdentifiers

/// Feedback goes to a **private** GitHub repository as issues, where coding agents pick it
/// up (see CLAUDE.md at the repo root). Private because feedback about designs names
/// clients, and StitchPeek's own repository is public.
///
/// Each Mac authenticates with a fine-grained token scoped to that one repository
/// (Issues + Contents, read and write), pasted once into Settings → Feedback and kept in
/// the Keychain. Nothing secret is compiled into the app.
enum FeedbackConfig {
    static let repository = "bobbymarko/StitchPeek-feedback"
    static let keychainService = "com.bobbymarko.stitchpeek.feedback"
    static let keychainAccount = "github-token"
    static let tokenSettingsURL = URL(string: "https://github.com/settings/personal-access-tokens/new")
}

// MARK: - Token

@MainActor
@Observable
final class FeedbackToken {
    static let shared = FeedbackToken()

    private(set) var isConfigured: Bool

    private init() {
        isConfigured = Keychain.read(service: FeedbackConfig.keychainService, account: FeedbackConfig.keychainAccount) != nil
    }

    var value: String? {
        Keychain.read(service: FeedbackConfig.keychainService, account: FeedbackConfig.keychainAccount)
    }

    func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.write(trimmed, service: FeedbackConfig.keychainService, account: FeedbackConfig.keychainAccount)
        isConfigured = true
    }

    func remove() {
        Keychain.delete(service: FeedbackConfig.keychainService, account: FeedbackConfig.keychainAccount)
        isConfigured = false
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    static func write(_ value: String, service: String, account: String) throws {
        delete(service: service, account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "StitchPeek feedback (GitHub token)",
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FeedbackError("Couldn't save the token to the Keychain (error \(status)).")
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct FeedbackError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - GitHub

struct FeedbackClient: Sendable {
    let token: String
    let repository: String

    /// Confirms the token can reach the repository. Used by Settings → Test.
    func verifyAccess() async throws {
        _ = try await send("GET", "repos/\(repository)", body: nil)
    }

    /// Commits a file into the feedback repository and returns a link that renders inline
    /// in the issue for anyone with access.
    func upload(_ data: Data, path: String, message: String) async throws -> URL {
        let encodedPath = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let body: [String: Any] = ["message": message, "content": data.base64EncodedString()]
        let response = try await send("PUT", "repos/\(repository)/contents/\(encodedPath)", body: body)
        guard let content = response["content"] as? [String: Any],
              let html = content["html_url"] as? String,
              let url = URL(string: html + "?raw=true")
        else { throw FeedbackError("GitHub stored the file but didn't say where.") }
        return url
    }

    func createIssue(title: String, body: String, labels: [String]) async throws -> URL {
        let response = try await send(
            "POST",
            "repos/\(repository)/issues",
            body: ["title": title, "body": body, "labels": labels]
        )
        guard let html = response["html_url"] as? String, let url = URL(string: html) else {
            throw FeedbackError("GitHub created the issue but didn't return its address.")
        }
        return url
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.github.com/\(path)") else { throw FeedbackError("Bad request path.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("StitchPeek-Feedback", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FeedbackError("Couldn't reach GitHub — check the internet connection and try again.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300:
            return json
        case 401:
            throw FeedbackError("GitHub didn't accept the feedback token — it may have expired. Paste a new one in Settings → Feedback.")
        case 403, 404:
            throw FeedbackError("The token can't write to \(repository). It needs access to that repository with Issues and Contents set to Read and write.")
        default:
            let detail = json["message"] as? String ?? "status \(status)"
            throw FeedbackError("GitHub refused the feedback: \(detail).")
        }
    }
}

// MARK: - Context

/// Everything about the moment feedback was started that an agent needs to reproduce it.
struct FeedbackContext: Sendable {
    struct Item: Sendable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var items: [Item]
    /// Short subject for the issue title, e.g. the design or window name.
    var subject: String?
    /// The open design, when the viewer is showing one, so it can be attached.
    var designFileURL: URL?

    @MainActor
    static func current(collection: DesignCollection?) -> FeedbackContext {
        var items: [Item] = []
        let version = Updater.currentVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let computer = Host.current().localizedName ?? "this Mac"
        items.append(Item(label: "From", value: "\(NSFullUserName()) on \(computer)"))
        items.append(Item(label: "App", value: "StitchPeek \(version) (\(build))"))
        items.append(Item(label: "macOS", value: ProcessInfo.processInfo.operatingSystemVersionString))

        guard let collection else {
            items.append(Item(label: "Screen", value: "Empty window — no designs open"))
            return FeedbackContext(items: items, subject: nil, designFileURL: nil)
        }

        items.append(Item(label: "Window", value: "\(collection.title) — \(collection.designs.count) design\(collection.designs.count == 1 ? "" : "s")"))
        if !collection.failures.isEmpty {
            let names = collection.failures.map(\.url.lastPathComponent).joined(separator: ", ")
            items.append(Item(label: "Failed to open", value: names))
        }

        guard let open = collection.visibleDesign else {
            items.append(Item(label: "Screen", value: "Index — \(collection.layout.label.lowercased()), tiles at \(Int((collection.tileScale * 100).rounded()))%"))
            return FeedbackContext(items: items, subject: collection.title, designFileURL: nil)
        }

        let model = open.model
        let design = model.design
        items.append(Item(label: "Screen", value: "Viewer"))
        items.append(Item(label: "Design", value: open.filename))
        items.append(Item(label: "Design stats", value: String(
            format: "%@ stitches · %d block%@ · %@ jumps · %.2f × %.2f in",
            design.stitchCount.formatted(), design.blocks.count, design.blocks.count == 1 ? "" : "s",
            design.jumpCount.formatted(), design.widthInches, design.heightInches
        )))

        var view = ["zoom \(model.zoomPercent)%"]
        if model.showsJumps { view.append("jumps shown") }
        if let isolated = model.isolatedBlockIndex { view.append("block \(isolated + 1) isolated") }
        if let limit = model.stitchLimit { view.append("scrubber at \(limit.formatted()) of \(design.stitchCount.formatted())") }
        if !model.recoloredBlocks.isEmpty {
            view.append("recolored block\(model.recoloredBlocks.count == 1 ? "" : "s") \(model.recoloredBlocks.sorted().map { String($0 + 1) }.joined(separator: ", "))")
        }
        items.append(Item(label: "View", value: view.joined(separator: " · ")))

        var file: [String] = []
        if design.header == nil { file.append("header unreadable") }
        if design.isTruncated { file.append("no end-of-file terminator") }
        if design.invalidRecordCount > 0 { file.append("\(design.invalidRecordCount) invalid records") }
        if !file.isEmpty { items.append(Item(label: "File notes", value: file.joined(separator: " · "))) }

        return FeedbackContext(items: items, subject: open.displayName, designFileURL: open.url)
    }
}

// MARK: - Draft

struct FeedbackDraft: Identifiable {
    let id = UUID()
    let screenshot: CGImage?
    let context: FeedbackContext
}

enum FeedbackKind: String, CaseIterable, Identifiable {
    case problem
    case idea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .problem: return "Something's wrong"
        case .idea: return "Idea or request"
        }
    }

    var systemImage: String {
        switch self {
        case .problem: return "ladybug"
        case .idea: return "lightbulb"
        }
    }

    /// GitHub's default labels, which every new repository has.
    var label: String {
        switch self {
        case .problem: return "bug"
        case .idea: return "enhancement"
        }
    }
}

// MARK: - Screenshot

enum FeedbackCapture {
    /// Renders the window — toolbar included — without Screen Recording permission, by
    /// asking the window's own view hierarchy to draw itself.
    @MainActor
    static func window(_ window: NSWindow?) -> CGImage? {
        guard let window,
              let view = window.contentView?.superview ?? window.contentView
        else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    /// Stamps numbered markers onto the screenshot. Marks are normalized, top-left origin.
    static func annotated(_ image: CGImage, marks: [CGPoint]) -> CGImage {
        guard !marks.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let radius = max(16, min(width, height) * 0.025)
        let red = CGColor(srgbRed: 0.90, green: 0.16, blue: 0.16, alpha: 1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        for (index, mark) in marks.enumerated() {
            let center = CGPoint(x: mark.x * width, y: (1 - mark.y) * height)   // CG is y-up

            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.setLineWidth(radius * 0.42)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setStrokeColor(red)
            context.setLineWidth(radius * 0.22)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

            let badgeRadius = radius * 0.62
            let badge = CGPoint(x: center.x + radius * 0.9, y: center.y + radius * 0.9)
            context.setFillColor(red)
            context.fillEllipse(in: CGRect(x: badge.x - badgeRadius, y: badge.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2))

            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: badgeRadius * 1.25, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: badge.x - size.width / 2, y: badge.y - size.height / 2))
        }
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Composing the issue

enum FeedbackComposer {
    static func title(for text: String, subject: String?) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let limit = 72
        let line = firstLine.count > limit ? String(firstLine.prefix(limit - 1)) + "…" : firstLine
        if let subject, !subject.isEmpty { return "\(line) — \(subject)" }
        return line
    }

    static func body(
        text: String,
        kind: FeedbackKind,
        context: FeedbackContext,
        markCount: Int,
        screenshotURL: URL?,
        designFile: (name: String, url: URL)?
    ) -> String {
        var lines: [String] = [text.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        if let screenshotURL {
            if markCount > 0 {
                lines.append("_Numbered markers on the screenshot (1–\(markCount)) show the spots this refers to._")
                lines.append("")
            }
            lines.append("![Screenshot](\(screenshotURL.absoluteString))")
            lines.append("")
        }
        if let designFile {
            lines.append("Design file: [\(designFile.name)](\(designFile.url.absoluteString))")
            lines.append("")
        }
        lines.append("### Context")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        lines.append("| Kind | \(kind.title) |")
        for item in context.items {
            lines.append("| \(escape(item.label)) | \(escape(item.value)) |")
        }
        lines.append("")
        lines.append("<sub>Sent with StitchPeek's Send Feedback.</sub>")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// `feedback/2026-11-08-1432-ab12cd` — one folder per report keeps attachments together.
    static func folder(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "feedback/\(formatter.string(from: date))-\(suffix)"
    }
}
