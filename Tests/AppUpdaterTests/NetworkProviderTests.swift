import Foundation
import XCTest
@testable import AppUpdater

final class NetworkProviderTests: XCTestCase {
    private func provider() -> GithubReleaseProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkFixtureProtocol.self]
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return GithubReleaseProvider(session: session)
    }

    private func destination() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func asset(_ path: String) -> Release.Asset {
        let url = URL(string: "https://assets.invalid/\(path)")!
        return Release.Asset(name: url.lastPathComponent, downloadUrl: url, contentType: .zip)
    }

    func testDefaultSessionBoundsTotalResourceTimeWithoutChangingInjectedSessions() {
        let timeout = GithubReleaseProvider().session.configuration.timeoutIntervalForResource
        XCTAssertGreaterThan(timeout, 0)
        XCTAssertLessThanOrEqual(timeout, 15 * 60)
        XCTAssertEqual(provider().session.configuration.timeoutIntervalForResource, 10)
    }

    func testFetchDecodesSuccessfulResponse() async throws {
        let releases = try await provider().fetchReleases(owner: "test", repo: "app")
        XCTAssertEqual(releases.map(\.tagName.description), ["1.2.3"])
    }

    func testFetchPreservesForbiddenStatusAndBody() async throws {
        do {
            _ = try await provider().fetchReleases(owner: "test", repo: "forbidden")
            XCTFail("Expected HTTP 403")
        } catch HTTPError.badStatusCode(let code, let body, let response) {
            XCTAssertEqual(code, 403)
            XCTAssertEqual(response.url?.path, "/repos/test/forbidden/releases")
            XCTAssertEqual(body, Data("forbidden".utf8))
        }
    }

    func testFetchRejectsMalformedJSON() async throws {
        do {
            _ = try await provider().fetchReleases(owner: "test", repo: "malformed")
            XCTFail("Expected malformed JSON to fail decoding")
        } catch is DecodingError {}
    }

    func testDownloadRejects404WithoutSavingErrorPage() async throws {
        let url = destination()
        do {
            let stream = try await provider().download(asset: asset("missing.zip"), to: url)
            for try await state in stream {
                if case .finished = state { XCTFail("HTTP 404 must not finish successfully") }
            }
            XCTFail("Expected HTTP 404")
        } catch HTTPError.badStatusCode(let code, let body, let response) {
            XCTAssertEqual(code, 404)
            XCTAssertEqual(response.url?.path, "/missing.zip")
            XCTAssertEqual(body, Data("not found".utf8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDownloadReportsProgressAndSavesResponse() async throws {
        let url = destination()
        let stream = try await provider().download(asset: asset("app.zip"), to: url)
        var sawProgress = false
        var finished = false
        for try await state in stream {
            XCTAssertFalse(finished, "Finished must be the last event")
            switch state {
            case .progress(let fraction):
                XCTAssertTrue((0...1).contains(fraction))
                sawProgress = true
            case .finished(let location):
                XCTAssertEqual(location, url)
                XCTAssertEqual(try Data(contentsOf: location), NetworkFixtureProtocol.archive)
                finished = true
            }
        }
        XCTAssertTrue(sawProgress)
        XCTAssertTrue(finished)
    }

    func testCancellingFetchStopsURLTask() async {
        let provider = provider()
        let id = UUID().uuidString
        let url = URL(string: "https://api.github.com/repos/slow/\(id)/releases")!
        await assertCancellationReachesURLTask(url) {
            _ = try await provider.fetchReleases(owner: "slow", repo: id)
            XCTFail("Cancelled fetch must not return releases")
        }
    }

    func testCancellingDownloadStopsURLTask() async {
        let provider = provider()
        let asset = asset("slow/\(UUID().uuidString).zip")
        let url = destination()
        await assertCancellationReachesURLTask(asset.downloadUrl) {
            let stream = try await provider.download(asset: asset, to: url)
            for try await state in stream {
                if case .finished = state { XCTFail("Cancelled download must not finish successfully") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAlreadyCancelledDownloadDoesNotStart() async throws {
        let provider = provider()
        let asset = asset("app.zip")
        let url = destination()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await provider.download(asset: asset, to: url)
        }
        do {
            try await task.value
            XCTFail("An already-cancelled caller must not start a download")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func assertCancellationReachesURLTask(_ url: URL, operation: @escaping @Sendable () async throws -> Void) async {
        let started = expectation(forNotification: NetworkFixtureProtocol.notification("started", url), object: nil)
        let stopped = expectation(forNotification: NetworkFixtureProtocol.notification("stopped", url), object: nil)
        let returned = expectation(description: "Cancelled operation returned")
        let task = Task {
            defer { returned.fulfill() }
            do {
                try await operation()
            } catch is CancellationError {
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            } catch {
                XCTFail("Unexpected cancellation error: \(error)")
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [stopped, returned], timeout: 5)
    }
}

// Only installed on each test's ephemeral session. Unrecognized URLs fail locally.
private final class NetworkFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let archive = Data(repeating: 0x41, count: 64 * 1024)

    static func notification(_ event: String, _ url: URL) -> Notification.Name {
        Notification.Name("NetworkProviderTests.\(event).\(url.absoluteString)")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url.pathComponents.contains("slow") {
            NotificationCenter.default.post(name: Self.notification("started", url), object: nil)
            return // Remain in flight until cancelled.
        }
        let status: Int
        let data: Data
        switch (url.host, url.path) {
        case ("api.github.com", "/repos/test/app/releases"):
            status = 200
            data = Data(#"[{"tag_name":"1.2.3","prerelease":false,"assets":[],"html_url":"https://example.invalid"}]"#.utf8)
        case ("api.github.com", "/repos/test/forbidden/releases"):
            status = 403
            data = Data("forbidden".utf8)
        case ("api.github.com", "/repos/test/malformed/releases"):
            status = 200
            data = Data("{".utf8)
        case ("assets.invalid", "/missing.zip"):
            status = 404
            data = Data("not found".utf8)
        case ("assets.invalid", "/app.zip"):
            status = 200
            data = Self.archive
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if let url = request.url, url.pathComponents.contains("slow") {
            NotificationCenter.default.post(name: Self.notification("stopped", url), object: nil)
        }
    }
}
