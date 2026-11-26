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
import os.log

// ApproovRequestUpdater adds the Approov protection to an intercepted request: the token fetch, the
// Approov headers, secure string substitution, the processed request hook and message signing, with every
// decision made by the service mutator. Every request asks the SDK afresh, since the SDK owns retry and
// back-off. Only bindingLock is mutable state, hence @unchecked.
final class ApproovRequestUpdater: @unchecked Sendable {

    // the outcome for a request
    enum Outcome {
        // forward the request, which is protected if Approov changed it, so its response is never cached
        case proceed(URLRequest, protected: Bool = false)

        // fail the request with the error
        case fail(Error)
    }

    // the backend and the interceptor holding the configuration
    private let backend: ApproovBackend
    private unowned let coordinator: ApproovInterceptor

    // held while a request carrying the binding header sets the data hash and fetches its token, since the
    // data hash is global SDK state and two requests binding different values could otherwise each get a
    // token bound to the other's value; requests without the header never take it
    private let bindingLock = NSLock()

    init(backend: ApproovBackend, coordinator: ApproovInterceptor) {
        self.backend = backend
        self.coordinator = coordinator
    }

    /**
     * Fetches the token for a request, bound to the value of the binding header if one is set and
     * the request carries it, in which case the data hash is set and the token fetched as one step.
     * A request without the header sets no data hash and proceeds, carrying whatever binding the SDK
     * already holds.
     *
     * @param url is the URL for the token fetch
     * @param request is the request being processed
     * @return ApproovTokenResult of the fetch
     */
    private func fetchBoundToken(url: String, request: URLRequest) -> ApproovTokenResult {
        guard let bindingHeader = coordinator.bindingHeader,
              let bindingValue = request.value(forHTTPHeaderField: bindingHeader) else {
            return backend.fetchToken(url: url)
        }
        bindingLock.lock()
        defer { bindingLock.unlock() }
        backend.setDataHashInToken(bindingValue)
        return backend.fetchToken(url: url)
    }

    /**
     * Adds the Approov protection to a request, blocking for the token and secure string fetches.
     * The caller passes the mutator it also uses for the pinning decision, so one request is never
     * decided by two mutators.
     *
     * @param request is the request to be processed
     * @param requestMutator is the service mutator to be used, or nil for the installed one
     * @return Outcome for the request
     */
    func update(_ request: URLRequest, mutator requestMutator: ApproovServiceMutator? = nil) -> Outcome {
        // forward the request untouched in bypass mode
        guard coordinator.isApproovProtectionEnabled else {
            return .proceed(request)
        }
        guard let url = request.url, let host = url.host, !host.isEmpty else {
            return .proceed(request)
        }

        let mutator = requestMutator ?? coordinator.getServiceMutator()
        let changes = ApproovRequestMutations()
        do {
            // check for exclusion, which by default uses the exclusion URL regexes
            guard try ApproovRequestPathError.callHook("handleInterceptorShouldProcessRequest", {
                try mutator.handleInterceptorShouldProcessRequest(request)
            }) else {
                return .proceed(request)
            }

            // a cleartext request to a host that is not an Approov API domain can never be protected: the SDK
            // answers BAD_URL for any URL that is not https without a network fetch, but only once the request
            // reaches the head of its serial fetch queue, so asking it would hold the request behind any
            // attestation in progress, as happens to a development server request at app start
            if url.scheme?.lowercased() == "http", !isApproovAPIDomain(host) {
                ApproovLog.log(.debug, "Request to ", host: host,
                               " is not https and not to an Approov API domain, proceeding untouched without a token fetch")
                // log each placeholder that is left, using a scratch copy so nothing is fetched or changed
                var scratch = request
                let refusal = Refusal(reason: "request is not https", level: .debug)
                try substituteHeaders(in: &scratch, mutator: mutator, changes: ApproovRequestMutations(), refusal: refusal)
                try substituteQueryParams(in: &scratch, mutator: mutator, changes: ApproovRequestMutations(), refusal: refusal)
                return .proceed(request)
            }

            // fetch the token, bound to any binding header value
            let urlString = url.absoluteString
            let result = fetchBoundToken(url: urlString, request: request)

            coordinator.recordLastARC(result)

            // fetching the config clears the update state and refreshes pins for future challenges
            if result.isConfigChanged {
                backend.fetchConfig()
            }

            // what the request carries follows its token fetch status: SUCCESS gets the Approov headers,
            // secure strings and signatures, UNPROTECTED_URL gets secure strings only, UNKNOWN_URL gets
            // nothing, and any other status gets the status header only, and only to an Approov API domain
            let secureStringChannel = (result.status == .success) || (result.status == .unprotectedURL)
            let failure = !secureStringChannel && (result.status != .unknownURL)
            // after a failed fetch the pins map is the only evidence the host is one of the app's APIs, so a
            // failure on a host it does not list goes out untouched, unless a custom mutator's own throw
            // aborts it
            let listed = result.status == .success ? true : isApproovAPIDomain(host)
            if failure && !listed {
                let decision = try ApproovRequestPathError.callHookIgnoringStandardDecisions("handleInterceptorFetchTokenResult") {
                    try mutator.handleInterceptorFetchTokenResult(result, url: urlString)
                }
                if decision == nil {
                    ApproovLog.log(.debug, "handleInterceptorFetchTokenResult: abort ignored for ", host: host,
                                   ", not an Approov API domain")
                }
                ApproovLog.log(.debug, "Approov token fetch for ", host: host,
                               ": \(result.status.rawValue)\(Self.arcDetail(result)), not an Approov API domain, proceeding untouched")
                // log each placeholder that is left, using a scratch copy so nothing is fetched or changed
                var scratch = request
                let refusal = Self.refusal(for: result, url: url)
                try substituteHeaders(in: &scratch, mutator: mutator, changes: ApproovRequestMutations(), refusal: refusal)
                try substituteQueryParams(in: &scratch, mutator: mutator, changes: ApproovRequestMutations(), refusal: refusal)
                return .proceed(request)
            }
            let proceedWithHeaders = try ApproovRequestPathError.callHook("handleInterceptorFetchTokenResult", {
                try mutator.handleInterceptorFetchTokenResult(result, url: urlString)
            })
            // on any status but SUCCESS the only header is the status header, and only to a listed API domain
            let addHeaders = proceedWithHeaders && listed
            if failure {
                // log a token failure the decision lets proceed, without any value
                ApproovLog.log(.debug, "Approov token fetch for ", host: host,
                               ": \(result.status.rawValue)\(Self.arcDetail(result)), "
                               + (addHeaders ? "proceeding with the status header only" : "proceeding with no Approov header"))
            }
            guard addHeaders || secureStringChannel else {
                // forward the request as the app built it, logging each placeholder left after a failure
                if failure {
                    var scratch = request
                    let refusal = Self.refusal(for: result, url: url)
                    try substituteHeaders(in: &scratch, mutator: mutator, changes: ApproovRequestMutations(), refusal: refusal)
                    try substituteQueryParams(in: &scratch, mutator: mutator, changes: ApproovRequestMutations(), refusal: refusal)
                }
                return .proceed(request)
            }
            var updated = request
            if addHeaders {
                try addApproovHeaders(to: &updated, result: result, changes: changes)
            }

            // a secure string is never substituted unless the token fetch status allows it and the request
            // is sent over TLS, whatever the mutator decides, and the placeholder is then left
            let refusal = Self.refusal(for: result, url: url)
            let headersReplaced = try substituteHeaders(in: &updated, mutator: mutator, changes: changes, refusal: refusal)
            let queryReplaced = try substituteQueryParams(in: &updated, mutator: mutator, changes: changes, refusal: refusal)
            guard addHeaders || headersReplaced || queryReplaced else {
                // leave a secrets-only request with no placeholder replaced as the app built it
                return .proceed(request)
            }

            // allow final changes to the processed request by the mutator
            let processed = updated
            updated = try ApproovRequestPathError.callHook("handleInterceptorProcessedRequest") {
                try mutator.handleInterceptorProcessedRequest(processed, changes: changes)
            }
            try Self.checkHeadersSet(from: processed, to: updated)

            // message signing runs last, over the final request, and only for a request carrying the token
            if let signing = coordinator.activeMessageSigning, changes.getTokenHeaderKey() != nil {
                updated = try signing.sign(updated, changes: changes)
            }
            // a request carrying Approov headers or a secure string is not cacheable
            return .proceed(updated, protected: true)
        } catch {
            return .fail(error)
        }
    }

    /**
     * Adds the Approov headers the token fetch status calls for: on SUCCESS the token header and
     * any trace ID header, and on every status the status header, replacing any value the app set.
     *
     * @param request is the request to add the headers to
     * @param result is the result of the token fetch
     * @param changes is the record of the changes made to the request
     * @throws URLError if a header cannot carry its value
     */
    private func addApproovHeaders(to request: inout URLRequest,
                                   result: ApproovTokenResult,
                                   changes: ApproovRequestMutations) throws {
        if result.status == .success {
            let (tokenHeader, tokenPrefix) = coordinator.tokenHeaderAndPrefix
            // a prefix a header cannot carry is the app's configuration error, but such a token is the SDK's
            guard Self.isSafeHeaderValue(tokenPrefix) else { throw Self.unsafeHeaderError(tokenHeader) }
            guard Self.isSafeHeaderValue(result.token) else {
                throw ApproovRequestPathError.sdkValue("token", header: tokenHeader)
            }
            request.setValue(tokenPrefix + result.token, forHTTPHeaderField: tokenHeader)
            changes.setTokenHeaderKey(tokenHeader)
        }
        if let statusHeader = coordinator.statusHeader {
            request.setValue(Self.statusValue(result.status), forHTTPHeaderField: statusHeader)
            changes.setStatusHeaderKey(statusHeader)
        }
        // the trace header is only sent on SUCCESS if the SDK supplies a trace ID, which is empty if none
        if result.status == .success, let traceIDHeader = coordinator.traceIDHeader,
           !traceIDHeader.isEmpty, !result.traceID.isEmpty {
            guard Self.isSafeHeaderValue(result.traceID) else {
                throw ApproovRequestPathError.sdkValue("trace ID", header: traceIDHeader)
            }
            request.setValue(result.traceID, forHTTPHeaderField: traceIDHeader)
            changes.setTraceIDHeaderKey(traceIDHeader)
        }
    }

    // why a request gets no secure string, and the level it is logged at: a warning for a request that is
    // not https or whose token fetch returned BAD_URL, and debug for any other status
    struct Refusal {
        let reason: String
        let level: ApproovLogLevel
    }

    /**
     * Gets the refusal of secure strings for a request.
     *
     * @param result is the result of the token fetch
     * @param url is the URL of the request
     * @return Refusal for the request, or nil if its secure strings may be substituted
     */
    static func refusal(for result: ApproovTokenResult, url: URL) -> Refusal? {
        if result.status == .badURL {
            return Refusal(reason: "token fetch status BAD_URL\(arcDetail(result))", level: .warning)
        }
        if (result.status != .success) && (result.status != .unprotectedURL) {
            return Refusal(reason: "token fetch status \(result.status.rawValue)\(arcDetail(result))", level: .debug)
        }
        if url.scheme?.lowercased() != "https" {
            return Refusal(reason: "request is not https", level: .warning)
        }
        return nil
    }

    // true if the host is an Approov API domain listed in the pins, false if not or they cannot be read
    private func isApproovAPIDomain(_ host: String) -> Bool {
        guard let pins = backend.pins(pinType: ApproovPinningVerifier.pinType) else { return false }
        return ApproovPinningVerifier.isListed(host: host, in: pins)
    }

    /**
     * Gets the ARC and rejection reasons of a result for logging. Neither is a secret.
     *
     * @param result is the result of a fetch
     * @return String of any ARC and rejection reasons, or an empty string if there are none
     */
    static func arcDetail(_ result: ApproovTokenResult) -> String {
        var detail = ""
        if !result.arc.isEmpty { detail += ", ARC \(result.arc)" }
        if !result.rejectionReasons.isEmpty { detail += ", rejection reasons \(result.rejectionReasons)" }
        return detail
    }

    /**
     * Gets a status as the status header writes it, which is also how a secure string fetch status
     * is written in place of a placeholder.
     *
     * @param status is the status to be written
     * @return String of the status name, never converted
     */
    static func statusValue(_ status: ApproovTokenStatus) -> String {
        return status.rawValue
    }

    // what is put in place of a placeholder: the secure string, or the status of a secure string fetch
    // that failed
    enum Replacement {
        case secureString(String)
        case status(String)

        var value: String {
            switch self {
            case .secureString(let value), .status(let value):
                return value
            }
        }
    }

    /**
     * Gets what is put in place of a placeholder after a secure string fetch the service mutator
     * let continue. On SUCCESS it is the secure string, if the mutator chose to substitute it. Any
     * other status, UNKNOWN_KEY included, is written in place of the placeholder as the status
     * header writes it, whatever the mutator answered, since there is no secure string to
     * substitute, so your backend sees why it is missing.
     *
     * @param result is the result of the secure string fetch
     * @param substitute is the answer of the service mutator
     * @return Replacement for the placeholder, or nil if the placeholder is left
     */
    static func replacement(for result: ApproovTokenResult, substitute: Bool) -> Replacement? {
        guard result.status == .success else {
            return .status(statusValue(result.status))
        }
        guard substitute, let secureString = result.secureString else { return nil }
        return .secureString(secureString)
    }

    // logs at debug level a secure string fetch that delivered nothing, naming the header or query parameter:
    // a status sent in place of the placeholder, a secure string the mutator declined, or none to substitute
    private static func logNotDelivered(_ name: String, _ result: ApproovTokenResult, declined: Bool,
                                        statusSent: Bool) {
        let cause = (statusSent || declined)
            ? "secure string fetch status \(result.status.rawValue)\(arcDetail(result))"
            : "no secure string for \(result.status.rawValue)"
        let outcome = statusSent ? "status sent in its place" : "placeholder left"
        ApproovLog.log(.debug, "Secure string not substituted in \(name): \(cause), \(outcome)")
    }

    /**
     * Determines whether a header value only holds tab and printable ASCII, which every network
     * stack carries unchanged.
     *
     * @param value is the header value to be checked
     * @return true if the value is safe, false otherwise
     */
    static func isSafeHeaderValue(_ value: String) -> Bool {
        return value.unicodeScalars.allSatisfy { ($0 == "\t") || (0x20...0x7e).contains($0.value) }
    }

    /**
     * Creates the error for a header value the app supplied that a header cannot carry, naming the
     * header but never the value.
     *
     * @param header is the header that cannot carry the value
     * @return URLError for the error
     */
    static func unsafeHeaderError(_ header: String) -> URLError {
        return ApproovRequestPathError.configuration("Approov header \(header): invalid character in value")
    }

    // checks every header the processed request hook added or changed
    private static func checkHeadersSet(from before: URLRequest, to after: URLRequest) throws {
        let previous = before.allHTTPHeaderFields ?? [:]
        for (header, value) in after.allHTTPHeaderFields ?? [:]
            where (previous[header] != value) && !isSafeHeaderValue(value) {
            throw unsafeHeaderError(header)
        }
    }

    /**
     * Substitutes secure strings into the substitution headers, replacing a value of the form
     * "<requiredPrefix><key>" with "<requiredPrefix><secure string>", or with
     * "<requiredPrefix><status>" if the secure string fetch failed. With a refusal the
     * placeholders are left and nothing is fetched.
     *
     * @param request is the request to be updated
     * @param mutator is the service mutator making the decisions
     * @param changes is the record of the changes made to the request
     * @param refusal is the refusal of secure strings, or nil if they may be substituted
     * @return true if any placeholder was replaced, false otherwise
     * @throws Error if a substitution hook aborts the request
     */
    @discardableResult
    private func substituteHeaders(in request: inout URLRequest,
                                   mutator: ApproovServiceMutator,
                                   changes: ApproovRequestMutations,
                                   refusal: Refusal?) throws -> Bool {
        let substitutionHeaders = coordinator.substitutionHeaders
        guard !substitutionHeaders.isEmpty else { return false }
        var substituted: [String] = []
        var replaced = false
        for (header, requiredPrefix) in substitutionHeaders {
            guard let value = request.value(forHTTPHeaderField: header),
                  value.hasPrefix(requiredPrefix),
                  value.count > requiredPrefix.count else { continue }
            if let refusal {
                ApproovLog.log(refusal.level, "Secure string not substituted in header \(header): \(refusal.reason), placeholder left")
                continue
            }
            let key = String(value.dropFirst(requiredPrefix.count))
            let result = backend.fetchSecureString(key: key, newDef: nil)
            coordinator.recordLastARC(result)
            if result.isConfigChanged {
                backend.fetchConfig()
            }
            // the hook may abort, and otherwise the result decides what replaces the placeholder
            let substitute = try ApproovRequestPathError.callHook("handleInterceptorHeaderSubstitutionResult", {
                try mutator.handleInterceptorHeaderSubstitutionResult(result, header: header)
            })
            switch Self.replacement(for: result, substitute: substitute) {
            case .none:
                Self.logNotDelivered("header \(header)", result, declined: !substitute, statusSent: false)
            case .status(let status):
                Self.logNotDelivered("header \(header)", result, declined: !substitute, statusSent: true)
                request.setValue(requiredPrefix + status, forHTTPHeaderField: header)
                replaced = true
            case .secureString(let secureString):
                // a secure string a header cannot carry leaves the placeholder and the request proceeds
                guard Self.isSafeHeaderValue(requiredPrefix + secureString) else {
                    ApproovLog.log(.warning, "Secure string not substituted in header \(header): invalid character in value, placeholder left")
                    continue
                }
                request.setValue(requiredPrefix + secureString, forHTTPHeaderField: header)
                substituted.append(header)
                replaced = true
            }
        }
        if !substituted.isEmpty {
            changes.setSubstitutionHeaderKeys(substituted)
        }
        return replaced
    }

    /**
     * Substitutes secure strings into every occurrence of the substitution query parameters. Each
     * occurrence is looked up on its own and only substituted if the URL carries the secure string
     * unchanged, and the rest of the URL is never re-encoded. An occurrence whose secure string
     * fetch failed gets the status instead. With a refusal the placeholders are left and nothing
     * is fetched. The query of a redirect target is the server's, so none of its values is looked
     * up or replaced, whatever its parameter names.
     *
     * @param request is the request to be updated
     * @param mutator is the service mutator making the decisions
     * @param changes is the record of the changes made to the request
     * @param refusal is the refusal of secure strings, or nil if they may be substituted
     * @return true if any placeholder was replaced, false otherwise
     * @throws Error if a substitution hook aborts the request
     */
    @discardableResult
    private func substituteQueryParams(in request: inout URLRequest,
                                       mutator: ApproovServiceMutator,
                                       changes: ApproovRequestMutations,
                                       refusal: Refusal?) throws -> Bool {
        let queryParams = coordinator.substitutionQueryParams.sorted()
        guard !queryParams.isEmpty, let url = request.url else { return false }
        // the query of a redirect followed to a URL the server sent holds no placeholder of the app's
        guard URLProtocol.property(forKey: ApproovURLProtocol.serverQueryKey, in: request) == nil else {
            return false
        }
        let originalURL = url.absoluteString
        var accepted = originalURL
        var substituted: [String] = []
        var replaced = false
        for key in queryParams {
            var searchFrom = 0
            while let occurrence = Self.nextQueryOccurrence(of: key, in: accepted, from: searchFrom) {
                if let refusal {
                    ApproovLog.log(refusal.level, "Secure string not substituted in query parameter \(key): \(refusal.reason), placeholder left")
                    break
                }
                let placeholder = Self.substring(accepted, occurrence)
                searchFrom = occurrence.upperBound
                let result = backend.fetchSecureString(key: placeholder, newDef: nil)
                coordinator.recordLastARC(result)
                if result.isConfigChanged {
                    backend.fetchConfig()
                }
                // the hook may abort, and otherwise the result decides what replaces the placeholder
                let substitute = try ApproovRequestPathError.callHook("handleInterceptorQueryParamSubstitutionResult", {
                    try mutator.handleInterceptorQueryParamSubstitutionResult(result, queryKey: key)
                })
                guard let replacement = Self.replacement(for: result, substitute: substitute) else {
                    Self.logNotDelivered("query parameter \(key)", result, declined: !substitute, statusSent: false)
                    continue
                }
                if case .status = replacement {
                    Self.logNotDelivered("query parameter \(key)", result, declined: !substitute, statusSent: true)
                }
                guard let candidate = Self.carriedCandidate(accepted, replacing: occurrence, with: replacement.value) else {
                    ApproovLog.log(.warning, "Secure string not substituted in query parameter \(key): value cannot be carried in the URL, "
                                   + "placeholder left")
                    continue
                }
                accepted = candidate.url
                searchFrom = occurrence.lowerBound + candidate.valueLength
                replaced = true
                if case .secureString = replacement, !substituted.contains(key) {
                    substituted.append(key)
                }
            }
        }
        // every accepted candidate parsed to itself, so this cannot fail, but the placeholders stay if it did
        guard replaced, let newURL = URL(string: accepted) else { return false }
        request.url = newURL
        changes.setSubstitutionQueryParamResults(originalURL: originalURL,
                                                 substitutionQueryParamKeys: substituted)
        return true
    }

    // the query of a URL as UTF-8 offsets, after the first "?" and before the first "#"
    private static func queryBounds(_ url: [UInt8]) -> Range<Int>? {
        let hash = url.firstIndex(of: UInt8(ascii: "#")) ?? url.count
        guard let question = url[..<hash].firstIndex(of: UInt8(ascii: "?")) else { return nil }
        return (question + 1)..<hash
    }

    /**
     * Finds the next non-empty value of a query parameter. The name must follow the "?" or an "&"
     * and be followed by "=", and the value runs to the next "&" or ";" or the end of the query.
     *
     * @param key is the query parameter name, compared byte for byte
     * @param url is the URL string
     * @param from is the UTF-8 offset to search from
     * @return the UTF-8 offsets of the value, or nil if there is none
     */
    static func nextQueryOccurrence(of key: String, in url: String, from: Int) -> Range<Int>? {
        let bytes = Array(url.utf8)
        let name = Array(key.utf8) + [UInt8(ascii: "=")]
        guard !key.isEmpty, let query = queryBounds(bytes) else { return nil }
        var position = max(query.lowerBound, from)
        while position + name.count <= query.upperBound {
            let atNameStart = (position == query.lowerBound) || (bytes[position - 1] == UInt8(ascii: "&"))
            if atNameStart, Array(bytes[position..<(position + name.count)]) == name {
                let valueStart = position + name.count
                var valueEnd = valueStart
                while valueEnd < query.upperBound,
                      bytes[valueEnd] != UInt8(ascii: "&"), bytes[valueEnd] != UInt8(ascii: ";") {
                    valueEnd += 1
                }
                if valueEnd > valueStart {
                    return valueStart..<valueEnd
                }
            }
            position += 1
        }
        return nil
    }

    // the text at UTF-8 offsets of a URL
    private static func substring(_ url: String, _ range: Range<Int>) -> String {
        return String(decoding: Array(url.utf8)[range], as: UTF8.self)
    }

    // the characters left as they are in a substituted query value: those Foundation leaves in a query, and
    // "#" so a value that would start the fragment is caught by the read-back
    private static let queryValueKept: CharacterSet = {
        var kept = CharacterSet.urlQueryAllowed
        kept.insert("#")
        return kept
    }()

    /**
     * Encodes a secure string for a query as Foundation encodes it when parsing a URL, so the rest
     * of the URL is never re-encoded. A character Foundation does not allow in a query is
     * percent-encoded and a "%" that does not start an escape becomes "%25"; any other character is
     * left for the read-back to judge.
     *
     * @param value is the secure string to be encoded
     * @return the encoded value
     */
    static func encodeLikeFoundation(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var out = ""
        for (index, scalar) in scalars.enumerated() {
            if scalar == "%" {
                let isEscape = (index + 2 < scalars.count)
                    && scalars[index + 1].properties.isASCIIHexDigit && scalars[index + 2].properties.isASCIIHexDigit
                out += isEscape ? "%" : "%25"
            } else if queryValueKept.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    out += String(format: "%%%02X", byte)
                }
            }
        }
        return out
    }

    /**
     * Substitutes a secure string for one occurrence of a query parameter value, only if the secure
     * string reaches your backend unchanged: Foundation must parse the candidate to the same string,
     * and the value read back must be printable ASCII and equal the secure string, as it is or after
     * percent-decoding. CR, LF and tab are never substituted.
     *
     * @param url is the URL string
     * @param occurrence is the UTF-8 offsets of the placeholder value
     * @param secureString is the secure string to be substituted
     * @return the candidate URL and the length of the encoded value, or nil if it is not carried unchanged
     */
    static func carriedCandidate(_ url: String, replacing occurrence: Range<Int>,
                                 with secureString: String) -> (url: String, valueLength: Int)? {
        guard !secureString.unicodeScalars.contains(where: { ($0 == "\r") || ($0 == "\n") || ($0 == "\t") }) else {
            return nil
        }
        let encoded = encodeLikeFoundation(secureString)
        var bytes = Array(url.utf8)
        bytes.replaceSubrange(occurrence, with: Array(encoded.utf8))
        let candidate = String(decoding: bytes, as: UTF8.self)
        guard let parsed = URL(string: candidate), parsed.absoluteString == candidate,
              let query = URLComponents(url: parsed, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              let bounds = queryBounds(bytes), query == String(decoding: bytes[bounds], as: UTF8.self) else {
            return nil
        }
        let queryBytes = Array(query.utf8)
        let valueStart = occurrence.lowerBound - bounds.lowerBound
        var valueEnd = valueStart
        while valueEnd < queryBytes.count,
              queryBytes[valueEnd] != UInt8(ascii: "&"), queryBytes[valueEnd] != UInt8(ascii: ";") {
            valueEnd += 1
        }
        let readBack = String(decoding: queryBytes[valueStart..<valueEnd], as: UTF8.self)
        guard readBack.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }),
              (readBack == secureString) || (WireURL.percentDecode(readBack) == secureString) else {
            return nil
        }
        return (candidate, encoded.utf8.count)
    }
}
