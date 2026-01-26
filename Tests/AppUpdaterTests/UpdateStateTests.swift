import XCTest
@testable import AppUpdater
import Version

final class UpdateStateTests: XCTestCase {

    func testNoneStateHasNoRelease() {
        let state = AppUpdater.UpdateState.none

        XCTAssertNil(state.release)
        XCTAssertNil(state.asset)
    }

    func testNewVersionDetectedHasRelease() {
        let release = makeRelease(tag: "1.0.0")
        let asset = makeAsset(name: "App-1.0.0.zip")
        let state = AppUpdater.UpdateState.newVersionDetected(release, asset)

        XCTAssertEqual(state.release?.tagName, Version(1, 0, 0))
        XCTAssertEqual(state.asset?.name, "App-1.0.0.zip")
    }

    func testDownloadingHasRelease() {
        let release = makeRelease(tag: "2.0.0")
        let asset = makeAsset(name: "App-2.0.0.zip")
        let state = AppUpdater.UpdateState.downloading(release, asset, fraction: 0.5)

        XCTAssertEqual(state.release?.tagName, Version(2, 0, 0))
        XCTAssertEqual(state.asset?.name, "App-2.0.0.zip")
    }

    func testDownloadedHasRelease() {
        let release = makeRelease(tag: "3.0.0")
        let asset = makeAsset(name: "App-3.0.0.zip")
        let bundle = Bundle.main
        let state = AppUpdater.UpdateState.downloaded(release, asset, bundle)

        XCTAssertEqual(state.release?.tagName, Version(3, 0, 0))
        XCTAssertEqual(state.asset?.name, "App-3.0.0.zip")
    }

    // MARK: - Helpers

    private func makeRelease(tag: String) -> Release {
        let json = """
        {
            "tag_name": "\(tag)",
            "prerelease": false,
            "assets": [],
            "body": "",
            "name": "v\(tag)",
            "html_url": "https://example.com/v\(tag)"
        }
        """
        return try! JSONDecoder().decode(Release.self, from: json.data(using: .utf8)!)
    }

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
