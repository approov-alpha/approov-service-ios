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

// ApproovRequestPathError creates the errors the layer raises on the request path for its own reasons:
// a failed service mutator hook, an app configuration error, or an SDK value a header cannot carry. Each
// is a URLError with code unknown, so it reaches the app as an ordinary URL loading failure.
enum ApproovRequestPathError {

    /**
     * Creates the error for a configuration error of the app's, which is logged. The message must
     * never quote a value that could be a token or a secure string.
     *
     * @param message is the description of the error
     * @return URLError for the error
     */
    static func configuration(_ message: String) -> URLError {
        ApproovLog.log(.error, message)
        return URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "ApproovService: " + message])
    }

    /**
     * Creates the error for a value the Approov SDK issued, such as a token, that a header cannot
     * carry, which is logged. The header is named but never the value.
     *
     * @param what is the description of the value, such as "token"
     * @param header is the header that cannot carry it
     * @return URLError for the error
     */
    static func sdkValue(_ what: String, header: String) -> URLError {
        let message = "Approov header \(header): invalid character in SDK \(what)"
        ApproovLog.log(.error, message)
        return URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "ApproovService: " + message])
    }

    /**
     * Creates the error for an error thrown by a service mutator hook that is neither a URL loading
     * error nor a standard decision, which is logged naming the hook.
     *
     * @param hook is the name of the hook
     * @param error is the error the hook threw, which becomes the underlying error
     * @return URLError for the error
     */
    static func hookFailure(_ hook: String, _ error: Error) -> URLError {
        let message = "ApproovServiceMutator.\(hook) failed: \(error)"
        // the hook is named publicly, but the app's error description may quote anything
        ApproovLog.log(.error, "ApproovServiceMutator.\(hook) failed", detail: "\(error)")
        let underlying = (error as? ApproovServiceError)?.asNSError() ?? error as NSError
        return URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "ApproovService: " + message,
                                             NSUnderlyingErrorKey: underlying])
    }

    /**
     * Calls a service mutator hook on the request path. A URL loading error is the app's own abort
     * and is thrown unchanged, as is a standard decision made during the call. Any other error,
     * including an ApproovServiceError the app's own code threw, is thrown as a hookFailure.
     *
     * @param hook is the name of the hook
     * @param call is the call to the hook
     * @return the result of the hook
     * @throws Error if the hook threw
     */
    static func callHook<T>(_ hook: String, _ call: () throws -> T) throws -> T {
        return try callHook(hook, call, standardDecision: { throw $0 })
    }

    /**
     * Calls a service mutator hook as callHook does, except that a standard decision thrown during
     * the call is ignored, for a hook whose standard decisions do not apply.
     *
     * @param hook is the name of the hook
     * @param call is the call to the hook
     * @return the result of the hook, or nil if it threw a standard decision
     * @throws Error if the hook threw anything else
     */
    static func callHookIgnoringStandardDecisions<T>(_ hook: String, _ call: () throws -> T) throws -> T? {
        return try callHook(hook, { try call() as T? }, standardDecision: { _ in nil })
    }

    // calls a hook, passing a standard decision it throws to standardDecision
    private static func callHook<T>(_ hook: String, _ call: () throws -> T,
                                    standardDecision: (ApproovServiceError) throws -> T) throws -> T {
        let decisions = ApproovStandardDecisions()
        do {
            return try ApproovStandardDecisions.$current.withValue(decisions) { try call() }
        } catch let approovError as ApproovServiceError {
            if decisions.contains(approovError) {
                return try standardDecision(approovError)
            }
            throw hookFailure(hook, approovError)
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                throw error
            }
            throw hookFailure(hook, error)
        }
    }
}

// ApproovStandardDecisions records the errors the standard decisions throw during one hook call, so
// callHook can tell them from an error the app's own hook code throws; it is bound per call as a
// task-local value, which synchronous code on the calling thread reads too
final class ApproovStandardDecisions: @unchecked Sendable {

    // the decisions of the current hook call
    @TaskLocal static var current: ApproovStandardDecisions?

    // the decisions made, guarded by lock
    private let lock = NSLock()
    private var made: [String] = []

    /**
     * Records an error as a standard decision made in the current hook call. Outside a hook call it
     * is only returned.
     *
     * @param error is the standard decision
     * @return the error to be thrown
     */
    static func made(_ error: ApproovServiceError) -> ApproovServiceError {
        current?.record(error)
        return error
    }

    // records a standard decision
    private func record(_ error: ApproovServiceError) {
        lock.lock()
        defer { lock.unlock() }
        made.append(String(reflecting: error))
    }

    /**
     * Determines whether an error is one of the standard decisions made in this call, with the same
     * case and values.
     *
     * @param error is the error to be checked
     * @return true if the error is a standard decision, false otherwise
     */
    func contains(_ error: ApproovServiceError) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return made.contains(String(reflecting: error))
    }
}
