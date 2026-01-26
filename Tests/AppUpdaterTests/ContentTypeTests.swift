import XCTest
@testable import AppUpdater

final class ContentTypeTests: XCTestCase {

    func testDecodeZip() throws {
        let json = "\"application/zip\""
        let contentType = try JSONDecoder().decode(ContentType.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contentType, .zip)
    }

    func testDecodeTarBzip2() throws {
        let json = "\"application/x-bzip2\""
        let contentType = try JSONDecoder().decode(ContentType.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contentType, .tar)
    }

    func testDecodeTarXz() throws {
        let json = "\"application/x-xz\""
        let contentType = try JSONDecoder().decode(ContentType.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contentType, .tar)
    }

    func testDecodeTarGzip() throws {
        let json = "\"application/x-gzip\""
        let contentType = try JSONDecoder().decode(ContentType.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contentType, .tar)
    }

    func testDecodeUnknown() throws {
        let json = "\"application/octet-stream\""
        let contentType = try JSONDecoder().decode(ContentType.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contentType, .unknown)
    }

    func testDecodeTextPlain() throws {
        let json = "\"text/plain\""
        let contentType = try JSONDecoder().decode(ContentType.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(contentType, .unknown)
    }
}
