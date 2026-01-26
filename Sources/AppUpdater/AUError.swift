//
//  Error.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/26.
//

import Foundation

public enum AUError: Error {
    /**
     The completionHandler with form `(T?, Error?)` was called with `(nil, nil)`.
     This is invalid as per Cocoa/Apple calling conventions.
     */
    case invalidCallingConvention

    /**
     A handler returned its own promise. 99% of the time, this is likely a
     programming error. It is also invalid per Promises/A+.
     */
    case returnedSelf

    /** `when()`, `race()` etc. were called with invalid parameters, eg. an empty array. */
    case badInput

    /// The operation was cancelled
    case cancelled

    /// `nil` was returned from `flatMap`
    @available(*, deprecated, message: "See: `compactMap`")
    case flatMap(Any, Any.Type)

    /// `nil` was returned from `compactMap`
    case compactMap(Any, Any.Type)

    /**
     The lastValue or firstValue of a sequence was requested but the sequence was empty.

     Also used if all values of this collection failed the test passed to `firstValue(where:)`.
     */
    case emptySequence

    /// no winner in `race(fulfilled:)`
    case noWinner
}

extension AUError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .flatMap(let obj, let type):
            return "Could not `flatMap<\(type)>`: \(obj)"
        case .compactMap(let obj, let type):
            return "Could not `compactMap<\(type)>`: \(obj)"
        case .invalidCallingConvention:
            return "A closure was called with an invalid calling convention, probably (nil, nil)"
        case .returnedSelf:
            return "A promise handler returned itself"
        case .badInput:
            return "Bad input was provided to a PromiseKit function"
        case .cancelled:
            return "The asynchronous sequence was cancelled"
        case .emptySequence:
            return "The first or last element was requested for an empty sequence"
        case .noWinner:
            return "All thenables passed to race(fulfilled:) were rejected"
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
