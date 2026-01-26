import XCTest
@testable import AppUpdater
import Version

final class MockReleaseProviderTests: XCTestCase {

    func testFetchReleasesFromBundled() async throws {
        let provider = MockReleaseProvider(source: .bundled)
        let releases = try await provider.fetchReleases(owner: "example", repo: "AppUpdaterExample", urlTransform: nil)

        XCTAssertEqual(releases.count, 3)
        XCTAssertEqual(releases[0].tagName, Version(2, 0, 0))
        XCTAssertEqual(releases[1].tagName, Version(1, 2, 3))
        XCTAssertEqual(releases[2].tagName, Version(1, 1, 0))
    }

    func testFetchReleasesFromFileURL() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let jsonURL = tempDir.appendingPathComponent("test-releases.json")
        let jsonData = """
        [
            {
                "tag_name": "5.0.0",
                "prerelease": false,
                "assets": [],
                "body": "Test",
                "name": "v5.0.0",
                "html_url": "https://example.com"
            }
        ]
        """.data(using: .utf8)!
        try jsonData.write(to: jsonURL)

        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let provider = MockReleaseProvider(source: .fileURL(jsonURL), mockFileName: "")
        let releases = try await provider.fetchReleases(owner: "test", repo: "test", urlTransform: nil)

        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].tagName, Version(5, 0, 0))
    }

    func testReleasesAreSortedCorrectly() async throws {
        let provider = MockReleaseProvider(source: .bundled)
        let releases = try await provider.fetchReleases(owner: "example", repo: "AppUpdaterExample", urlTransform: nil)
        let sorted = releases.sorted()

        XCTAssertEqual(sorted[0].tagName, Version(1, 1, 0))
        XCTAssertEqual(sorted[1].tagName, Version(1, 2, 3))
        XCTAssertEqual(sorted[2].tagName, Version(2, 0, 0))
        XCTAssertEqual(sorted.last?.tagName, Version(2, 0, 0))
    }

    func testPrereleaseFiltering() async throws {
        let provider = MockReleaseProvider(source: .bundled)
        let releases = try await provider.fetchReleases(owner: "example", repo: "AppUpdaterExample", urlTransform: nil)
        let stableReleases = releases.filter { !$0.prerelease }

        XCTAssertEqual(stableReleases.count, 2)
        XCTAssertTrue(stableReleases.allSatisfy { !$0.prerelease })
    }

    func testDownloadSimulatesProgress() async throws {
        let provider = MockReleaseProvider(source: .bundled, simulatedSteps: 3, simulatedDelay: 10_000_000)
        let asset = makeAsset(name: "TestApp-1.0.0.zip")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let saveLocation = tempDir.appendingPathComponent("download.zip")
        let stream = try await provider.download(asset: asset, to: saveLocation, urlTransform: nil)

        var progressCount = 0
        var finishCount = 0

        for try await state in stream {
            switch state {
            case .progress:
                progressCount += 1
            case .finished:
                finishCount += 1
            }
        }

        XCTAssertEqual(progressCount, 3)
        XCTAssertEqual(finishCount, 1)
    }

    // MARK: - Helpers

    private func makeAsset(name: String) -> Release.Asset {
        let json = """
        {
            "name": "\(name)",
            "browser_download_url": "https://example.com/\(name)",
            "content_type": "application/zip"
        }
        """
        return try! JSONDecoder().decode(Release.Asset.self, from: json.data(using: .utf8)!)
    }
}
