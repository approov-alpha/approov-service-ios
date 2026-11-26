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
import CryptoKit
import Security

// ApproovPinningVerifier evaluates TLS server trust against the Approov public key pins: for a host with
// pins, platform trust evaluation first and then an SPKI SHA256 match anywhere in the certificate chain.
// A host without pins is not evaluated here.
final class ApproovPinningVerifier: Sendable {

    // the ASN.1 SubjectPublicKeyInfo headers prepended to the raw key bytes, by key type and size in bits
    private static let rsa2048SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]
    private static let rsa3072SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x01, 0xa2, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x01, 0x8f, 0x00
    ]
    private static let rsa4096SPKIHeader: [UInt8] = [
        0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05,
        0x00, 0x03, 0x82, 0x02, 0x0f, 0x00
    ]
    private static let ecdsaSecp256r1SPKIHeader: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48,
        0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
    ]
    private static let ecdsaSecp384r1SPKIHeader: [UInt8] = [
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04,
        0x00, 0x22, 0x03, 0x62, 0x00
    ]

    private static let spkiHeaders: [String: [Int: Data]] = [
        kSecAttrKeyTypeRSA as String: [
            2048: Data(rsa2048SPKIHeader),
            3072: Data(rsa3072SPKIHeader),
            4096: Data(rsa4096SPKIHeader),
        ],
        kSecAttrKeyTypeECSECPrimeRandom as String: [
            256: Data(ecdsaSecp256r1SPKIHeader),
            384: Data(ecdsaSecp384r1SPKIHeader),
        ],
    ]

    // the backend the pins are read from
    private let backend: ApproovBackend

    // the hosts already warned about having no Managed Trust Roots, so each is logged once
    private let managedTrustRootsWarnings = WarnedHosts()

    init(backend: ApproovBackend) {
        self.backend = backend
    }

    // a set of hosts behind a lock, since the verifier runs on several queues
    private final class WarnedHosts: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: Set<String> = []

        // true the first time a host is inserted
        func insert(_ host: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return hosts.insert(host).inserted
        }
    }

    /**
     * Gets the pins for a host, as selectPins does, logging once per host if it is listed to use
     * the Managed Trust Roots but there are none, so its connections fall back to platform trust.
     *
     * @param host is the host to get the pins for
     * @param allPins is the map of hosts to their pins
     * @return the pins for the host, or nil if it is unpinned
     */
    private func pins(forHost host: String, from allPins: [String: [String]]) -> [String]? {
        let pins = Self.selectPins(forHost: host, from: allPins)
        if pins == nil, Self.listedPins(forHost: host, in: allPins)?.isEmpty == true,
           managedTrustRootsWarnings.insert(Self.normalizedHost(host)) {
            ApproovLog.log(.warning, "Approov domain ", host: Self.normalizedHost(host),
                           ": no pins and no managed trust roots, OS trust only")
        }
        return pins
    }

    // extra trust anchors for the platform evaluation, which are only set by tests
    private static let anchorsLock = NSLock()
    nonisolated(unsafe) private static var testTrustAnchorsValue: [SecCertificate] = []

    static var testTrustAnchors: [SecCertificate] {
        get { anchorsLock.lock(); defer { anchorsLock.unlock() }; return testTrustAnchorsValue }
        set { anchorsLock.lock(); testTrustAnchorsValue = newValue; anchorsLock.unlock() }
    }

    // the decision for a server trust challenge, with the cause of any refusal so the app's error names it
    enum Verdict: Equatable {
        // the chain passed platform trust and matched one of the host's Approov pins
        case passed(SecTrust)

        // the host has no Approov pins, so the connection is the app's to decide
        case unpinned

        // the host has Approov pins and the chain failed platform trust evaluation
        case untrusted

        // the chain passed platform trust but matched none of the host's Approov pins
        case mismatch

        // the pins could not be read, so the connection fails closed
        case pinsUnreadable
    }

    /**
     * Verifies a server trust challenge.
     *
     * @param challenge is the authentication challenge
     * @return the challenge disposition and any credential
     */
    func verify(challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return verify(serverTrust: serverTrust, host: challenge.protectionSpace.host)
    }

    /**
     * Verifies server trust for a host as a challenge disposition. A passed check uses the
     * evaluated trust, an unpinned host gets default handling and every refusal cancels.
     *
     * @param serverTrust is the server trust to be evaluated
     * @param challengeHost is the host of the challenge
     * @return the challenge disposition and any credential
     */
    func verify(serverTrust: SecTrust, host challengeHost: String) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch evaluate(serverTrust: serverTrust, host: challengeHost) {
        case .passed(let trust): return (.useCredential, URLCredential(trust: trust))
        case .unpinned: return (.performDefaultHandling, nil)
        case .untrusted, .mismatch, .pinsUnreadable: return (.cancelAuthenticationChallenge, nil)
        }
    }

    /**
     * Evaluates the server trust of a connection against the pins the SDK holds now. A host without
     * Approov pins is not evaluated, so it is decided by the app's own trust logic.
     *
     * @param serverTrust is the server trust to be evaluated
     * @param challengeHost is the host of the challenge
     * @return Verdict for the connection
     */
    func evaluate(serverTrust: SecTrust, host challengeHost: String) -> Verdict {
        // host names are case-insensitive, so a mixed-case host must never miss its pins
        let host = challengeHost.lowercased()

        // pins that cannot be read fail the connection closed, and no verdict is cached
        guard let allPins = backend.pins(pinType: Self.pinType) else {
            ApproovLog.log(.error, "Approov pinning: pins unavailable for ", host: host)
            return .pinsUnreadable
        }
        // an unpinned host, including before any configuration, is left to the app's trust logic
        guard let pins = pins(forHost: host, from: allPins) else {
            return .unpinned
        }

        // platform trust evaluation runs first, since pinning narrows trust and never widens it
        SecTrustSetPolicies(serverTrust, SecPolicyCreateSSL(true, host as CFString))
        let anchors = Self.testTrustAnchors
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(serverTrust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        }
        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            return .untrusted
        }
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return .untrusted
        }
        for certificate in chain {
            if let pin = Self.spkiSHA256Base64(of: certificate), pins.contains(pin) {
                return .passed(serverTrust)
            }
        }
        ApproovLog.log(.error, "Approov pinning: no pin matches for ", host: host)
        return .mismatch
    }

    // the pin type requested from the SDK
    static let pinType = "public-key-sha256"

    /**
     * Determines whether a request may be sent to a host without TLS, which is not the case if the
     * host has Approov pins or the pins cannot be read.
     *
     * @param host is the host of the request
     * @return true if cleartext is allowed, false otherwise
     */
    func allowsCleartext(toHost host: String) -> Bool {
        guard let allPins = backend.pins(pinType: Self.pinType) else {
            ApproovLog.log(.error, "Approov pinning: pins unavailable for ", host: host)
            return false
        }
        guard pins(forHost: host, from: allPins) == nil else {
            ApproovLog.log(.warning, "Approov pinning: cleartext connection to pinned host ", host: host)
            return false
        }
        return true
    }

    /**
     * Normalizes a host name for the pin lookup, in lower case and without one trailing dot.
     *
     * @param host is the host name to be normalized
     * @return the normalized host name
     */
    static func normalizedHost(_ host: String) -> String {
        let lowercased = host.lowercased()
        return lowercased.hasSuffix(".") ? String(lowercased.dropLast()) : lowercased
    }

    /**
     * Gets the pins listed for a host. The keys are compared normalized like the host, as an exact
     * match, and keys that normalize to the same host contribute all their pins. The "*" key never
     * matches a host.
     *
     * @param host is the host to get the pins for
     * @param allPins is the map of hosts to their pins
     * @return the pins listed for the host, or nil if it is not listed
     */
    private static func listedPins(forHost host: String, in allPins: [String: [String]]) -> [String]? {
        let wanted = normalizedHost(host)
        var found: [String]?
        for (key, pins) in allPins where (key != "*") && (normalizedHost(key) == wanted) {
            found = (found ?? []) + pins
        }
        return found
    }

    /**
     * Determines whether the pin map lists a host under a key of its own, so it is an Approov API
     * domain, with or without pins of its own.
     *
     * @param host is the host to be checked
     * @param allPins is the map of hosts to their pins
     * @return true if the host is listed, false otherwise
     */
    static func isListed(host: String, in allPins: [String: [String]]) -> Bool {
        return listedPins(forHost: host, in: allPins) != nil
    }

    /**
     * Selects the pins for a host. A host with pins of its own uses those, a host listed with no
     * pins uses the "*" Managed Trust Roots, and a host not listed is unpinned.
     *
     * @param host is the host to select the pins for
     * @param allPins is the map of hosts to their pins
     * @return the pins for the host, or nil if it is unpinned
     */
    static func selectPins(forHost host: String, from allPins: [String: [String]]?) -> [String]? {
        guard let allPins = allPins, let hostPins = listedPins(forHost: host, in: allPins) else { return nil }
        if !hostPins.isEmpty { return hostPins }
        if let managedTrustRoots = allPins["*"], !managedTrustRoots.isEmpty { return managedTrustRoots }
        return nil
    }

    /**
     * Computes the SPKI SHA256 pin of the public key of a certificate. Unsupported key types and
     * sizes are skipped rather than treated as a mismatch.
     *
     * @param certificate is the certificate to be pinned
     * @return base64 encoded pin or nil if the key is not supported
     */
    static func spkiSHA256Base64(of certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String].map({ String(describing: $0) }),
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int,
              let header = spkiHeaders[keyType]?[keySize],
              let keyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }
        var spki = header
        spki.append(keyData)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}
