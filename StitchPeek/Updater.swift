import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Finds new releases on GitHub and installs them in place.
///
/// The flow, and what each step protects against:
///
/// 1. **Check** `releases/latest` on GitHub. Unauthenticated; one request at launch and
///    every six hours, well inside the 60-an-hour limit.
/// 2. **Download** `StitchPeek.zip` and `StitchPeek.zip.sig` from that release.
/// 3. **Verify** the Ed25519 signature against the public key compiled in below. The private
///    key never leaves the release machine, so a compromised GitHub account still cannot
///    ship an update — this is the check that stands in for notarization.
/// 4. **Validate** the unpacked app: same bundle identifier, the version the release
///    claims, and a code signature that verifies.
/// 5. **Install** by staging the new app beside the current one, quitting, and letting a
///    small shell script swap the two once this process has exited, then relaunch.
///    If the swap fails the old app is put back, and the next launch reports it.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repository = "bobbymarko/StitchPeek"
    nonisolated static let archiveName = "StitchPeek.zip"
    nonisolated static let signatureName = "StitchPeek.zip.sig"

    /// Ed25519 public key. The private half is at ~/.config/stitchpeek/update-signing-key on
    /// the release machine; see Scripts/sign_update.swift and Scripts/release.sh.
    nonisolated static let publicKey = "AziHIzL5cST4fpegQ2JIR7IPaVrPfXXK/HkszgMd4bo="

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release: Equatable, Sendable {
        let version: String
        let pageURL: URL
        let archiveURL: URL?
        let signatureURL: URL?

        /// A release published without the signed archive can only be downloaded by hand.
        var canInstall: Bool { archiveURL != nil && signatureURL != nil }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(Release)
        case installing(Release, step: String)
        case failed(Release, message: String)
        /// Shown once, on the first launch after a successful update.
        case updated(version: String)
    }

    private(set) var phase: Phase = .idle
    /// Hides the banner for the rest of this session.
    var bannerDismissed = false
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic)
            schedule()
        }
    }

    private var timer: Timer?

    private enum Keys {
        static let automatic = "checksForUpdatesAutomatically"
        static let pendingVersion = "pendingUpdateVersion"
    }

    private init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
    }

    // MARK: - Scheduling

    /// Called once at launch.
    func start() {
        reportPreviousInstall()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await self.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(userInitiated: false) }
        }
    }

    // MARK: - Checking

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        switch phase {
        case .installing, .checking: return
        default: break
        }
        // A background check that finds nothing new, or fails, leaves whatever the banner
        // was saying (an available update, the post-update note) where it was.
        let previous = phase
        phase = .checking

        do {
            let latest = try await Self.fetchLatestRelease()
            lastChecked = Date()
            if let latest, Self.isVersion(latest.version, newerThan: Self.currentVersion) {
                phase = .available(latest)
                if userInitiated {
                    bannerDismissed = false
                    offer(latest)
                }
            } else {
                phase = previous
                if case .available = previous { phase = .idle }     // superseded: nothing newer now
                if userInitiated {
                    Self.alert("StitchPeek is up to date", "Version \(Self.currentVersion) is the newest release.")
                }
            }
        } catch {
            phase = previous
            if userInitiated { Self.alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "StitchPeek \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). "
            + (release.canInstall ? "StitchPeek will quit, update itself, and reopen." : "This release has to be downloaded by hand.")
        alert.addButton(withTitle: release.canInstall ? "Update and Relaunch" : "Open Download Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "What's New")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if release.canInstall { install(release) } else { NSWorkspace.shared.open(release.pageURL) }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    // MARK: - Installing

    func install(_ release: Release) {
        Task { await performInstall(release) }
    }

    private func performInstall(_ release: Release) async {
        guard let archiveURL = release.archiveURL, let signatureURL = release.signatureURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        do {
            let target = Bundle.main.bundleURL
            try Self.checkInstallable(target)

            phase = .installing(release, step: "downloading")
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("StitchPeek-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = try await Self.download(archiveURL, to: work.appendingPathComponent(Self.archiveName))
            let signature = try await Self.fetchData(signatureURL)

            phase = .installing(release, step: "verifying")
            let archiveData = try Data(contentsOf: archive)
            guard Self.isValidSignature(signature, for: archiveData) else {
                throw UpdateError("The download's signature doesn't match StitchPeek's signing key, so it was not installed.")
            }

            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            let unzip = try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            guard unzip.status == 0 else { throw UpdateError("The download couldn't be unpacked.") }
            let newApp = unpacked.appendingPathComponent("StitchPeek.app", isDirectory: true)
            try await Self.validate(newApp, expectedVersion: release.version)

            phase = .installing(release, step: "installing")
            // Stage beside the running app so the final swap is a same-volume rename.
            let staged = target.deletingLastPathComponent()
                .appendingPathComponent(".StitchPeek-update.app", isDirectory: true)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: newApp, to: staged)
            try? FileManager.default.removeItem(at: work)

            try Self.launchSwapper(target: target, staged: staged)
            UserDefaults.standard.set(release.version, forKey: Keys.pendingVersion)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(release, message: error.localizedDescription)
            bannerDismissed = false
        }
    }

    /// After an update the app comes back up as the new version. If it didn't, the swap
    /// failed and the old app was restored — say so rather than failing silently.
    private func reportPreviousInstall() {
        guard let pending = UserDefaults.standard.string(forKey: Keys.pendingVersion) else { return }
        UserDefaults.standard.removeObject(forKey: Keys.pendingVersion)
        if Self.currentVersion == pending {
            phase = .updated(version: pending)
        } else if let page = URL(string: "https://github.com/\(Self.repository)/releases/tag/v\(pending)") {
            phase = .failed(
                Release(version: pending, pageURL: page, archiveURL: nil, signatureURL: nil),
                message: "the new version couldn't replace this one, so the old one was kept"
            )
        }
    }

    private static func checkInstallable(_ target: URL) throws {
        if target.path.contains("/AppTranslocation/") {
            throw UpdateError("StitchPeek is running from a temporary location. Move it to Applications, open it from there, and update again.")
        }
        let parent = target.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path) else {
            throw UpdateError("This account can't replace StitchPeek in \(parent.path). Install the update by hand, or from an administrator account.")
        }
    }

    private static func validate(_ app: URL, expectedVersion: String) async throws {
        guard let bundle = Bundle(url: app) else { throw UpdateError("The download doesn't contain StitchPeek.") }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download is a different app (\(bundle.bundleIdentifier ?? "unknown")).")
        }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        guard version == expectedVersion else {
            throw UpdateError("The download is version \(version ?? "unknown"), not \(expectedVersion).")
        }
        let codesign = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard codesign.status == 0 else { throw UpdateError("The downloaded app's code signature is broken.") }
    }

    /// Waits for this process to exit, swaps the staged app in, re-registers it so the
    /// Quick Look extensions inside are picked up, and relaunches. Restores the old app if
    /// the swap fails part-way.
    private static func launchSwapper(target: URL, staged: URL) throws {
        let script = """
        pid="$1"; target="$2"; staged="$3"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="${target%.app}.previous.app"
        rm -rf "$backup"
        if mv "$target" "$backup"; then
          if mv "$staged" "$target"; then
            rm -rf "$backup"
          else
            mv "$backup" "$target"
          fi
        fi
        rm -rf "$staged"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" >/dev/null 2>&1
        open "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
        try process.run()
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    nonisolated private static func fetchLatestRelease() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("StitchPeek-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }            // no releases published yet
        guard status == 200 else { throw UpdateError("GitHub answered \(status).") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return Release(
            version: version,
            pageURL: release.html_url,
            archiveURL: release.assets.first { $0.name == archiveName }?.browser_download_url,
            signatureURL: release.assets.first { $0.name == signatureName }?.browser_download_url
        )
    }

    nonisolated private static func download(_ url: URL, to destination: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    nonisolated private static func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The signature couldn't be downloaded.") }
        return data
    }

    // MARK: - Helpers

    nonisolated static func isValidSignature(_ signature: Data, for data: Data) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signatureBytes = Data(base64Encoded: text),
              let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { return false }
        return key.isValidSignature(signatureBytes, for: data)
    }

    /// Numeric, component-wise: 1.10.0 is newer than 1.9.3.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // Read to EOF before waiting, so a chatty tool can't fill the pipe and stall.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Banner

/// Sits along the top of every window while there is something to say about updates.
struct UpdateBanner: View {
    private var updater: Updater { Updater.shared }

    var body: some View {
        switch updater.phase {
        case .available(let release) where !updater.bannerDismissed:
            bar(symbol: "arrow.down.circle.fill", tint: .accentColor) {
                Text("StitchPeek \(release.version) is available").fontWeight(.medium)
                Text("You have \(Updater.currentVersion).").foregroundStyle(.secondary)
                Spacer()
                Button("What's New") { NSWorkspace.shared.open(release.pageURL) }
                if release.canInstall {
                    Button("Update and Relaunch") { updater.install(release) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Download…") { NSWorkspace.shared.open(release.pageURL) }
                }
                dismissButton
            }

        case .installing(let release, let step):
            bar(symbol: nil, tint: .accentColor) {
                ProgressView().controlSize(.small)
                Text("Updating to \(release.version) — \(step)…")
                Spacer()
            }

        case .failed(let release, let message) where !updater.bannerDismissed:
            bar(symbol: "exclamationmark.triangle.fill", tint: .orange) {
                Text("Update to \(release.version) didn't install: \(message)")
                    .lineLimit(2)
                Spacer()
                if release.canInstall {
                    Button("Try Again") { updater.install(release) }
                }
                Button("Download Manually") { NSWorkspace.shared.open(release.pageURL) }
                dismissButton
            }

        case .updated(let version) where !updater.bannerDismissed:
            bar(symbol: "checkmark.circle.fill", tint: .green) {
                Text("Updated to StitchPeek \(version).").fontWeight(.medium)
                Spacer()
                if let page = URL(string: "https://github.com/\(Updater.repository)/releases/tag/v\(version)") {
                    Button("What's New") { NSWorkspace.shared.open(page) }
                }
                dismissButton
            }

        default:
            EmptyView()
        }
    }

    private var dismissButton: some View {
        Button {
            updater.bannerDismissed = true
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Hide until StitchPeek is reopened")
    }

    private func bar<Content: View>(symbol: String?, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            content()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
