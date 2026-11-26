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

import CryptoKit
import Foundation
import os.log

// counters showing that interception and pinning are exercised, not just installed
public struct ApproovInterceptionDiagnostics: Sendable {
    // the number of requests forwarded through interception
    public let requestsForwarded: Int

    // the number of TLS challenges that passed the Approov pin check
    public let pinnedChallengesAllowed: Int

    // the number of TLS challenges refused by the Approov pin check
    public let pinnedChallengesBlocked: Int

    // the number of challenges answered by the app's challenge handler or default handling
    public let delegatedChallenges: Int
}

// ForwardingSession is the URLSession that all intercepted traffic is forwarded through, which relays the
// callbacks to the originating ApproovURLProtocol and applies Approov pinning to the TLS handshakes. Pins
// are only checked when a connection is opened, so a pin change builds a new session and retires the old
// one, whose in-flight requests still complete. Its configuration keeps only the Apple URLProtocol classes,
// so no other protocol can claim a forwarded request and bypass the pinning. The state is guarded by lock,
// hence @unchecked since an NSObject subclass cannot be checked Sendable.
final class ForwardingSession: NSObject, @unchecked Sendable {

    static let shared = ForwardingSession()

    // the lock guarding all of the mutable state
    private let lock = NSLock()

    // the protocol instance for each task, keyed by the task object since identifiers are only unique
    // within one session and tasks of a retired session may still be running
    private var handlers: [ObjectIdentifier: ApproovURLProtocol] = [:]

    // the tasks refused by Approov pinning with the cause, so their cancellation is remapped on completion
    private var refusedTasks: [ObjectIdentifier: RefusalReason] = [:]

    // why a connection to a host with Approov pins was refused, which decides the error text
    enum RefusalReason {
        // the certificate chain failed platform trust evaluation
        case untrusted

        // the chain is trusted but matches none of the host's Approov pins
        case mismatch

        // the Approov pins could not be read
        case pinsUnreadable

        var errorDescription: String {
            switch self {
            case .untrusted:
                return "The certificate for this server is invalid."
            case .mismatch:
                return "The certificate for this server does not match the public keys Approov holds for this domain."
            case .pinsUnreadable:
                return "The certificate for this server could not be checked: the Approov pins could not be read."
            }
        }
    }

    // the counters reported by ApproovInterceptionDiagnostics
    private var requestsForwarded = 0
    private var pinnedChallengesAllowed = 0
    private var pinnedChallengesBlocked = 0
    private var delegatedChallenges = 0

    var diagnostics: ApproovInterceptionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return ApproovInterceptionDiagnostics(requestsForwarded: requestsForwarded,
                                              pinnedChallengesAllowed: pinnedChallengesAllowed,
                                              pinnedChallengesBlocked: pinnedChallengesBlocked,
                                              delegatedChallenges: delegatedChallenges)
    }

    // the live session and the fingerprint of the pin set it was built for, rebuilt when the pins change
    private var session: URLSession?
    private var sessionPinFingerprint: String?
    private var generationCount = 0

    // the session for requests opted out of Approov pinning, whose connections pinned requests never share
    private var optedOutSession: URLSession?

    // the tasks running on optedOutSession
    private var optedOutTasks: Set<ObjectIdentifier> = []

    // the number of forwarding sessions built so far, for tests and diagnostics
    var sessionGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationCount
    }

    /**
     * Gets the session for a request about to be forwarded, building a new one if the pins have
     * changed. This is called after the token fetch, so pins delivered with that fetch are used. In
     * bypass mode the pins are treated as empty.
     *
     * @return URLSession for the current pins
     */
    func currentSession() -> URLSession {
        let pins = ApproovInterceptor.shared.pinningVerifier == nil ? nil
            : ApproovInterceptor.shared.backend?.pins(pinType: ApproovPinningVerifier.pinType)
        let fingerprint = Self.fingerprint(of: pins ?? [:])
        lock.lock()
        if let session = session, sessionPinFingerprint == fingerprint {
            lock.unlock()
            return session
        }
        let retired = session
        let fresh = makeSession()
        session = fresh
        sessionPinFingerprint = fingerprint
        generationCount += 1
        lock.unlock()
        // in-flight requests finish on the retired session, which then releases this delegate
        retired?.finishTasksAndInvalidate()
        return fresh
    }

    // builds a forwarding session with no cache, since a cached response would be replayed without a pin check
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = Self.sanitizedProtocolClasses(configuration.protocolClasses)
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // gets the session for requests opted out of Approov pinning, building it on first use
    private func currentOptedOutSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = optedOutSession {
            return existing
        }
        let fresh = makeSession()
        optedOutSession = fresh
        return fresh
    }

    /**
     * Gets an order-independent digest of a pin map.
     *
     * @param pins is the map of hosts to their pins
     * @return base64 encoded SHA256 digest of the sorted pins
     */
    static func fingerprint(of pins: [String: [String]]) -> String {
        let canonical = pins.keys.sorted().map { host in
            "\(host)=\((pins[host] ?? []).sorted().joined(separator: ","))"
        }.joined(separator: "|")
        return Data(SHA256.hash(data: Data(canonical.utf8))).base64EncodedString()
    }

    // the protocol classes of the live session, for tests that no custom protocol can claim forwarded traffic
    var sessionProtocolClasses: [AnyClass]? {
        return currentSession().configuration.protocolClasses
    }

    /**
     * Keeps only the Apple system protocol classes, from a com.apple bundle, so ApproovURLProtocol is
     * dropped and any third party protocol that could bypass Approov pinning is dropped and logged.
     *
     * @param classes is the list of protocol classes
     * @return the Apple protocol classes, or nil if there were none
     */
    static func sanitizedProtocolClasses(_ classes: [AnyClass]?) -> [AnyClass]? {
        guard let classes = classes else { return nil }
        return classes.filter { cls in
            if Bundle(for: cls).bundleIdentifier?.hasPrefix("com.apple.") == true {
                return true
            }
            if cls != ApproovURLProtocol.self,
               ApproovInterceptor.shared.loggingLevel >= .error {
                os_log("ApproovService: forwarding session: removed URLProtocol %{public}@ from %{public}@",
                       type: .error, NSStringFromClass(cls), ConfigurationSwizzler.classOrigin(cls))
            }
            return false
        }
    }

    /**
     * Creates a forwarding task for the request and registers its handler.
     *
     * @param request is the request to be forwarded
     * @param handler is the protocol instance that receives the task callbacks
     * @param pinned is true if Approov pinning applies, false if the request is opted out of it
     * @return URLSessionDataTask on the session for the request
     */
    func dataTask(for request: URLRequest, handler: ApproovURLProtocol,
                  pinned: Bool = true) -> URLSessionDataTask {
        let task = (pinned ? currentSession() : currentOptedOutSession()).dataTask(with: request)
        lock.lock()
        handlers[ObjectIdentifier(task)] = handler
        if !pinned {
            optedOutTasks.insert(ObjectIdentifier(task))
        }
        requestsForwarded += 1
        lock.unlock()
        return task
    }

    func unregister(_ task: URLSessionTask) {
        lock.lock()
        handlers[ObjectIdentifier(task)] = nil
        refusedTasks[ObjectIdentifier(task)] = nil
        optedOutTasks.remove(ObjectIdentifier(task))
        lock.unlock()
    }

    private func isOptedOut(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return optedOutTasks.contains(ObjectIdentifier(task))
    }

    private func markRefused(_ task: URLSessionTask, _ reason: RefusalReason) {
        lock.lock()
        refusedTasks[ObjectIdentifier(task)] = reason
        lock.unlock()
    }

    // removes and returns why Approov pinning refused the task, or nil if it was not refused
    private func takeRefused(_ task: URLSessionTask) -> RefusalReason? {
        lock.lock()
        defer { lock.unlock() }
        return refusedTasks.removeValue(forKey: ObjectIdentifier(task))
    }

    /**
     * Restates an error from the forwarding task so that it names the app's own request URL as the
     * failing URL at every level of its underlying errors, since the forwarded URL can carry a
     * substituted secure string. References to the forwarding task are dropped.
     *
     * @param error is the error from the forwarding task
     * @param appURL is the app's own request URL
     * @return the restated error
     */
    static func replacingFailingURL(in error: Error, with appURL: URL?) -> Error {
        let original = error as NSError
        var info: [String: Any] = [:]
        for (key, value) in original.userInfo {
            switch key {
            case NSURLErrorFailingURLErrorKey, NSURLErrorFailingURLStringErrorKey,
                 "_NSURLErrorFailingURLSessionTaskErrorKey", "_NSURLErrorRelatedURLSessionTaskErrorKey":
                continue
            case NSUnderlyingErrorKey:
                if let nested = value as? NSError {
                    info[key] = replacingFailingURL(in: nested, with: appURL)
                } else {
                    info[key] = value
                }
            case NSMultipleUnderlyingErrorsKey:
                if let nested = value as? [NSError] {
                    info[key] = nested.map { replacingFailingURL(in: $0, with: appURL) }
                } else {
                    info[key] = value
                }
            default:
                info[key] = value
            }
        }
        let hadFailingURL = (original.userInfo[NSURLErrorFailingURLErrorKey] != nil)
            || (original.userInfo[NSURLErrorFailingURLStringErrorKey] != nil)
        if let appURL = appURL, hadFailingURL || (original.domain == NSURLErrorDomain) {
            info[NSURLErrorFailingURLErrorKey] = appURL
            info[NSURLErrorFailingURLStringErrorKey] = appURL.absoluteString
        }
        return NSError(domain: original.domain, code: original.code, userInfo: info)
    }

    /**
     * Remaps the cancellation that follows a pinning refusal to NSURLErrorServerCertificateUntrusted,
     * so the app does not read it as its own cancellation. The cancellation is kept as the underlying
     * error and any other error passes through unchanged.
     *
     * @param error is the error the forwarding task completed with
     * @param failingURL is the app's own request URL
     * @param reason is why the connection was refused
     * @return the error to relay to the app
     */
    static func pinningError(replacing error: Error?, failingURL: URL?,
                             reason: RefusalReason = .mismatch) -> Error? {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain,
              error.code == NSURLErrorCancelled else {
            return error
        }
        var urlInfo: [String: Any] = [:]
        if let url = failingURL {
            urlInfo[NSURLErrorFailingURLErrorKey] = url
            urlInfo[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: urlInfo)
        var info = urlInfo
        info[NSLocalizedDescriptionKey] = reason.errorDescription
        info[NSUnderlyingErrorKey] = underlying
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: info)
    }

    /**
     * Creates the error for a cleartext request to a host with Approov pins, which is the platform's
     * untrusted certificate error, as for a refused handshake.
     *
     * @param failingURL is the app's own request URL
     * @return NSError for the refused request
     */
    static func cleartextPinningError(failingURL: URL?) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey:
            "A cleartext connection to a host with Approov pins is not allowed; use https."]
        if let url = failingURL {
            info[NSURLErrorFailingURLErrorKey] = url
            info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: info)
    }

    private func handler(for task: URLSessionTask) -> ApproovURLProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[ObjectIdentifier(task)]
    }
}

extension ForwardingSession: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        handler(for: dataTask)?.forwarded(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.forwarded(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = handler(for: task)
        let appURL = handler?.request.url
        var relayed = error
        if let reason = takeRefused(task) {
            relayed = Self.pinningError(replacing: error, failingURL: appURL, reason: reason)
        } else if let error = error {
            relayed = Self.replacingFailingURL(in: error, with: appURL)
        }
        handler?.forwardedDidComplete(error: relayed)
        unregister(task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // hand the redirect back to the URL loading system, so the redirected request is intercepted again
        handler(for: task)?.forwardedRedirect(to: request, response: response)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let verifier = ApproovInterceptor.shared.pinningVerifier else {
            // the app's own session delegate cannot be reached from here, so other challenges and all
            // challenges in bypass mode go to the app's challenge handler, or default handling
            Self.respondViaChallengeHandler(challenge, completionHandler)
            return
        }
        // the challenges for a request opted out of Approov pinning are the app's to answer
        if isOptedOut(task) {
            Self.respondViaChallengeHandler(challenge, completionHandler)
            return
        }
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            markRefused(task, .untrusted)
            Self.relayPinningOutcome(.cancelAuthenticationChallenge, nil,
                                     challenge: challenge, completionHandler: completionHandler)
            return
        }
        switch verifier.evaluate(serverTrust: serverTrust, host: challenge.protectionSpace.host) {
        case .unpinned:
            // a host without Approov pins is the app's to decide, as in bypass mode
            Self.respondViaChallengeHandler(challenge, completionHandler)
        case .passed(let trust):
            Self.relayPinningOutcome(.useCredential, URLCredential(trust: trust),
                                     challenge: challenge, completionHandler: completionHandler)
        case .untrusted:
            markRefused(task, .untrusted)
            Self.relayPinningOutcome(.cancelAuthenticationChallenge, nil,
                                     challenge: challenge, completionHandler: completionHandler)
        case .mismatch:
            markRefused(task, .mismatch)
            Self.relayPinningOutcome(.cancelAuthenticationChallenge, nil,
                                     challenge: challenge, completionHandler: completionHandler)
        case .pinsUnreadable:
            markRefused(task, .pinsUnreadable)
            Self.relayPinningOutcome(.cancelAuthenticationChallenge, nil,
                                     challenge: challenge, completionHandler: completionHandler)
        }
    }

    // answers a challenge with the app's challenge handler if one is set, or default handling otherwise
    static func respondViaChallengeHandler(
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        shared.count(\.delegatedChallenges)
        if let handler = ApproovInterceptor.shared.challengeHandler {
            handler(challenge, completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // relays the pinning outcome; a passed check is offered to the app's challenge handler so it can narrow
    // trust further, but a failed check is final so the handler can never widen trust
    static func relayPinningOutcome(
        _ disposition: URLSession.AuthChallengeDisposition,
        _ credential: URLCredential?,
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // only a refusal counts as blocked, and default handling counts as delegated
        switch disposition {
        case .useCredential: shared.count(\.pinnedChallengesAllowed)
        case .cancelAuthenticationChallenge: shared.count(\.pinnedChallengesBlocked)
        default: shared.count(\.delegatedChallenges)
        }
        if disposition == .useCredential, let handler = ApproovInterceptor.shared.challengeHandler {
            handler(challenge, completionHandler)
        } else {
            completionHandler(disposition, credential)
        }
    }

    // increments one of the diagnostics counters
    private func count(_ counter: ReferenceWritableKeyPath<ForwardingSession, Int>) {
        lock.lock()
        self[keyPath: counter] += 1
        lock.unlock()
    }
}
