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

// the binary Approov SDK ships iOS and watchOS slices only, so on macOS this module compiles to nothing
// and the SDK-free core can still be built and tested
#if canImport(Approov)

import Foundation
import Approov

// re-export the core so a single `import ApproovService` gives apps the whole public API; the CocoaPods
// pod compiles the core sources into this module, where there is nothing to import
#if canImport(ApproovServiceCore)
@_exported import ApproovServiceCore
#endif

// ApproovService provides a mediation layer to the Approov SDK itself
public enum ApproovService {

    // name and version reported to the Approov platform as the user property
    public static let serviceVersion = "approov-service-ios/3.7.0"

    // the SDK binding every initialize activates interception with
    private static let sdkBackend = ApproovSDKBackend()

    // the persistent configuration, kept in Application Support/approov and tied to the version of the app
    private static let persistentConfiguration = ApproovPersistentConfiguration(
        directory: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("approov", isDirectory: true),
        appVersion: appVersion())

    // the version of the app as build number "/" version name, from the main bundle
    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String ?? ""
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        return build + "/" + version
    }

    // the location of the bundled approov.config, or nil if the app has none
    private static func bundledConfigURL() -> URL? {
        return Bundle.main.url(forResource: "approov", withExtension: "config")
    }

    /**
     * Initializes the service layer with the Approov account ID, obtained using
     * `approov sdk -getConfigString` or in the original onboarding email, and activates
     * interception for every URLSession created afterwards. Call this as early as possible in
     * application(_:didFinishLaunchingWithOptions:), since sessions created before this call are
     * not covered unless installInterception was called before they were created. A repeat call
     * with the same account ID and comment changes nothing. An empty account ID enables bypass
     * mode, where requests pass through without any Approov processing;
     * it is ignored once Approov protection is enabled. Note that configuration set before or after
     * this call is never reset.
     *
     * @param config is the Approov account ID, or an empty string for bypass mode
     * @param comment is an optional comment to be passed to the SDK
     * @throws ApproovServiceError if there was a problem
     */
    public static func initialize(_ config: String, comment: String? = nil) throws {
        try ApproovInterceptor.shared.initializeService(
            config: config, comment: comment, backend: sdkBackend,
            defaultUserProperty: serviceVersion,
            reportUserProperty: { Approov.setUserProperty($0) }) { config, comment in
            try Approov.initialize(config, updateConfig: "auto", comment: comment)
        }
    }

    /**
     * Initializes the service layer from the approov.config file in the app's main bundle, with its
     * config and comment, as initialize(_:comment:) does with an explicit account ID. If this call
     * is the first to initialize the service layer, bypass mode included, the other options in the
     * file are then applied, once per process, through the same setters your app can call. A call
     * that finds the layer already initialized applies nothing, and nothing is ever reset. Add the
     * file to the app target, or a different file to each target that needs its own configuration.
     * An unknown key or a bad value is logged and skipped, and does not fail this call. Options
     * stored by setPersistentConfiguration are applied with the file, in place of the same keys.
     *
     * @throws ApproovServiceError if there was a problem, including if the file is missing, unreadable, not a valid
     * JSON object or has no config
     */
    public static func initialize() throws {
        // read and parse the file before any lock is taken
        let url = Bundle.main.url(forResource: "approov", withExtension: "config")
        let configFile = try ApproovConfigFile.read(from: url)
        try ApproovInterceptor.shared.initializeService(
            configFile: configFile, backend: sdkBackend,
            persistentConfiguration: persistentConfiguration,
            defaultUserProperty: serviceVersion,
            reportUserProperty: { Approov.setUserProperty($0) }) { config, comment in
            try Approov.initialize(config, updateConfig: "auto", comment: comment)
        }
    }

    /**
     * Stores options that initialize() applies over the bundled approov.config from the next launch,
     * such as options delivered with an over-the-air update of your app's JavaScript. Nothing
     * changes in the running process, also if initialize() has not run yet. The options are a
     * JSON object with the keys of approov.config, apart from config, comment and devKey, which are
     * refused. Each key replaces the same key of the file whole, so a list replaces the bundled list. A
     * known key with a bad value is refused and nothing is stored, while an unknown key is stored and
     * ignored when applied. The options are deleted at a launch whose bundled approov.config differs in
     * content from the one they were stored with, or whose app version (CFBundleVersion and
     * CFBundleShortVersionString) differs, so a store release never inherits them. Note that
     * initialize(_:comment:) never applies them.
     *
     * @param json is the options as a JSON object of at most 64 KiB
     * @param source is a tag of at most 1024 UTF-8 bytes naming where the options came from, such as an update ID,
     * or nil for none
     * @throws ApproovServiceError if there was a problem, in which case nothing is stored
     */
    public static func setPersistentConfiguration(_ json: String, source: String?) throws {
        try persistentConfiguration.store(json, source: source, bundledFile: bundledConfigURL())
    }

    /**
     * Deletes any options stored by setPersistentConfiguration, so the bundled approov.config alone
     * applies from the next launch. Nothing changes in the running process.
     *
     * @throws ApproovServiceError if there was a problem
     */
    public static func clearPersistentConfiguration() throws {
        try persistentConfiguration.clear()
    }

    /**
     * Gets the source passed to setPersistentConfiguration with the options currently stored. This is
     * what is stored, not what is in force: it includes options stored in this launch, which apply from
     * the next one, and options the next launch may still delete because the bundled approov.config has
     * changed or they cannot be read.
     *
     * @return the source, or nil if no options are stored or they have no source
     */
    public static func persistentConfigurationSource() -> String? {
        return persistentConfiguration.source()
    }

    /**
     * Installs interception of every URLSession created afterwards without initializing, for
     * frameworks that create their sessions before the app can call initialize, such as React
     * Native. Until initialize succeeds the requests of those sessions go out untouched, neither
     * failed nor held, and from then on they are protected like any other. Calling it again changes
     * nothing, and initialize installs interception itself, so apps need not call this.
     */
    public static func installInterception() {
        ApproovInterceptor.shared.installInterception()
    }

    /**
     * Sets the user property reported to the Approov platform in place of serviceVersion, for the
     * Approov packages that host this layer in another framework only, such as
     * "approov-react-native/3.7.0" set by the React Native package. It applies whether it is set
     * before initialize, which then reports it, or after, when it is reported at once. Apps must not
     * call this: it is not part of the public API and may change without notice.
     *
     * @param identity is the name and version of the host framework package, or nil for serviceVersion
     */
    @_spi(HostFramework)
    public static func setHostFrameworkIdentity(_ identity: String?) {
        ApproovInterceptor.shared.setHostFrameworkIdentity(identity, defaultProperty: serviceVersion) {
            Approov.setUserProperty($0)
        }
    }

    /**
     * Determines whether the service layer is installed and processing requests, which is the case
     * once any initialize has succeeded, bypass mode included.
     *
     * @return true if the service layer is enabled, false otherwise
     */
    public static func isApproovServiceEnabled() -> Bool {
        return ApproovInterceptor.shared.isApproovServiceEnabled
    }

    /**
     * Determines whether the Approov SDK is initialized and Approov protection is active. This is
     * false before initialize and in bypass mode.
     *
     * @return true if Approov protection is enabled, false otherwise
     */
    public static func isApproovProtectionEnabled() -> Bool {
        return ApproovInterceptor.shared.isApproovProtectionEnabled
    }

    /**
     * Verifies that Approov interception is installed and positioned ahead of any other
     * URLProtocol-based networking SDK in a freshly created URLSessionConfiguration. A failure is
     * logged, naming whether the interception failed to install or another SDK is ahead of Approov.
     * Call this once after every other networking SDK has initialized, for instance at the end of
     * app launch. It checks the hook only: it is true once installInterception or initialize has
     * installed interception, also before initialize, when requests still go out untouched. Note
     * that the explicit approov-service-urlsession layer can be used for the affected sessions if
     * there is a conflict.
     *
     * @return true if interception is installed first, false otherwise
     */
    @discardableResult
    public static func verifyInterceptionInstalled() -> Bool {
        return ApproovInterceptor.shared.verifyInterceptionInstalled()
    }

    /**
     * Gets counters of the requests forwarded through interception and of the TLS challenges that
     * were pin verified or delegated. These show whether interception is actually exercised, not
     * merely installed.
     *
     * @return ApproovInterceptionDiagnostics holding the current counters
     */
    public static func getInterceptionDiagnostics() -> ApproovInterceptionDiagnostics {
        return ApproovInterceptor.shared.interceptionDiagnostics()
    }

    /**
     * Fetches a current Approov token for the given URL. This is only useful if the token needs
     * to be added for a transport that interception does not cover. This will likely require
     * network access so may take some time to complete, and should not be called from the main
     * thread.
     *
     * @param url is the URL giving the domain for the token fetch
     * @return String of the fetched token
     * @throws ApproovServiceError if there was a problem
     */
    public static func fetchToken(url: String) throws -> String {
        return try ApproovInterceptor.shared.fetchToken(url: url)
    }

    /**
     * Fetches a secure string with the given key. If newDef is not nil then a secure string for
     * the particular app instance may be defined. This will likely require network access so may
     * take some time to complete, and should not be called from the main thread.
     *
     * @param key is the secure string key to be looked up
     * @param newDef is any new definition for the secure string, or nil for lookup only
     * @return secure string or nil if the key is not defined
     * @throws ApproovServiceError if there was a problem
     */
    public static func fetchSecureString(key: String, newDef: String? = nil) throws -> String? {
        return try ApproovInterceptor.shared.fetchSecureString(key: key, newDef: newDef)
    }

    /**
     * Fetches a custom JWT with the given payload. This will likely require network access so
     * may take some time to complete, and should not be called from the main thread.
     *
     * @param payload is the marshaled JSON object for the claims to be included
     * @return custom JWT string or nil if not available
     * @throws ApproovServiceError if there was a problem
     */
    public static func fetchCustomJWT(payload: String) throws -> String? {
        return try ApproovInterceptor.shared.fetchCustomJWT(payload: payload)
    }

    /**
     * Gets the device ID used by Approov to identify the particular device that the SDK is running
     * on.
     *
     * @return String of the device ID
     * @throws ApproovServiceError if there was a problem, including if no device ID is available
     */
    public static func getDeviceID() throws -> String {
        return try ApproovInterceptor.shared.getDeviceID()
    }

    /**
     * Gets the current time in milliseconds since the epoch, adjusted by the offset between the device clock and
     * the clock of the Approov servers that the SDK learns at each attestation. Before the installation's first
     * attestation it is the device clock. A device whose clock is wrong still gets a time the backend agrees with,
     * which is why message signatures take their created and expires times from it. Use it for timestamps of your
     * own that your backend compares with its clock. With an Approov SDK earlier than 3.7.0 it is the device clock.
     *
     * @return the current time in milliseconds since the epoch, adjusted to the Approov servers' clock
     * @throws ApproovServiceError if there was a problem, such as Approov protection not being enabled
     */
    public static func getServerAdjustedCurrentTimeMS() throws -> Int64 {
        return try ApproovInterceptor.shared.getServerAdjustedCurrentTimeMS()
    }

    /**
     * Gets the Attestation Response Code (ARC) of the most recent token, secure string or custom
     * JWT fetch made by this layer. This performs no fetch, so it can be read after a rejected
     * request to correlate with your backend.
     *
     * @return ARC of the last fetch, or an empty string if there was none or ARC is not enabled for the account
     */
    public static func getLastARC() -> String {
        return ApproovInterceptor.shared.getLastARC()
    }

    /**
     * Sets the header that the Approov token is added on, as well as an optional prefix String
     * (such as "Bearer "). By default the token is provided on "Approov-Token" with no prefix.
     * Note that the token header is only added when the token fetch succeeds.
     *
     * @param header is the header to place the Approov token on
     * @param prefix is any prefix String for the Approov token header, or nil for none
     */
    public static func setTokenHeader(_ header: String, prefix: String? = nil) {
        ApproovInterceptor.shared.setTokenHeader(header, prefix: prefix)
    }

    /**
     * Gets the header that is used to hold the Approov token.
     *
     * @return String of the header used for the Approov token
     */
    public static func getTokenHeader() -> String {
        return ApproovInterceptor.shared.getTokenHeader()
    }

    /**
     * Gets the prefix that is added before the Approov token in the header.
     *
     * @return String of the prefix added before the Approov token, or an empty string for none
     */
    public static func getTokenPrefix() -> String {
        return ApproovInterceptor.shared.getTokenPrefix()
    }

    /**
     * Sets the header that the Approov token is added on. Deprecated: use setTokenHeader instead.
     *
     * @param header is the header to place the Approov token on
     * @param prefix is any prefix String for the Approov token header
     */
    @available(*, deprecated, renamed: "setTokenHeader(_:prefix:)")
    public static func setApproovHeader(_ header: String, prefix: String = "") {
        ApproovInterceptor.shared.setTokenHeader(header, prefix: prefix)
    }

    /**
     * Sets the header that reports the Approov token fetch status on every request processed by
     * Approov. By default this is "Approov-Status". The value is the fetch status name, never
     * converted, such as "SUCCESS" or "NO_NETWORK", as on Android. Note that it is never sent to a host that is not added
     * to Approov or to a secrets-only API, and after a failed token fetch it is only sent to a
     * host listed in the Approov pins.
     *
     * @param header is the header to place the status on, or nil to stop adding it
     */
    public static func setStatusHeader(_ header: String?) {
        ApproovInterceptor.shared.setStatusHeader(header)
    }

    /**
     * Gets the header that is used to report the Approov token fetch status.
     *
     * @return String of the status header or nil if disabled
     */
    public static func getStatusHeader() -> String? {
        return ApproovInterceptor.shared.getStatusHeader()
    }

    /**
     * Sets a binding header that may be present on requests being made. A header should be chosen
     * whose value is unchanging for most requests (such as an Authorization header). If the header
     * is present, then a hash of the header value is included in the issued Approov tokens to bind
     * them to the value. This may then be verified by your backend API integration. A header
     * registered for secure string substitution cannot also be the binding header.
     *
     * @param header is the header to use for Approov token binding, or nil to remove it
     * @throws ApproovServiceError if the header is already a substitution header, in any case
     */
    public static func setBindingHeader(_ header: String?) throws {
        try ApproovInterceptor.shared.setBindingHeader(header)
    }

    /**
     * Gets any current binding header.
     *
     * @return binding header or nil if not set
     */
    public static func getBindingHeader() -> String? {
        return ApproovInterceptor.shared.getBindingHeader()
    }

    /**
     * Sets the debug header that carries the SDK trace ID. By default this is "Approov-TraceID".
     *
     * @param header is the header to place the trace ID on, or nil to stop adding it
     */
    public static func setTraceIDHeader(_ header: String?) {
        ApproovInterceptor.shared.setTraceIDHeader(header)
    }

    /**
     * Gets the header that carries the SDK trace ID.
     *
     * @return String of the trace ID header or nil if disabled
     */
    public static func getTraceIDHeader() -> String? {
        return ApproovInterceptor.shared.getTraceIDHeader()
    }

    /**
     * Sets the debug header that carries the SDK trace ID. Deprecated: use setTraceIDHeader
     * instead.
     *
     * @param header is the header to place the trace ID on, or nil to stop adding it
     */
    @available(*, deprecated, renamed: "setTraceIDHeader(_:)")
    public static func setApproovTraceIDHeader(_ header: String?) {
        ApproovInterceptor.shared.setTraceIDHeader(header)
    }

    /**
     * Sets the service mutator that makes the request decisions. This may be `.CLOSE_FAILURE`, the
     * 3.5.x decisions, `.ALWAYS_PROCEED`, which never aborts a request, or your own implementation.
     * Note that `.DEFAULT` points to the default behaviour of the release, which is `.ALWAYS_PROCEED`,
     * so name one of the other two if a fixed behaviour is required.
     *
     * @param mutator is the service mutator to be used, or nil to use `.DEFAULT`
     */
    public static func setServiceMutator(_ mutator: ApproovServiceMutator?) {
        ApproovInterceptor.shared.setServiceMutator(mutator)
    }

    /**
     * Gets the current service mutator.
     *
     * @return ApproovServiceMutator currently making the request decisions
     */
    public static func getServiceMutator() -> ApproovServiceMutator {
        return ApproovInterceptor.shared.getServiceMutator()
    }

    /**
     * Enables message signing, so every request carrying the Approov token header is signed with
     * both the install and the account signature, or as the given factory configures. Message
     * signing is on by default, with both signatures, and is not changed by initialize. Note that if
     * a signature cannot be produced the request proceeds without it.
     *
     * @param defaultFactory is the factory for the signature parameters, or nil for the default factory
     */
    public static func enableMessageSigning(_ defaultFactory: SignatureParametersFactory? = nil) {
        ApproovInterceptor.shared.enableMessageSigning(defaultFactory)
    }

    /**
     * Disables message signing. Any factories are kept for a later enableMessageSigning.
     */
    public static func disableMessageSigning() {
        ApproovInterceptor.shared.disableMessageSigning()
    }

    /**
     * Determines whether message signing is enabled.
     *
     * @return true if protected requests are signed, false otherwise
     */
    public static func isMessageSigningEnabled() -> Bool {
        return ApproovInterceptor.shared.isMessageSigningEnabled()
    }

    /**
     * Sets the factory used to sign requests to a particular host instead of the default factory.
     *
     * @param hostName is the host name, matched without regard to case and without a port
     * @param factory is the factory for the host's signature parameters, or nil to remove it
     */
    public static func putMessageSigningHostFactory(hostName: String, factory: SignatureParametersFactory?) {
        ApproovInterceptor.shared.putMessageSigningHostFactory(hostName: hostName, factory: factory)
    }

    /**
     * Gets the type of the default signature parameters factory, or of the factory of one host, so
     * that an Approov package hosting this layer in another framework can tell an app's own subclass
     * from the standard factory without calling it. Apps must not call this: it is not part of the
     * public API and may change without notice.
     *
     * @param hostName is the host name, matched as by putMessageSigningHostFactory, or nil for the default factory
     * @return the type of the factory, or nil if there is none
     */
    @_spi(HostFramework)
    public static func getMessageSigningFactoryClass(hostName: String?) -> SignatureParametersFactory.Type? {
        return ApproovInterceptor.shared.messageSigningFactoryType(hostName: hostName)
    }

    /**
     * Sets a handler for the TLS and authentication challenges that interception cannot deliver to
     * your own session delegate. These are client certificate and HTTP authentication challenges,
     * server trust challenges for hosts without Approov pins, and server trust challenges for hosts
     * with Approov pins after the Approov check has passed, so your own logic can narrow trust
     * further. Without a handler these get the platform default handling. Install this if your app
     * relies on a session delegate for client certificates or its own pinning.
     *
     * @param handler is the challenge handler to be used, or nil to remove it
     */
    public static func setChallengeHandler(_ handler: ApproovChallengeHandler?) {
        ApproovInterceptor.shared.setChallengeHandler(handler)
    }

    /**
     * Sets the level of logging from the service layer.
     *
     * @param level is the logging level to be used
     */
    public static func setLoggingLevel(_ level: ApproovLogLevel) {
        ApproovInterceptor.shared.setLoggingLevel(level)
    }

    /**
     * Adds an exclusion URL regular expression. If a URL for a request matches this regular
     * expression then it is not subject to any Approov protection.
     *
     * @param pattern is the regular expression that will be compared against URLs for exclusion
     * @throws ApproovServiceError if there was a problem, including if the pattern does not compile
     */
    public static func addExclusionURLRegex(_ pattern: String) throws {
        try ApproovInterceptor.shared.addExclusionURLRegex(pattern)
    }

    /**
     * Removes an exclusion URL regular expression previously added using addExclusionURLRegex.
     *
     * @param pattern is the regular expression that will be compared against URLs for exclusion
     */
    public static func removeExclusionURLRegex(_ pattern: String) {
        ApproovInterceptor.shared.removeExclusionURLRegex(pattern)
    }

    /**
     * Gets the exclusion URL regular expressions.
     *
     * @return map of each pattern, as added, to its compiled regular expression
     */
    public static func getExclusionURLRegexs() -> [String: NSRegularExpression] {
        return ApproovInterceptor.shared.getExclusionURLRegexs()
    }

    /**
     * Adds the name of a header which should be subject to secure strings substitution. This
     * means that if the header is present then the value will be used as a key to look up a
     * secure string value which will be substituted into the header value instead. This allows
     * easy migration to the use of secure strings. A required prefix may be specified to deal
     * with cases such as the use of "Bearer " prefixed before values in an authorization header.
     * If the secure string fetch fails and the request continues, the status of the fetch, such
     * as "rejected" or "unknown_key", is sent after the prefix instead. Header names match without
     * regard to case. The binding header cannot also be a substitution header.
     *
     * @param header is the header to be marked for substitution
     * @param requiredPrefix is any required prefix to the value being substituted, or an empty string for none
     * @throws ApproovServiceError if the header is already the binding header, in any case
     */
    public static func addSubstitutionHeader(_ header: String, requiredPrefix: String = "") throws {
        try ApproovInterceptor.shared.addSubstitutionHeader(header, requiredPrefix: requiredPrefix)
    }

    /**
     * Removes a header previously added using addSubstitutionHeader.
     *
     * @param header is the header to be removed for substitution
     */
    public static func removeSubstitutionHeader(_ header: String) {
        ApproovInterceptor.shared.removeSubstitutionHeader(header)
    }

    /**
     * Gets all of the substitution headers that are currently setup.
     *
     * @return map of each header name, as last added, to its required prefix
     */
    public static func getSubstitutionHeaders() -> [String: String] {
        return ApproovInterceptor.shared.getSubstitutionHeaders()
    }

    /**
     * Adds a key name for a query parameter that should be subject to secure strings substitution.
     * This means that if the query parameter is present in a URL then the value will be used as a
     * key to look up a secure string value which will be substituted as the query parameter value
     * instead. This allows easy migration to the use of secure strings. If the secure string fetch
     * fails and the request continues, the status of the fetch, such as "rejected" or
     * "unknown_key", is sent as the value instead.
     *
     * @param key is the query parameter key name to be added for substitution
     */
    public static func addSubstitutionQueryParam(_ key: String) {
        ApproovInterceptor.shared.addSubstitutionQueryParam(key)
    }

    /**
     * Removes a query parameter key name previously added using addSubstitutionQueryParam.
     *
     * @param key is the query parameter key name to be removed for substitution
     */
    public static func removeSubstitutionQueryParam(_ key: String) {
        ApproovInterceptor.shared.removeSubstitutionQueryParam(key)
    }

    /**
     * Gets all of the substitution query parameters that are currently setup.
     *
     * @return set of the query parameter key names
     */
    public static func getSubstitutionQueryParams() -> Set<String> {
        return ApproovInterceptor.shared.getSubstitutionQueryParams()
    }

    /**
     * Sets a hash of the given data value into any future Approov tokens obtained in the
     * pay claim. If the data values are transmitted to the API backend along with the Approov
     * token then this allows the backend to check that the data value was indeed known to the
     * app at the time of the token fetch and hasn't been spoofed.
     *
     * @param data is the data whose SHA256 hash is to be included in future Approov tokens
     * @throws ApproovServiceError if there was a problem
     */
    public static func setDataHashInToken(_ data: String) throws {
        try ApproovInterceptor.shared.setDataHashInToken(data)
    }

    /**
     * Sets a development key indicating that the app is a development version and it should
     * pass attestation even if the app is not registered or it is running on an emulator.
     *
     * @param devKey is the development key to be used
     * @throws ApproovServiceError if there was a problem
     */
    public static func setDevKey(_ devKey: String) throws {
        try ApproovInterceptor.shared.setDevKey(devKey)
    }

    /**
     * Sets the install attributes for this app installation, which are associated with it on
     * future Approov token fetches. The next token fetch does not use a cached token, so the
     * attributes reach the server, which accepts them only if they are signed, within their expiry
     * and bound to this device ID.
     *
     * @param attrs is the signed JWT holding the new install attributes
     * @throws ApproovServiceError if there was a problem
     */
    public static func setInstallAttributes(_ attrs: String) throws {
        try ApproovInterceptor.shared.setInstallAttributes(attrs)
    }

    /**
     * Gets the install message signature for the given message. This uses an app install specific
     * message signing key (ECDSA P-256) that is generated the first time an app launches.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded ASN.1 DER signature or nil if not available
     * @throws ApproovServiceError if there was a problem
     */
    public static func getInstallMessageSignature(message: String) throws -> String? {
        return try ApproovInterceptor.shared.installMessageSignature(message: message)
    }

    /**
     * Gets the account message signature for the given message. This uses an account specific
     * message signing key (HMAC-SHA256) that is transmitted to the SDK after a successful fetch
     * if the facility is enabled for the account.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded signature or nil if not available
     * @throws ApproovServiceError if there was a problem
     */
    public static func getAccountMessageSignature(message: String) throws -> String? {
        return try ApproovInterceptor.shared.accountMessageSignature(message: message)
    }

    /**
     * Gets the account message signature for the given message. Deprecated: use
     * getAccountMessageSignature instead, which returns the same signature and throws if Approov
     * protection is not enabled.
     *
     * @param message is the message whose content is to be signed
     * @return base64 encoded signature or nil if not available
     */
    @available(*, deprecated, message: "Use getAccountMessageSignature(message:), which returns the same signature and throws while Approov protection is not enabled.")
    public static func getMessageSignature(message: String) -> String? {
        return ApproovInterceptor.shared.deprecatedMessageSignature(message: message)
    }
}

// ApproovSDKBackend binds the SDK-free interception core to the Approov SDK; it is stateless, so it is
// Sendable through the protocol
final class ApproovSDKBackend: ApproovBackend {

    func fetchToken(url: String) -> ApproovTokenResult {
        return Self.map(Approov.fetchTokenAndWait(url))
    }

    @discardableResult
    func fetchConfig() -> String? {
        return Approov.fetchConfig()
    }

    func pins(pinType: String) -> [String: [String]]? {
        return Approov.getPins(pinType)
    }

    func setDataHashInToken(_ data: String) {
        Approov.setDataHashInToken(data)
    }

    func fetchSecureString(key: String, newDef: String?) -> ApproovTokenResult {
        return Self.map(Approov.fetchSecureStringAndWait(key, newDef))
    }

    func fetchCustomJWT(payload: String) -> ApproovTokenResult {
        return Self.map(Approov.fetchCustomJWTAndWait(payload))
    }

    func deviceID() -> String? {
        return Approov.getDeviceID()
    }

    // +getServerAdjustedCurrentTimeMS exists from SDK 3.7.0; it is looked up at run time, so the package uses it when
    // the SDK has it and the device clock otherwise. The SDK returns 0 when it cannot give the time (before
    // initialize), which is reported as unavailable.
    func serverAdjustedCurrentTimeMS() -> Int64? {
        let selector = NSSelectorFromString("getServerAdjustedCurrentTimeMS")
        let sdk: AnyObject = Approov.self
        guard sdk.responds(to: selector), let implementation = sdk.method(for: selector) else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        typealias ServerAdjustedTime = @convention(c) (AnyObject, Selector) -> Int64
        let time = unsafeBitCast(implementation, to: ServerAdjustedTime.self)(sdk, selector)
        return (time > 0) ? time : nil
    }

    func setDevKey(_ devKey: String) {
        Approov.setDevKey(devKey)
    }

    func setInstallAttributes(_ attrs: String) {
        Approov.setInstallAttrsInToken(attrs)
    }

    func installMessageSignature(message: String) -> String? {
        return Approov.getInstallMessageSignature(message)
    }

    func accountMessageSignature(message: String) -> String? {
        return Approov.getMessageSignature(message)
    }

    static func map(_ result: ApproovTokenFetchResult) -> ApproovTokenResult {
        // the SDK declares the result nonnull, but a nil result would read as SUCCESS with an empty
        // token, so report INTERNAL_ERROR instead
        guard unsafeBitCast(result, to: UnsafeRawPointer?.self) != nil else {
            return ApproovTokenResult(status: .internalError)
        }
        return ApproovTokenResult(status: map(result.status),
                                      token: result.token,
                                      secureString: result.secureString,
                                      traceID: result.traceID,
                                      arc: result.arc,
                                      rejectionReasons: result.rejectionReasons,
                                      isConfigChanged: result.isConfigChanged)
    }

    // map the statuses by case, and MITM_DETECTED by the SDK's own name for it
    private static func map(_ status: ApproovTokenFetchStatus) -> ApproovTokenStatus {
        switch status {
        case .success: return .success
        case .noNetwork: return .noNetwork
        case .poorNetwork: return .poorNetwork
        case .noApproovService: return .noApproovService
        case .badURL: return .badURL
        case .unknownURL: return .unknownURL
        case .unprotectedURL: return .unprotectedURL
        case .notInitialized: return .notInitialized
        case .rejected: return .rejected
        case .disabled: return .disabled
        case .unknownKey: return .unknownKey
        case .badKey: return .badKey
        case .badPayload: return .badPayload
        case .internalError: return .internalError
        default: return ApproovTokenStatus(sdkName: Approov.string(from: status))
        }
    }
}

#endif
