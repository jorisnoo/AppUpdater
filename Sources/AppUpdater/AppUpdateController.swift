import AppKit
import Combine
import SwiftUI
@preconcurrency import Version

/// The standard app integration: silent downloads, install on quit, and manual dialogs.
@MainActor
public final class AppUpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    public let updater: AppUpdater
    @Published public private(set) var pendingUpdate: DeferredUpdate?
    @Published public private(set) var isPresenting = false

    private let defaults: UserDefaults
    private let directory: URL?
    private let automaticChecks: Bool
    private var started = false
    private var terminating = false
    private var allowsTermination = false
    private static let preferenceKey = "deferredUpdate"

    public convenience init(owner: String, repo: String, releasePrefix: String? = nil) {
        #if DEBUG
        let automaticChecks = false
        #else
        let automaticChecks = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
        self.init(
            updater: AppUpdater(owner: owner, repo: repo, releasePrefix: releasePrefix, automaticallyChecks: automaticChecks),
            defaults: .standard,
            directory: nil,
            automaticChecks: automaticChecks
        )
    }

    init(updater: AppUpdater, defaults: UserDefaults, directory: URL?, automaticChecks: Bool) {
        self.updater = updater
        self.defaults = defaults
        self.directory = directory
        self.automaticChecks = automaticChecks
        super.init()
        restorePendingUpdate()
        updater.savedBundle = { [weak self] version, assetName in
            guard let pending = self?.pendingUpdate,
                  pending.releaseVersion == version.description, pending.assetName == assetName else { return nil }
            return pending.loadBundle()
        }
        updater.onDownloadSuccess = { [weak self] in
            do { try self?.saveDownloadedUpdate() }
            catch { self?.updater.traceFailure("Could not save update", error) }
        }
        updater.onInstallSuccess = { [weak self] in
            self?.clearPendingUpdate()
            self?.allowsTermination = true
        }
    }

    /// Call once from applicationDidFinishLaunching. Debug builds do not check automatically.
    public func start() {
        guard !started else { return }
        started = true
        guard automaticChecks else { return }
        updater.check(success: updater.onDownloadSuccess, fail: updater.onDownloadFail)
    }

    @objc public func checkForUpdates() {
        guard !isPresenting, !terminating, !updater.isInstalling else { return }
        isPresenting = true
        Task {
            defer { isPresenting = false }
            do {
                try await updater.checkThrowing()
                try saveDownloadedUpdate()
                guard !terminating else { return }
                if let pendingUpdate {
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "Version \(pendingUpdate.releaseVersion) is ready to install."
                    alert.addButton(withTitle: "Restart Now")
                    alert.addButton(withTitle: "Install on Quit")
                    if alert.runModal() == .alertFirstButtonReturn { await installPendingUpdate() }
                } else {
                    showMessage("No Updates Available", "You're running the latest version of \(appName).")
                }
            } catch {
                if !terminating { showMessage("Update Check Failed", error.localizedDescription, warning: true) }
            }
        }
    }

    @objc public func restartAndUpdate() {
        guard !isPresenting, !updater.isInstalling, !terminating else { return }
        isPresenting = true
        Task {
            defer { isPresenting = false }
            await installPendingUpdate()
        }
    }

    private func installPendingUpdate() async {
        guard !terminating else { return }
        guard let bundle = pendingUpdate?.loadBundle() else {
            clearPendingUpdate()
            showMessage("Update Unavailable", "Please check for updates again.", warning: true)
            return
        }
        do { try await updater.installThrowing(bundle) }
        catch { showMessage("Installation Failed", error.localizedDescription, warning: true) }
    }

    /// Forward applicationShouldTerminate here, including in apps that quit with their last window.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowsTermination { return .terminateNow }
        if terminating || updater.isInstalling { return .terminateCancel }
        guard pendingUpdate != nil else { return .terminateNow }
        terminating = true
        updater.stopChecksForTermination()
        Task {
            do {
                if let bundle = pendingUpdate?.loadBundle() {
                    try await updater.replaceBundle(bundle)
                    clearPendingUpdate()
                } else {
                    clearPendingUpdate()
                }
            } catch {
                updater.traceFailure("Install on quit failed; retaining pending update", error)
            }
            allowsTermination = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func saveDownloadedUpdate() throws {
        guard !terminating, !updater.isInstalling else { return }
        guard case .downloaded(let release, let asset, let bundle) = updater.state else { return }
        let saved = try DeferredUpdate.persistBundle(bundle, to: directory)
        let pending = DeferredUpdate(bundlePath: saved.path, releaseVersion: release.tagName.description,
                                     releaseName: release.name, assetName: asset.name)
        let data = try JSONEncoder().encode(pending)
        defaults.set(data, forKey: Self.preferenceKey)
        pendingUpdate = pending
        if let savedBundle = Bundle(url: saved) {
            updater.state = .downloaded(release, asset, savedBundle)
            updater.discardTemporaryDownload()
        }
    }

    private func restorePendingUpdate() {
        guard let data = defaults.data(forKey: Self.preferenceKey) else { return }
        guard let pending = try? JSONDecoder().decode(DeferredUpdate.self, from: data),
              let root = try? directory ?? DeferredUpdate.pendingUpdatesDirectory(),
              URL(fileURLWithPath: pending.bundlePath).resolvingSymlinksInPath() == root.appendingPathComponent("Update.app").resolvingSymlinksInPath(),
              let bundle = pending.loadBundle(),
              bundle.bundleIdentifier == updater.installedBundle.bundleIdentifier,
              let version = Version(tolerant: pending.releaseVersion),
              version > updater.installedBundle.updateVersion,
              bundle.updateVersion.matchesRelease(version) else {
            clearPendingUpdate()
            return
        }
        pendingUpdate = pending
    }

    private func clearPendingUpdate() {
        defaults.removeObject(forKey: Self.preferenceKey)
        pendingUpdate = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        else { DeferredUpdate.cleanup() }
    }

    private var appName: String {
        updater.installedBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? updater.installedBundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    private func showMessage(_ title: String, _ message: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// AppKit equivalent of AppUpdateMenu, for menu-bar apps.
    public func menuItems() -> [NSMenuItem] {
        let check = NSMenuItem(title: updater.isChecking ? "Checking for Updates…" : "Check for Updates…",
                               action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        var items = [check]
        if pendingUpdate != nil {
            let restart = NSMenuItem(title: "Restart and Update", action: #selector(restartAndUpdate), keyEquivalent: "")
            restart.target = self
            items.append(restart)
        }
        return items
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !updater.isInstalling && !isPresenting && !terminating &&
            (menuItem.action == #selector(restartAndUpdate) || !updater.isChecking)
    }
}

/// Place inside CommandGroup(after: .appInfo).
@MainActor
public struct AppUpdateMenu: View {
    @ObservedObject private var controller: AppUpdateController
    @ObservedObject private var updater: AppUpdater

    public init(controller: AppUpdateController) {
        self.controller = controller
        self.updater = controller.updater
    }

    public var body: some View {
        Group {
            Button(updater.isChecking ? "Checking for Updates…" : "Check for Updates…", action: controller.checkForUpdates)
                .disabled(updater.isChecking)
            if controller.pendingUpdate != nil {
                Button("Restart and Update", action: controller.restartAndUpdate)
            }
        }
        .disabled(updater.isInstalling || controller.isPresenting)
    }
}
