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

// Ported from approov-service-urlsession (MIT License, Copyright (c) 2025-present, Approov Ltd),
// adapted to the SDK-free core.

import CryptoKit
import RawStructuredFieldValues
import Foundation
import os.log

/**
 * Provides HTTP message signing (RFC 9421) of the requests protected by Approov, which is on by default
 * and is switched off with ApproovService.disableMessageSigning. Every request carrying the Approov token
 * header is signed last, so the signature covers what is sent. The default factory produces both the install signature
 * ("install", ecdsa-p256-sha256) and the account signature ("account", hmac-sha256) as members of the
 * same Signature and Signature-Input headers, and your backend chooses which it verifies. A signature
 * that cannot be produced is left out and the request proceeds, but a body digest configured as required
 * that cannot be generated, or an unsupported algorithm, fails the request.
 */
public final class ApproovDefaultMessageSigning: CustomStringConvertible, @unchecked Sendable {

    /**
     * Constant for the SHA-256 digest algorithm (used for body digests).
     */
    public static let DIGEST_SHA256 = "sha-256"

    /**
     * Constant for the SHA-512 digest algorithm (used for body digests).
     */
    public static let DIGEST_SHA512 = "sha-512"

    /**
     * Constant for the ECDSA P-256 with SHA-256 algorithm (used when signing with install private key).
     */
    public static let ALG_ES256 = "ecdsa-p256-sha256"

    /**
     * Constant for the HMAC with SHA-256 algorithm (used when signing with the account signing key).
     */
    public static let ALG_HS256 = "hmac-sha256"

    /**
     * Signature dictionary member name for the install message signature.
     */
    public static let SIG_ID_INSTALL = "install"

    /**
     * Signature dictionary member name for the account message signature.
     */
    public static let SIG_ID_ACCOUNT = "account"

    // the lock guarding the factories
    private let lock = NSLock()

    // the factory for every host without a factory of its own, which starts as the default factory, or nil to sign
    // nothing for such hosts
    private var defaultFactory: SignatureParametersFactory? =
        ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()

    // the host specific factories, keyed by the lowercase host name without a port
    private var hostFactories: [String: SignatureParametersFactory] = [:]

    // the missing signature conditions already logged above debug in this process, keyed by the signature
    // member name, or by noSignatureKey when no signature was produced
    private var missingLogged: Set<String> = []

    // the missingLogged key for a request that proceeds with no signature at all
    private static let noSignatureKey = "none"

    init() {}

    public var description: String {
        return "ApproovDefaultMessageSigning"
    }

    /**
     * Sets the factory used for every host without a factory of its own.
     *
     * @param factory is the default factory, or nil to sign nothing for such hosts
     */
    func setDefaultFactory(_ factory: SignatureParametersFactory?) {
        lock.lock()
        defer { lock.unlock() }
        defaultFactory = factory
    }

    /**
     * Sets the factory used for requests to a particular host instead of the default factory.
     *
     * @param hostName is the host name, matched without regard to case and without a port
     * @param factory is the factory for the host, or nil to remove it
     */
    func putHostFactory(hostName: String, factory: SignatureParametersFactory?) {
        lock.lock()
        defer { lock.unlock() }
        hostFactories[hostName.lowercased()] = factory
    }

    // the factory for every host without a factory of its own, or nil
    var defaultFactoryValue: SignatureParametersFactory? {
        lock.lock()
        defer { lock.unlock() }
        return defaultFactory
    }

    // the host's own factory, matched as by putHostFactory, or nil if it has none
    func hostFactory(hostName: String) -> SignatureParametersFactory? {
        lock.lock()
        defer { lock.unlock() }
        return hostFactories[hostName.lowercased()]
    }

    // puts back the default factory, forgets the host factories and the missing signatures logged, for tests only
    func reset() {
        let factory = ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()
        lock.lock()
        defer { lock.unlock() }
        defaultFactory = factory
        hostFactories = [:]
        missingLogged = []
    }

    /**
     * Logs a missing signature condition at the given level the first time it occurs in this process,
     * and at debug after that, so an account without a signing key does not log on every request.
     *
     * @param key is the condition, which is the signature member name or noSignatureKey
     * @param level is the logging level for the first occurrence
     * @param message is the message to be logged, which must never include a value
     * @param detail is any error, whose description is logged private, or nil for none
     */
    private func logMissing(_ key: String, _ level: ApproovLogLevel, _ message: String, detail: Error? = nil) {
        lock.lock()
        let first = missingLogged.insert(key).inserted
        lock.unlock()
        ApproovLog.log(first ? level : .debug, "Message signing: " + message,
                       detail: detail.map { String(describing: $0) })
    }

    // gets the factory for a host, or the default factory if it has none of its own
    private func factory(forHost host: String) -> SignatureParametersFactory? {
        lock.lock()
        defer { lock.unlock() }
        return hostFactories[host.lowercased()] ?? defaultFactory
    }

    /**
     * Signs a request protected by Approov. Only a request carrying the Approov token header to a
     * host with a factory is signed, and any other failure proceeds with what could be signed.
     *
     * @param request is the request to be signed
     * @param changes is the record of the changes Approov made to the request
     * @return the signed request
     * @throws URLError if a required body digest cannot be generated or an algorithm is not supported
     */
    func sign(_ request: URLRequest, changes: ApproovRequestMutations) throws -> URLRequest {
        guard changes.getTokenHeaderKey() != nil else { return request }
        // choose the factory by host alone, read from the URL string as sent
        let provider = ApproovURLSessionComponentProvider(request: request)
        guard let factory = factory(forHost: provider.getHost()) else { return request }

        // the parameters only fail closed for a required body digest, and otherwise proceed unsigned, which
        // includes any error an app's own factory throws
        let built: SignatureParameters?
        do {
            built = try factory.buildSignatureParameters(provider: provider, changes: changes)
        } catch let error as RequiredBodyDigestError {
            throw ApproovRequestPathError.configuration("Message signing: " + error.message)
        } catch {
            return failOpen("failed to build signature parameters, proceeding unsigned", request, detail: error)
        }
        // a factory that returns no parameters leaves the request unsigned, which is its choice and not logged
        guard let params = built else { return request }

        // an algorithm set on the parameters gives that single signature, or otherwise the factory's algorithms
        var algs: [String] = []
        for alg in params.getAlg().map({ [$0] }) ?? factory.getAlgs() where !algs.contains(alg) {
            algs.append(alg)
        }
        // no usable algorithm sends the request unsigned, with an error logged
        guard !algs.isEmpty else {
            return failOpen("no usable algorithm, proceeding unsigned: empty algorithm list", request)
        }
        for alg in algs where (alg != Self.ALG_ES256) && (alg != Self.ALG_HS256) {
            throw ApproovRequestPathError.configuration("Message signing: unsupported algorithm identifier: \(alg)")
        }

        // one signature per algorithm over the same components, each with its own base since the base
        // includes the algorithm; never log a base, since it contains the Approov token
        var signatures: [(String, Data)] = []
        var inputs: [(String, InnerList)] = []
        var bases: [(String, String)] = []
        var missing: [(String, SignatureUnavailable)] = []
        for alg in algs {
            let algParams = SignatureParameters(base: params).setAlg(alg)
            let install = alg == Self.ALG_ES256
            let member = install ? Self.SIG_ID_INSTALL : Self.SIG_ID_ACCOUNT
            let base: String
            let input: InnerList
            do {
                base = try SignatureBaseBuilder(sigParams: algParams, ctx: provider).createSignatureBase()
                input = try algParams.toComponentValue()
            } catch {
                return failOpen("failed to build the signature base, proceeding unsigned", request, detail: error)
            }
            switch install ? installSignature(base) : accountSignature(base) {
            case .success(let signature):
                signatures.append((member, signature))
                inputs.append((member, input))
                bases.append((member, base))
            case .failure(let unavailable):
                missing.append((member, unavailable))
            }
        }
        // no signature at all is an error, and one missing signature next to the other a warning, each logged
        // once per process so an account without a signing key does not log on every request
        guard !signatures.isEmpty else {
            let reasons = missing.map { $0.1.reason }.joined(separator: ", ")
            logMissing(Self.noSignatureKey, .error, "no signature produced, proceeding unsigned: " + reasons,
                       detail: missing.compactMap { $0.1.detail }.first)
            return request
        }
        for (member, unavailable) in missing {
            logMissing(member, .warning, "skipping the \(member) signature: " + unavailable.reason,
                       detail: unavailable.detail)
        }

        // the request the provider holds carries any Content-Digest the factory added
        var signed = provider.getRequest()
        do {
            guard let signatureHeader = try SFV.serializeByteSequenceDictionary(signatures),
                  let inputHeader = try SFV.serializeInnerListDictionary(inputs) else {
                return failOpen("failed to add the signatures, proceeding unsigned", request)
            }
            // replace any value already present
            signed.setValue(signatureHeader, forHTTPHeaderField: "Signature")
            signed.setValue(inputHeader, forHTTPHeaderField: "Signature-Input")
        } catch {
            return failOpen("failed to add the signatures, proceeding unsigned", request, detail: error)
        }
        if params.isDebugMode() {
            let digests = bases.map { ($0.0, Data(SHA256.hash(data: Data($0.1.utf8)))) }
            // the optional debug digest header must not drop a valid signature on failure
            if let digestHeader = try? SFV.serializeByteSequenceDictionary(digests) {
                signed.setValue(digestHeader, forHTTPHeaderField: "Signature-Base-Digest")
            }
        }
        // never log the full request, since it contains the Approov token
        return signed
    }

    // logs a signing failure, with any error description, which could quote a component value, as private
    private func logError(_ message: String, detail: Error? = nil) {
        ApproovLog.log(.error, "Message signing: " + message, detail: detail.map { String(describing: $0) })
    }

    // logs a signing failure and returns the request unsigned
    private func failOpen(_ message: String, _ request: URLRequest, detail: Error? = nil) -> URLRequest {
        logError(message, detail: detail)
        return request
    }

    /**
     * Gets the install signature in the raw 64 byte form required for ecdsa-p256-sha256, from the
     * base64 ASN.1 DER the SDK returns.
     *
     * @param message is the signature base to be signed
     * @return the raw signature, or the reason it is not available or is malformed
     */
    private func installSignature(_ message: String) -> Result<Data, SignatureUnavailable> {
        // signing only runs while protection is enabled, so any error is treated as unavailable
        guard let base64 = (try? ApproovInterceptor.shared.installMessageSignature(message: message)) ?? nil,
              !base64.isEmpty else {
            return .failure(SignatureUnavailable(reason: "install signature unavailable"))
        }
        guard let der = Data(base64Encoded: base64) else {
            return .failure(SignatureUnavailable(reason: "install signature not base64"))
        }
        do {
            return .success(try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation)
        } catch {
            return .failure(SignatureUnavailable(reason: "install signature not ASN.1 DER ES256", detail: error))
        }
    }

    /**
     * Gets the account signature (HMAC-SHA256).
     *
     * @param message is the signature base to be signed
     * @return the raw signature, or the reason it is not available
     */
    private func accountSignature(_ message: String) -> Result<Data, SignatureUnavailable> {
        guard let base64 = (try? ApproovInterceptor.shared.accountMessageSignature(message: message)) ?? nil,
              !base64.isEmpty else {
            return .failure(SignatureUnavailable(reason: "account signature unavailable"))
        }
        guard let raw = Data(base64Encoded: base64) else {
            return .failure(SignatureUnavailable(reason: "account signature not base64"))
        }
        return .success(raw)
    }

    /**
     * SHA256 of given input bytes.
     *
     * @param data is the input data
     * @return the hash data
     */
    static func sha256(data: Data) -> Data {
        return Data(SHA256.hash(data: data))
    }

    /**
     * Generates the default SignatureParametersFactory, producing both the install and the account
     * signature over @method, @target-uri, the Approov token header, the trace ID and status headers,
     * Authorization, Content-Length and Content-Type when present, and a sha-256 Content-Digest if
     * the body can be digested, with a created timestamp and an expiry of 15 seconds.
     *
     * @param baseParametersOverride is the base parameters to be used, or nil for the default ones
     * @return SignatureParametersFactory with the default settings
     */
    public static func generateDefaultSignatureParametersFactory(baseParametersOverride: SignatureParameters? = nil) -> SignatureParametersFactory {
        // default expiry seconds, which must encompass the worst case request retry time and clock skew
        let defaultExpiresLifetime: Int64 = 15
        let baseParameters: SignatureParameters

        if let override = baseParametersOverride {
            baseParameters = override
        } else {
            baseParameters = SignatureParameters()
                .addComponentIdentifier(ApproovURLSessionComponentProvider.DC_METHOD)
                .addComponentIdentifier(ApproovURLSessionComponentProvider.DC_TARGET_URI)
        }

        let defaultSignatureParametersFactory = SignatureParametersFactory()
            .setBaseParameters(baseParameters)
            .setUseInstallAndAccountMessageSigning()
            .setAddCreated(true)
            .setExpiresLifetime(defaultExpiresLifetime)
            .setAddApproovTokenHeader(true)
            .setAddApproovTraceIDHeader(true)
            .setAddApproovStatusHeader(true)
            .addOptionalHeaders(["Authorization", "Content-Length", "Content-Type"])
        do {
            _ = try defaultSignatureParametersFactory.setBodyDigestConfig(ApproovDefaultMessageSigning.DIGEST_SHA256, required: false)
        } catch {
            // DIGEST_SHA256 is a supported body digest algorithm, so this never throws
            if ApproovInterceptor.shared.loggingLevel >= .error {
                os_log("ApproovService: Message signing: default body digest algorithm not set", type: .error)
            }
        }
        return defaultSignatureParametersFactory
    }
}

// a body digest configured as required could not be generated, which fails the request
struct RequiredBodyDigestError: Error {
    let message: String
}

// a signature the SDK could not give, with the reason and any error, whose description could quote a value
struct SignatureUnavailable: Error {
    let reason: String
    var detail: Error?
}

/**
 * Factory class for creating per-request SignatureParameters with configurable settings. A new factory
 * produces both the install and the account signature. Note that a factory must be fully configured
 * before it is passed to enableMessageSigning or putMessageSigningHostFactory.
 * <p>
 * Your app may subclass the factory and override buildSignatureParameters to decide the signature of
 * each request, such as different covered components for some paths of a host or no signature at all.
 * One factory is shared by every request it applies to, so an override is called for many requests at
 * the same time on different threads: it must be thread-safe, guarding any state of its own, and it
 * must not block, since each call holds up the request it is made for.
 */
open class SignatureParametersFactory: @unchecked Sendable {
    private var baseParameters: SignatureParameters?
    private var bodyDigestAlgorithm: String?
    private var bodyDigestRequired: Bool = false

    // internal only so tests can reach the state with no algorithm, which the public methods never produce
    var useInstallMessageSigning: Bool = true
    var useAccountMessageSigning: Bool = true
    private var addCreated: Bool = false
    private var expiresLifetime: Int64 = 0
    private var addApproovTokenHeader: Bool = false
    private var addApproovTraceIDHeader: Bool = false
    private var addApproovStatusHeader: Bool = false
    private var optionalHeaders: [String] = []

    public init() {}

    /**
     * Sets the base parameters for the factory.
     *
     * @param baseParameters is the base parameters to be used
     * @return the factory for method chaining
     */
    public func setBaseParameters(_ baseParameters: SignatureParameters) -> SignatureParametersFactory {
        self.baseParameters = baseParameters
        return self
    }

    /**
     * Sets the body digest configuration.
     *
     * @param bodyDigestAlgorithm is the digest algorithm, or nil for no body digest
     * @param required is true if the request should fail when the digest cannot be generated
     * @return the factory for method chaining
     * @throws ApproovServiceError if the algorithm is not supported
     */
    public func setBodyDigestConfig(_ bodyDigestAlgorithm: String?, required: Bool) throws -> SignatureParametersFactory {
        if let algorithm = bodyDigestAlgorithm {
            guard (algorithm == ApproovDefaultMessageSigning.DIGEST_SHA256) ||
                  (algorithm == ApproovDefaultMessageSigning.DIGEST_SHA512) else {
                throw ApproovServiceError.permanentError(message: "Unsupported body digest algorithm: \(algorithm)")
            }
            self.bodyDigestAlgorithm = algorithm
            self.bodyDigestRequired = required
        } else {
            // no algorithm turns the body digest off, as on Android
            self.bodyDigestAlgorithm = nil
            self.bodyDigestRequired = false
        }
        return self
    }

    /**
     * Sets the factory to produce only the install (ecdsa-p256-sha256) signature.
     *
     * @return the factory for method chaining
     */
    public func setUseInstallMessageSigning() -> SignatureParametersFactory {
        self.useInstallMessageSigning = true
        self.useAccountMessageSigning = false
        return self
    }

    /**
     * Sets the factory to produce only the account (hmac-sha256) signature.
     *
     * @return the factory for method chaining
     */
    public func setUseAccountMessageSigning() -> SignatureParametersFactory {
        self.useInstallMessageSigning = false
        self.useAccountMessageSigning = true
        return self
    }

    /**
     * Sets the factory to produce both signatures, as members "install" and "account" of the same
     * Signature and Signature-Input headers, which is the default.
     *
     * @return the factory for method chaining
     */
    public func setUseInstallAndAccountMessageSigning() -> SignatureParametersFactory {
        self.useInstallMessageSigning = true
        self.useAccountMessageSigning = true
        return self
    }

    /**
     * Gets the signature algorithms of the factory, in the order the signatures are added. If there
     * are none then a request is sent unsigned with an error logged. These are the algorithms of every
     * request the factory applies to whose signature parameters have no algorithm set, whichever
     * factory built those parameters, so a subclass that leaves the building to another factory may
     * override this to return the algorithms of that factory.
     *
     * @return the list of signature algorithms
     */
    open func getAlgs() -> [String] {
        var algs: [String] = []
        if useInstallMessageSigning {
            algs.append(ApproovDefaultMessageSigning.ALG_ES256)
        }
        if useAccountMessageSigning {
            algs.append(ApproovDefaultMessageSigning.ALG_HS256)
        }
        return algs
    }

    /**
     * Sets whether the "created" field should be added to the signature parameters. It holds the time from
     * ApproovService.getServerAdjustedCurrentTimeMS(), so it agrees with the backend's clock.
     *
     * @param addCreated is true to add the created field
     * @return the factory for method chaining
     */
    public func setAddCreated(_ addCreated: Bool) -> SignatureParametersFactory {
        self.addCreated = addCreated
        return self
    }

    /**
     * Sets the expiration lifetime of the signature, counted from the time
     * ApproovService.getServerAdjustedCurrentTimeMS() gives.
     *
     * @param expiresLifetime is the lifetime in seconds, or 0 or less for no expiration
     * @return the factory for method chaining
     */
    public func setExpiresLifetime(_ expiresLifetime: Int64) -> SignatureParametersFactory {
        self.expiresLifetime = expiresLifetime
        return self
    }

    /**
     * Sets whether the Approov token header should be covered by the signature.
     *
     * @param addApproovTokenHeader is true to cover the Approov token header
     * @return the factory for method chaining
     */
    public func setAddApproovTokenHeader(_ addApproovTokenHeader: Bool) -> SignatureParametersFactory {
        self.addApproovTokenHeader = addApproovTokenHeader
        return self
    }

    /**
     * Sets whether the Approov trace ID header should be covered by the signature.
     *
     * @param addApproovTraceIDHeader is true to cover the trace ID header when present
     * @return the factory for method chaining
     */
    public func setAddApproovTraceIDHeader(_ addApproovTraceIDHeader: Bool) -> SignatureParametersFactory {
        self.addApproovTraceIDHeader = addApproovTraceIDHeader
        return self
    }

    /**
     * Sets whether the Approov status header should be covered by the signature, so the reported
     * status cannot be removed or altered in transit.
     *
     * @param addApproovStatusHeader is true to cover the status header when present
     * @return the factory for method chaining
     */
    public func setAddApproovStatusHeader(_ addApproovStatusHeader: Bool) -> SignatureParametersFactory {
        self.addApproovStatusHeader = addApproovStatusHeader
        return self
    }

    /**
     * Adds headers that are covered by the signature when present on the request.
     *
     * @param headers is the list of header names
     * @return the factory for method chaining
     */
    public func addOptionalHeaders(_ headers: [String]) -> SignatureParametersFactory {
        self.optionalHeaders.append(contentsOf: headers)
        return self
    }

    /**
     * Builds the signature parameters for a given request. A subclass may override this to build
     * them itself, to call this implementation, or to return what another factory builds for the
     * request. An algorithm set on the returned parameters gives that single signature. Note that an
     * override is called on many threads at the same time and must not block. If it throws then the
     * request is sent unsigned with an error logged, as only a required body digest that cannot be
     * generated fails the request.
     *
     * @param provider is the component provider for the request
     * @param changes is the record of the changes Approov made to the request
     * @return the signature parameters for the request, or nil to leave the request unsigned
     * @throws Error if a required body digest cannot be generated or there was another problem
     */
    open func buildSignatureParameters(provider: ApproovURLSessionComponentProvider,
                                       changes: ApproovRequestMutations) throws -> SignatureParameters? {
        var requestParameters: SignatureParameters
        if let baseParameters = baseParameters {
            requestParameters = SignatureParameters(base: baseParameters)
        } else {
            requestParameters = SignatureParameters()
        }
        // the algorithm is left unset so one signature per configured algorithm is produced over these
        // same parameters

        if addCreated || (expiresLifetime > 0) {
            let currentTime = ApproovInterceptor.shared.signatureTimeMillis() / 1000
            if addCreated {
                requestParameters = requestParameters.setCreated(currentTime)
            }
            if expiresLifetime > 0 {
                // a lifetime that overflows the timestamp saturates rather than trapping
                let (expires, overflow) = currentTime.addingReportingOverflow(expiresLifetime)
                requestParameters = requestParameters.setExpires(overflow ? Int64.max : expires)
            }
        }

        if addApproovTokenHeader, let tokenHeaderKey = changes.getTokenHeaderKey() {
            requestParameters = requestParameters.addComponentIdentifier(tokenHeaderKey)
        }

        if addApproovTraceIDHeader, let traceIDHeaderKey = changes.getTraceIDHeaderKey() {
            requestParameters = requestParameters.addComponentIdentifier(traceIDHeaderKey)
        }

        if addApproovStatusHeader, let statusHeaderKey = changes.getStatusHeaderKey() {
            requestParameters = requestParameters.addComponentIdentifier(statusHeaderKey)
        }

        for headerName in optionalHeaders {
            if provider.hasField(name: headerName) {
                requestParameters = requestParameters.addComponentIdentifier(headerName)
            }
        }

        if bodyDigestAlgorithm != nil {
            let bodyDigestCreated = try generateBodyDigest(provider: provider, requestParameters: requestParameters)
            if !bodyDigestCreated && bodyDigestRequired {
                throw RequiredBodyDigestError(message: "required body digest not generated")
            }
        }

        return requestParameters
    }

    /**
     * Generates a body digest for the request if possible, adding the Content-Digest header to the
     * request of the provider and covering it in the signature parameters. This is called by
     * buildSignatureParameters if a body digest is configured, and a subclass may override it to
     * return false for a request that is to have no digest, which fails the request if the digest is
     * configured as required.
     *
     * @param provider is the component provider for the request
     * @param requestParameters is the signature parameters for the request
     * @return true if a digest was added, false otherwise
     * @throws ApproovServiceError if there was a problem
     */
    open func generateBodyDigest(provider: ApproovURLSessionComponentProvider,
                                 requestParameters: SignatureParameters) throws -> Bool {
        var request = provider.getRequest()

        guard let body = SignatureParametersFactory.getHTTPBody(request) else {
            // we cannot generate a digest if there is no body
            return false
        }

        // we do not generate a digest if no body digest algorithm has been set
        guard let bodyDigestAlg = bodyDigestAlgorithm else {
            return false
        }

        // generate the digest
        let digest: Data
        switch bodyDigestAlg {
        case ApproovDefaultMessageSigning.DIGEST_SHA256:
            digest = ApproovDefaultMessageSigning.sha256(data: body)
        case ApproovDefaultMessageSigning.DIGEST_SHA512:
            digest = SignatureParametersFactory.sha512(data: body)
        default:
            throw ApproovServiceError.permanentError(message: "Unsupported body digest algorithm: \(bodyDigestAlg)")
        }

        // add the digest header to the request
        do {
            guard let digestHeader = try SFV.serializeDictionary(key: bodyDigestAlg, data: digest) else {
                throw ApproovServiceError.permanentError(message: "Failed to serialize Content-Digest header")
            }
            request.setValue(digestHeader, forHTTPHeaderField: "Content-Digest")
            provider.setRequest(request)
        } catch let error {
            throw ApproovServiceError.permanentError(message: "Failed to serialize Content-Digest header: \(error)")
        }
        _ = requestParameters.addComponentIdentifier("Content-Digest")
        return true
    }

    /**
     * Gets the HTTP body from the request. An empty body has a digest like any other.
     *
     * @param request is the request
     * @return the body or nil if not available
     */
    private static func getHTTPBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        } else if request.httpBodyStream != nil {
            // a one-shot body stream cannot be digested without consuming the upload
            return nil
        }
        // with no body, URLSession sends an empty body for every method except GET and HEAD, so its
        // digest is that of no bytes
        switch (request.httpMethod ?? "GET").uppercased() {
        case "GET", "HEAD":
            return nil
        default:
            return Data()
        }
    }

    /**
     * SHA512 of given input bytes.
     *
     * @param data is the input data
     * @return the hash data
     */
    private static func sha512(data: Data) -> Data {
        return Data(SHA512.hash(data: data))
    }
}

/**
 * Provides the components of a request to a SignatureParametersFactory, each as URLSession sends it:
 * the URL components are read from the URL string of the request and never parsed or encoded again,
 * so your backend rebuilds the same values from the request it receives. One is created for each
 * request that is signed and it is only read, as a factory cannot change the request.
 */
public final class ApproovURLSessionComponentProvider: ComponentProvider {

    // the request being signed, with any Content-Digest header a factory added
    private var request: URLRequest

    init(request: URLRequest) {
        self.request = request
    }

    /**
     * Gets the request being signed, as left by Approov and your service mutator, with any
     * Content-Digest header already added for it.
     *
     * @return the request
     */
    public func getRequest() -> URLRequest {
        return request
    }

    // sets the request, which only the standard body digest does to add its Content-Digest header
    func setRequest(_ newRequest: URLRequest) {
        self.request = newRequest
    }

    /**
     * Gets the method of the request.
     *
     * @return the method, which is GET if the request has none set
     */
    public func getMethod() -> String {
        return request.httpMethod ?? "GET"
    }

    // the request URL as URLSession holds it, which is never re-parsed
    private var url: String {
        return request.url?.absoluteString ?? ""
    }

    // the host a host factory is chosen by, or an empty string if the URL has none
    func getHost() -> String {
        return WireURL.factoryHost(url) ?? ""
    }

    /**
     * Gets the authority of the request, which is the host in lowercase followed by the port only
     * if it is not the default for the scheme.
     *
     * @return the authority, or an empty string if the URL has none
     */
    public func getAuthority() -> String {
        return WireURL.authority(url) ?? ""
    }

    /**
     * Gets the scheme of the request in lowercase.
     *
     * @return the scheme, or an empty string if the URL has none
     */
    public func getScheme() -> String {
        return WireURL.scheme(url) ?? ""
    }

    /**
     * Gets the target URI of the request as URLSession sends it, without any fragment.
     *
     * @return the target URI
     */
    public func getTargetUri() -> String {
        return WireURL.targetURI(url)
    }

    /**
     * Gets the request target, which is the path and any query as written in the request line.
     *
     * @return the request target
     */
    public func getRequestTarget() -> String {
        return WireURL.requestTarget(url)
    }

    /**
     * Gets the path of the request as sent, still percent-encoded.
     *
     * @return the path, which is "/" if the URL has none
     */
    public func getPath() -> String {
        let path = WireURL.path(url)
        return path.isEmpty ? "/" : path
    }

    /**
     * Gets the query of the request as sent, still percent-encoded, with its leading "?".
     *
     * @return the query, which is "?" alone if the URL has none
     */
    public func getQuery() -> String {
        return "?" + (WireURL.query(url) ?? "")
    }

    /**
     * Gets the value of a query parameter, decoded and then encoded again with the form
     * percent-encode set. Note that a request whose signature covers a parameter that is absent or
     * occurs more than once proceeds unsigned.
     *
     * @param name is the name of the query parameter
     * @return the value, or nil if the parameter is absent or occurs more than once
     */
    public func getQueryParam(name: String) -> String? {
        return WireURL.queryParam(url, name: name)
    }

    /**
     * Determines whether the request has a header field.
     *
     * @param name is the name of the header field, matched without regard to case
     * @return true if the request has the field, false otherwise
     */
    public func hasField(name: String) -> Bool {
        return request.value(forHTTPHeaderField: name) != nil
    }

    /**
     * Gets the value of a header field of the request.
     *
     * @param name is the name of the header field, matched without regard to case
     * @return the value, or nil if the request does not have the field
     */
    public func getField(name: String) -> String? {
        guard let value = request.value(forHTTPHeaderField: name) else {
            return nil
        }
        return ApproovURLSessionComponentProvider.combineFieldValues(fields: [value])
    }

    /**
     * Determines whether the request has a body, either in memory or as a stream.
     *
     * @return true if the request has a body, false otherwise
     */
    public func hasBody() -> Bool {
        return (request.httpBody != nil) || (request.httpBodyStream != nil)
    }
}
