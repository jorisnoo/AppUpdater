import Foundation

/// Represents a downloaded update that's been deferred for later installation.
/// Apps can persist this (e.g., to UserDefaults) to track pending updates across launches.
public struct DeferredUpdate: Codable, Sendable {
    public let bundlePath: String
    public let releaseVersion: String
    public let releaseName: String
    public let assetName: String
    public let downloadDate: Date

    public init(
        bundlePath: String,
        releaseVersion: String,
        releaseName: String,
        assetName: String,
        downloadDate: Date = Date()
    ) {
        self.bundlePath = bundlePath
        self.releaseVersion = releaseVersion
        self.releaseName = releaseName
        self.assetName = assetName
        self.downloadDate = downloadDate
    }

    /// Loads the bundle from the stored path.
    /// Returns nil if the bundle no longer exists or is invalid.
    public func loadBundle() -> Bundle? {
        Bundle(url: URL(fileURLWithPath: bundlePath))
    }
}

// MARK: - Persistence Helpers

public extension DeferredUpdate {
    /// Default directory for storing pending update bundles.
    /// Located in Application Support under the app's bundle identifier.
    static func pendingUpdatesDirectory(
        for bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let identifier = bundleIdentifier ?? "AppUpdater"
        let pendingDir = appSupport
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("PendingUpdates", isDirectory: true)

        try FileManager.default.createDirectory(
            at: pendingDir,
            withIntermediateDirectories: true
        )

        return pendingDir
    }

    /// Persists the downloaded bundle to a stable location.
    /// - Parameter bundle: The downloaded bundle from `.downloaded` state
    /// - Parameter directory: Optional custom directory; defaults to pendingUpdatesDirectory()
    /// - Returns: URL where the bundle was persisted
    static func persistBundle(_ bundle: Bundle, to directory: URL? = nil) throws -> URL {
        let destDir = try directory ?? pendingUpdatesDirectory()
        let destination = destDir.appendingPathComponent("Update.app")

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: bundle.bundleURL, to: destination)

        return destination
    }

    /// Removes the pending updates directory and its contents.
    static func cleanup(for bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let dir = try? pendingUpdatesDirectory(for: bundleIdentifier) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
