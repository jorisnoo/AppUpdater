import XCTest
@testable import AppUpdater

final class AUErrorTests: XCTestCase {

    func testInvalidCallingConventionDescription() {
        let error = AUError.invalidCallingConvention

        XCTAssertEqual(error.errorDescription, "A closure was called with an invalid calling convention, probably (nil, nil)")
    }
}
