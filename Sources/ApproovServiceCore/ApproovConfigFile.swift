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

import CryptoKit
import Foundation

// a standard service mutator that can be named in the configuration file
package enum ApproovConfigMutator: Equatable, Sendable {
    case closeFailure
    case alwaysProceed
}

// one option read from the configuration file, with a value that has passed the type and value checks
package enum ApproovConfigOption: Equatable, Sendable {
    case logLevel(ApproovLogLevel)
    case devKey(String)
    case tokenHeader(name: String, prefix: String)
    case traceIDHeader(String?)
    case statusHeader(String?)
    case mutator(ApproovConfigMutator)
    case messageSigning(Bool)
    case substitutionHeaders([String: String])
    case substitutionQueryParams([String])
    case exclusionURLRegexes([String])
    case bindingHeader(String?)

    // the key in the configuration file that the option was read from
    package var key: String {
        switch self {
        case .logLevel: return "logLevel"
        case .devKey: return "devKey"
        case .tokenHeader: return "tokenHeader"
        case .traceIDHeader: return "traceIDHeader"
        case .statusHeader: return "statusHeader"
        case .mutator: return "mutator"
        case .messageSigning: return "messageSigning"
        case .substitutionHeaders: return "substitutionHeaders"
        case .substitutionQueryParams: return "substitutionQueryParams"
        case .exclusionURLRegexes: return "exclusionURLRegexes"
        case .bindingHeader: return "bindingHeader"
        }
    }
}

// a line to be logged about the configuration file, which names keys only and never a value
package struct ApproovConfigDiagnostic: Equatable, Sendable {
    package let level: ApproovLogLevel
    package let message: String

    // the key and what is wrong with its value, without the name of the file, or nil for a line that is not about
    // a bad value
    package var cause: String? = nil

    // the top-level key the line is about, or nil for none
    package var key: String? = nil

    // two lines are the same if they log the same, since the cause and the key are taken from the message
    package static func == (lhs: ApproovConfigDiagnostic, rhs: ApproovConfigDiagnostic) -> Bool {
        return (lhs.level == rhs.level) && (lhs.message == rhs.message)
    }
}

// the cause of rejecting configuration content, which names a key at most and never a value
package struct ApproovConfigRejection: Error, Equatable {
    package let cause: String
}

// the options of a persistent configuration, to be applied in place of the same keys of the bundled file
package struct ApproovPersistentOverride: Equatable, Sendable {

    // the source tag stored with the options, or nil for none
    package let source: String?

    // every key of the stored options, each replacing the same key of the file even when its value is skipped
    package let keys: [String]

    // the options with a value that passed the checks, in the order they are applied
    package let options: [ApproovConfigOption]

    // the lines logged when the options are applied, for unknown keys and skipped values
    package let diagnostics: [ApproovConfigDiagnostic]
}

// ApproovConfigFile is the content of the bundled approov.config file: the account ID and comment that the
// file form of initialize passes to the SDK, and the options applied when that call first initializes the layer
package struct ApproovConfigFile: Equatable, Sendable {

    // the name of the file, used in every message about it
    package static let fileName = "approov.config"

    // the account ID, or an empty string for bypass mode
    package let config: String

    // the comment passed to the SDK, or nil for none
    package let comment: String?

    // the options in the order they are applied, logLevel first
    package let options: [ApproovConfigOption]

    // the lines logged when the options are applied, for unknown keys and skipped values
    package let diagnostics: [ApproovConfigDiagnostic]

    // true if the file is a 3.5.x configuration file holding only the account ID on its first line
    package let isLegacy: Bool

    // the SHA-256 of the bytes of the file as lowercase hex, which ties a persistent configuration to the file
    package let contentHash: String

    // the persistent configuration merged into the options, or nil for none
    package let override: ApproovPersistentOverride?

    // the lines about a persistent configuration deleted instead of applied, logged after the logging level is set
    package var notices: [ApproovConfigDiagnostic] = []

    // the name the lines give for a value that comes from a persistent configuration
    package static let persistentName = fileName + " (persistent)"

    // the keys only the bundled file may hold, never a persistent configuration
    package static let fileOnlyKeys = ["config", "comment", "devKey"]

    // the keys read from a JSON file, in the order their options are applied; the binding header comes after
    // the substitution headers so a clash with one of them skips the binding header
    private static let optionKeys = [
        "logLevel", "devKey", "tokenHeader", "traceIDHeader", "statusHeader", "mutator", "messageSigning",
        "substitutionHeaders", "substitutionQueryParams", "exclusionURLRegexes", "bindingHeader",
    ]

    // the largest file accepted, 1 MiB, which is far above any real configuration
    package static let maxFileSize = 1_048_576

    // the UTF-8 byte order mark, which is ignored at the start of the file
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /**
     * Reads the configuration file at the given location. A missing or unreadable file is an error,
     * as is a file that parse rejects. The error names the cause and never the content of the file,
     * and is also logged.
     *
     * @param url is the location of the file, or nil if the file is not present
     * @return ApproovConfigFile holding the content of the file
     * @throws ApproovServiceError if there was a problem, as an initializationError naming the cause
     */
    package static func read(from url: URL?) throws -> ApproovConfigFile {
        guard let url = url else {
            throw failure("not found in the main bundle")
        }
        // a file above the limit is refused before it is read
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize {
            throw failure("larger than 1 MiB")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw failure("unreadable")
        }
        return try parse(data)
    }

    /**
     * Parses the content of a configuration file. Content whose first non-whitespace character is
     * not "{" is a 3.5.x configuration file, whose first line is the account ID, unless it is a
     * top-level JSON array or scalar, which is rejected. Otherwise it must be a single JSON object
     * without duplicate keys and with a string config. Unknown keys and known keys with a bad value
     * do not fail parsing: they are recorded as diagnostics and left out of the options.
     *
     * @param data is the content of the file, with or without a leading UTF-8 byte order mark
     * @return ApproovConfigFile holding the content of the file
     * @throws ApproovServiceError if there was a problem, as an initializationError naming the cause
     */
    package static func parse(_ data: Data) throws -> ApproovConfigFile {
        // a file above the limit is invalid whatever it holds
        guard data.count <= maxFileSize else {
            throw failure("larger than 1 MiB")
        }
        let contentHash = sha256Hex(data)

        // ignore a leading byte order mark
        var bytes = [UInt8](data)
        if bytes.starts(with: byteOrderMark) {
            bytes.removeFirst(byteOrderMark.count)
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw failure("not valid UTF-8")
        }

        // the first character that is not Unicode whitespace decides the format, and the same definition of
        // whitespace is used to find the 3.5.x line, so content starting with "{" or "[" is never a 3.5.x file
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else {
            throw failure("no config")
        }
        let first = scalars[start]
        if first == "{" {
            return try parseObject(Data(bytes), contentHash: contentHash)
        }
        if first == "[" {
            throw failure("not a JSON object")
        }

        // a top-level JSON scalar is not a 3.5.x configuration string, which starts with "#" or is a JWT
        do {
            try ApproovStrictJSON.check(Data(bytes))
            throw failure("not a JSON object")
        } catch ApproovStrictJSON.Problem.numberOutOfRange {
            throw failure("not valid JSON")
        } catch is ApproovStrictJSON.Problem {
            // not JSON, so a 3.5.x configuration file
        }

        // a 3.5.x configuration file holds the account ID on its first non-blank line and no options
        let rest = scalars[start...]
        let lineEnd = rest.firstIndex(where: { isLineBreak($0) }) ?? rest.endIndex
        var line = String.UnicodeScalarView(rest[start..<lineEnd])
        while let last = line.last, last.properties.isWhitespace {
            line.removeLast()
        }

        // a 3.5.x configuration string never holds "{" or a quote, so such a line is broken JSON, for example behind
        // an invisible character, and is never passed to the SDK as the account ID
        if line.contains(where: { ($0 == "{") || ($0 == "\"") }) {
            throw failure("not valid JSON")
        }
        return ApproovConfigFile(config: String(line), comment: nil, options: [], diagnostics: [], isLegacy: true,
                                 contentHash: contentHash, override: nil)
    }

    /**
     * Parses a configuration file that holds a JSON object.
     *
     * @param data is the content of the file without a byte order mark
     * @param contentHash is the SHA-256 of the bytes of the file as lowercase hex
     * @return ApproovConfigFile holding the content of the file
     * @throws ApproovServiceError if there was a problem, as an initializationError naming the cause
     */
    private static func parseObject(_ data: Data, contentHash: String) throws -> ApproovConfigFile {
        let object: NSDictionary
        do {
            object = try strictObject(data)
        } catch {
            throw failure((error as? ApproovConfigRejection)?.cause ?? "not valid JSON")
        }

        // the config is required and must be a string
        guard let configValue = object.object(forKey: "config"), !(configValue is NSNull) else {
            throw failure("no config")
        }
        guard let config = string(configValue) else {
            throw failure("config: wrong type")
        }

        // the comment is a string, or null for none
        var diagnostics: [ApproovConfigDiagnostic] = []
        var comment: String?
        if let commentValue = object.object(forKey: "comment"), !(commentValue is NSNull) {
            if let value = string(commentValue) {
                comment = value
            } else {
                diagnostics.append(badValue("comment", "wrong type"))
            }
        }

        // every known option present in the file, in the order they are applied
        var options: [ApproovConfigOption] = []
        for key in optionKeys {
            guard let value = object.object(forKey: key) else { continue }
            if let option = option(key: key, value: value, diagnostics: &diagnostics) {
                options.append(option)
            }
        }

        // an unknown key is ignored, so a newer file still loads
        let knownKeys = Set(optionKeys + ["config", "comment"])
        for key in keys(of: object) where !knownKeys.contains(key) {
            diagnostics.append(unknownKey(key))
        }
        return ApproovConfigFile(config: config, comment: comment, options: options, diagnostics: diagnostics,
                                 isLegacy: false, contentHash: contentHash, override: nil)
    }

    /**
     * Parses content that must be one strict JSON object, with no duplicate key at any depth. The
     * object is kept as an NSDictionary, since keys that differ but are canonically equivalent, such
     * as a precomposed and a decomposed accent, would be silently merged when bridged to a Swift
     * dictionary.
     *
     * @param data is the content without a byte order mark
     * @param maxDepth is the deepest nesting of objects and arrays accepted, the object itself counting as one
     * @return NSDictionary of the object
     * @throws ApproovConfigRejection if the content is not valid JSON or not a JSON object
     */
    package static func strictObject(_ data: Data, maxDepth: Int = ApproovStrictJSON.maxDepth) throws -> NSDictionary {
        // the content must be one strict JSON value without duplicate keys, which JSONSerialization does not check
        do {
            try ApproovStrictJSON.check(data, maxDepth: maxDepth)
        } catch ApproovStrictJSON.Problem.duplicateKey(let key) {
            throw ApproovConfigRejection(cause: "duplicate key \(loggableKey(key))")
        } catch {
            // a syntax error, a nesting limit exceeded, or a number that is not finite as a double
            throw ApproovConfigRejection(cause: "not valid JSON")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ApproovConfigRejection(cause: "not valid JSON")
        }
        guard let object = parsed as? NSDictionary else {
            throw ApproovConfigRejection(cause: "not a JSON object")
        }
        return object
    }

    /**
     * Reads the options of a persistent configuration as the file reads its options: a known key with
     * a bad value is skipped with an error line and an unknown key is ignored with an info line, both
     * worded as for the file but naming the persistent configuration. The keys only the file may hold
     * are left out.
     *
     * @param object is the options object
     * @param source is the source tag stored with the options, or nil for none
     * @return ApproovPersistentOverride holding the options
     */
    package static func persistentOverride(_ object: NSDictionary, source: String?) -> ApproovPersistentOverride {
        var options: [ApproovConfigOption] = []
        var diagnostics: [ApproovConfigDiagnostic] = []
        for key in optionKeys where !fileOnlyKeys.contains(key) {
            guard let value = object.object(forKey: key) else { continue }
            if let option = option(key: key, value: value, label: persistentName, diagnostics: &diagnostics) {
                options.append(option)
            }
        }
        let knownKeys = Set(optionKeys + fileOnlyKeys)
        for key in keys(of: object) where !knownKeys.contains(key) {
            diagnostics.append(unknownKey(key, label: persistentName))
        }
        let present = keys(of: object).filter { !fileOnlyKeys.contains($0) }
        return ApproovPersistentOverride(source: source, keys: present, options: options, diagnostics: diagnostics)
    }

    /**
     * Checks the options of a persistent configuration before they are stored, more strictly than the
     * file: the keys only the file may hold are refused, and so is any known key with a value the file
     * would skip, a bad list element included, an exclusion pattern that does not compile, and a
     * binding header that is also one of its substitution headers, also once merged over the bundled
     * file. Unknown keys are accepted.
     *
     * @param object is the options object
     * @param bundled is the object of the bundled file, or nil if there is no valid JSON one
     * @throws ApproovConfigRejection naming the first key refused and why, never a value
     */
    package static func checkPersistentOptions(_ object: NSDictionary, bundled: NSDictionary?) throws {
        for key in fileOnlyKeys where object.object(forKey: key) != nil {
            throw ApproovConfigRejection(cause: "\(key): not allowed")
        }
        let override = persistentOverride(object, source: nil)
        if let problem = override.diagnostics.first(where: { $0.level == .error }) {
            throw ApproovConfigRejection(cause: problem.cause ?? "not valid")
        }

        // what only the setters find when the options are applied
        for option in override.options {
            switch option {
            case .exclusionURLRegexes(let patterns):
                for pattern in patterns where (try? NSRegularExpression(pattern: pattern)) == nil {
                    throw ApproovConfigRejection(cause: "exclusionURLRegexes: invalid regular expression")
                }
            case .bindingHeader(let header?):
                for case .substitutionHeaders(let headers) in override.options
                where headers.keys.contains(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) {
                    throw ApproovConfigRejection(cause: "bindingHeader: a substitution header")
                }
            default:
                break
            }
        }

        // the same clash between a key of the options and a key the bundled file keeps
        if let bundled = bundled {
            let value: (String) -> Any? = { key in object.object(forKey: key) ?? bundled.object(forKey: key) }
            if let binding = value("bindingHeader") as? String, let headers = value("substitutionHeaders") as? NSDictionary,
               keys(of: headers).contains(where: { $0.caseInsensitiveCompare(binding) == .orderedSame }) {
                if object.object(forKey: "bindingHeader") != nil {
                    throw ApproovConfigRejection(cause: "bindingHeader: a substitution header")
                }
                throw ApproovConfigRejection(cause: "substitutionHeaders: element is the binding header")
            }
        }
    }

    /**
     * Gets the configuration file with a persistent configuration in place of its own options: each
     * key the persistent configuration holds replaces the whole value of the same key in the file, so
     * a token header or a list replaces the bundled value rather than adding to it, and a skipped value
     * leaves the key unset. The account ID, comment and development key always come from the file. The
     * lines logged are those the merged options would give, in the order the file gives them.
     *
     * @param override is the persistent configuration, or nil for none
     * @param notices are the lines about a persistent configuration deleted instead of applied
     * @return ApproovConfigFile holding the merged options
     */
    package func merging(_ override: ApproovPersistentOverride?,
                         notices: [ApproovConfigDiagnostic] = []) -> ApproovConfigFile {
        guard let override = override else {
            return ApproovConfigFile(config: config, comment: comment, options: options, diagnostics: diagnostics,
                                     isLegacy: isLegacy, contentHash: contentHash, override: nil, notices: notices)
        }
        let replaced = Set(override.keys)
        var merged: [ApproovConfigOption] = []
        for key in Self.optionKeys {
            let source = replaced.contains(key) ? override.options : options
            if let option = source.first(where: { $0.key == key }) {
                merged.append(option)
            }
        }
        let lines = diagnostics.filter { ($0.key == nil) || !replaced.contains($0.key ?? "") } + override.diagnostics
        let ordered = lines.enumerated().sorted { lhs, rhs in
            let left = Self.order(of: lhs.element.key)
            let right = Self.order(of: rhs.element.key)
            return (left != right) ? (left < right) : (lhs.offset < rhs.offset)
        }.map { $0.element }
        return ApproovConfigFile(config: config, comment: comment, options: merged, diagnostics: ordered,
                                 isLegacy: isLegacy, contentHash: contentHash, override: override, notices: notices)
    }

    /**
     * Gets the name the lines about an option give for where its value comes from: the persistent
     * configuration if it holds the key, the file otherwise.
     *
     * @param key is the key of the option
     * @return String naming where the value comes from
     */
    package func origin(of key: String) -> String {
        return (override?.keys.contains(key) ?? false) ? Self.persistentName : Self.fileName
    }

    /**
     * Gets where a line about a key comes in the lines of a file: the comment first, then the options
     * in the order they are applied, then the unknown keys sorted.
     *
     * @param key is the top-level key the line is about, or nil for none
     * @return String that sorts in that order
     */
    private static func order(of key: String?) -> String {
        guard let key = key else { return "0" }
        if key == "comment" {
            return "1"
        }
        if let index = optionKeys.firstIndex(of: key) {
            return String(format: "2%03d", index)
        }
        return "3" + key
    }

    /**
     * Gets the SHA-256 of some bytes as lowercase hex.
     *
     * @param data is the bytes to be hashed
     * @return String of the hash
     */
    package static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // an info line for an unknown key, which names the key only
    private static func unknownKey(_ key: String, label: String = fileName) -> ApproovConfigDiagnostic {
        return ApproovConfigDiagnostic(level: .info, message: "\(label): unknown key \(loggableKey(key)) ignored",
                                       key: key)
    }

    /**
     * Gets the option for a known key, checking the type and value. A bad value is recorded as an
     * error diagnostic naming the key, and so is each bad element of a list, which is left out while
     * the others are kept.
     *
     * @param key is the known key
     * @param value is the value of the key as parsed by JSONSerialization
     * @param label is the name the lines give for where the value comes from
     * @param diagnostics are the diagnostics to which any problem is added
     * @return ApproovConfigOption for the key, or nil if its value is skipped
     */
    private static func option(key: String, value: Any, label: String = fileName,
                               diagnostics: inout [ApproovConfigDiagnostic]) -> ApproovConfigOption? {
        switch key {
        case "logLevel":
            let levels: [String: ApproovLogLevel] = [
                "OFF": .off, "ERROR": .error, "WARNING": .warning, "INFO": .info, "DEBUG": .debug,
            ]
            guard let name = string(value) else { break }
            guard let level = levels[name] else { return skip(key, "unknown value", label, &diagnostics) }
            return .logLevel(level)

        case "devKey":
            guard let devKey = string(value) else { break }
            guard !devKey.isEmpty else { return skip(key, "empty value", label, &diagnostics) }
            return .devKey(devKey)

        case "tokenHeader":
            guard let header = value as? NSDictionary else { break }
            guard let name = header.object(forKey: "name").flatMap(string), !name.isEmpty else {
                return skip(key, "name missing or not a non-empty string", label, &diagnostics)
            }
            var prefix = ""
            if let prefixValue = header.object(forKey: "prefix") {
                guard let value = string(prefixValue) else { return skip(key, "prefix: wrong type", label, &diagnostics) }
                prefix = value
            }
            for subkey in keys(of: header) where (subkey != "name") && (subkey != "prefix") {
                diagnostics.append(ApproovConfigDiagnostic(
                    level: .info, message: "\(label): unknown key \(loggableKey(key + "." + subkey)) ignored",
                    key: key))
            }
            return .tokenHeader(name: name, prefix: prefix)

        case "traceIDHeader", "statusHeader", "bindingHeader":
            // null disables the header
            var header: String?
            if !(value is NSNull) {
                guard let name = string(value) else { break }
                guard !name.isEmpty else { return skip(key, "empty name", label, &diagnostics) }
                header = name
            }
            switch key {
            case "traceIDHeader": return .traceIDHeader(header)
            case "statusHeader": return .statusHeader(header)
            default: return .bindingHeader(header)
            }

        case "mutator":
            guard let name = string(value) else { break }
            switch name {
            case "CLOSE_FAILURE": return .mutator(.closeFailure)
            case "ALWAYS_PROCEED": return .mutator(.alwaysProceed)
            default: return skip(key, "unknown value", label, &diagnostics)
            }

        case "messageSigning":
            guard let enabled = bool(value) else { break }
            return .messageSigning(enabled)

        case "substitutionHeaders":
            guard let headers = value as? NSDictionary else { break }
            var accepted: [String: String] = [:]
            for header in keys(of: headers) {
                let prefixValue = headers.object(forKey: header) as Any
                guard !header.isEmpty else {
                    diagnostics.append(badValue(key, label: label, "element with an empty name skipped"))
                    continue
                }
                guard let prefix = string(prefixValue) else {
                    diagnostics.append(badValue(key, label: label, "element with a prefix of the wrong type skipped"))
                    continue
                }
                accepted[header] = prefix
            }
            return .substitutionHeaders(accepted)

        case "substitutionQueryParams", "exclusionURLRegexes":
            guard let elements = value as? [Any] else { break }
            var accepted: [String] = []
            for element in elements {
                guard let name = string(element), !name.isEmpty else {
                    diagnostics.append(badValue(key, label: label, "element that is not a non-empty string skipped"))
                    continue
                }
                accepted.append(name)
            }
            return (key == "substitutionQueryParams")
                ? .substitutionQueryParams(accepted) : .exclusionURLRegexes(accepted)

        default:
            return nil
        }
        return skip(key, "wrong type", label, &diagnostics)
    }

    // records a skipped key as an error diagnostic and gives no option
    private static func skip(_ key: String, _ reason: String, _ label: String,
                             _ diagnostics: inout [ApproovConfigDiagnostic]) -> ApproovConfigOption? {
        diagnostics.append(badValue(key, label: label, reason))
        return nil
    }

    // an error diagnostic naming the key and the reason, never the value
    private static func badValue(_ key: String, label: String = fileName, _ reason: String) -> ApproovConfigDiagnostic {
        return ApproovConfigDiagnostic(level: .error, message: "\(label): \(key): \(reason), skipped",
                                       cause: "\(key): \(reason)", key: key)
    }

    /**
     * Gets a JSON string value, which is never a number or boolean.
     *
     * @param value is the value as parsed by JSONSerialization
     * @return String of the value, or nil if it is not a JSON string
     */
    private static func string(_ value: Any) -> String? {
        return (value is NSNumber) ? nil : (value as? String)
    }

    /**
     * Gets a JSON boolean value. JSONSerialization gives both booleans and numbers as NSNumber, so
     * a boolean is told apart by its CFBoolean type and the number 1 is not true.
     *
     * @param value is the value as parsed by JSONSerialization
     * @return Bool of the value, or nil if it is not a JSON boolean
     */
    package static func bool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    // gets the keys of a JSON object, sorted so that the lines logged about them are in a fixed order
    private static func keys(of object: NSDictionary) -> [String] {
        return object.allKeys.compactMap { $0 as? String }.sorted()
    }

    // the most UTF-16 code units of a key shown in a log line or an error message
    package static let maxLoggedKeyLength = 40

    /**
     * Gets a key as it may be logged, as loggable does, cut after 40 UTF-16 code units.
     *
     * @param key is the key as found in the file
     * @return String of the key for a log line or an error message
     */
    package static func loggableKey(_ key: String) -> String {
        return loggable(key, limit: maxLoggedKeyLength)
    }

    /**
     * Gets a string as it may be logged: quoted and escaped as a JSON string, so that it can neither
     * break nor forge a log line, and cut after the given number of UTF-16 code units with "..." after
     * the closing quote. Control characters and a surrogate left unpaired by the cut are written as
     * lowercase \u escapes.
     *
     * @param value is the string to be logged
     * @param limit is the number of UTF-16 code units shown before the string is cut
     * @return String for a log line or an error message
     */
    package static func loggable(_ value: String, limit: Int) -> String {
        let units = Array(value.utf16)
        let cut = units.count > limit
        let shown = cut ? Array(units[0..<limit]) : units
        var out = "\""
        var index = 0
        while index < shown.count {
            let unit = shown[index]

            // a surrogate pair is kept as the character it encodes
            if UTF16.isLeadSurrogate(unit), (index + 1) < shown.count, UTF16.isTrailSurrogate(shown[index + 1]) {
                out += String(decoding: shown[index...(index + 1)], as: UTF16.self)
                index += 2
                continue
            }
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if let scalar = Unicode.Scalar(unit), unit >= 0x20 {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += String(format: "\\u%04x", Int(unit))
                }
            }
            index += 1
        }
        out += "\""
        return cut ? (out + "...") : out
    }

    // determines whether a character ends a line: LF, VT, FF, CR, NEL, LS or PS
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /**
     * Gets the error for a configuration file that cannot be used, logging it. The cause never
     * includes the content of the file.
     *
     * @param cause is the cause of the problem
     * @return ApproovServiceError as an initializationError naming the cause
     */
    private static func failure(_ cause: String) -> ApproovServiceError {
        let message = "initialize: \(fileName) \(cause)"
        ApproovLog.log(.error, message)
        return ApproovServiceError.initializationError(message: message)
    }
}

// ApproovStrictJSON checks that a document is strict JSON, as RFC 8259 defines it, and that no object holds
// the same key twice. JSONSerialization accepts trailing commas and keeps one of two duplicate keys, so a file
// it parses is checked here as well.
struct ApproovStrictJSON {

    // a problem found in the document
    enum Problem: Error, Equatable {
        // the document is not strict JSON
        case syntax

        // an object holds the given key more than once
        case duplicateKey(String)

        // the document is valid JSON but holds a number that is not finite as a double
        case numberOutOfRange
    }

    // the deepest nesting of objects and arrays accepted, so the recursion stays well within the stack
    static let maxDepth = 128

    // the bytes of the document and the position reached
    private let bytes: [UInt8]
    private var index = 0

    // the deepest nesting of objects and arrays accepted in this document
    private let depthLimit: Int

    // true once a number that is not finite as a double has been read
    private var outOfRange = false

    /**
     * Checks a document, which must be one JSON value with only whitespace around it.
     *
     * @param data is the content of the document
     * @param maxDepth is the deepest nesting of objects and arrays accepted, at most 128
     * @throws Problem if the document is not strict JSON, an object holds a key more than once, or a
     * number is not finite as a double
     */
    static func check(_ data: Data, maxDepth: Int = maxDepth) throws {
        var parser = ApproovStrictJSON(bytes: [UInt8](data), depthLimit: min(maxDepth, Self.maxDepth))
        parser.skipWhitespace()
        try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw Problem.syntax }

        // a syntax error is reported in preference to a number out of range
        if parser.outOfRange {
            throw Problem.numberOutOfRange
        }
    }

    private init(bytes: [UInt8], depthLimit: Int) {
        self.bytes = bytes
        self.depthLimit = depthLimit
    }

    // the byte at the current position, or nil at the end
    private var current: UInt8? {
        return (index < bytes.count) ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = current, (byte == 0x20) || (byte == 0x09) || (byte == 0x0A) || (byte == 0x0D) {
            index += 1
        }
    }

    // consumes the given byte, which must be at the current position
    private mutating func expect(_ byte: UInt8) throws {
        guard current == byte else { throw Problem.syntax }
        index += 1
    }

    // consumes the given literal, such as true, which must be at the current position
    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            try expect(byte)
        }
    }

    /**
     * Consumes one value starting at the current position.
     *
     * @param depth is the number of objects and arrays the value is inside
     * @throws Problem if there was a problem
     */
    private mutating func value(depth: Int) throws {
        guard let byte = current else { throw Problem.syntax }
        switch byte {
        case UInt8(ascii: "{"):
            try object(depth: depth + 1)
        case UInt8(ascii: "["):
            try array(depth: depth + 1)
        case UInt8(ascii: "\""):
            _ = try string()
        case UInt8(ascii: "t"):
            try literal("true")
        case UInt8(ascii: "f"):
            try literal("false")
        case UInt8(ascii: "n"):
            try literal("null")
        default:
            try number()
        }
    }

    /**
     * Consumes an object, checking that no key appears twice. Keys are compared after their escapes
     * are decoded, by their Unicode scalars, so "a" and "a" are the same key, while a precomposed
     * and a decomposed accent are not.
     *
     * @param depth is the nesting depth of the object
     * @throws Problem if there was a problem
     */
    private mutating func object(depth: Int) throws {
        guard depth <= depthLimit else { throw Problem.syntax }
        try expect(UInt8(ascii: "{"))
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return
        }
        var keys = Set<[Unicode.Scalar]>()
        while true {
            skipWhitespace()
            let key = try string()
            if !keys.insert(Array(key.unicodeScalars)).inserted {
                throw Problem.duplicateKey(key)
            }
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            try value(depth: depth)
            skipWhitespace()
            if current == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect(UInt8(ascii: "}"))
            return
        }
    }

    /**
     * Consumes an array.
     *
     * @param depth is the nesting depth of the array
     * @throws Problem if there was a problem
     */
    private mutating func array(depth: Int) throws {
        guard depth <= depthLimit else { throw Problem.syntax }
        try expect(UInt8(ascii: "["))
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return
        }
        while true {
            skipWhitespace()
            try value(depth: depth)
            skipWhitespace()
            if current == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect(UInt8(ascii: "]"))
            return
        }
    }

    /**
     * Consumes a string, which holds no unescaped control character and only the escapes JSON
     * defines.
     *
     * @return String of the decoded value
     * @throws Problem if there was a problem
     */
    private mutating func string() throws -> String {
        let start = index
        try expect(UInt8(ascii: "\""))
        while true {
            guard let byte = current, byte >= 0x20 else { throw Problem.syntax }
            index += 1
            if byte == UInt8(ascii: "\"") {
                break
            }
            if byte == UInt8(ascii: "\\") {
                guard let escaped = current else { throw Problem.syntax }
                index += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                     UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    break
                case UInt8(ascii: "u"):
                    for _ in 0..<4 {
                        guard let hex = current, isHexDigit(hex) else { throw Problem.syntax }
                        index += 1
                    }
                default:
                    throw Problem.syntax
                }
            }
        }

        // the escapes are decoded by JSONSerialization, which also rejects a lone surrogate
        let token = Data(bytes[start..<index])
        guard let decoded = (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) as? String else {
            throw Problem.syntax
        }
        return decoded
    }

    // consumes a number: an optional minus, an integer part without leading zeros, then any fraction and exponent;
    // one that is not finite as a double is recorded as out of range
    private mutating func number() throws {
        let start = index
        defer {
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if let value = Double(token), !value.isFinite {
                outOfRange = true
            }
        }
        if current == UInt8(ascii: "-") {
            index += 1
        }
        if current == UInt8(ascii: "0") {
            index += 1
        } else {
            try digits()
        }
        if current == UInt8(ascii: ".") {
            index += 1
            try digits()
        }
        if (current == UInt8(ascii: "e")) || (current == UInt8(ascii: "E")) {
            index += 1
            if (current == UInt8(ascii: "+")) || (current == UInt8(ascii: "-")) {
                index += 1
            }
            try digits()
        }
    }

    // consumes one or more decimal digits
    private mutating func digits() throws {
        guard let first = current, isDigit(first) else { throw Problem.syntax }
        while let byte = current, isDigit(byte) {
            index += 1
        }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        return (byte >= UInt8(ascii: "0")) && (byte <= UInt8(ascii: "9"))
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        return isDigit(byte) || ((byte >= UInt8(ascii: "a")) && (byte <= UInt8(ascii: "f"))) ||
            ((byte >= UInt8(ascii: "A")) && (byte <= UInt8(ascii: "F")))
    }
}
