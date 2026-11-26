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

// logging levels for the service layer
public enum ApproovLogLevel: Int, Comparable, Sendable {
    case off = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4

    public static func < (lhs: ApproovLogLevel, rhs: ApproovLogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// handler for the TLS and authentication challenges that interception cannot deliver to the app's own
// session delegate, called like the didReceiveChallenge delegate method of URLSession
public typealias ApproovChallengeHandler =
    @Sendable (URLAuthenticationChallenge,
               @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void

// ApproovInterceptor coordinates the interception of URLSession networking, whichever HTTP library sits
// on top. URLProtocol.registerClass covers URLSession.shared, and a swizzle of the URLSessionConfiguration
// factory getters covers every session built from a configuration. Background sessions and WKWebView are
// not covered. All mutable state is guarded by lock, which the compiler cannot see, hence @unchecked.
public final class ApproovInterceptor: @unchecked Sendable {

    public static let shared = ApproovInterceptor()

    // the Approov SDK's own attestation and token service domains, which are never intercepted since
    // that would deadlock token fetches and strip the SDK's own pinning: every *.approovr.io host (the
    // 3.5.x primary attest.approovr.io, the 3.7.0 secondary and each account's att-<account>.approovr.io),
    // every *.approoval.com host (the failover endpoints), and attest.api.approov.io (the 3.7.0 primary,
    // the primary of an account proxied through Cloudflare, and the attester's pinning test probe)
    public static let sdkInfrastructureDomains = ["approovr.io", "approoval.com", "attest.api.approov.io"]

    /**
     * Determines whether a host belongs to the Approov SDK's own infrastructure, as an exact match or
     * a subdomain of one of the sdkInfrastructureDomains.
     *
     * @param host is the host to be checked
     * @return true if the host is Approov infrastructure, false otherwise
     */
    public static func isSDKInfrastructureHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        for domain in sdkInfrastructureDomains {
            if (lowercased == domain) || lowercased.hasSuffix("." + domain) {
                return true
            }
        }
        return false
    }

    // the most intercepted requests processed at once, since each blocks a thread in the SDK fetches;
    // further requests wait their turn without holding a thread, keeping well below the dispatch pool limit
    static let maxConcurrentRequestUpdates = 8

    // the concurrent queue that request processing runs on, only submitted to by requestExecutor
    static let workQueue = DispatchQueue(label: "io.approov.service.fetch",
                                         qos: .userInitiated,
                                         attributes: .concurrent)

    // runs request processing on workQueue, at most maxConcurrentRequestUpdates at a time, in arrival order
    static let requestExecutor = BoundedExecutor(limit: maxConcurrentRequestUpdates, queue: workQueue)

    // the lock guarding all of the mutable state below
    private let lock = NSLock()

    // the backend, request updater and pinning verifier while the service is enabled
    private var activeBackend: ApproovBackend?
    private var activeUpdater: ApproovRequestUpdater?
    private var activeVerifier: ApproovPinningVerifier?

    // true if Approov protection is enabled, false in bypass mode
    private var enabled = false

    // true once the protocol is registered, since registerClass appends on every call and repeated
    // registrations would not all be removed by one unregisterClass
    private var protocolRegistered = false

    // configuration, with the same defaults as approov-service-urlsession
    private var tokenHeaderValue = "Approov-Token"
    private var tokenPrefixValue = ""
    private var traceIDHeaderValue: String? = "Approov-TraceID"
    private var statusHeaderValue: String? = "Approov-Status"
    private var bindingHeaderValue: String?
    private var exclusionRegexesValue: [String: NSRegularExpression] = [:]
    private var substitutionHeadersValue: [String: String] = [:]
    private var substitutionQueryParamsValue: Set<String> = []
    private var serviceMutatorValue: ApproovServiceMutator = .DEFAULT
    private var challengeHandlerValue: ApproovChallengeHandler?
    private var loggingLevelValue: ApproovLogLevel = .info

    // the message signer and whether it is enabled, which is on by default with the default factory, signing
    // with both the install and the account signature, and kept by initialize
    private let messageSigning = ApproovDefaultMessageSigning()
    private var messageSigningEnabledValue = true

    // the ARC of the most recent fetch, which is kept by initialize and only cleared by deactivate
    private var lastARCValue = ""

    // true once the options of the configuration file have been applied, which happens once per process
    private var configFileAppliedValue = false

    // the lock serializing a change of the host framework identity with reporting the user property,
    // so the identity set last is the one the SDK holds whichever of the two runs first
    private let userPropertyLock = NSLock()

    // the user property set by a host framework package in place of the layer's own, or nil for none
    private var hostFrameworkIdentityValue: String?

    private init() {}

    // true once any initialize has succeeded, bypass mode included, so requests before then are not claimed
    public var isApproovServiceEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeBackend != nil
    }

    // true once the SDK is initialized and Approov protection is active, false in bypass mode
    public var isApproovProtectionEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (activeBackend != nil) && enabled
    }

    var updater: ApproovRequestUpdater? {
        lock.lock()
        defer { lock.unlock() }
        return activeUpdater
    }

    var pinningVerifier: ApproovPinningVerifier? {
        lock.lock()
        defer { lock.unlock() }
        return enabled ? activeVerifier : nil
    }

    var backend: ApproovBackend? {
        lock.lock()
        defer { lock.unlock() }
        return activeBackend
    }

    /**
     * Installs global interception backed by the given backend. In bypass mode interception is
     * installed but requests pass through untouched and pinning is not applied. Activating again with
     * the same backend only sets whether protection is enabled; a different backend replaces the
     * request updater and pinning verifier. No configuration is reset. This is a test hook, since
     * initialize is the entry point for apps.
     *
     * @param backend is the Approov backend to be used
     * @param enabled is true if Approov protection is enabled, false for bypass mode
     */
    @_spi(Testing)
    public func activate(backend: ApproovBackend, enabled: Bool = true) {
        lock.lock()
        if activeBackend === backend {
            self.enabled = enabled
            lock.unlock()
            return
        }
        activeBackend = backend
        self.enabled = enabled
        activeUpdater = ApproovRequestUpdater(backend: backend, coordinator: self)
        activeVerifier = ApproovPinningVerifier(backend: backend)
        lock.unlock()
        installInterception()

        // log an error if interception did not actually install
        verifyInterceptionInstalled()
    }

    /**
     * Installs global interception without initializing: the swizzle of the URLSessionConfiguration
     * factory getters and the registration of ApproovURLProtocol. Sessions created from then on carry
     * the protocol, but it claims no request until an initialize succeeds, so requests before then go
     * out untouched, neither failed nor held, and are protected from the moment initialize succeeds.
     * This is for frameworks that create sessions before the app can initialize, such as React Native.
     * Calling it again changes nothing, and initialize installs interception itself when this was not
     * called.
     */
    public func installInterception() {
        lock.lock()
        let needsRegistration = !protocolRegistered
        protocolRegistered = true
        lock.unlock()
        // skips the getters that are already swizzled, so a repeat never exchanges them back
        ConfigurationSwizzler.install()
        if needsRegistration {
            URLProtocol.registerClass(ApproovURLProtocol.self)
        }
    }

    // true once interception is installed by installInterception or initialize
    var isInterceptionInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return protocolRegistered
    }

    /**
     * Verifies that Approov interception is installed and positioned ahead of any other
     * URLProtocol-based networking SDK in a freshly created URLSessionConfiguration. Any failure is
     * logged as an error, naming whether the swizzle failed to install or another SDK is ahead of
     * Approov. Call this again after all other networking SDKs have initialized, since this is a
     * snapshot. It checks the hook only, so it is true after installInterception and before
     * initialize, while requests still go out untouched.
     *
     * @return true if interception is installed first, false otherwise
     */
    @discardableResult
    public func verifyInterceptionInstalled() -> Bool {
        guard isInterceptionInstalled else {
            if loggingLevel >= .error {
                os_log("ApproovService: verifyInterceptionInstalled: interception not installed", type: .error)
            }
            return false
        }
        let state = ConfigurationSwizzler.interceptionState()
        if !state.present {
            if loggingLevel >= .error {
                os_log("ApproovService: verifyInterceptionInstalled: ApproovURLProtocol missing from new configurations, default getter from %{public}@",
                       type: .error, ConfigurationSwizzler.defaultGetterOrigin())
            }
            return false
        }
        if !state.first {
            if loggingLevel >= .error {
                // name the SDK whose protocol is ahead of Approov
                let front: AnyClass? = URLSessionConfiguration.default.protocolClasses?.first
                let frontDescription = front.map {
                    "\(NSStringFromClass($0)) from \(ConfigurationSwizzler.classOrigin($0))"
                } ?? "<unknown>"
                os_log("ApproovService: verifyInterceptionInstalled: %{public}@ is ahead of ApproovURLProtocol",
                       type: .error, frontDescription)
            }
            return false
        }
        return true
    }

    /**
     * Gets counters of the requests forwarded through interception and of the TLS challenges that
     * were pin verified or delegated.
     *
     * @return ApproovInterceptionDiagnostics holding the current counters
     */
    public func interceptionDiagnostics() -> ApproovInterceptionDiagnostics {
        return ForwardingSession.shared.diagnostics
    }

    /**
     * Removes interception, for tests only. Sessions created while active keep the protocol class,
     * but it no longer claims their requests.
     */
    @_spi(Testing)
    public func deactivate() {
        URLProtocol.unregisterClass(ApproovURLProtocol.self)
        ConfigurationSwizzler.uninstall()
        lock.lock()
        activeBackend = nil
        enabled = false
        activeUpdater = nil
        activeVerifier = nil
        protocolRegistered = false
        lastARCValue = ""
        lock.unlock()
    }

    /**
     * Resets all configuration to the defaults, and allows the configuration file to be applied
     * again, for tests only. Note that initialize never resets configuration.
     */
    @_spi(Testing)
    public func resetConfiguration() {
        // taken on its own, since setHostFrameworkIdentity takes lock while holding userPropertyLock
        userPropertyLock.lock()
        hostFrameworkIdentityValue = nil
        userPropertyLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        tokenHeaderValue = "Approov-Token"
        tokenPrefixValue = ""
        traceIDHeaderValue = "Approov-TraceID"
        statusHeaderValue = "Approov-Status"
        bindingHeaderValue = nil
        exclusionRegexesValue = [:]
        substitutionHeadersValue = [:]
        substitutionQueryParamsValue = []
        serviceMutatorValue = .DEFAULT
        challengeHandlerValue = nil
        loggingLevelValue = .info
        messageSigningEnabledValue = true
        messageSigning.reset()
        configFileAppliedValue = false
    }

    /**
     * Claims the single application of the configuration file options in this process.
     *
     * @return true if the options are to be applied by the caller, false if they were applied before
     */
    package func claimConfigFileApplication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !configFileAppliedValue
        configFileAppliedValue = true
        return first
    }

    /**
     * Sets the user property a host framework package reports to the Approov platform in place of the
     * layer's own, such as "approov-react-native/3.7.0". If Approov protection is already enabled then
     * it is reported at once, otherwise the initialize that enables protection reports it.
     *
     * @param identity is the user property of the host framework, or nil to report the layer's own
     * @param defaultProperty is the layer's own user property
     * @param report is the call that sets the user property in the SDK
     */
    package func setHostFrameworkIdentity(_ identity: String?, defaultProperty: String,
                                          report: (String) -> Void) {
        userPropertyLock.lock()
        hostFrameworkIdentityValue = identity
        if isApproovProtectionEnabled {
            report(identity ?? defaultProperty)
        }
        userPropertyLock.unlock()
        ApproovLog.log(.debug, "setHostFrameworkIdentity " + Self.describe(identity))
    }

    /**
     * Gets the user property a host framework package set in place of the layer's own.
     *
     * @return the host framework identity, or nil if none was set
     */
    package var hostFrameworkIdentity: String? {
        userPropertyLock.lock()
        defer { userPropertyLock.unlock() }
        return hostFrameworkIdentityValue
    }

    /**
     * Reports the user property to the SDK, which is the host framework identity if one was set and
     * the layer's own otherwise.
     *
     * @param defaultProperty is the layer's own user property
     * @param report is the call that sets the user property in the SDK
     */
    package func reportUserProperty(defaultProperty: String, report: (String) -> Void) {
        userPropertyLock.lock()
        defer { userPropertyLock.unlock() }
        report(hostFrameworkIdentityValue ?? defaultProperty)
    }

    /**
     * Sets the header that the Approov token is added on, as well as an optional prefix String
     * (such as "Bearer "). By default the token is provided on "Approov-Token" with no prefix.
     * Note that the token header is only added when the token fetch succeeds.
     *
     * @param header is the header to place the Approov token on
     * @param prefix is any prefix String for the Approov token header, or nil for none
     */
    public func setTokenHeader(_ header: String, prefix: String? = nil) {
        lock.lock()
        tokenHeaderValue = header
        tokenPrefixValue = prefix ?? ""
        lock.unlock()
        ApproovLog.log(.debug, "setTokenHeader " + header + ", " + Self.describe(prefix))
    }

    /**
     * Gets the header that is used to hold the Approov token.
     *
     * @return String of the header used for the Approov token
     */
    public func getTokenHeader() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tokenHeaderValue
    }

    /**
     * Gets the prefix that is added before the Approov token in the header.
     *
     * @return String of the prefix added before the Approov token, or an empty string for none
     */
    public func getTokenPrefix() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tokenPrefixValue
    }

    /**
     * Sets the header that the Approov token is added on. Deprecated: use setTokenHeader instead.
     *
     * @param header is the header to place the Approov token on
     * @param prefix is any prefix String for the Approov token header
     */
    @available(*, deprecated, renamed: "setTokenHeader(_:prefix:)")
    public func setApproovHeader(_ header: String, prefix: String = "") {
        setTokenHeader(header, prefix: prefix)
    }

    /**
     * Sets the debug header that carries the SDK trace ID for each token fetch. By default this is
     * "Approov-TraceID".
     *
     * @param header is the header to place the trace ID on, or nil to stop adding it
     */
    public func setTraceIDHeader(_ header: String?) {
        lock.lock()
        traceIDHeaderValue = header
        lock.unlock()
        ApproovLog.log(.debug, "setTraceIDHeader " + Self.describe(header))
    }

    /**
     * Gets the header that carries the SDK trace ID.
     *
     * @return String of the trace ID header or nil if disabled
     */
    public func getTraceIDHeader() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return traceIDHeaderValue
    }

    /**
     * Sets the header that reports the Approov token fetch status on every request processed by
     * Approov, replacing any value the app set itself. By default this is "Approov-Status". The
     * value is the fetch status name, never converted, such as "SUCCESS" or "NO_NETWORK". Note that it is
     * never sent to a host that is not added to Approov or to a secrets-only API, and after a failed
     * token fetch it is only sent to a host listed in the Approov pins.
     *
     * @param header is the header to place the status on, or nil or an empty string to stop adding it
     */
    public func setStatusHeader(_ header: String?) {
        lock.lock()
        statusHeaderValue = header
        lock.unlock()
        ApproovLog.log(.debug, "setStatusHeader " + Self.describe(header))
    }

    /**
     * Gets the header that is used to report the Approov token fetch status.
     *
     * @return String of the status header or nil if disabled
     */
    public func getStatusHeader() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return statusHeaderValue
    }

    /**
     * Sets a binding header whose value is bound into the pay claim of the Approov token. A header
     * registered for secure string substitution cannot also be the binding header.
     *
     * @param header is the header to use for Approov token binding, or nil to remove it
     * @throws ApproovServiceError if the header is already a substitution header, in any case
     */
    public func setBindingHeader(_ header: String?) throws {
        // logged before the check, so a rejected call is logged too
        ApproovLog.log(.debug, "setBindingHeader " + Self.describe(header))
        lock.lock()
        defer { lock.unlock() }
        if !setBindingHeaderLocked(header), let header {
            throw ApproovServiceError.permanentError(message: "setBindingHeader \(header): already a substitution header")
        }
    }

    // sets the binding header, with the lock held, unless it is a substitution header, which it then reports
    private func setBindingHeaderLocked(_ header: String?) -> Bool {
        // a header is never both bound and substituted, in any case
        if let header,
           substitutionHeadersValue.keys.contains(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) {
            return false
        }
        bindingHeaderValue = header
        return true
    }

    /**
     * Gets any current binding header.
     *
     * @return binding header or nil if not set
     */
    public func getBindingHeader() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bindingHeaderValue
    }

    /**
     * Sets the service mutator that makes the request decisions.
     *
     * @param mutator is the service mutator to be used, or nil to use `.DEFAULT`
     */
    public func setServiceMutator(_ mutator: ApproovServiceMutator?) {
        let mutator = mutator ?? .DEFAULT
        lock.lock()
        serviceMutatorValue = mutator
        lock.unlock()
        ApproovLog.log(.debug, lazy: "setServiceMutator " + Self.describe(mutator))
    }

    /**
     * Enables message signing, so every request carrying the Approov token header is signed after
     * the mutator decisions, the substitutions and the processed request hook. Message signing is on
     * by default with the default factory. Installing a mutator never changes this, and initialize
     * leaves it as it is.
     *
     * @param defaultFactory is the factory for hosts without their own, or nil for the default factory
     */
    public func enableMessageSigning(_ defaultFactory: SignatureParametersFactory? = nil) {
        messageSigning.setDefaultFactory(
            defaultFactory ?? ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory())
        lock.lock()
        messageSigningEnabledValue = true
        lock.unlock()
        ApproovLog.log(.debug, "enableMessageSigning")
    }

    /**
     * Disables message signing. Any factories are kept for a later enableMessageSigning.
     */
    public func disableMessageSigning() {
        lock.lock()
        messageSigningEnabledValue = false
        lock.unlock()
        ApproovLog.log(.debug, "disableMessageSigning")
    }

    /**
     * Determines whether message signing is enabled.
     *
     * @return true if protected requests are signed, false otherwise
     */
    public func isMessageSigningEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return messageSigningEnabledValue
    }

    /**
     * Sets the factory used to sign requests to a particular host instead of the default factory,
     * while message signing is enabled.
     *
     * @param hostName is the host name, matched without regard to case and without a port
     * @param factory is the factory for the host's signature parameters, or nil to remove it
     */
    public func putMessageSigningHostFactory(hostName: String, factory: SignatureParametersFactory?) {
        messageSigning.putHostFactory(hostName: hostName, factory: factory)
        ApproovLog.log(.debug, "putMessageSigningHostFactory ", host: hostName)
    }

    /**
     * Gets the type of the default signature parameters factory, or of the factory of one host, so that an
     * Approov package hosting this layer in another framework can tell an app's own subclass from the
     * standard factory without calling it.
     *
     * @param hostName is the host name, matched as by putMessageSigningHostFactory, or nil for the default factory
     * @return the type of the factory, or nil if there is none
     */
    package func messageSigningFactoryType(hostName: String?) -> SignatureParametersFactory.Type? {
        let factory: SignatureParametersFactory?
        if let hostName {
            factory = messageSigning.hostFactory(hostName: hostName)
        } else {
            factory = messageSigning.defaultFactoryValue
        }
        return factory.map { type(of: $0) }
    }

    // the message signer while signing is enabled, nil otherwise
    var activeMessageSigning: ApproovDefaultMessageSigning? {
        lock.lock()
        defer { lock.unlock() }
        return messageSigningEnabledValue ? messageSigning : nil
    }

    /**
     * Gets the current service mutator.
     *
     * @return ApproovServiceMutator currently making the request decisions
     */
    public func getServiceMutator() -> ApproovServiceMutator {
        lock.lock()
        defer { lock.unlock() }
        return serviceMutatorValue
    }

    /**
     * Sets a handler for the challenges that interception cannot deliver to the app's own session
     * delegate. These are all challenges other than server trust, server trust challenges for hosts
     * without Approov pins, which the handler decides on its own as in bypass mode, and server trust
     * challenges for hosts with Approov pins after the Approov check has passed. A failed Approov
     * check is final and never offered to the handler.
     *
     * @param handler is the challenge handler to be used, or nil to remove it
     */
    public func setChallengeHandler(_ handler: ApproovChallengeHandler?) {
        lock.lock()
        challengeHandlerValue = handler
        lock.unlock()
        ApproovLog.log(.debug, "setChallengeHandler" + ((handler == nil) ? " null" : ""))
    }

    var challengeHandler: ApproovChallengeHandler? {
        lock.lock()
        defer { lock.unlock() }
        return challengeHandlerValue
    }

    /**
     * Sets the level of logging from the service layer.
     *
     * @param level is the logging level to be used
     */
    public func setLoggingLevel(_ level: ApproovLogLevel) {
        lock.lock()
        loggingLevelValue = level
        lock.unlock()
        ApproovLog.log(.debug, "setLoggingLevel " + level.name)
    }

    /**
     * Adds an exclusion URL regular expression. If a URL for a request matches this regular
     * expression then it is not subject to any Approov protection. Note that this also means that
     * the request gives no opportunity for a pin update.
     *
     * @param pattern is the regular expression that will be compared against URLs for exclusion
     * @throws ApproovServiceError if there was a problem, including if the pattern does not compile
     */
    public func addExclusionURLRegex(_ pattern: String) throws {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ApproovServiceError.permanentError(
                message: "addExclusionURLRegex: invalid regular expression \(pattern): \(error.localizedDescription)")
        }
        lock.lock()
        exclusionRegexesValue[pattern] = regex
        lock.unlock()

        // a pattern can name a host, so it is logged private
        ApproovLog.log(.debug, "addExclusionURLRegex ", host: pattern)
    }

    /**
     * Removes an exclusion URL regular expression previously added using addExclusionURLRegex.
     *
     * @param pattern is the regular expression that will be compared against URLs for exclusion
     */
    public func removeExclusionURLRegex(_ pattern: String) {
        ApproovLog.log(.debug, "removeExclusionURLRegex ", host: pattern)
        lock.lock()
        defer { lock.unlock() }
        exclusionRegexesValue[pattern] = nil
    }

    /**
     * Removes all exclusion URL regular expressions.
     */
    public func removeAllExclusionURLRegexes() {
        ApproovLog.log(.debug, "removeAllExclusionURLRegexes")
        lock.lock()
        defer { lock.unlock() }
        exclusionRegexesValue.removeAll()
    }

    /**
     * Gets the exclusion URL regular expressions.
     *
     * @return map of each pattern, as added, to its compiled regular expression
     */
    public func getExclusionURLRegexs() -> [String: NSRegularExpression] {
        lock.lock()
        defer { lock.unlock() }
        return exclusionRegexesValue
    }

    /**
     * Adds the name of a header which should be subject to secure strings substitution. If the
     * header value, less the required prefix, names a secure string then it is replaced with the
     * secure string value, or with the status of a secure string fetch that failed. Header names
     * match without regard to case, so adding a name again in any case replaces the entry and its
     * required prefix. The binding header cannot also be a substitution header.
     *
     * @param header is the header to be marked for substitution
     * @param requiredPrefix is any required prefix to the value being substituted, or an empty string for none
     * @throws ApproovServiceError if the header is already the binding header, in any case
     */
    public func addSubstitutionHeader(_ header: String, requiredPrefix: String = "") throws {
        // logged before the check, so a rejected call is logged too
        ApproovLog.log(.debug, "addSubstitutionHeader " + header + ", " + requiredPrefix)
        lock.lock()
        defer { lock.unlock() }
        if !addSubstitutionHeaderLocked(header, requiredPrefix: requiredPrefix) {
            throw ApproovServiceError.permanentError(message: "addSubstitutionHeader \(header): already the binding header")
        }
    }

    // adds a substitution header, with the lock held, unless it is the binding header, which it then reports
    private func addSubstitutionHeaderLocked(_ header: String, requiredPrefix: String) -> Bool {
        // a header is never both bound and substituted, in any case
        if let binding = bindingHeaderValue, binding.caseInsensitiveCompare(header) == .orderedSame {
            return false
        }
        removeSubstitutionHeaderLocked(header)
        substitutionHeadersValue[header] = requiredPrefix
        return true
    }

    /**
     * Removes a header previously added using addSubstitutionHeader, matching its name in any case.
     *
     * @param header is the header to be removed for substitution
     */
    public func removeSubstitutionHeader(_ header: String) {
        ApproovLog.log(.debug, "removeSubstitutionHeader " + header)
        lock.lock()
        defer { lock.unlock() }
        removeSubstitutionHeaderLocked(header)
    }

    /**
     * Gets all of the substitution headers that are currently setup.
     *
     * @return map of each header name, as last added, to its required prefix
     */
    public func getSubstitutionHeaders() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return substitutionHeadersValue
    }

    // removes every case variant of the header, with the lock held
    private func removeSubstitutionHeaderLocked(_ header: String) {
        for key in substitutionHeadersValue.keys where key.caseInsensitiveCompare(header) == .orderedSame {
            substitutionHeadersValue[key] = nil
        }
    }

    /**
     * Adds a key name for a query parameter that should be subject to secure strings substitution.
     *
     * @param key is the query parameter key name to be added for substitution
     */
    public func addSubstitutionQueryParam(_ key: String) {
        ApproovLog.log(.debug, "addSubstitutionQueryParam " + key)
        lock.lock()
        defer { lock.unlock() }
        substitutionQueryParamsValue.insert(key)
    }

    /**
     * Removes a query parameter key name previously added using addSubstitutionQueryParam.
     *
     * @param key is the query parameter key name to be removed for substitution
     */
    public func removeSubstitutionQueryParam(_ key: String) {
        ApproovLog.log(.debug, "removeSubstitutionQueryParam " + key)
        lock.lock()
        defer { lock.unlock() }
        substitutionQueryParamsValue.remove(key)
    }

    /**
     * Gets all of the substitution query parameters that are currently setup. The keys are matched
     * as literals.
     *
     * @return set of the query parameter key names
     */
    public func getSubstitutionQueryParams() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return substitutionQueryParamsValue
    }

    var tokenHeader: String {
        lock.lock()
        defer { lock.unlock() }
        return tokenHeaderValue
    }

    var tokenPrefix: String {
        lock.lock()
        defer { lock.unlock() }
        return tokenPrefixValue
    }

    // the token header name and prefix as one consistent snapshot
    var tokenHeaderAndPrefix: (header: String, prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        return (tokenHeaderValue, tokenPrefixValue)
    }

    var traceIDHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        return traceIDHeaderValue
    }

    // the status header to set, or nil if disabled by a nil or empty name
    var statusHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let header = statusHeaderValue, !header.isEmpty else { return nil }
        return header
    }

    var bindingHeader: String? {
        lock.lock()
        defer { lock.unlock() }
        return bindingHeaderValue
    }

    public var loggingLevel: ApproovLogLevel {
        lock.lock()
        defer { lock.unlock() }
        return loggingLevelValue
    }

    public var exclusionRegexes: [String: NSRegularExpression] {
        lock.lock()
        defer { lock.unlock() }
        return exclusionRegexesValue
    }

    var substitutionHeaders: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return substitutionHeadersValue
    }

    var substitutionQueryParams: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return substitutionQueryParamsValue
    }

    // the configuration as one consistent snapshot, for checking that a change is seen whole
    struct ConfigurationSnapshot: Equatable {
        let tokenHeader: String
        let tokenPrefix: String
        let traceIDHeader: String?
        let statusHeader: String?
        let bindingHeader: String?
        let substitutionHeaders: [String: String]
        let substitutionQueryParams: Set<String>
        let exclusionPatterns: Set<String>
        let serviceMutator: String
        let messageSigningEnabled: Bool
        let loggingLevel: ApproovLogLevel
    }

    // the configuration read under one hold of the lock
    var configurationSnapshot: ConfigurationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConfigurationSnapshot(
            tokenHeader: tokenHeaderValue, tokenPrefix: tokenPrefixValue, traceIDHeader: traceIDHeaderValue,
            statusHeader: statusHeaderValue, bindingHeader: bindingHeaderValue,
            substitutionHeaders: substitutionHeadersValue, substitutionQueryParams: substitutionQueryParamsValue,
            exclusionPatterns: Set(exclusionRegexesValue.keys), serviceMutator: Self.describe(serviceMutatorValue),
            messageSigningEnabled: messageSigningEnabledValue, loggingLevel: loggingLevelValue)
    }

    /**
     * Gets a value as a setter logs it, with nil written as null.
     *
     * @param value is the value, or nil for none
     * @return String of the value for a log line
     */
    static func describe(_ value: String?) -> String {
        return value ?? "null"
    }

    /**
     * Gets a service mutator as a setter logs it: a standard mutator by its name, such as
     * "ApproovServiceMutator.CLOSE_FAILURE", and any other by the name of its type. No code of the
     * mutator runs, so neither its description nor the values it holds are ever read.
     *
     * @param mutator is the service mutator
     * @return String naming the mutator for a log line
     */
    static func describe(_ mutator: ApproovServiceMutator) -> String {
        if mutator is ApproovCloseFailureMutator {
            return "ApproovServiceMutator.CLOSE_FAILURE"
        }
        if mutator is ApproovAlwaysProceedMutator {
            return "ApproovServiceMutator.ALWAYS_PROCEED"
        }
        return String(reflecting: type(of: mutator))
    }

    /**
     * Gets the Attestation Response Code (ARC) of the most recent token, secure string or custom
     * JWT fetch made by this layer, without performing a fetch.
     *
     * @return ARC of the last fetch, or an empty string if there was none or it carried no ARC
     */
    package func getLastARC() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastARCValue
    }

    /**
     * Records the ARC of a fetch just made as the most recent one. A fetch without an ARC clears
     * the previous value.
     *
     * @param result is the result of the fetch
     */
    package func recordLastARC(_ result: ApproovTokenResult) {
        lock.lock()
        defer { lock.unlock() }
        lastARCValue = result.arc
    }

    /**
     * Gets the install message signature (ECDSA P-256) for the given message.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded ASN.1 DER signature or nil if not available
     * @throws ApproovServiceError if there was a problem, including if Approov protection is not enabled
     */
    public func installMessageSignature(message: String) throws -> String? {
        return try protectedBackend("getInstallMessageSignature").installMessageSignature(message: message)
    }

    /**
     * Gets the account message signature (HMAC-SHA256) for the given message.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded signature or nil if not available
     * @throws ApproovServiceError if there was a problem, including if Approov protection is not enabled
     */
    public func accountMessageSignature(message: String) throws -> String? {
        return try protectedBackend("getAccountMessageSignature").accountMessageSignature(message: message)
    }

    /**
     * Gets the account message signature for the deprecated getMessageSignature, which does not
     * throw. A deprecation warning is logged once per process.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded signature or nil if not available or Approov protection is not enabled
     */
    package func deprecatedMessageSignature(message: String) -> String? {
        ApproovLog.logOnce(.warning, "getMessageSignature is deprecated: use getAccountMessageSignature")
        return try? accountMessageSignature(message: message)
    }
}
