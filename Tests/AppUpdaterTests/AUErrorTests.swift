import XCTest
@testable import AppUpdater

final class AUErrorTests: XCTestCase {

    func testInvalidCallingConventionDescription() {
        let error = AUError.invalidCallingConvention

        XCTAssertEqual(error.debugDescription, "A closure was called with an invalid calling convention, probably (nil, nil)")
        XCTAssertEqual(error.errorDescription, error.debugDescription)
    }

    func testBadInputDescription() {
        let error = AUError.badInput

        XCTAssertEqual(error.debugDescription, "Bad input was provided")
        XCTAssertEqual(error.errorDescription, error.debugDescription)
    }

    func testCancelledDescription() {
        let error = AUError.cancelled

        XCTAssertEqual(error.debugDescription, "The operation was cancelled")
        XCTAssertEqual(error.errorDescription, error.debugDescription)
    }

    func testIsCancelledExtension() {
        let cancelledError = AUError.cancelled
        let otherError = AUError.badInput

        XCTAssertTrue(cancelledError.isCancelled)
        XCTAssertFalse(otherError.isCancelled)
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
