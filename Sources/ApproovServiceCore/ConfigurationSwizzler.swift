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
import ObjectiveC
import os.log

// ConfigurationSwizzler swizzles the URLSessionConfiguration default and ephemeral getters so every
// configuration created from them carries ApproovURLProtocol, since a session built from a configuration
// only consults its own protocolClasses. Background configurations are not touched, as they cannot use a
// custom URLProtocol. Whether the swizzle took and whether Approov is first can be checked with
// interceptionState.
enum ConfigurationSwizzler {

    // the lock guarding swizzledBodies
    private static let lock = NSLock()

    // the getters that are swizzled, each paired with its replacement
    private static let pairs: [(original: Selector, replacement: Selector)] = [
        (#selector(getter: URLSessionConfiguration.default),
         #selector(URLSessionConfiguration.approovService_default)),
        (#selector(getter: URLSessionConfiguration.ephemeral),
         #selector(URLSessionConfiguration.approovService_ephemeral)),
    ]
    // the implementation of the replacement for each swizzled getter, so uninstall can tell whether another
    // SDK has swizzled on top since
    nonisolated(unsafe) private static var swizzledBodies: [Selector: IMP] = [:]

    /**
     * Installs the swizzle of the configuration getters, skipping any already installed. A getter
     * that cannot be found is logged as an error, since sessions built from it bypass Approov.
     *
     * @return true if both getters are swizzled, false otherwise
     */
    @discardableResult
    static func install() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var allOK = true
        for pair in pairs {
            guard swizzledBodies[pair.original] == nil else { continue }
            guard let originalMethod = class_getClassMethod(URLSessionConfiguration.self, pair.original),
                  let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, pair.replacement) else {
                // a missing getter means a newer iOS changed the configuration getters
                if ApproovInterceptor.shared.loggingLevel >= .error {
                    os_log("ApproovService: cannot swizzle URLSessionConfiguration.%{public}@",
                           type: .error, NSStringFromSelector(pair.original))
                }
                allOK = false
                continue
            }
            let bodyIMP = method_getImplementation(replacementMethod)
            method_exchangeImplementations(originalMethod, replacementMethod)
            swizzledBodies[pair.original] = bodyIMP
        }
        return allOK
    }

    /**
     * Removes the swizzle where that is safe. A getter that another SDK has swizzled on top of
     * Approov is left in place, since exchanging back would break that SDK's chain; it stays inert
     * while interception is deactivated.
     *
     * @return true if every getter was restored, false otherwise
     */
    @discardableResult
    static func uninstall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for pair in pairs {
            guard let bodyIMP = swizzledBodies[pair.original] else { continue }
            guard let originalMethod = class_getClassMethod(URLSessionConfiguration.self, pair.original),
                  let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, pair.replacement),
                  method_getImplementation(originalMethod) == bodyIMP else {
                if ApproovInterceptor.shared.loggingLevel >= .error {
                    let owner = class_getClassMethod(URLSessionConfiguration.self, pair.original)
                        .map { Self.implementationOrigin(of: method_getImplementation($0)) } ?? "<unknown>"
                    os_log("ApproovService: URLSessionConfiguration.%{public}@ swizzled after Approov by %{public}@, swizzle left installed",
                           type: .error, NSStringFromSelector(pair.original), owner)
                }
                continue
            }
            // exchanging again restores the original implementation
            method_exchangeImplementations(originalMethod, replacementMethod)
            swizzledBodies[pair.original] = nil
        }
        return swizzledBodies.isEmpty
    }

    /**
     * Determines whether ApproovURLProtocol is present in the protocol classes of a configuration,
     * and if so whether it is first.
     *
     * @param configuration is the session configuration to be checked
     * @return whether the protocol is present and whether it is first
     */
    static func position(in configuration: URLSessionConfiguration) -> (present: Bool, first: Bool) {
        let classes = configuration.protocolClasses ?? []
        guard let index = classes.firstIndex(where: { $0 == ApproovURLProtocol.self }) else {
            return (present: false, first: false)
        }
        return (present: true, first: index == 0)
    }

    /**
     * Gets the owner of an implementation, used to name the framework behind a swizzling conflict.
     *
     * @param imp is the implementation to be looked up
     * @return String of the symbol and the image it is in
     */
    static func implementationOrigin(of imp: IMP) -> String {
        var info = Dl_info()
        guard dladdr(unsafeBitCast(imp, to: UnsafeRawPointer.self), &info) != 0 else {
            return "<unknown>"
        }
        let image = info.dli_fname.map { String(cString: $0) } ?? "<unknown image>"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "<unknown symbol>"
        return "\(symbol) in \(image)"
    }

    /**
     * Gets the owner of the current implementation of the URLSessionConfiguration default getter.
     *
     * @return String of the symbol and the image it is in
     */
    static func defaultGetterOrigin() -> String {
        guard let method = class_getClassMethod(URLSessionConfiguration.self,
                                                #selector(getter: URLSessionConfiguration.default)) else {
            return "<getter not found>"
        }
        return implementationOrigin(of: method_getImplementation(method))
    }

    /**
     * Gets the image a class was loaded from, used to name the SDK behind another URLProtocol.
     *
     * @param cls is the class to be looked up
     * @return String of the image name
     */
    static func classOrigin(_ cls: AnyClass) -> String {
        guard let imageName = class_getImageName(cls) else { return "<unknown image>" }
        return String(cString: imageName)
    }

    /**
     * Determines whether ApproovURLProtocol is present and first in freshly created default and
     * ephemeral configurations. If not present then the swizzle did not take or was removed, and if
     * not first then another URLProtocol-based SDK is ahead of Approov.
     *
     * @return whether the protocol is present and whether it is first in both configurations
     */
    static func interceptionState() -> (present: Bool, first: Bool) {
        for configuration in [URLSessionConfiguration.default, URLSessionConfiguration.ephemeral] {
            let state = position(in: configuration)
            if !state.present { return (present: false, first: false) }
            if !state.first { return (present: true, first: false) }
        }
        return (present: true, first: true)
    }
}

extension URLSessionConfiguration {

    // after the exchange these run for the original getters, and the apparently recursive call runs the
    // implementation that was there before. That call is always sent to URLSessionConfiguration and never to
    // the receiver, since another library that saved one of these implementations may call it with a
    // receiver of its own, which does not respond to the selector
    @objc dynamic class func approovService_default() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.approovService_default()
        ApproovURLProtocol.install(into: configuration)
        return configuration
    }

    @objc dynamic class func approovService_ephemeral() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.approovService_ephemeral()
        ApproovURLProtocol.install(into: configuration)
        return configuration
    }
}
