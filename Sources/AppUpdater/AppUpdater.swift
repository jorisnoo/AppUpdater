import Foundation
import AppKit
@preconcurrency import Version
import OSLog

@MainActor
public final class AppUpdater: ObservableObject {
    public typealias OnSuccess = @MainActor @Sendable () -> Void
    public typealias OnFail = @MainActor @Sendable (Swift.Error) -> Void

    // Configuration and use are main-actor isolated; deinit only invalidates it.
    nonisolated(unsafe) private let activity: NSBackgroundActivityScheduler
    let owner: String
    let repo: String
    let releasePrefix: String

    var slug: String {
        return "\(owner)/\(repo)"
    }

    public var provider: ReleaseProvider

    /// update state
    @Published public var state: UpdateState = .none

    /// all releases
    @Published public var releases: [Release] = []

    /// last error captured for diagnostics
    @Published public var lastError: Swift.Error?

    /// guards against overlapping checks
    @Published public private(set) var isChecking = false
    @Published public private(set) var isInstalling = false
    private var checkTask: Task<Void, Swift.Error>?
    var installedBundle = Bundle.main
    private var downloadDirectory: URL?

    public var onDownloadSuccess: OnSuccess? = nil
    public var onDownloadFail: OnFail? = nil

    public var onInstallSuccess: OnSuccess? = nil
    public var onInstallFail: OnFail? = nil

    public var allowPrereleases = false
    /// Skip code signing validation (useful for mock/testing).
    public var skipCodeSignValidation = false

    public init(owner: String, repo: String, releasePrefix: String? = nil, interval: TimeInterval = 24 * 60 * 60, provider: ReleaseProvider = GithubReleaseProvider(), automaticallyChecks: Bool = true) {
        self.owner = owner
        self.repo = repo
        self.releasePrefix = releasePrefix ?? repo
        self.provider = provider

        activity = NSBackgroundActivityScheduler(identifier: "AppUpdater.\(Bundle.main.bundleIdentifier ?? "")")
        activity.repeats = true
        activity.interval = interval
        if automaticallyChecks {
            activity.schedule { [weak self] completion in
                Task { @MainActor in
                    guard let self else { return completion(.finished) }
                    guard !self.activity.shouldDefer else { return completion(.deferred) }
                    do {
                        try await self.checkThrowing()
                        self.onDownloadSuccess?()
                    } catch {
                        self.onDownloadFail?(error)
                    }
                    completion(.finished)
                }
            }
        }
    }

    deinit {
        activity.invalidate()
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
    }

    public enum Error: Swift.Error, LocalizedError {
        case bundleExecutableURL
        case codeSigningIdentity
        case invalidDownloadedBundle
        case unzipFailed
        case downloadFailed
        case pathTraversalDetected
        case invalidURL(String)
        case relaunchFailed
        case installationInProgress
        case incompatibleUpdate

        public var errorDescription: String? {
            switch self {
            case .bundleExecutableURL, .invalidDownloadedBundle: return "The update does not contain a valid application."
            case .codeSigningIdentity: return "The update's signature or application identity could not be verified."
            case .unzipFailed: return "The update archive could not be extracted."
            case .downloadFailed: return "The update download did not complete."
            case .pathTraversalDetected: return "The update archive contains unsafe paths."
            case .invalidURL: return "The update URL is invalid."
            case .relaunchFailed: return "The updated app could not be launched."
            case .installationInProgress: return "An update is already being installed."
            case .incompatibleUpdate: return "This update is not newer than the installed app, or requires a newer version of macOS."
            }
        }
    }
    
    public func check(success: OnSuccess? = nil, fail: OnFail? = nil) {
        Task {
            do {
                try await checkThrowing()
                success?()
            } catch {
                trace("check failed:", String(describing: error))
                fail?(error)
            }
        }
    }
    
    public func install(_ appBundle: Bundle, success: OnSuccess? = nil, fail: OnFail? = nil) {
        Task { @MainActor in
            do {
                try await performInstallation(appBundle, success: success)
            } catch {
                fail?(error)
                onInstallFail?(error)
            }
        }
    }

    public func checkThrowing() async throws {
        guard !isInstalling else { throw Error.installationInProgress }
        if let checkTask {
            try await checkTask.value
            return
        }
        isChecking = true
        lastError = nil
        let previousState = state
        let task = Task {
            defer {
                self.checkTask = nil
                self.isChecking = false
            }
            do { try await self.performCheck() }
            catch {
                self.state = previousState
                self.lastError = error
                throw error
            }
        }
        checkTask = task
        try await task.value
    }

    private func performCheck() async throws {
        trace("begin check for", slug)
        guard installedBundle.executableURL != nil else {
            throw Error.bundleExecutableURL
        }
        let currentVersion = installedBundle.version

        trace("fetch releases")
        let releases = try await provider.fetchReleases(owner: owner, repo: repo)
        trace("fetched releases count:", releases.count)

        notifyReleasesDidChange(releases)

        guard let (release, asset) = try releases.findViableUpdate(appVersion: currentVersion, releasePrefix: self.releasePrefix, prerelease: self.allowPrereleases) else {
            trace("no viable update for", currentVersion.description, "prefix", self.releasePrefix, "prerelease", self.allowPrereleases)
            notifyStateChanged(newState: .none)
            return
        }

        if case .downloaded(let cached, _, let bundle) = state,
           cached.tagName == release.tagName,
           let executable = bundle.executableURL,
           FileManager.default.fileExists(atPath: executable.path) { return }

        trace("viable release:", release.tagName.description, "asset:", asset.name)
        notifyStateChanged(newState: .newVersionDetected(release, asset))

        let bundle = try await downloadAndExtract(asset: asset, release: release)
        notifyStateChanged(newState: .downloaded(release, asset, bundle))
    }

    private func validateCodeSigning(_ current: Bundle, _ downloaded: Bundle) async throws -> Bool {
        if skipCodeSignValidation { return true }
        let currentURL = current.bundleURL
        let downloadedURL = downloaded.bundleURL
        return try await Task.detached {
            try Bundle.validateUpdate(at: downloadedURL, against: currentURL)
            return true
        }.value
    }

    private func downloadAndExtract(asset: Release.Asset, release: Release) async throws -> Bundle {
        trace("update start:", release.tagName.description, asset.name)

        let tmpdir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedBundle.bundleURL, create: true)

        var keepBundle = false
        defer { if !keepBundle { try? FileManager.default.removeItem(at: tmpdir) } }

        let downloadState = try await provider.download(asset: asset, to: tmpdir.appendingPathComponent("download"))

        var dst: URL? = nil
        for try await state in downloadState {
            switch state {
            case .progress(let fraction):
                trace("downloading", Int(fraction * 100), "%")
                notifyStateChanged(newState: .downloading(release, asset, fraction: fraction))
            case .finished(let saveLocation):
                trace("download finished at", saveLocation.path)
                dst = saveLocation
            }
        }

        guard let dst = dst else {
            trace("download failed: destination missing")
            throw Error.downloadFailed
        }

        guard let unziped = try await unzip(dst, contentType: asset.contentType) else {
            trace("unzip failed")
            throw Error.unzipFailed
        }

        guard let downloadedAppBundle = Bundle(url: unziped) else {
            throw Error.invalidDownloadedBundle
        }

        if try await validateCodeSigning(installedBundle, downloadedAppBundle) {
            try validateVersion(downloadedAppBundle, expected: release.tagName)
            try? FileManager.default.removeItem(at: dst)
            discardTemporaryDownload()
            downloadDirectory = tmpdir
            keepBundle = true
            return downloadedAppBundle
        } else {
            trace("codesign mismatch")
            throw Error.codeSigningIdentity
        }
    }
    
    func discardTemporaryDownload() {
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
        downloadDirectory = nil
    }

    private func validateVersion(_ bundle: Bundle, expected: Version? = nil) throws {
        guard let exe = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw Error.invalidDownloadedBundle
        }
        // Mock archives deliberately contain a placeholder version and executable.
        guard !skipCodeSignValidation else { return }
        guard bundle.updateVersion > installedBundle.version,
              expected == nil || bundle.updateVersion == expected else { throw Error.incompatibleUpdate }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let running = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard running.compare(minimum, options: .numeric) != .orderedAscending else {
                throw Error.incompatibleUpdate
            }
        }
    }

    /// Installs without relaunching. The source remains available if installation fails.
    /// Returns the installed application's URL.
    @discardableResult
    public func replaceBundle(_ bundle: Bundle) async throws -> URL? {
        guard !isInstalling, !isChecking else { throw Error.installationInProgress }
        isInstalling = true
        defer { isInstalling = false }
        let backup = try await replaceValidatedBundle(bundle)
        try? FileManager.default.removeItem(at: backup)
        state = .none
        return installedBundle.bundleURL
    }

    private func replaceValidatedBundle(_ bundle: Bundle) async throws -> URL {
        try validateVersion(bundle)
        let destination = installedBundle.bundleURL
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedURL = staging.appendingPathComponent(destination.lastPathComponent)
        try FileManager.default.copyItem(at: bundle.bundleURL, to: stagedURL)
        guard let staged = Bundle(url: stagedURL),
              try await validateCodeSigning(installedBundle, staged) else { throw Error.codeSigningIdentity }
        try validateVersion(staged)
        let backupName = ".\(destination.lastPathComponent).\(UUID().uuidString).backup"
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagedURL, backupItemName: backupName,
                                                  options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
        return destination.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    /// Replaces, confirms launch, and terminates. Restores the old app if launch fails.
    public func installThrowing(_ bundle: Bundle) async throws {
        try await performInstallation(bundle, success: nil)
    }

    private func performInstallation(_ bundle: Bundle, success: OnSuccess?) async throws {
        guard !isInstalling, !isChecking else { throw Error.installationInProgress }
        isInstalling = true
        defer { isInstalling = false }
        let backup = try await replaceValidatedBundle(bundle)
        do {
            try await launchApplication(installedBundle.bundleURL)
        } catch {
            _ = try FileManager.default.replaceItemAt(installedBundle.bundleURL, withItemAt: backup, options: .usingNewMetadataOnly)
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
        state = .none
        success?()
        onInstallSuccess?()
        terminateApplication()
    }

    // Internal seams let installation tests exercise rollback without launching or quitting apps.
    var terminateApplication: () -> Void = { NSApp.terminate(nil) }
    var launchApplication: (URL) async throws -> Void = { url in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: Error.relaunchFailed) }
            }
        }
    }

    private func notifyStateChanged(newState: UpdateState) {
        state = newState
    }

    private func notifyReleasesDidChange(_ releases: [Release]) {
        self.releases = releases
    }
}

public struct Release: Decodable, Sendable {
    public let tagName: Version
    public let prerelease: Bool
    public let assets: [Asset]
    public let body: String
    public let name: String
    public let htmlUrl: String

    public struct Asset: Decodable, Sendable {
        public let name: String
        public let downloadUrl: URL
        public let contentType: ContentType

        enum CodingKeys: String, CodingKey {
            case name
            case downloadUrl = "browser_download_url"
            case contentType = "content_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case assets
        case body
        case name
        case htmlUrl = "html_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTagName = try container.decodeIfPresent(String.self, forKey: .tagName)
        self.tagName = rawTagName.flatMap(Version.init(tolerant:)) ?? .null
        self.prerelease = try container.decode(Bool.self, forKey: .prerelease)
        self.assets = try container.decode([Release.Asset].self, forKey: .assets)
        self.body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? rawTagName ?? ""
        self.htmlUrl = try container.decode(String.self, forKey: .htmlUrl)
    }

    func viableAsset(forRelease releasePrefix: String) -> Asset? {
        let prefix = "\(releasePrefix.lowercased())-\(tagName)"

        return assets.first { asset in
            let name = asset.name.lowercased()

            switch asset.contentType {
            case .zip:
                return name == "\(prefix).zip"
            case .tar:
                return [".tar", ".tar.gz", ".tar.xz", ".tar.bz2", ".tgz"]
                    .contains { name == prefix + $0 }
            case .unknown:
                return false
            }
        }
    }
}

public enum ContentType: Decodable, Sendable {
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "application/x-bzip2", "application/x-xz", "application/x-gzip", "application/gzip", "application/x-tar":
            self = .tar
        case "application/zip":
            self = .zip
        default:
            self = .unknown
        }
    }

    case zip
    case tar
    case unknown
}

extension Release: Comparable {
    public static func < (lhs: Release, rhs: Release) -> Bool {
        return lhs.tagName < rhs.tagName
    }

    public static func == (lhs: Release, rhs: Release) -> Bool {
        return lhs.tagName == rhs.tagName
    }
}

extension Array where Element == Release {
    func findViableUpdate(appVersion: Version, releasePrefix: String, prerelease: Bool) throws -> (Release, Release.Asset)? {
        let suitableReleases = prerelease ? self : filter { !$0.prerelease }

        guard let latestRelease = suitableReleases.sorted().last else { return nil }

        guard appVersion < latestRelease.tagName else { return nil }

        guard let asset = latestRelease.viableAsset(forRelease: releasePrefix) else { return nil }

        return (latestRelease, asset)
    }
}

func unzip(_ url: URL, contentType: ContentType) async throws -> URL? {

    let proc = Process()
    proc.currentDirectoryURL = url.deletingLastPathComponent()

    guard contentType != .unknown else { throw AppUpdater.Error.unzipFailed }
    // macOS bsdtar reads both zip and tar. Its default extraction rejects writes
    // through symlinks and paths containing ".." (never enable -P).
    let listing = Process()
    listing.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    listing.arguments = ["-tf", url.path]
    let (contents, _) = try await listing.launching()
    for path in String(decoding: contents, as: UTF8.self).split(separator: "\n") {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw AppUpdater.Error.pathTraversalDetected
        }
    }
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    proc.arguments = ["-xf", url.path, "--no-same-owner"]

    func validateExtractedContents(in directory: URL) throws {
        let basePath = directory.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return
        }

        while let url = enumerator.nextObject() as? URL {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard (resolved + "/").hasPrefix(basePath) else {
                throw AppUpdater.Error.pathTraversalDetected
            }
        }
    }

    func findApp() throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let apps = try contents.filter { url in
            guard url.pathExtension == "app" else { return false }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        guard apps.count == 1 else { throw AppUpdater.Error.invalidDownloadedBundle }
        return apps.first
    }

    _ = try await proc.launching(timeout: 120)

    let extractionDir = url.deletingLastPathComponent()
    try validateExtractedContents(in: extractionDir)

    return try findApp()
}

// MARK: - Debug Trace helper
extension AppUpdater {
    private static let logger = Logger(subsystem: "AppUpdater", category: "update")

    @inline(__always)
    func trace(_ items: Any...) {
        let msg = items.map { String(describing: $0) }.joined(separator: " ")
        Self.logger.debug("\(msg, privacy: .public)")
    }
}
