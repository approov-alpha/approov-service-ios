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

/**
 * ApproovServiceMutator is the single place where an app changes the request decisions of the service
 * layer. Each decision made during interception and by the direct methods is delegated to the installed
 * mutator, and every method has a default implementation so an implementation only overrides the
 * decisions it cares about. The standard mutators are `.CLOSE_FAILURE`, the 3.5.x decisions which are
 * also the default implementations, `.ALWAYS_PROCEED`, which never aborts a request, and `.DEFAULT`,
 * which points to the default behaviour of the release and is `.ALWAYS_PROCEED`.
 *
 * To abort a request for some further outcome, override the relevant interceptor method and throw a
 * URLError, which is relayed to the app unchanged. Any other error thrown by a method fails the request
 * with a URLError naming the method, with the original as its underlying error. Note that an
 * implementation must be Sendable, since it is called from concurrent queues.
 */
public protocol ApproovServiceMutator: Sendable {

    /**
     * Decides how to handle the result of a fetchToken.
     *
     * @param result is the result of the fetch
     * @throws ApproovServiceError if the token fetch failed
     */
    func handleFetchTokenResult(_ result: ApproovTokenResult) throws

    /**
     * Decides how to handle the result of a fetchSecureString.
     *
     * @param result is the result of the fetch
     * @param operation is "lookup" or "definition" for the type of operation
     * @param key is the secure string key
     * @throws ApproovServiceError if the secure string fetch failed
     */
    func handleFetchSecureStringResult(_ result: ApproovTokenResult,
                                       operation: String,
                                       key: String) throws

    /**
     * Decides how to handle the result of a fetchCustomJWT.
     *
     * @param result is the result of the fetch
     * @throws ApproovServiceError if the custom JWT fetch failed
     */
    func handleFetchCustomJWTResult(_ result: ApproovTokenResult) throws

    /**
     * Decides whether a request should be processed by Approov at all, at the start of interception.
     * The default excludes requests matching an exclusion URL regular expression.
     *
     * @param request is the request being intercepted
     * @return true if the request should be processed, false to forward it untouched
     * @throws Error to abort the request
     */
    func handleInterceptorShouldProcessRequest(_ request: URLRequest) throws -> Bool

    /**
     * Decides how to handle the token fetch result for a request. On SUCCESS the Approov headers
     * are the token, status and trace headers and any signatures; on any other status they are the
     * status header only, and only to a host listed in the Approov pins. For a failure status on any
     * other host the request goes out untouched, and only an error of the app's own aborts it. Note
     * that the answer does not decide the secure strings.
     *
     * @param result is the result of the token fetch
     * @param url is the URL of the request
     * @return true to add the Approov headers for the status, false to add none
     * @throws Error to abort the request, which should be a URLError for the app's own policy
     */
    func handleInterceptorFetchTokenResult(_ result: ApproovTokenResult,
                                           url: String) throws -> Bool

    /**
     * Decides how to handle the secure string fetch result for a substitution header. This is only
     * called for an https request whose token fetch returned SUCCESS or UNPROTECTED_URL. The default
     * substitutes on SUCCESS only. If the request continues after a status other than SUCCESS, the
     * status is sent in place of the placeholder, after any required prefix, written as the status
     * header writes it, so your backend sees why the secure string is missing.
     *
     * @param result is the result of the secure string fetch
     * @param header is the header being substituted
     * @return true to substitute a secure string, false to leave the placeholder on SUCCESS
     * @throws Error to abort the request, which should be a URLError for the app's own policy
     */
    func handleInterceptorHeaderSubstitutionResult(_ result: ApproovTokenResult,
                                                   header: String) throws -> Bool

    /**
     * Decides how to handle the secure string fetch result for a substitution query parameter. This
     * is only called for an https request whose token fetch returned SUCCESS or UNPROTECTED_URL. The
     * default substitutes on SUCCESS only. If the request continues after a status other than
     * SUCCESS, the status is sent as the parameter value, written as the status header writes it.
     *
     * @param result is the result of the secure string fetch
     * @param queryKey is the query parameter key being substituted
     * @return true to substitute a secure string, false to leave the placeholder on SUCCESS
     * @throws Error to abort the request, which should be a URLError for the app's own policy
     */
    func handleInterceptorQueryParamSubstitutionResult(_ result: ApproovTokenResult,
                                                       queryKey: String) throws -> Bool

    /**
     * Allows further changes to a request after Approov has processed it, before it is sent.
     *
     * @param request is the request processed by Approov
     * @param changes is the record of the changes Approov made to the request
     * @return the request to be sent
     * @throws Error to abort the request, which should be a URLError for the app's own policy
     */
    func handleInterceptorProcessedRequest(_ request: URLRequest,
                                           changes: ApproovRequestMutations) throws -> URLRequest

    /**
     * Decides whether Approov pinning should be applied to the TLS handshake for a request.
     *
     * @param request is the request being sent
     * @return true to apply Approov pinning, false to leave trust to the app or the platform
     */
    func handlePinningShouldProcessRequest(_ request: URLRequest) -> Bool
}

public extension ApproovServiceMutator {

    func handleFetchTokenResult(_ result: ApproovTokenResult) throws {
        switch result.status {
        case .success:
            return
        case .noNetwork, .poorNetwork, .mitmDetected:
            throw ApproovServiceError.networkingError(message: "fetchToken: " + result.status.rawValue,
                                                      status: result.status)
        default:
            throw ApproovServiceError.permanentError(message: "fetchToken: " + result.status.rawValue,
                                                     status: result.status)
        }
    }

    func handleFetchSecureStringResult(_ result: ApproovTokenResult,
                                       operation: String,
                                       key: String) throws {
        switch result.status {
        case .rejected:
            throw ApproovServiceError.rejectionError(message: "fetchSecureString \(operation) for \(key): REJECTED",
                                                  arc: result.arc,
                                                  rejectionReasons: result.rejectionReasons)
        case .noNetwork, .poorNetwork, .mitmDetected:
            throw ApproovServiceError.networkingError(message: "fetchSecureString \(operation) for \(key): " +
                                                   result.status.rawValue, status: result.status)
        case .success, .unknownKey:
            return
        default:
            throw ApproovServiceError.permanentError(message: "fetchSecureString \(operation) for \(key): " +
                                                  result.status.rawValue, status: result.status)
        }
    }

    func handleFetchCustomJWTResult(_ result: ApproovTokenResult) throws {
        switch result.status {
        case .rejected:
            throw ApproovServiceError.rejectionError(message: "fetchCustomJWT: REJECTED",
                                                  arc: result.arc,
                                                  rejectionReasons: result.rejectionReasons)
        case .noNetwork, .poorNetwork, .mitmDetected:
            throw ApproovServiceError.networkingError(message: "fetchCustomJWT: " + result.status.rawValue,
                                                      status: result.status)
        case .success:
            return
        default:
            throw ApproovServiceError.permanentError(message: "fetchCustomJWT: " + result.status.rawValue,
                                                     status: result.status)
        }
    }

    func handleInterceptorShouldProcessRequest(_ request: URLRequest) throws -> Bool {
        guard let url = request.url else {
            throw ApproovStandardDecisions.made(.permanentError(
                message: "handleInterceptorShouldProcessRequest: request has no URL"))
        }
        let urlString = url.absoluteString
        let urlStringRange = NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
        for (_, regex) in ApproovInterceptor.shared.exclusionRegexes {
            if regex.firstMatch(in: urlString, options: [], range: urlStringRange) != nil {
                return false
            }
        }
        return true
    }

    func handleInterceptorFetchTokenResult(_ result: ApproovTokenResult,
                                           url: String) throws -> Bool {
        // the host only, since the path or query of the URL can carry personal data or a secret
        let host = URL(string: url)?.host.flatMap { $0.isEmpty ? nil : $0 } ?? "a URL without a host"
        switch result.status {
        case .success, .noApproovService:
            // NO_APPROOV_SERVICE proceeds with the status header only, as evidence that Approov ran
            return true
        case .noNetwork, .poorNetwork, .mitmDetected:
            throw ApproovStandardDecisions.made(.networkingError(
                message: "Approov token fetch for \(host): " + result.status.rawValue, status: result.status))
        case .unknownURL, .unprotectedURL:
            // no Approov headers for a host not added to Approov or a secrets-only API
            return false
        case .rejected:
            // surface the ARC and rejection reasons, which reach the caller in the relayed NSError
            throw ApproovStandardDecisions.made(.rejectionError(message: "Approov token fetch for \(host): REJECTED",
                                                                arc: result.arc,
                                                                rejectionReasons: result.rejectionReasons))
        default:
            throw ApproovStandardDecisions.made(.permanentError(
                message: "Approov token fetch for \(host): " + result.status.rawValue, status: result.status))
        }
    }

    func handleInterceptorHeaderSubstitutionResult(_ result: ApproovTokenResult,
                                                   header: String) throws -> Bool {
        return standardSubstitution(result)
    }

    func handleInterceptorQueryParamSubstitutionResult(_ result: ApproovTokenResult,
                                                       queryKey: String) throws -> Bool {
        return standardSubstitution(result)
    }

    func handleInterceptorProcessedRequest(_ request: URLRequest,
                                           changes: ApproovRequestMutations) throws -> URLRequest {
        return request
    }

    func handlePinningShouldProcessRequest(_ request: URLRequest) -> Bool {
        return true
    }
}

// the substitution decision of both standard mutators, which substitutes on SUCCESS and never aborts a
// request because of a secure string, so any other status is sent in place of the placeholder
private func standardSubstitution(_ result: ApproovTokenResult) -> Bool {
    return result.status == .success
}

// ApproovCloseFailureMutator makes the 3.5.x token decisions, which are also the default implementations:
// a request proceeds on SUCCESS and NO_APPROOV_SERVICE and fails with an ApproovServiceError otherwise
public final class ApproovCloseFailureMutator: ApproovServiceMutator, CustomStringConvertible {
    static let instance = ApproovCloseFailureMutator()

    private init() {}

    public var description: String {
        return "ApproovServiceMutator.CLOSE_FAILURE"
    }
}

// ApproovAlwaysProceedMutator makes decisions that never abort a request, leaving your backend to decide
public final class ApproovAlwaysProceedMutator: ApproovServiceMutator, CustomStringConvertible {
    static let instance = ApproovAlwaysProceedMutator()

    private init() {}

    public var description: String {
        return "ApproovServiceMutator.ALWAYS_PROCEED"
    }

    public func handleInterceptorFetchTokenResult(_ result: ApproovTokenResult,
                                                  url: String) throws -> Bool {
        switch result.status {
        case .unknownURL, .unprotectedURL:
            // no Approov headers for a host not added to Approov or a secrets-only API
            return false
        default:
            // SUCCESS adds the token, and any other status proceeds with the status header only
            return true
        }
    }

    public func handleInterceptorHeaderSubstitutionResult(_ result: ApproovTokenResult,
                                                          header: String) throws -> Bool {
        return standardSubstitution(result)
    }

    public func handleInterceptorQueryParamSubstitutionResult(_ result: ApproovTokenResult,
                                                              queryKey: String) throws -> Bool {
        return standardSubstitution(result)
    }
}

// the standard mutators are static members constrained to their concrete type, since Swift cannot hold a
// static on the protocol type, so they can be written as .CLOSE_FAILURE wherever a mutator is expected
public extension ApproovServiceMutator where Self == ApproovCloseFailureMutator {
    // the 3.5.x decisions, named for decisions that stay fixed
    static var CLOSE_FAILURE: ApproovCloseFailureMutator {
        return ApproovCloseFailureMutator.instance
    }
}

public extension ApproovServiceMutator where Self == ApproovAlwaysProceedMutator {
    // the decisions that never abort a request
    static var ALWAYS_PROCEED: ApproovAlwaysProceedMutator {
        return ApproovAlwaysProceedMutator.instance
    }

    // the default decisions of the release, which never abort a request, declared as the protocol so stored
    // values keep compiling when it points elsewhere; the Self constraint only lets it be written as .DEFAULT
    static var DEFAULT: ApproovServiceMutator {
        return ApproovAlwaysProceedMutator.instance
    }
}
