import Foundation

public final class MockReleaseProvider: ReleaseProvider, Sendable {
    public enum Source: Sendable {
        case bundled // use `Bundle.module` resources
        case fileURL(URL) // load JSON from a local file URL
    }

    private let source: Source
    private let mockFileName: String
    private let simulatedSteps: Int
    private let simulatedDelay: UInt64

    public init(source: Source = .bundled, mockFileName: String = "releases.mock.json", simulatedSteps: Int = 10, simulatedDelay: UInt64 = 100_000_000) {
        self.source = source
        self.mockFileName = mockFileName
        self.simulatedSteps = max(simulatedSteps, 1)
        self.simulatedDelay = simulatedDelay
    }

    public func fetchReleases(owner: String, repo: String, urlTransform: URLTransform?) async throws -> [Release] {
        let data: Data
        switch source {
        case .bundled:
            if let url = Bundle.module.url(forResource: mockFileName, withExtension: nil, subdirectory: "Mocks") {
                data = try Data(contentsOf: url)
            } else if let url = Bundle.module.url(forResource: (mockFileName as NSString).deletingPathExtension, withExtension: (mockFileName as NSString).pathExtension.isEmpty ? nil : (mockFileName as NSString).pathExtension) {
                data = try Data(contentsOf: url)
            } else {
                throw CocoaError(.fileNoSuchFile)
            }
        case .fileURL(let url):
            data = try Data(contentsOf: url)
        }

        return try JSONDecoder().decode([Release].self, from: data)
    }

    public func download(asset: Release.Asset, to saveLocation: URL, urlTransform: URLTransform?) async throws -> AsyncThrowingStream<DownloadingState, Error> {
        let steps = simulatedSteps
        let delay = simulatedDelay
        let assetName = asset.name

        return AsyncThrowingStream<DownloadingState, Error> { continuation in
            Task {
                // Simulate progress
                for i in 1...steps {
                    try await Task.sleep(nanoseconds: delay)
                    let fraction = Double(i) / Double(steps)
                    continuation.yield(.progress(fractionCompleted: fraction))
                }

                // Materialize a mock zip at saveLocation if requested type is zip, otherwise tar
                do {
                    try await MockReleaseProvider.createMockArchive(at: saveLocation, assetName: assetName)
                    continuation.yield(.finished(saveLocation: saveLocation))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func createMockArchive(at url: URL, assetName: String) async throws {
        // Decide archive type by extension
        let ext = (assetName as NSString).pathExtension.lowercased()
        let tempDir = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create a minimal .app bundle
        let appName = ((assetName as NSString).deletingPathExtension as NSString).lastPathComponent
        let appDir = tempDir.appendingPathComponent("\(appName).app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let contentsMacOS = appDir.appendingPathComponent("Contents/MacOS")
        let contentsResources = appDir.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: contentsMacOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contentsResources, withIntermediateDirectories: true)
        // Minimal Info.plist
        let infoPlist = appDir.appendingPathComponent("Contents/Info.plist")
        let info = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>CFBundleName</key><string>\(appName)</string>
            <key>CFBundleIdentifier</key><string>com.example.\(appName)</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>CFBundleShortVersionString</key><string>1.0.0</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleExecutable</key><string>\(appName)</string>
        </dict>
        </plist>
        """
        try info.write(to: infoPlist, atomically: true, encoding: .utf8)
        // Create a tiny executable shell script as placeholder
        let exe = contentsMacOS.appendingPathComponent(appName)
        try "#!/bin/sh\necho Mock app launched\nsleep 3\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        // Archive
        if ext == "zip" {
            try await shellZip(contentsOf: tempDir, into: url)
        } else if ext == "tar" {
            try await shellTar(contentsOf: tempDir, into: url)
        } else {
            // default to zip
            try await shellZip(contentsOf: tempDir, into: url)
        }

        // Cleanup tempDir
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func shellZip(contentsOf dir: URL, into dst: URL) async throws {
        let proc = Process()
        proc.launchPath = "/usr/bin/zip"
        proc.currentDirectoryPath = dir.path
        proc.arguments = ["-r", dst.path, "."]
        let _ = try await proc.launching()
    }

    private static func shellTar(contentsOf dir: URL, into dst: URL) async throws {
        let proc = Process()
        proc.launchPath = "/usr/bin/tar"
        proc.currentDirectoryPath = dir.path
        proc.arguments = ["-czf", dst.path, "."]
        let _ = try await proc.launching()
    }
}
