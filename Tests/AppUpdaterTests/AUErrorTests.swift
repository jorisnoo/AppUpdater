import XCTest
@testable import AppUpdater

final class AUErrorTests: XCTestCase {

    func testInvalidCallingConventionDescription() {
        let error = AUError.invalidCallingConvention

        XCTAssertEqual(error.errorDescription, "A closure was called with an invalid calling convention, probably (nil, nil)")
    }

    func testURLErrorCancelledIsCancelled() {
        let urlError = URLError(.cancelled)

        XCTAssertTrue(urlError.isCancelled)
    }

    func testURLErrorOtherIsNotCancelled() {
        let urlError = URLError(.timedOut)

        XCTAssertFalse(urlError.isCancelled)
    }

    func testCocoaErrorUserCancelledIsCancelled() {
        let cocoaError = CocoaError(.userCancelled)

        XCTAssertTrue(cocoaError.isCancelled)
    }

    func testCocoaErrorOtherIsNotCancelled() {
        let cocoaError = CocoaError(.fileReadUnknown)

        XCTAssertFalse(cocoaError.isCancelled)
    }
}
