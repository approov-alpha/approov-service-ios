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

// ApproovURLProtocol claims each intercepted request, adds the Approov protection asynchronously, forwards
// it through the pinned forwarding session and relays the callbacks to the URL loading system. Instance
// state is guarded by stateLock, since the callbacks arrive on arbitrary threads, hence @unchecked.
public final class ApproovURLProtocol: URLProtocol, @unchecked Sendable {

    // the property set on every forwarded request so that canInit declines it when it passes through again
    static let handledKey = "io.approov.service.handled"

    // the property set on a redirect followed to a URL the server sent, whose query is the server's and so
    // holds no placeholder of the app's
    static let serverQueryKey = "io.approov.service.server-query"

    // the lock guarding the instance state below
    private let stateLock = NSLock()

    // the forwarded task, and whether the request was stopped or redirected
    private var forwardedTask: URLSessionTask?
    private var stopped = false
    private var redirected = false

    // false once the request was protected by Approov, so its response is never stored in the app's URLCache
    private var cacheable = true

    // the inner task deliveries held after a redirect is reported, which are discarded if the app follows
    // the redirect and delivered as the final response if it declines, or nil if not holding
    private var held: [Delivery]?

    // the URL the request was forwarded with, which includes any secure string substituted into its query
    private var forwardedURL: URL?

    // the request processing job, so stopLoading can withdraw it while it waits for its turn
    private var queuedJob: BoundedExecutor.Job?

    // one relayed inner task callback, as held while a redirect decision is pending
    private enum Delivery {
        case response(URLResponse)
        case data(Data)
        case completion(Error?)
    }

    // how long to wait for stopLoading after reporting a redirect before treating it as declined, which is
    // only set by tests
    static var redirectDecisionGrace: TimeInterval {
        get { graceLock.lock(); defer { graceLock.unlock() }; return graceValue }
        set { graceLock.lock(); graceValue = newValue; graceLock.unlock() }
    }
    private static let graceLock = NSLock()
    nonisolated(unsafe) private static var graceValue: TimeInterval = 1.0

    // the queue for the redirect grace timers only, so a declined redirect is delivered on time however
    // many requests are blocked in SDK fetches
    private static let redirectGraceQueue = DispatchQueue(label: "io.approov.service.redirect-grace",
                                                          qos: .userInitiated)

    /**
     * Inserts this protocol first in the protocol classes of a configuration, if not already present.
     *
     * @param configuration is the session configuration to be updated
     */
    static func install(into configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 == ApproovURLProtocol.self }) else { return }
        classes.insert(ApproovURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    /**
     * Removes this protocol from the protocol classes of a configuration.
     *
     * @param configuration is the session configuration to be updated
     */
    static func remove(from configuration: URLSessionConfiguration) {
        guard let classes = configuration.protocolClasses else { return }
        configuration.protocolClasses = classes.filter { $0 != ApproovURLProtocol.self }
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        guard ApproovInterceptor.shared.isApproovServiceEnabled else { return false }
        guard let scheme = request.url?.scheme?.lowercased(),
              (scheme == "http") || (scheme == "https") else { return false }
        // never claim the Approov SDK's own attestation traffic
        if let host = request.url?.host, ApproovInterceptor.isSDKInfrastructureHost(host) {
            return false
        }
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    // the largest body that is buffered into memory for a message signing body digest; a larger body
    // stream is forwarded untouched without a digest
    static let maxBufferedBodySize = 10 * 1024 * 1024

    /**
     * Reads the one-shot body stream the URL loading system provides back into the request body, so
     * it is available for message signing digests. The body is only read if its Content-Length is
     * declared and no larger than maxBufferedBodySize.
     *
     * @param request is the request whose body is to be read
     * @return the request with its body read into httpBody, or the original request if it is not read
     */
    static func materializeBody(of request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        // only buffer a body whose declared length is within the limit, so a chunked or very large
        // upload is never read into memory
        guard let lengthHeader = request.value(forHTTPHeaderField: "Content-Length"),
              let length = Int(lengthHeader), length >= 0, length <= maxBufferedBodySize else {
            return request
        }
        var data = Data()
        data.reserveCapacity(length)
        stream.open()
        defer { stream.close() }
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let read = stream.read(&buffer, maxLength: bufferSize)
            // a stream error forwards the request as it is, so the send fails
            if read < 0 { return request }
            if read == 0 { break }
            data.append(buffer, count: read)
            // an under-declared Content-Length must not become an unbounded read, so give up and forward
            // the original request, whose send then fails
            if data.count > maxBufferedBodySize { return request }
        }
        var materialized = request
        materialized.httpBodyStream = nil
        materialized.httpBody = data
        return materialized
    }

    // processing runs on the bounded request executor, where stopLoading can withdraw a waiting request
    override public func startLoading() {
        let capturedRequest = request
        let job = ApproovInterceptor.requestExecutor.submit { [weak self] in
            guard let self = self else { return }
            // nothing is fetched or sent if stopped while waiting for its turn
            self.stateLock.lock()
            let stoppedBeforeStart = self.stopped
            self.stateLock.unlock()
            guard !stoppedBeforeStart else { return }
            let originalRequest = Self.materializeBody(of: capturedRequest)

            // one mutator decides everything about this request, its pinning included
            let mutator = ApproovInterceptor.shared.getServiceMutator()
            let outcome = ApproovInterceptor.shared.updater?.update(originalRequest, mutator: mutator)
                ?? .proceed(originalRequest)

            switch outcome {
            case .fail(let error):
                self.stateLock.lock()
                let stopped = self.stopped
                self.stateLock.unlock()
                if !stopped {
                    let nsError = (error as? ApproovServiceError)?.asNSError() ?? (error as NSError)
                    self.client?.urlProtocol(self, didFailWithError: nsError)
                }

            case .proceed(let decorated, let protected):
                // the pinning decision is made once for the whole request, and an unpinned request
                // travels on connections of its own that a pinned request never reuses
                let pinned = (ApproovInterceptor.shared.pinningVerifier == nil)
                    || mutator.handlePinningShouldProcessRequest(decorated)
                // a cleartext request to a host with Approov pins has no handshake to pin, so it fails
                // before anything is sent, even for an excluded or unprotected URL
                if let url = decorated.url, url.scheme?.lowercased() == "http", let host = url.host,
                   let verifier = ApproovInterceptor.shared.pinningVerifier, pinned,
                   !verifier.allowsCleartext(toHost: host) {
                    self.stateLock.lock()
                    let stopped = self.stopped
                    self.stateLock.unlock()
                    if !stopped {
                        self.client?.urlProtocol(self, didFailWithError:
                            ForwardingSession.cleartextPinningError(failingURL: capturedRequest.url))
                    }
                    return
                }
                guard let mutable = (decorated as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
                    // never expected, so fail with a URL loading error
                    self.client?.urlProtocol(self, didFailWithError: URLError(.unknown, userInfo: [
                        NSLocalizedDescriptionKey: "ApproovService: unable to copy the request"]))
                    return
                }
                URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

                let task = ForwardingSession.shared.dataTask(for: mutable as URLRequest, handler: self,
                                                             pinned: pinned)
                self.stateLock.lock()
                if self.stopped {
                    self.stateLock.unlock()
                    ForwardingSession.shared.unregister(task)
                    return
                }
                self.forwardedTask = task
                self.forwardedURL = decorated.url
                self.cacheable = !protected
                self.stateLock.unlock()
                task.resume()
            }
        }
        stateLock.lock()
        if !stopped {
            queuedJob = job
        }
        stateLock.unlock()
    }

    override public func stopLoading() {
        stateLock.lock()
        stopped = true
        // a followed redirect, so the held 3xx is never delivered
        held = nil
        let task = forwardedTask
        forwardedTask = nil
        let job = queuedJob
        queuedJob = nil
        stateLock.unlock()

        // withdraw a request still waiting for its turn, since once started it checks stopped itself
        if let job {
            ApproovInterceptor.requestExecutor.cancel(job)
        }
        task?.cancel()
    }

    // the relays from the forwarding session are held while a reported redirect awaits the app's decision,
    // and delivered at once otherwise
    func forwarded(response: URLResponse) {
        holdOrDeliver(.response(appFacing(response)))
    }

    /**
     * Gets the response as the app should see it. If substitution changed the URL then the forwarded
     * response names the substituted secure string, so it is restated for the app's own URL.
     *
     * @param response is the response received by the forwarding task
     * @return the response for the app's URL
     */
    private func appFacing(_ response: URLResponse) -> URLResponse {
        stateLock.lock()
        let forwardedURL = self.forwardedURL
        stateLock.unlock()
        guard let appURL = request.url, let forwardedURL = forwardedURL, forwardedURL != appURL else {
            return response
        }
        return Self.naming(appURL, in: response)
    }

    /**
     * Restates an HTTP response for another URL, keeping its status and header fields.
     *
     * @param appURL is the URL the response should name
     * @param response is the response to be restated
     * @return the restated response, or the original if it is not HTTP or already names the URL
     */
    static func naming(_ appURL: URL, in response: URLResponse) -> URLResponse {
        guard let http = response as? HTTPURLResponse, http.url != appURL else {
            return response
        }
        var fields: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                fields[name] = value
            }
        }
        return HTTPURLResponse(url: appURL, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
                               headerFields: fields) ?? response
    }

    func forwarded(data: Data) {
        holdOrDeliver(.data(data))
    }

    func forwardedDidComplete(error: Error?) {
        stateLock.lock()
        forwardedTask = nil
        stateLock.unlock()
        holdOrDeliver(.completion(error))
    }

    private func holdOrDeliver(_ delivery: Delivery) {
        stateLock.lock()
        if !stopped, held != nil {
            held?.append(delivery)
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        deliver(delivery)
    }

    // the response and data deliveries hold stateLock across the client call, so a concurrent stopLoading
    // cannot come between the check and the call; the completion does not, since the loading system may call
    // stopLoading synchronously from it
    private func deliver(_ delivery: Delivery) {
        switch delivery {
        case .response(let response):
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: response,
                                cacheStoragePolicy: cacheable ? .allowed : .notAllowed)
        case .data(let data):
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didLoad: data)
        case .completion(let error):
            stateLock.lock()
            let stopped = self.stopped
            stateLock.unlock()
            guard !stopped else { return }
            if let error = error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    // the app declined the redirect if there was no stopLoading within the grace period, so the held 3xx is
    // the final response; deliveries are replayed in order while holding, so later relays queue behind them
    private func releaseHeld() {
        while true {
            stateLock.lock()
            guard !stopped, let queue = held else {
                stateLock.unlock()
                return
            }
            guard let next = queue.first else {
                held = nil
                stateLock.unlock()
                return
            }
            held = Array(queue.dropFirst())
            stateLock.unlock()
            deliver(next)
        }
    }

    /**
     * Builds the request a redirect is followed with from the app's own request, never from the
     * forwarded one, so nothing added for one destination can reach another and the new request is
     * protected afresh from the app's placeholders. Only the redirect itself is taken from the
     * followup: the new URL, the method and body, and which of the app's headers were dropped. A
     * redirect to the forwarded URL itself goes back to the app's URL, so a substituted query
     * parameter returns to its placeholder. Any other target URL is the server's, so the request is
     * marked to have no query parameter looked up as a secure string key. On an origin change the
     * app's Authorization header is removed as well.
     *
     * @param original is the app's own request
     * @param followup is the request the network stack would follow the redirect with
     * @param forwardedURL is the URL the original request was forwarded with
     * @return the request to follow the redirect with
     */
    static func rebuiltRedirect(from original: URLRequest, following followup: URLRequest,
                                forwardedURL: URL?) -> URLRequest {
        var rebuilt = original
        var serverQuery = false
        if let target = followup.url, target != forwardedURL {
            rebuilt.url = target
            serverQuery = true
        }
        rebuilt.httpMethod = followup.httpMethod
        rebuilt.httpBody = nil
        rebuilt.httpBodyStream = nil
        if let body = followup.httpBody {
            rebuilt.httpBody = body
        } else if let stream = followup.httpBodyStream {
            rebuilt.httpBodyStream = stream
        }
        // remove header by header, since assigning allHTTPHeaderFields merges with the existing fields
        let kept = Set((followup.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        var removed = Set<String>()
        if !hasSameOrigin(original.url, rebuilt.url) {
            removed = ["authorization"]
        }
        for name in (original.allHTTPHeaderFields ?? [:]).keys
            where !kept.contains(name.lowercased()) || removed.contains(name.lowercased()) {
            rebuilt.setValue(nil, forHTTPHeaderField: name)
        }
        if let mutable = (rebuilt as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
            URLProtocol.removeProperty(forKey: handledKey, in: mutable)
            // a redirect back to the forwarded URL keeps whatever the original request had
            if serverQuery {
                URLProtocol.setProperty(true, forKey: serverQueryKey, in: mutable)
            }
            rebuilt = mutable as URLRequest
        }
        return rebuilt
    }

    // the port of a URL, or the default port for its scheme
    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    // true if both URLs have the same scheme, host and port
    private static func hasSameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second else { return false }
        return (first.scheme?.lowercased() == second.scheme?.lowercased())
            && (first.host?.lowercased() == second.host?.lowercased())
            && (effectivePort(for: first) == effectivePort(for: second))
    }

    /**
     * Reports a redirect to the URL loading system, holding the 3xx the inner task goes on to
     * deliver. If the app follows the redirect then stopLoading discards the held 3xx and the new
     * request is intercepted afresh. If the app declines it, the held 3xx is delivered as the final
     * response after redirectDecisionGrace.
     *
     * @param request is the request the forwarding session would follow the redirect with
     * @param response is the redirect response
     */
    func forwardedRedirect(to request: URLRequest, response: HTTPURLResponse) {
        stateLock.lock()
        let alreadyDone = stopped || redirected
        redirected = true
        if !alreadyDone {
            held = []
        }
        let forwardedURL = self.forwardedURL
        stateLock.unlock()
        guard !alreadyDone else { return }

        let redirect = Self.rebuiltRedirect(from: self.request, following: request, forwardedURL: forwardedURL)
        client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: appFacing(response))
        Self.redirectGraceQueue.asyncAfter(deadline: .now() + Self.redirectDecisionGrace) { [weak self] in
            self?.releaseHeld()
        }
    }
}
