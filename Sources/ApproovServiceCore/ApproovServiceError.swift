//
// MIT License
// 
// Copyright (c) 2016-present, Approov Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
// ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
// THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

// Approov error conditions
public enum ApproovServiceError: LocalizedError {
    // a transient networking problem reaching Approov, so the request may be retried, with the SDK status
    // that caused it or nil if none applies
    case networkingError(message: String, status: ApproovTokenStatus? = nil)

    // the attestation was rejected, with the ARC and the rejection reasons if enabled for the account
    case rejectionError(message: String, arc: String, rejectionReasons: String)

    // a permanent error that retrying will not fix, with the SDK status that caused it or nil if none applies
    case permanentError(message: String, status: ApproovTokenStatus? = nil)

    // pinning could not be verified for a protected domain
    case pinningError(message: String)

    // the Approov SDK rejected initialize, with the SDK's own message and the NSError it reported
    case initializationError(message: String, underlying: NSError? = nil)

    // the SDK token fetch status the error was raised for, so an app need not parse the message: rejected
    // for a rejectionError, or nil if no SDK status applies
    public var status: ApproovTokenStatus? {
        switch self {
        case .networkingError(_, let status), .permanentError(_, let status):
            return status
        case .rejectionError:
            return .rejected
        case .pinningError, .initializationError:
            return nil
        }
    }

    // the error the Approov SDK reported for an initializationError, or nil otherwise
    public var underlyingError: NSError? {
        if case .initializationError(_, let underlying) = self {
            return underlying
        }
        return nil
    }

    // the NSError domain and code used for permanent failures of intercepted requests
    public static let errorDomain = "io.approov.ApproovService"
    public static let errorCode = 499

    /**
     * Converts the error to an NSError for the URL loading system, which only keeps the domain,
     * code and userInfo, so the description and attestation details are carried in the userInfo. A
     * networkingError becomes NSURLErrorNetworkConnectionLost, so the app's retry logic treats it
     * as a network failure; every other error uses errorDomain and errorCode.
     *
     * @return NSError for the error
     */
    public func asNSError() -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "ApproovService error"]
        // the SDK status name ("NO_NETWORK", "REJECTED", ...), when one applies
        if let status = status {
            userInfo["status"] = status.rawValue
        }
        switch self {
        case .networkingError:
            userInfo["type"] = "network"
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                           userInfo: userInfo)
        case .rejectionError(_, let arc, let rejectionReasons):
            userInfo["type"] = "rejection"
            userInfo["rejectionARC"] = arc
            userInfo["rejectionReasons"] = rejectionReasons
        case .initializationError(_, let underlying):
            userInfo["type"] = "general"
            if let underlying = underlying {
                userInfo[NSUnderlyingErrorKey] = underlying
            }
        default:
            userInfo["type"] = "general"
        }
        return NSError(domain: Self.errorDomain, code: Self.errorCode, userInfo: userInfo)
    }

    public var errorDescription: String? {
        switch self {
        case .networkingError(let message, _):
            return "ApproovService network error (retry possible): \(message)"
        case .rejectionError(let message, let arc, let rejectionReasons):
            var description = "ApproovService rejection: \(message)"
            if !arc.isEmpty { description += ", ARC \(arc)" }
            if !rejectionReasons.isEmpty { description += ", rejection reasons \(rejectionReasons)" }
            return description
        case .permanentError(let message, _):
            return "ApproovService error: \(message)"
        case .pinningError(let message):
            return "ApproovService pinning error: \(message)"
        case .initializationError(let message, _):
            return "ApproovService initialization error: \(message)"
        }
    }
}
