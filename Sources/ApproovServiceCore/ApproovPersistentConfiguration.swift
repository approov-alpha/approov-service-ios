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

// ApproovPersistentConfiguration stores options that replace options of the bundled approov.config from the next
// launch, so an over-the-air update of the app's JavaScript can change the options in force before any JavaScript
// runs. Nothing stored is applied in the running process: each process uses the configuration stored before it
// first looked at it. A configuration stored by another version of the app, or with another bundled approov.config,
// is deleted at the next launch. The file is read and written under a lock of its own, which is never held while a
// line is logged, the interceptor lock is taken or an initialize runs.
package final class ApproovPersistentConfiguration: @unchecked Sendable {

    // the name of the file holding the stored record
    package static let fileName = "override.json"

    // the largest options accepted, 64 KiB, which is far above any real configuration
    package static let maxOptionsSize = 65_536

    // the largest source tag accepted, in UTF-8 bytes
    package static let maxSourceSize = 1024

    // the largest record read; a larger file was not written by this layer and is not read
    package static let maxRecordSize = 131_072

    // the version of the record this layer writes and reads
    package static let recordVersion = 1

    // the UTF-8 byte order mark, which is ignored at the start of the options
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    // the directory holding the file
    package let directory: URL

    // the version of the running app, as build number "/" version name, recorded with the options so a record
    // stored by another version of the app is deleted
    package let appVersion: String

    // the file holding the stored record
    package let fileURL: URL

    // the lock serializing every read, write and delete of the file, and guarding the state below
    private let lock = NSLock()

    // true once this process has read the record in force for it
    private var launchRead = false

    // the record in force for this process while it is not yet checked against the bundled file, or nil
    private var launchRecord: Record?

    // the configuration in force for this process, once checked, or nil for none
    private var launchOverride: ApproovPersistentOverride?

    // the lines about the record of this process deleted instead of applied, logged by initialize after the logging
    // level of the options is set
    private var launchNotices: [ApproovConfigDiagnostic] = []

    // a stored record, with every part checked but the values of the options, which are checked as they are applied
    private struct Record {
        let source: String?
        let bundledHash: String?

        // the app version the options were stored by, or nil if the record holds none
        let appVersion: String?
        let options: NSDictionary
    }

    /**
     * Creates the persistent configuration kept in a directory, which is created when the first
     * configuration is stored.
     *
     * @param directory is the directory to hold the file
     * @param appVersion is the version of the running app, as build number "/" version name
     */
    package init(directory: URL, appVersion: String) {
        self.directory = directory
        self.appVersion = appVersion
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /**
     * Stores options to be applied over the bundled approov.config from the next launch. They are
     * checked as strictly as the file, and more: the account ID, comment and development key are
     * refused, and so is any known key with a bad value, while unknown keys are kept. Nothing is
     * applied in the running process. Storing the same options and source again writes nothing.
     *
     * @param json is the options as a JSON object of at most 64 KiB
     * @param source is a tag naming where the options came from, such as an update ID, or nil for none
     * @param bundledFile is the location of the bundled approov.config, or nil if there is none
     * @throws ApproovServiceError if there was a problem, as a permanentError naming the cause and never a value,
     * in which case nothing is stored
     */
    package func store(_ json: String, source: String?, bundledFile: URL?) throws {
        // the options are checked as strictly as the file, and a leading byte order mark is ignored as in the file
        var options = Data(json.utf8)
        if options.starts(with: Self.byteOrderMark) {
            options.removeFirst(Self.byteOrderMark.count)
        }
        guard options.count <= Self.maxOptionsSize else {
            throw Self.failure("setPersistentConfiguration", "larger than 64 KiB")
        }

        // a Swift string holds no lone surrogate, which bridging replaces, so the source is always valid Unicode
        if let source = source, source.utf8.count > Self.maxSourceSize {
            throw Self.failure("setPersistentConfiguration", "source longer than 1024 bytes")
        }

        // the bundled file, read before the lock as initialize reads it, for its hash and for the options checks
        let bundled: Data?
        do {
            bundled = try Self.contents(of: bundledFile)
        } catch {
            throw Self.failure("setPersistentConfiguration", "\(ApproovConfigFile.fileName) unreadable")
        }
        let bundledHash = bundled.map { ApproovConfigFile.sha256Hex($0) }
        let object: NSDictionary
        do {
            // one level less deep than the record holding the options, so a record stored is always readable
            object = try ApproovConfigFile.strictObject(options, maxDepth: ApproovStrictJSON.maxDepth - 1)
            try ApproovConfigFile.checkPersistentOptions(object, bundled: bundled.flatMap { Self.bundledObject($0) })
        } catch {
            throw Self.failure("setPersistentConfiguration", (error as? ApproovConfigRejection)?.cause ?? "not valid JSON")
        }
        let record = Self.record(options: Self.trimmed(options), source: source, bundledHash: bundledHash,
                                 appVersion: appVersion)

        // the configuration in force for this process is read before it can be replaced, so that the record
        // stored now applies only from the next launch
        lock.lock()
        var lines = readForLaunchLocked(bundledHash: bundledHash, bundledKnown: true)
        let written: Bool
        do {
            written = try writeLocked(record)
        } catch {
            lock.unlock()
            Self.log(lines)
            throw Self.failure("setPersistentConfiguration", "write failed", detail: error.localizedDescription)
        }
        lock.unlock()
        if written {
            lines.append((.info, "persistent configuration stored, applies at the next launch"))
            let keys = (object.allKeys.compactMap { $0 as? String }).sorted().map { ApproovConfigFile.loggableKey($0) }
            lines.append((.debug, "setPersistentConfiguration keys: " + keys.joined(separator: ", ")))
        } else {
            lines.append((.debug, "setPersistentConfiguration: unchanged"))
        }
        Self.log(lines)
    }

    /**
     * Deletes any stored options, so the bundled approov.config alone applies from the next launch.
     * Nothing changes in the running process, and there being nothing stored is not an error. The
     * bundled file is not read.
     *
     * @throws ApproovServiceError if there was a problem, as a permanentError
     */
    package func clear() throws {
        // the record in force for this process is read before it is deleted, so this process keeps it; it is checked
        // against the bundled file when initialize reads that file
        lock.lock()
        var lines = readForLaunchLocked(bundledHash: nil, bundledKnown: false)
        let deleted: Bool
        do {
            deleted = try deleteLocked()
        } catch {
            lock.unlock()
            Self.log(lines)
            throw Self.failure("clearPersistentConfiguration", "delete failed", detail: error.localizedDescription)
        }
        lock.unlock()
        if deleted {
            let fileName = ApproovConfigFile.fileName
            lines.append((.info, "persistent configuration cleared, the next launch uses the bundled \(fileName)"))
        }
        Self.log(lines)
    }

    /**
     * Gets the source stored with the options. The record is checked but not the bundled file it was
     * stored with, and nothing is deleted.
     *
     * @return String of the source, or nil if no valid record is stored or it has no source
     */
    package func source() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard case .content(let data) = readFileLocked() else {
            return nil
        }
        return (try? Self.parseRecord(data))?.source
    }

    /**
     * Gets the persistent configuration in force for this process: the record stored before the
     * process first looked at it, here or in store or clear; later calls give the same answer whatever
     * was stored since. A record that cannot be used, that was stored with a bundled approov.config whose content differs from this one, or that was
     * stored by another version of the app, is deleted instead. The lines about that are returned rather
     * than logged, for initialize to log them after the logging level of the options is set.
     *
     * @param bundledHash is the SHA-256 of the bundled approov.config as lowercase hex
     * @return the persistent configuration in force, or nil for none, and the lines about one deleted
     */
    package func forLaunch(bundledHash: String)
        -> (override: ApproovPersistentOverride?, notices: [ApproovConfigDiagnostic]) {
        lock.lock()
        let lines = readForLaunchLocked(bundledHash: bundledHash, bundledKnown: true)
        let launch = (launchOverride, launchNotices)
        lock.unlock()
        Self.log(lines)
        return launch
    }

    // forgets the record read for this process, as if the app were launched again, for tests only
    package func resetForTesting() {
        lock.lock()
        launchRead = false
        launchRecord = nil
        launchOverride = nil
        launchNotices = []
        lock.unlock()
    }

    /**
     * Reads the record in force for this process once, which the caller must hold the lock for, and
     * checks it against the bundled file when that is known. A record that cannot be used is deleted at
     * once; one stored with another bundled file is deleted only while it is still the one on the
     * device, which it is when this first look checks it.
     *
     * @param bundledHash is the SHA-256 of the bundled approov.config as lowercase hex, or nil if there is none
     * @param bundledKnown is true if the bundled file was read, false if the record is to be checked later
     * @return the lines to be logged once the lock is released
     */
    private func readForLaunchLocked(bundledHash: String?, bundledKnown: Bool) -> [(ApproovLogLevel, String)] {
        if launchRead {
            if bundledKnown && (launchRecord != nil) {
                checkForLaunchLocked(bundledHash: bundledHash, deleteFile: false)
            }
            return []
        }
        launchRead = true
        let file = readFileLocked()
        if case .none = file {
            return []
        }

        // a record that cannot be used, a file larger than any record included, is deleted, so it is reported once
        do {
            guard case .content(let data) = file else {
                throw ApproovConfigRejection(cause: "unreadable")
            }
            launchRecord = try Self.parseRecord(data)
        } catch {
            let cause = (error as? ApproovConfigRejection)?.cause ?? "not valid"
            launchNotices.append(ApproovConfigDiagnostic(level: .warning,
                                                         message: "persistent configuration deleted: \(cause)"))
            return deleteReportingFailureLocked()
        }
        if bundledKnown {
            return checkForLaunchLocked(bundledHash: bundledHash, deleteFile: true)
        }
        return []
    }

    /**
     * Checks the record of this process against the bundled file and the app version, which the caller
     * must hold the lock for. A record stored with another bundled file, or by another version of the
     * app, belongs to another release of the app. A record that holds no app version is taken as
     * stored by another version.
     *
     * @param bundledHash is the SHA-256 of the bundled approov.config as lowercase hex, or nil if there is none
     * @param deleteFile is true if the record is the one on the device and is to be deleted if it does not match
     * @return the lines to be logged once the lock is released
     */
    @discardableResult
    private func checkForLaunchLocked(bundledHash: String?, deleteFile: Bool) -> [(ApproovLogLevel, String)] {
        guard let record = launchRecord else {
            return []
        }
        launchRecord = nil
        guard record.bundledHash == bundledHash else {
            let fileName = ApproovConfigFile.fileName
            launchNotices.append(ApproovConfigDiagnostic(
                level: .info, message: "persistent configuration deleted: store release changed the bundled \(fileName)"))
            return deleteFile ? deleteReportingFailureLocked() : []
        }
        guard record.appVersion == appVersion else {
            launchNotices.append(ApproovConfigDiagnostic(
                level: .info, message: "persistent configuration deleted: app version changed"))
            return deleteFile ? deleteReportingFailureLocked() : []
        }
        launchOverride = ApproovConfigFile.persistentOverride(record.options, source: record.source)
        return []
    }

    // deletes the record, which the caller must hold the lock for, and gives the line to log if that failed
    private func deleteReportingFailureLocked() -> [(ApproovLogLevel, String)] {
        do {
            _ = try deleteLocked()
        } catch {
            return [(.warning, "persistent configuration: delete failed")]
        }
        return []
    }

    // what reading the file found
    private enum RecordFile {
        // no file, or one that cannot be read and is kept
        case none

        // a file larger than any record, which is not read
        case tooLarge

        // the content of the file
        case content(Data)
    }

    /**
     * Reads the file, which the caller must hold the lock for. Its size is checked before it is read.
     * A file that cannot be read, for example before the first unlock after a restart, when data
     * protection refuses the read, is kept.
     *
     * @return RecordFile saying what was found
     */
    private func readFileLocked() -> RecordFile {
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
           size > Self.maxRecordSize {
            return .tooLarge
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .none
        }

        // a file that grew between the two checks is treated as too large
        return (data.count <= Self.maxRecordSize) ? .content(data) : .tooLarge
    }

    /**
     * Parses a stored record, checking every part of it but the values of the options, which are
     * checked as they are applied.
     *
     * @param data is the content of the file
     * @return Record holding the parts
     * @throws ApproovConfigRejection as unreadable, not valid or unknown version
     */
    private static func parseRecord(_ data: Data) throws -> Record {
        let record: NSDictionary
        do {
            record = try ApproovConfigFile.strictObject(data)
        } catch let rejection as ApproovConfigRejection where rejection.cause == "not a JSON object" {
            throw ApproovConfigRejection(cause: "not valid")
        } catch {
            throw ApproovConfigRejection(cause: "unreadable")
        }

        // the version first, so a record of another format is reported as such
        guard let version = record.object(forKey: "v") as? NSNumber, ApproovConfigFile.bool(version) == nil,
              version.doubleValue == Double(recordVersion) else {
            throw ApproovConfigRejection(cause: "unknown version")
        }
        let source = record.object(forKey: "source")
        let bundledHash = record.object(forKey: "bundledHash")

        // a record that holds no app version is valid, and is deleted when checked for the launch
        let appVersion = record.object(forKey: "appVersion")
        guard (source is NSNull) || (source is String), (bundledHash is NSNull) || (bundledHash is String),
              (appVersion == nil) || (appVersion is String),
              let options = record.object(forKey: "options") as? NSDictionary,
              !ApproovConfigFile.fileOnlyKeys.contains(where: { options.object(forKey: $0) != nil }) else {
            throw ApproovConfigRejection(cause: "not valid")
        }
        return Record(source: source as? String, bundledHash: bundledHash as? String,
                      appVersion: appVersion as? String, options: options)
    }

    /**
     * Writes a record unless the same record is stored, which the caller must hold the lock for. The
     * write is atomic, the file is readable from the first unlock after a restart, and the file and its
     * directory are left out of backups, so a restored or transferred device does not inherit it.
     *
     * @param record is the record to be written
     * @return true if the record was written, false if it was already stored
     * @throws Error if there was a problem, in which case no new record is stored
     */
    private func writeLocked(_ record: Data) throws -> Bool {
        if let stored = try? Data(contentsOf: fileURL), stored == record {
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directoryURL = directory
        try directoryURL.setResourceValues(excluded)
        try record.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])

        // the atomic write replaced the file, so it is excluded again, and a file that cannot be excluded is removed
        do {
            var url = fileURL
            try url.setResourceValues(excluded)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        return true
    }

    /**
     * Deletes the stored record, which the caller must hold the lock for.
     *
     * @return true if a record was deleted, false if there was none
     * @throws Error if there was a problem
     */
    private func deleteLocked() throws -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            let deleteError = error as NSError
            if (deleteError.domain == NSCocoaErrorDomain) && (deleteError.code == NSFileNoSuchFileError) {
                return false
            }
            throw error
        }
    }

    /**
     * Gets the content of the bundled approov.config.
     *
     * @param url is the location of the file, or nil if there is none
     * @return Data of the file, or nil if there is no file
     * @throws Error if the file is present but cannot be read
     */
    private static func contents(of url: URL?) throws -> Data? {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    /**
     * Gets the object of the bundled approov.config, for checking options against it, without logging.
     *
     * @param data is the content of the file
     * @return NSDictionary of the file, or nil if it is not one valid JSON object
     */
    private static func bundledObject(_ data: Data) -> NSDictionary? {
        var bytes = data
        if bytes.starts(with: byteOrderMark) {
            bytes.removeFirst(byteOrderMark.count)
        }
        return try? ApproovConfigFile.strictObject(bytes)
    }

    /**
     * Gets the record to be stored: the version, the source, the hash of the bundled file, the app
     * version, and the options exactly as given, which are a checked JSON object and so are placed
     * into the record as they are.
     *
     * @param options is the options as a JSON object without a byte order mark or surrounding whitespace
     * @param source is the source, or nil for none
     * @param bundledHash is the hash of the bundled file, or nil if there is none
     * @param appVersion is the version of the running app
     * @return Data of the record
     */
    private static func record(options: Data, source: String?, bundledHash: String?, appVersion: String) -> Data {
        let head = "{\"v\":\(recordVersion),\"source\":\(jsonString(source)),"
            + "\"bundledHash\":\(jsonString(bundledHash)),\"appVersion\":\(jsonString(appVersion)),\"options\":"
        var record = Data(head.utf8)
        record.append(options)
        record.append(Data("}".utf8))
        return record
    }

    // the options without the JSON whitespace around them
    private static func trimmed(_ options: Data) -> Data {
        let isWhitespace: (UInt8) -> Bool = { ($0 == 0x20) || ($0 == 0x09) || ($0 == 0x0A) || ($0 == 0x0D) }
        guard let first = options.firstIndex(where: { !isWhitespace($0) }),
              let last = options.lastIndex(where: { !isWhitespace($0) }) else {
            return options
        }
        return options.subdata(in: first..<(last + 1))
    }

    /**
     * Gets a JSON string literal.
     *
     * @param value is the string, or nil for null
     * @return String of the literal
     */
    private static func jsonString(_ value: String?) -> String {
        guard let value = value,
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let literal = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return literal
    }

    // logs the lines gathered under the lock
    private static func log(_ lines: [(ApproovLogLevel, String)]) {
        for (level, message) in lines {
            ApproovLog.log(level, message)
        }
    }

    /**
     * Gets the error for a call that failed, logging it. The cause never includes a value.
     *
     * @param call is the name of the call that failed
     * @param cause is the cause of the problem
     * @param detail is any detail that could carry a value, logged private, or nil for none
     * @return ApproovServiceError as a permanentError naming the cause
     */
    private static func failure(_ call: String, _ cause: String, detail: String? = nil) -> ApproovServiceError {
        let message = "\(call): \(cause)"
        ApproovLog.log(.error, message, detail: detail)
        return ApproovServiceError.permanentError(message: message)
    }
}
