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

// what an initialize call did, so the SDK binding can follow up only when protection was newly enabled
package enum ApproovInitializeOutcome: Equatable, Sendable {
    // the first empty account ID, which enables the service layer in bypass mode
    case bypassEntered

    // an empty account ID while already in bypass mode, which changes nothing
    case bypassUnchanged

    // an empty account ID while protection is enabled, which is ignored
    case emptyIgnored

    // the SDK accepted a non-empty account ID and protection is now enabled
    case protectionEnabled

    // the SDK accepted a non-empty account ID while protection was already enabled, which changes nothing
    case protectionUnchanged
}

// forwards a non-empty account ID and comment to the SDK, throwing whatever the SDK reports as an error
package typealias ApproovSDKInitialize = (_ config: String, _ comment: String?) throws -> Void

extension ApproovInterceptor {

    // the dispatch queue serializing every initialize, so the SDK call and the state change are one step
    package static let initializerQueue = DispatchQueue(label: "io.approov.service.initializer")

    /**
     * Determines whether an error is the Swift bridging of an Objective-C NO return with a nil
     * NSError, which is how the Approov SDK reports that it is already initialized with the same
     * account ID and comment.
     *
     * @param error is the error from the SDK
     * @return true if the SDK is already initialized, false otherwise
     */
    package static func isAlreadyInitializedBridgingError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == "Foundation._GenericObjCError") && (nsError.code == 0)
    }

    /**
     * Initializes the service layer, separately from the SDK binding so it can be tested with a fake
     * SDK. Every non-empty account ID is forwarded to the SDK with the comment, and the SDK decides;
     * already initialized is a success. An empty account ID enters bypass mode, or is ignored once
     * protection is enabled. Only the enabled state changes, and configuration is never reset.
     *
     * @param config is the Approov account ID, or an empty string for bypass mode
     * @param comment is an optional comment to be passed to the SDK
     * @param backend is the Approov backend to be activated
     * @param sdkInitialize is the call that initializes the SDK
     * @return ApproovInitializeOutcome of the call
     * @throws ApproovServiceError if there was a problem, with the SDK's own error as the underlying error
     */
    @discardableResult
    package func initializeService(config: String,
                                   comment: String?,
                                   backend: ApproovBackend,
                                   sdkInitialize: ApproovSDKInitialize) throws -> ApproovInitializeOutcome {
        return try Self.initializerQueue.sync {
            try initializeOnQueue(config: config, comment: comment, backend: backend, sdkInitialize: sdkInitialize)
        }
    }

    /**
     * Initializes the service layer from the configuration file, as initializeService does with its
     * config and comment. If this call newly enables the service layer, in bypass mode or by turning
     * protection on, the options of the file are applied, once per process, before the layer reports
     * itself enabled and so before any other initialize can return. That includes protection the SDK
     * reports as already initialized by another caller, as long as this layer was not yet enabled with
     * it. A call that finds the layer already enabled in the state it asks for applies, logs and
     * resets nothing from the file. The call that applies the file also applies the persistent
     * configuration in force for the process, if any, as one set with the file, the persistent
     * options replacing the options of the same keys in the file.
     *
     * @param configFile is the content of the configuration file
     * @param backend is the Approov backend to be activated
     * @param persistentConfiguration is the persistent configuration to be applied over the file, or nil for none
     * @param sdkInitialize is the call that initializes the SDK
     * @return ApproovInitializeOutcome of the call
     * @throws ApproovServiceError if there was a problem, with the SDK's own error as the underlying error
     */
    @discardableResult
    package func initializeService(configFile: ApproovConfigFile,
                                   backend: ApproovBackend,
                                   persistentConfiguration: ApproovPersistentConfiguration? = nil,
                                   sdkInitialize: ApproovSDKInitialize) throws -> ApproovInitializeOutcome {
        return try Self.initializerQueue.sync {
            try initializeOnQueue(config: configFile.config, comment: configFile.comment, backend: backend,
                                  sdkInitialize: sdkInitialize) { protection in
                if claimConfigFileApplication() {
                    // the persistent configuration in force for this process is read here, without the lock, by the
                    // one call that applies the file
                    var applied = configFile
                    if let launch = persistentConfiguration?.forLaunch(bundledHash: configFile.contentHash) {
                        applied = configFile.merging(launch.override, notices: launch.notices)
                    }
                    applyConfigFileOptions(applied, backend: backend, protection: protection)
                } else if configFile.config.isEmpty {
                    logEmptyConfig()
                }
            }
        }
    }

    /**
     * Initializes the service layer on the initializer queue, which the caller must be running on.
     *
     * @param config is the Approov account ID, or an empty string for bypass mode
     * @param comment is an optional comment to be passed to the SDK
     * @param backend is the Approov backend to be activated
     * @param sdkInitialize is the call that initializes the SDK
     * @param beforeEnabling is called when this call newly enables the layer, with true if it turns protection on and
     * false for bypass mode, after the SDK accepted the config and before the layer reports itself enabled
     * @return ApproovInitializeOutcome of the call
     * @throws ApproovServiceError if there was a problem, with the SDK's own error as the underlying error
     */
    private func initializeOnQueue(config: String,
                                   comment: String?,
                                   backend: ApproovBackend,
                                   sdkInitialize: ApproovSDKInitialize,
                                   beforeEnabling: (Bool) -> Void = { _ in }) throws -> ApproovInitializeOutcome {
        if config.isEmpty {
            if isApproovProtectionEnabled {
                ApproovLog.log(.info, "initialize: empty config ignored, Approov protection already enabled")
                return .emptyIgnored
            }
            if isApproovServiceEnabled {
                return .bypassUnchanged
            }
            beforeEnabling(false)
            activate(backend: backend, enabled: false)
            ApproovLog.log(.info, "initialize: bypass mode, Approov protection not active")
            return .bypassEntered
        }

        do {
            try sdkInitialize(config, comment)
        } catch where Self.isAlreadyInitializedBridgingError(error) {
            ApproovLog.log(.debug, "initialize: Approov SDK already initialized with the same config and comment")
        } catch {
            // nothing has changed, and the SDK's error is carried unchanged
            let sdkError = error as NSError
            let message = sdkError.localizedDescription
            ApproovLog.log(.error, "initialize: Approov SDK failed", detail: message)
            throw ApproovServiceError.initializationError(message: message, underlying: sdkError)
        }

        if isApproovProtectionEnabled {
            return .protectionUnchanged
        }
        beforeEnabling(true)
        activate(backend: backend, enabled: true)
        ApproovLog.log(.info, "initialize: Approov protection enabled")
        return .protectionEnabled
    }

    // logs that the configuration file starts bypass mode
    private func logEmptyConfig() {
        ApproovLog.log(.warning, "initialize: \(ApproovConfigFile.fileName) config is empty, bypass mode")
    }

    /**
     * Applies the options of the configuration file through the same setters an app calls, before the
     * layer reports itself enabled. The logging level is set first, so the rest is logged at the level
     * the file asks for. A value a setter rejects is skipped with an error naming the key and the
     * other options still apply. This code logs key names only. The development key is passed to the
     * SDK only when protection is being turned on. This must not be called while holding the lock.
     *
     * @param configFile is the content of the configuration file, with any persistent configuration merged in
     * @param backend is the Approov backend being activated, which receives the development key
     * @param protection is true if Approov protection is being turned on, false for bypass mode
     */
    package func applyConfigFileOptions(_ configFile: ApproovConfigFile, backend: ApproovBackend, protection: Bool) {
        let fileName = ApproovConfigFile.fileName

        // the logging level comes first, then the empty config warning and the lines about unknown keys and
        // skipped values
        for case .logLevel(let level) in configFile.options {
            setLoggingLevel(level)
        }
        if configFile.config.isEmpty {
            logEmptyConfig()
        }
        for notice in configFile.notices {
            ApproovLog.log(notice.level, notice.message)
        }
        for diagnostic in configFile.diagnostics {
            ApproovLog.log(diagnostic.level, diagnostic.message)
        }

        for option in configFile.options {
            switch option {
            case .logLevel:
                break
            case .devKey(let devKey):
                // the SDK has accepted the config, but the layer is not enabled yet, so the backend is called directly
                if protection {
                    backend.setDevKey(devKey)
                    ApproovLog.log(.debug, "setDevKey")
                } else {
                    ApproovLog.log(.warning, "\(fileName): devKey: not applied, Approov protection not enabled")
                }
            case .tokenHeader(let name, let prefix):
                setTokenHeader(name, prefix: prefix)
            case .traceIDHeader(let header):
                setTraceIDHeader(header)
            case .statusHeader(let header):
                setStatusHeader(header)
            case .mutator(let mutator):
                switch mutator {
                case .closeFailure: setServiceMutator(.CLOSE_FAILURE)
                case .alwaysProceed: setServiceMutator(.ALWAYS_PROCEED)
                }
            case .messageSigning(let enabled):
                if enabled {
                    enableMessageSigning()
                } else {
                    disableMessageSigning()
                }
            case .substitutionHeaders(let headers):
                for header in headers.keys.sorted() {
                    do {
                        try addSubstitutionHeader(header, requiredPrefix: headers[header] ?? "")
                    } catch {
                        let origin = configFile.origin(of: option.key)
                        ApproovLog.log(.error, "\(origin): substitutionHeaders: element is the binding header, skipped")
                    }
                }
            case .substitutionQueryParams(let keys):
                for key in keys {
                    addSubstitutionQueryParam(key)
                }
            case .exclusionURLRegexes(let patterns):
                for pattern in patterns {
                    do {
                        try addExclusionURLRegex(pattern)
                    } catch {
                        let origin = configFile.origin(of: option.key)
                        ApproovLog.log(.error, "\(origin): exclusionURLRegexes: invalid regular expression, skipped")
                    }
                }
            case .bindingHeader(let header):
                do {
                    try setBindingHeader(header)
                } catch {
                    let origin = configFile.origin(of: option.key)
                    ApproovLog.log(.error, "\(origin): bindingHeader: a substitution header, skipped")
                }
            }
        }
        ApproovLog.log(.debug, "\(fileName): options applied")
        if let override = configFile.override {
            let source = override.source.map { ApproovConfigFile.loggable($0, limit: 128) } ?? "none"
            ApproovLog.log(.info, "initialize: persistent configuration applied (source \(source))")
        }
    }

    /**
     * Initializes the service layer as initializeService does and, when this call enabled Approov
     * protection, reports the user property: the host framework identity if a host framework package
     * set one, and the layer's own otherwise.
     *
     * @param config is the Approov account ID, or an empty string for bypass mode
     * @param comment is an optional comment to be passed to the SDK
     * @param backend is the Approov backend to be activated
     * @param defaultUserProperty is the layer's own user property
     * @param reportUserProperty is the call that sets the user property in the SDK
     * @param sdkInitialize is the call that initializes the SDK
     * @return ApproovInitializeOutcome of the call
     * @throws ApproovServiceError if there was a problem, with the SDK's own error as the underlying error
     */
    @discardableResult
    package func initializeService(config: String,
                                   comment: String?,
                                   backend: ApproovBackend,
                                   defaultUserProperty: String,
                                   reportUserProperty: (String) -> Void,
                                   sdkInitialize: ApproovSDKInitialize) throws -> ApproovInitializeOutcome {
        let outcome = try initializeService(config: config, comment: comment, backend: backend,
                                            sdkInitialize: sdkInitialize)
        if outcome == .protectionEnabled {
            self.reportUserProperty(defaultProperty: defaultUserProperty, report: reportUserProperty)
        }
        return outcome
    }

    /**
     * Initializes the service layer from the configuration file as initializeService(configFile:)
     * does and, when this call enabled Approov protection, reports the user property as the
     * initialize with an explicit account ID does.
     *
     * @param configFile is the content of the configuration file
     * @param backend is the Approov backend to be activated
     * @param persistentConfiguration is the persistent configuration to be applied over the file, or nil for none
     * @param defaultUserProperty is the layer's own user property
     * @param reportUserProperty is the call that sets the user property in the SDK
     * @param sdkInitialize is the call that initializes the SDK
     * @return ApproovInitializeOutcome of the call
     * @throws ApproovServiceError if there was a problem, with the SDK's own error as the underlying error
     */
    @discardableResult
    package func initializeService(configFile: ApproovConfigFile,
                                   backend: ApproovBackend,
                                   persistentConfiguration: ApproovPersistentConfiguration? = nil,
                                   defaultUserProperty: String,
                                   reportUserProperty: (String) -> Void,
                                   sdkInitialize: ApproovSDKInitialize) throws -> ApproovInitializeOutcome {
        let outcome = try initializeService(configFile: configFile, backend: backend,
                                            persistentConfiguration: persistentConfiguration,
                                            sdkInitialize: sdkInitialize)
        if outcome == .protectionEnabled {
            self.reportUserProperty(defaultProperty: defaultUserProperty, report: reportUserProperty)
        }
        return outcome
    }
}
