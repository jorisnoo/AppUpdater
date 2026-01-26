import Foundation

public enum AUError: Error, LocalizedError {
    /// The completionHandler with form `(T?, Error?)` was called with `(nil, nil)`.
    case invalidCallingConvention

    public var errorDescription: String? {
        switch self {
        case .invalidCallingConvention:
            return "A closure was called with an invalid calling convention, probably (nil, nil)"
        }
    }
}

public protocol CancellableError: Error {
    var isCancelled: Bool { get }
}

extension Error {
    public var isCancelled: Bool {
        if let cancellable = self as? CancellableError {
            return cancellable.isCancelled
        }

        if let urlError = self as? URLError, urlError.code == .cancelled {
            return true
        }

        if let cocoaError = self as? CocoaError, cocoaError.code == .userCancelled {
            return true
        }

        let nsError = self as NSError
        return nsError.domain == "SKErrorDomain" && nsError.code == 2
    }
}
