//
//  Error.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/26.
//

import Foundation

public enum AUError: Error {
    /// The completionHandler with form `(T?, Error?)` was called with `(nil, nil)`.
    /// This is invalid as per Cocoa/Apple calling conventions.
    case invalidCallingConvention

    /// Bad input was provided to a function
    case badInput

    /// The operation was cancelled
    case cancelled
}

extension AUError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .invalidCallingConvention:
            return "A closure was called with an invalid calling convention, probably (nil, nil)"
        case .badInput:
            return "Bad input was provided"
        case .cancelled:
            return "The operation was cancelled"
        }
    }
}

extension AUError: LocalizedError {
    public var errorDescription: String? {
        return debugDescription
    }
}


//////////////////////////////////////////////////////////// Cancellation

/// An error that may represent the cancelled condition
public protocol CancellableError: Error {
    /// returns true if this Error represents a cancelled condition
    var isCancelled: Bool { get }
}

extension Error {
    public var isCancelled: Bool {
        if let auError = self as? AUError, case .cancelled = auError {
            return true
        }

        if let cancellable = self as? CancellableError {
            return cancellable.isCancelled
        }

        if let urlError = self as? URLError, urlError.code == .cancelled {
            return true
        }

        if let cocoaError = self as? CocoaError, cocoaError.code == .userCancelled {
            return true
        }

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let nsError = self as NSError
        return nsError.domain == "SKErrorDomain" && nsError.code == 2
        #else
        return false
        #endif
    }
}

/// Used by `catch` and `recover`
public enum CatchPolicy {
    /// Indicates that `catch` or `recover` handle all error types including cancellable-errors.
    case allErrors

    /// Indicates that `catch` or `recover` handle all error except cancellable-errors.
    case allErrorsExceptCancellation
}
