import XCTest
@testable import AppUpdater
import Version

final class ReleaseTests: XCTestCase {

    // MARK: - JSON Decoding

    func testDecodeSingleRelease() throws {
        let json = """
        {
            "tag_name": "1.0.0",
            "prerelease": false,
            "assets": [],
            "body": "Release notes",
            "name": "Version 1.0.0",
            "html_url": "https://github.com/example/repo/releases/v1.0.0"
        }
        """
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(Release.self, from: data)

        XCTAssertEqual(release.tagName, Version(1, 0, 0))
        XCTAssertFalse(release.prerelease)
        XCTAssertTrue(release.assets.isEmpty)
        XCTAssertEqual(release.body, "Release notes")
        XCTAssertEqual(release.name, "Version 1.0.0")
        XCTAssertEqual(release.htmlUrl, "https://github.com/example/repo/releases/v1.0.0")
    }

    func testDecodeReleaseWithAssets() throws {
        let json = """
        {
            "tag_name": "2.0.0",
            "prerelease": true,
            "assets": [
                {
                    "name": "MyApp-2.0.0.zip",
                    "browser_download_url": "https://example.com/download.zip",
                    "content_type": "application/zip"
                }
            ],
            "body": "",
            "name": "v2.0.0",
            "html_url": "https://example.com/releases/v2.0.0"
        }
        """
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(Release.self, from: data)

        XCTAssertEqual(release.tagName, Version(2, 0, 0))
        XCTAssertTrue(release.prerelease)
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "MyApp-2.0.0.zip")
        XCTAssertEqual(release.assets[0].downloadUrl.absoluteString, "https://example.com/download.zip")
        XCTAssertEqual(release.assets[0].contentType, .zip)
    }

    func testDecodeReleaseWithInvalidVersion() throws {
        let json = """
        {
            "tag_name": "not-a-version",
            "prerelease": false,
            "assets": [],
            "body": "",
            "name": "Invalid",
            "html_url": "https://example.com"
        }
        """
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(Release.self, from: data)

        XCTAssertEqual(release.tagName, .null)
    }

    // MARK: - Asset Selection

    func testViableAssetMatchesZip() throws {
        let release = makeRelease(
            tag: "1.0.0",
            assets: [(name: "MyApp-1.0.0.zip", contentType: "application/zip")]
        )
        let asset = release.viableAsset(forRelease: "MyApp")

        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.name, "MyApp-1.0.0.zip")
    }

    func testViableAssetMatchesTar() throws {
        let release = makeRelease(
            tag: "1.0.0",
            assets: [(name: "MyApp-1.0.0.tar.tar", contentType: "application/x-gzip")]
        )
        let asset = release.viableAsset(forRelease: "MyApp")

        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.name, "MyApp-1.0.0.tar.tar")
    }

    func testViableAssetIgnoresWrongPrefix() throws {
        let release = makeRelease(
            tag: "1.0.0",
            assets: [(name: "OtherApp-1.0.0.zip", contentType: "application/zip")]
        )
        let asset = release.viableAsset(forRelease: "MyApp")

        XCTAssertNil(asset)
    }

    func testViableAssetIgnoresWrongExtension() throws {
        let release = makeRelease(
            tag: "1.0.0",
            assets: [(name: "MyApp-1.0.0.dmg", contentType: "application/octet-stream")]
        )
        let asset = release.viableAsset(forRelease: "MyApp")

        XCTAssertNil(asset)
    }

    func testViableAssetIsCaseInsensitive() throws {
        let release = makeRelease(
            tag: "1.0.0",
            assets: [(name: "MYAPP-1.0.0.zip", contentType: "application/zip")]
        )
        let asset = release.viableAsset(forRelease: "MyApp")

        XCTAssertNotNil(asset)
    }

    func testViableAssetSelectsFirstMatch() throws {
        let release = makeRelease(
            tag: "1.0.0",
            assets: [
                (name: "MyApp-1.0.0.zip", contentType: "application/zip"),
                (name: "MyApp-1.0.0.tar.tar", contentType: "application/x-gzip")
            ]
        )
        let asset = release.viableAsset(forRelease: "MyApp")

        XCTAssertEqual(asset?.name, "MyApp-1.0.0.zip")
    }

    // MARK: - Release Comparison

    func testReleaseSorting() {
        let releases = [
            makeRelease(tag: "2.0.0", assets: []),
            makeRelease(tag: "1.0.0", assets: []),
            makeRelease(tag: "1.5.0", assets: [])
        ]
        let sorted = releases.sorted()

        XCTAssertEqual(sorted[0].tagName, Version(1, 0, 0))
        XCTAssertEqual(sorted[1].tagName, Version(1, 5, 0))
        XCTAssertEqual(sorted[2].tagName, Version(2, 0, 0))
    }

    func testReleaseEquality() {
        let release1 = makeRelease(tag: "1.0.0", assets: [])
        let release2 = makeRelease(tag: "1.0.0", assets: [])
        let release3 = makeRelease(tag: "2.0.0", assets: [])

        XCTAssertEqual(release1, release2)
        XCTAssertNotEqual(release1, release3)
    }

    // MARK: - Helpers

    private func makeRelease(tag: String, assets: [(name: String, contentType: String)], prerelease: Bool = false) -> Release {
        let assetsJson = assets.map { asset in
            """
            {"name": "\(asset.name)", "browser_download_url": "https://example.com/\(asset.name)", "content_type": "\(asset.contentType)"}
            """
        }.joined(separator: ",")

        let json = """
        {
            "tag_name": "\(tag)",
            "prerelease": \(prerelease),
            "assets": [\(assetsJson)],
            "body": "",
            "name": "v\(tag)",
            "html_url": "https://example.com/v\(tag)"
        }
        """
        return try! JSONDecoder().decode(Release.self, from: json.data(using: .utf8)!)
    }
}
