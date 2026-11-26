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

// the direct methods, which report a failure by throwing an ApproovServiceError and never reach the SDK
// while Approov protection is not enabled; each fetch records its ARC for getLastARC
extension ApproovInterceptor {

    /**
     * Gets the active backend if Approov protection is enabled.
     *
     * @param operation is the name of the method, for the error message
     * @return the active backend
     * @throws ApproovServiceError if Approov protection is not enabled
     */
    func protectedBackend(_ operation: String) throws -> ApproovBackend {
        guard let backend = backendIfProtected(operation) else {
            throw ApproovServiceError.permanentError(message: "\(operation): Approov protection not enabled")
        }
        return backend
    }

    // gets the active backend if Approov protection is enabled, or logs and returns nil otherwise
    private func backendIfProtected(_ operation: String) -> ApproovBackend? {
        guard isApproovProtectionEnabled, let backend = backend else {
            if loggingLevel >= .error {
                os_log("ApproovService: %{public}@: Approov protection not enabled", type: .error, operation)
            }
            return nil
        }
        return backend
    }

    /**
     * Fetches an Approov token for the URL, blocking until complete.
     *
     * @param url is the URL giving the domain for the token fetch
     * @return String of the fetched token
     * @throws ApproovServiceError if there was a problem
     */
    package func fetchToken(url: String) throws -> String {
        let backend = try protectedBackend("fetchToken")
        let result = backend.fetchToken(url: url)
        recordLastARC(result)
        try getServiceMutator().handleFetchTokenResult(result)
        return result.token
    }

    /**
     * Fetches or defines a secure string, blocking until complete.
     *
     * @param key is the secure string key to be looked up
     * @param newDef is any new definition for the secure string, or nil for lookup only
     * @return secure string or nil if the key is not defined
     * @throws ApproovServiceError if there was a problem
     */
    package func fetchSecureString(key: String, newDef: String?) throws -> String? {
        let backend = try protectedBackend("fetchSecureString")
        let operation = (newDef == nil) ? "lookup" : "definition"
        let result = backend.fetchSecureString(key: key, newDef: newDef)
        recordLastARC(result)
        try getServiceMutator().handleFetchSecureStringResult(result, operation: operation, key: key)
        return result.secureString
    }

    /**
     * Fetches a custom JWT, blocking until complete.
     *
     * @param payload is the marshaled JSON object for the claims to be included
     * @return custom JWT string or nil if not available
     * @throws ApproovServiceError if there was a problem
     */
    package func fetchCustomJWT(payload: String) throws -> String? {
        let backend = try protectedBackend("fetchCustomJWT")
        let result = backend.fetchCustomJWT(payload: payload)
        recordLastARC(result)
        try getServiceMutator().handleFetchCustomJWTResult(result)
        return result.token
    }

    /**
     * Gets the Approov device ID.
     *
     * @return String of the device ID
     * @throws ApproovServiceError if there was a problem, including if no device ID is available
     */
    package func getDeviceID() throws -> String {
        guard let deviceID = try protectedBackend("getDeviceID").deviceID() else {
            throw ApproovServiceError.permanentError(message: "getDeviceID: device ID unavailable")
        }
        return deviceID
    }

    /**
     * Gets the current time adjusted to the clock of the Approov servers.
     *
     * @return the time in milliseconds since the epoch
     * @throws ApproovServiceError if there was a problem, including if the SDK cannot give the time
     */
    package func getServerAdjustedCurrentTimeMS() throws -> Int64 {
        guard let time = try protectedBackend("getServerAdjustedCurrentTimeMS").serverAdjustedCurrentTimeMS() else {
            throw ApproovServiceError.permanentError(message: "getServerAdjustedCurrentTimeMS: time unavailable")
        }
        return time
    }

    /**
     * Gets the time message signatures are stamped with: the server adjusted time while protection is enabled,
     * so a wrong device clock does not put created and expires outside the backend's window, and otherwise the
     * device clock. A signature is never left out for want of it, so if the SDK cannot give the time the device
     * clock is used and a warning is logged.
     *
     * @return the time in milliseconds since the epoch
     */
    func signatureTimeMillis() -> Int64 {
        if isApproovProtectionEnabled, let backend = backend {
            if let time = backend.serverAdjustedCurrentTimeMS() {
                return time
            }
            if loggingLevel >= .warning {
                os_log("ApproovService: Message signing: server adjusted time unavailable, using the device clock",
                       type: .default)
            }
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    /**
     * Sets a development key.
     *
     * @param devKey is the development key to be used
     * @throws ApproovServiceError if there was a problem
     */
    package func setDevKey(_ devKey: String) throws {
        try protectedBackend("setDevKey").setDevKey(devKey)
        ApproovLog.log(.debug, "setDevKey")
    }

    /**
     * Sets a hash of the given data into the pay claim of future tokens.
     *
     * @param data is the data whose hash is to be included
     * @throws ApproovServiceError if there was a problem
     */
    package func setDataHashInToken(_ data: String) throws {
        try protectedBackend("setDataHashInToken").setDataHashInToken(data)
        ApproovLog.log(.debug, "setDataHashInToken")
    }

    /**
     * Sets the install attributes sent with future token fetches for this app installation.
     *
     * @param attrs is the signed JWT holding the new install attributes
     * @throws ApproovServiceError if there was a problem
     */
    package func setInstallAttributes(_ attrs: String) throws {
        try protectedBackend("setInstallAttributes").setInstallAttributes(attrs)
        ApproovLog.log(.debug, "setInstallAttributes")
    }
}
