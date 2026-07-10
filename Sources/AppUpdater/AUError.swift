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
