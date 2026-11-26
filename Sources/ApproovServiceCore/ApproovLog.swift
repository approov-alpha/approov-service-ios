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

// ApproovLog writes the request path conditions an integrator needs to see. Messages name headers, query
// parameters and hooks but never a value, and are logged public; a host named inside a message, and
// anything that could carry a value, such as an error description, is logged private.
enum ApproovLog {

    // the lock guarding the observers and the once-only messages
    private static let lock = NSLock()

    // receives every message logged, whatever the logging level, for tests only
    nonisolated(unsafe) private static var observerValue: ((ApproovLogLevel, String) -> Void)?

    static var observer: ((ApproovLogLevel, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return observerValue }
        set { lock.lock(); observerValue = newValue; lock.unlock() }
    }

    // receives every message the logging level lets through to os_log, without the detail, for tests only
    nonisolated(unsafe) private static var emittedObserverValue: ((ApproovLogLevel, String) -> Void)?

    static var emittedObserver: ((ApproovLogLevel, String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return emittedObserverValue }
        set { lock.lock(); emittedObserverValue = newValue; lock.unlock() }
    }

    // the messages already logged by logOnce
    nonisolated(unsafe) private static var loggedOnce: Set<String> = []

    /**
     * Logs a message the first time it is passed in this process and never again, whatever the
     * logging level was the first time.
     *
     * @param level is the logging level of the message
     * @param message is the message to be logged
     */
    static func logOnce(_ level: ApproovLogLevel, _ message: String) {
        lock.lock()
        let first = loggedOnce.insert(message).inserted
        lock.unlock()
        if first {
            log(level, message)
        }
    }

    // forgets which once-only messages were logged, for tests only
    static func resetOnceMessages() {
        lock.lock(); loggedOnce.removeAll(); lock.unlock()
    }

    /**
     * Logs a message if the logging level includes it, with any detail logged private.
     *
     * @param level is the logging level of the message
     * @param message is the message to be logged, which must never include a value
     * @param detail is any detail that could carry a value, or nil for none
     */
    static func log(_ level: ApproovLogLevel, _ message: String, detail: String? = nil) {
        observer?(level, detail.map { "\(message): \($0)" } ?? message)
        guard ApproovInterceptor.shared.loggingLevel >= level else { return }
        emittedObserver?(level, message)
        let type = osLogType(level)
        if let detail = detail {
            os_log("ApproovService: %{public}@: %{private}@", type: type, message, detail)
        } else {
            os_log("ApproovService: %{public}@", type: type, message)
        }
    }

    /**
     * Logs a message if the logging level includes it, building it only then, so a message that is
     * costly to build, or that names a value the app supplied, costs nothing when it is not logged.
     *
     * @param level is the logging level of the message
     * @param message is the message to be logged, which must never include a value
     */
    static func log(_ level: ApproovLogLevel, lazy message: @autoclosure () -> String) {
        guard (observer != nil) || (ApproovInterceptor.shared.loggingLevel >= level) else { return }
        log(level, message())
    }

    /**
     * Logs a message naming a host if the logging level includes it. The text reads the same as on
     * the other platforms, but the host is logged private, as is any detail.
     *
     * @param level is the logging level of the message
     * @param before is the text before the host, which must never include a value
     * @param host is the host named by the message
     * @param after is the text after the host, which must never include a value
     * @param detail is any detail that could carry a value, or nil for none
     */
    static func log(_ level: ApproovLogLevel, _ before: String, host: String, _ after: String = "",
                    detail: String? = nil) {
        let message = before + host + after
        observer?(level, detail.map { "\(message): \($0)" } ?? message)
        guard ApproovInterceptor.shared.loggingLevel >= level else { return }
        emittedObserver?(level, before + "<private>" + after)
        let type = osLogType(level)
        if let detail = detail {
            os_log("ApproovService: %{public}@%{private}@%{public}@: %{private}@", type: type, before, host, after, detail)
        } else {
            os_log("ApproovService: %{public}@%{private}@%{public}@", type: type, before, host, after)
        }
    }

    /**
     * Gets the os_log type for a logging level.
     *
     * @param level is the logging level
     * @return OSLogType for the level
     */
    private static func osLogType(_ level: ApproovLogLevel) -> OSLogType {
        switch level {
        case .error: return .error
        case .warning: return .default
        case .info: return .info
        case .debug, .off: return .debug
        }
    }
}

extension ApproovLogLevel {
    // the name of the level as a setter logs it and approov.config names it, such as DEBUG
    var name: String {
        switch self {
        case .off: return "OFF"
        case .error: return "ERROR"
        case .warning: return "WARNING"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }
}
