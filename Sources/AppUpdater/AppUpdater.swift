import Foundation
import AppKit
@preconcurrency import Version
import OSLog

public final class AppUpdater: ObservableObject, @unchecked Sendable {
    public typealias OnSuccess = @Sendable () -> Void
    public typealias OnFail = @Sendable (Swift.Error) -> Void

    let activity: NSBackgroundActivityScheduler
    let owner: String
    let repo: String
    let releasePrefix: String

    var slug: String {
        return "\(owner)/\(repo)"
    }

    var urlTransform: URLTransform?
    public var provider: ReleaseProvider

    /// update state
    @MainActor
    @Published public var state: UpdateState = .none

    /// all releases
    @MainActor
    @Published public var releases: [Release] = []

    /// last error captured for diagnostics
    @MainActor
    @Published public var lastError: Swift.Error?

    public var onDownloadSuccess: OnSuccess? = nil
    public var onDownloadFail: OnFail? = nil

    public var onInstallSuccess: OnSuccess? = nil
    public var onInstallFail: OnFail? = nil

    public var allowPrereleases = false
    /// Skip code signing validation (useful for mock/testing).
    public var skipCodeSignValidation = false
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 3 * 60
        
        return URLSession(configuration: config)
    }()

    public init(owner: String, repo: String, releasePrefix: String? = nil, interval: TimeInterval = 24 * 60 * 60, urlTransform: URLTransform? = nil, provider: ReleaseProvider = GithubReleaseProvider()) {
        self.owner = owner
        self.repo = repo
        self.releasePrefix = releasePrefix ?? repo
        self.urlTransform = urlTransform
        self.provider = provider

        activity = NSBackgroundActivityScheduler(identifier: "AppUpdater.\(Bundle.main.bundleIdentifier ?? "")")
        activity.repeats = true
        activity.interval = interval
        activity.schedule { [unowned self] completion in
            guard !self.activity.shouldDefer else {
                return completion(.deferred)
            }
            self.check(success: { [self] in
                self.onDownloadSuccess?()
                completion(.finished)
            }, fail: { [self] err in
                self.onDownloadFail?(err)
                completion(.finished)
            })
        }
    }

    deinit {
        activity.invalidate()
    }

    public enum Error: Swift.Error {
        case bundleExecutableURL
        case codeSigningIdentity
        case invalidDownloadedBundle
        case noValidUpdate
        case unzipFailed
        case downloadFailed
        case pathTraversalDetected
        case extractionTimeout
        case invalidURL(String)
        case relaunchFailed
    }
    
    public func check(success: OnSuccess? = nil, fail: OnFail? = nil) {
        Task {
            do {
                try await checkThrowing()
                success?()
            } catch {
                trace("check failed:", String(describing: error))
                Task { @MainActor in self.lastError = error }
                fail?(error)
            }
        }
    }
    
    @MainActor
    public func install(_ appBundle: Bundle, success: OnSuccess? = nil, fail: OnFail? = nil) {
        Task { @MainActor in
            do {
                try await installThrowing(appBundle)
                success?()
                onInstallSuccess?()
            } catch {
                fail?(error)
                onInstallFail?(error)
            }
        }
    }

    public func checkThrowing() async throws {
        trace("begin check for", slug)
        guard Bundle.main.executableURL != nil else {
            throw Error.bundleExecutableURL
        }
        let currentVersion = Bundle.main.version

        trace("fetch releases")
        let releases = try await provider.fetchReleases(owner: owner, repo: repo, urlTransform: urlTransform)
        trace("fetched releases count:", releases.count)

        await notifyReleasesDidChange(releases)

        guard let (release, asset) = try releases.findViableUpdate(appVersion: currentVersion, releasePrefix: self.releasePrefix, prerelease: self.allowPrereleases) else {
            trace("no viable update for", currentVersion.description, "prefix", self.releasePrefix, "prerelease", self.allowPrereleases)
            throw Error.noValidUpdate
        }

        trace("viable release:", release.tagName.description, "asset:", asset.name)
        await notifyStateChanged(newState: .newVersionDetected(release, asset))

        if let bundle = try await downloadAndExtract(asset: asset, release: release) {
            await notifyStateChanged(newState: .downloaded(release, asset, bundle))
        }
    }

    private func validateCodeSigning(_ b1: Bundle, _ b2: Bundle) async throws -> Bool {
        let csi1 = try? await b1.codeSigningIdentity()
        let csi2 = try? await b2.codeSigningIdentity()

        if csi1 == nil || csi2 == nil {
            return skipCodeSignValidation
        }

        trace("comparing current: \(csi1) downloaded: \(csi2) equals? \(csi1 == csi2)")
        return skipCodeSignValidation || (csi1 == csi2)
    }

    private func downloadAndExtract(asset: Release.Asset, release: Release) async throws -> Bundle? {
        trace("update start:", release.tagName.description, asset.name)

        let tmpdir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)

        let downloadState = try await provider.download(asset: asset, to: tmpdir.appendingPathComponent("download"), urlTransform: urlTransform)

        var dst: URL? = nil
        for try await state in downloadState {
            switch state {
            case .progress(let fraction):
                trace("downloading", Int(fraction * 100), "%")
                await notifyStateChanged(newState: .downloading(release, asset, fraction: fraction))
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

        if try await validateCodeSigning(.main, downloadedAppBundle) {
            trace("codesign validated ok")
            return downloadedAppBundle
        } else {
            trace("codesign mismatch")
            throw Error.codeSigningIdentity
        }
    }
    
    @MainActor
    public func installThrowing(_ downloadedAppBundle: Bundle) async throws {
        trace("install start")
        let installedAppBundle = Bundle.main
        guard let exe = downloadedAppBundle.executableURL, FileManager.default.fileExists(atPath: exe.path) else {
            trace("invalid downloaded bundle")
            throw Error.invalidDownloadedBundle
        }

        _ = try FileManager.default.replaceItemAt(
            installedAppBundle.bundleURL,
            withItemAt: downloadedAppBundle.bundleURL,
            backupItemName: "backup.app",
            options: .usingNewMetadataOnly
        )
        trace("bundle replaced")

        let newAppURL = installedAppBundle.bundleURL
        let launched = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Swift.Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true

            NSWorkspace.shared.openApplication(at: newAppURL, configuration: configuration) { app, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: app != nil)
                }
            }
        }

        guard launched else {
            throw Error.relaunchFailed
        }

        trace("new app launched, terminating old instance")
        NSApp.terminate(self)
    }
    
    @MainActor
    private func notifyStateChanged(newState: UpdateState) {
        state = newState
    }

    @MainActor
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
        self.tagName = (try? container.decodeIfPresent(Version.self, forKey: .tagName)) ?? .null
        self.prerelease = try container.decode(Bool.self, forKey: .prerelease)
        self.assets = try container.decode([Release.Asset].self, forKey: .assets)
        self.body = try container.decode(String.self, forKey: .body)
        self.name = try container.decode(String.self, forKey: .name)
        self.htmlUrl = try container.decode(String.self, forKey: .htmlUrl)
    }

    func viableAsset(forRelease releasePrefix: String) -> Asset? {
        return assets.first { asset in
            let prefix = "\(releasePrefix.lowercased())-\(tagName)"
            let assetName = (asset.name as NSString).deletingPathExtension.lowercased()
            let fileExtension = (asset.name as NSString).pathExtension

            switch (assetName, asset.contentType, fileExtension) {
            case ("\(prefix).tar", .tar, "tar"):
                return true
            case (prefix, .zip, "zip"):
                return true
            default:
                return false
            }
        }
    }
}

public enum ContentType: Decodable, Sendable {
    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "application/x-bzip2", "application/x-xz", "application/x-gzip":
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

private extension Array where Element == Release {
    func findViableUpdate(appVersion: Version, releasePrefix: String, prerelease: Bool) throws -> (Release, Release.Asset)? {
        let suitableReleases = prerelease ? self : filter { !$0.prerelease }

        guard let latestRelease = suitableReleases.sorted().last else { return nil }

        guard appVersion < latestRelease.tagName else { return nil }

        guard let asset = latestRelease.viableAsset(forRelease: releasePrefix) else { return nil }

        return (latestRelease, asset)
    }
}

private func unzip(_ url: URL, contentType: ContentType) async throws -> URL? {

    let proc = Process()
    proc.currentDirectoryURL = url.deletingLastPathComponent()

    switch contentType {
    case .tar:
        proc.launchPath = "/usr/bin/tar"
        proc.arguments = ["xf", url.path]
    case .zip:
        proc.launchPath = "/usr/bin/unzip"
        proc.arguments = [url.path]
    default:
        throw AppUpdater.Error.unzipFailed
    }

    func validateExtractedContents(in directory: URL) throws {
        let basePath = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return
        }

        while let url = enumerator.nextObject() as? URL {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(basePath) else {
                throw AppUpdater.Error.pathTraversalDetected
            }
        }
    }

    func findApp() async throws -> URL? {
        let cnts = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsSubdirectoryDescendants)
        for url in cnts {
            guard url.pathExtension == "app" else { continue }
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else { continue }
            return url
        }
        return nil
    }

    let timeoutTask = Task {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        proc.terminate()
    }
    let _ = try await proc.launching()
    timeoutTask.cancel()

    let extractionDir = url.deletingLastPathComponent()
    try validateExtractedContents(in: extractionDir)

    return try await findApp()
}

public extension Bundle {
    func isCodeSigned() async -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/bin/codesign"
        proc.arguments = ["-dv", bundlePath]
        return (try? await proc.launching()) != nil
    }

    func codeSigningIdentity() async throws -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/codesign"
        proc.arguments = ["-dvvv", bundlePath]
        
        let (_, err) = try await proc.launching()
        guard let errInfo = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n") else {
            return nil
        }
        let result = errInfo.filter { $0.hasPrefix("Authority=") }
            .first.map { String($0.dropFirst(10)) }

        return result
    }
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
