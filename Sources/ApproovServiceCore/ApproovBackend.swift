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

// ApproovTokenStatus mirrors the token fetch status of the Approov SDK, so the core has no dependency on
// the binary SDK. The raw value is the status name as the Android SDK names the same status, so the names are
// the same on both platforms and are never converted further. The iOS SDK gives prose, such as "MITM detected",
// which init(sdkName:) converts to the name.
public enum ApproovTokenStatus: String, Equatable, Sendable {
    case success = "SUCCESS"
    case noNetwork = "NO_NETWORK"
    // the network is untrusted or behind a captive portal, which is a network status like noNetwork
    case mitmDetected = "MITM_DETECTED"
    case poorNetwork = "POOR_NETWORK"
    case noApproovService = "NO_APPROOV_SERVICE"
    case badURL = "BAD_URL"
    case unknownURL = "UNKNOWN_URL"
    case unprotectedURL = "UNPROTECTED_URL"
    case notInitialized = "NOT_INITIALIZED"
    case rejected = "REJECTED"
    case disabled = "DISABLED"
    case unknownKey = "UNKNOWN_KEY"
    case badKey = "BAD_KEY"
    case badPayload = "BAD_PAYLOAD"
    case internalError = "INTERNAL_ERROR"

    // true for the statuses where the attestation could not be performed because of the network
    public var isNetworkFailure: Bool {
        switch self {
        case .noNetwork, .poorNetwork, .mitmDetected:
            return true
        default:
            return false
        }
    }

    /**
     * Constructs a status from the SDK's own name for it, such as "no Approov service" or
     * "NO_APPROOV_SERVICE", and an unknown name becomes internalError.
     *
     * @param sdkName is the SDK's name for the status
     */
    package init(sdkName: String) {
        let name = sdkName.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "_")
        self = ApproovTokenStatus(rawValue: name) ?? .internalError
    }
}

// ApproovTokenResult mirrors the fields of the SDK's token fetch result used by the service layer
public struct ApproovTokenResult: Sendable {
    public let status: ApproovTokenStatus
    public let token: String
    public let secureString: String?
    public let traceID: String
    public let arc: String
    public let rejectionReasons: String
    public let isConfigChanged: Bool

    public init(status: ApproovTokenStatus,
                token: String = "",
                secureString: String? = nil,
                traceID: String = "",
                arc: String = "",
                rejectionReasons: String = "",
                isConfigChanged: Bool = false) {
        self.status = status
        self.token = token
        self.secureString = secureString
        self.traceID = traceID
        self.arc = arc
        self.rejectionReasons = rejectionReasons
        self.isConfigChanged = isConfigChanged
    }
}

// ApproovBackend provides the Approov SDK operations the service layer needs, bound to the SDK by the
// ApproovService module and to a mock by tests; it must be Sendable as it is called from concurrent queues
public protocol ApproovBackend: AnyObject, Sendable {
    /**
     * Fetches an Approov token for a URL, blocking until complete.
     *
     * @param url is the full request URL
     * @return ApproovTokenResult of the fetch
     */
    func fetchToken(url: String) -> ApproovTokenResult

    /**
     * Fetches the latest SDK configuration, after a fetch reports a configuration change.
     *
     * @return the configuration, or nil if not available
     */
    @discardableResult
    func fetchConfig() -> String?

    /**
     * Gets the current pins, where "*" holds the Managed Trust Roots for domains listed without pins.
     *
     * @param pinType is the type of pin required
     * @return map of each domain to its base64 encoded pins, or nil if they cannot be read
     */
    func pins(pinType: String) -> [String: [String]]?

    /**
     * Sets a hash of the given data into the pay claim of future tokens.
     *
     * @param data is the data to be hashed
     */
    func setDataHashInToken(_ data: String)

    /**
     * Fetches or defines a secure string, blocking until complete.
     *
     * @param key is the secure string key
     * @param newDef is any new definition, or nil for lookup only
     * @return ApproovTokenResult of the fetch, carrying any value in secureString
     */
    func fetchSecureString(key: String, newDef: String?) -> ApproovTokenResult

    /**
     * Fetches a custom JWT, blocking until complete.
     *
     * @param payload is the marshaled JSON object for the claims
     * @return ApproovTokenResult of the fetch, carrying any JWT in token
     */
    func fetchCustomJWT(payload: String) -> ApproovTokenResult

    /**
     * Gets the Approov device ID.
     *
     * @return the device ID, or nil if not available
     */
    func deviceID() -> String?

    /**
     * Sets a development key so the app passes attestation during development.
     *
     * @param devKey is the development key to be used
     */
    func setDevKey(_ devKey: String)

    /**
     * Sets the install attributes sent with future token fetches for this app installation.
     *
     * @param attrs is the signed JWT holding the install attributes
     */
    func setInstallAttributes(_ attrs: String)

    /**
     * Gets the install message signature (ECDSA P-256) for the given message.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded signature or nil if not available
     */
    func installMessageSignature(message: String) -> String?

    /**
     * Gets the account message signature (HMAC-SHA256) for the given message.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded signature or nil if not available
     */
    func accountMessageSignature(message: String) -> String?

    /**
     * Gets the current time, adjusted by the offset between the device clock and the clock of the Approov servers
     * that the SDK learns at each attestation.
     *
     * @return the time in milliseconds since the epoch, or nil if the SDK cannot give it
     */
    func serverAdjustedCurrentTimeMS() -> Int64?
}

extension ApproovBackend {
    // a backend without the SDK's server adjusted time, such as a test backend, reports the device clock
    func serverAdjustedCurrentTimeMS() -> Int64? {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
