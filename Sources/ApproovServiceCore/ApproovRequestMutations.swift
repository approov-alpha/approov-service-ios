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
 * ApproovRequestMutations stores information about changes made to a network request during Approov
 * processing, such as the token, trace ID and status headers, substituted headers and query parameters.
 * It is passed to handleInterceptorProcessedRequest of the service mutator.
 */
public class ApproovRequestMutations {
    private var tokenHeaderKey: String?
    private var traceIDHeaderKey: String?
    private var statusHeaderKey: String?
    private var substitutionHeaderKeys: [String] = []
    private var originalURL: String?
    private var substitutionQueryParamKeys: [String] = []

    public init() {}

    /**
     * Gets the header key used for the Approov token.
     *
     * @return the Approov token header key, or nil if no token header was added
     */
    public func getTokenHeaderKey() -> String? {
        return tokenHeaderKey
    }

    /**
     * Sets the header key used for the Approov token.
     *
     * @param tokenHeaderKey is the Approov token header key
     */
    func setTokenHeaderKey(_ tokenHeaderKey: String) {
        self.tokenHeaderKey = tokenHeaderKey
    }

    /**
     * Gets the header key used for the Approov trace ID debug header.
     *
     * @return the trace ID header key, or nil if it was not added
     */
    public func getTraceIDHeaderKey() -> String? {
        return traceIDHeaderKey
    }

    /**
     * Sets the header key used for the Approov trace ID debug header.
     *
     * @param traceIDHeaderKey is the trace ID header key, or nil if it was not added
     */
    func setTraceIDHeaderKey(_ traceIDHeaderKey: String?) {
        self.traceIDHeaderKey = traceIDHeaderKey
    }

    /**
     * Gets the header key used for the Approov status header.
     *
     * @return the status header key, or nil if it was not added
     */
    public func getStatusHeaderKey() -> String? {
        return statusHeaderKey
    }

    /**
     * Sets the header key used for the Approov status header.
     *
     * @param statusHeaderKey is the status header key, or nil if it was not added
     */
    func setStatusHeaderKey(_ statusHeaderKey: String?) {
        self.statusHeaderKey = statusHeaderKey
    }

    /**
     * Gets the list of headers that were substituted with secure strings. A header that was sent
     * the status of a failed secure string fetch instead is not listed.
     *
     * @return the list of substituted header keys
     */
    public func getSubstitutionHeaderKeys() -> [String] {
        return substitutionHeaderKeys
    }

    /**
     * Sets the list of headers that were substituted with secure strings.
     *
     * @param substitutionHeaderKeys is the list of substituted header keys
     */
    func setSubstitutionHeaderKeys(_ substitutionHeaderKeys: [String]) {
        self.substitutionHeaderKeys = substitutionHeaderKeys
    }

    /**
     * Gets the original URL before any query parameter substitutions, including a status sent in
     * place of a secure string.
     *
     * @return the original URL, or nil if no query parameter was changed
     */
    public func getOriginalURL() -> String? {
        return originalURL
    }

    /**
     * Gets the list of query parameter keys that were substituted with secure strings. A query
     * parameter that was sent the status of a failed secure string fetch instead is not listed.
     *
     * @return the list of substituted query parameter keys
     */
    public func getSubstitutionQueryParamKeys() -> [String] {
        return substitutionQueryParamKeys
    }

    /**
     * Sets the results of the query parameter substitutions.
     *
     * @param originalURL is the URL before any substitutions
     * @param substitutionQueryParamKeys is the list of substituted query parameter keys
     */
    func setSubstitutionQueryParamResults(originalURL: String, substitutionQueryParamKeys: [String]) {
        self.originalURL = originalURL
        self.substitutionQueryParamKeys = substitutionQueryParamKeys
    }
}
