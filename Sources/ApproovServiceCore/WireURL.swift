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

// WireURL reads a request URL as URLSession writes it on the wire, for message signing. The URL string is
// only split at its delimiters, so nothing is decoded, re-encoded or validated and no input makes any
// function fail; URL and URLComponents decode the path and query, so they must not be used here.
// URLSession lowercases the host, keeps an explicit port, sends "/" for an empty path and never sends the
// user information or the fragment, and targetURI makes exactly those changes.
enum WireURL {

    // the URL up to the first "#", since a fragment is never sent
    static func withoutFragment(_ url: String) -> Substring {
        return url[..<(url.firstIndex(of: "#") ?? url.endIndex)]
    }

    // the end of "scheme:" if the URL starts with a scheme, or the start otherwise
    private static func schemeEnd(_ url: Substring) -> Substring.Index {
        guard let colon = url.firstIndex(of: ":"), colon > url.startIndex else { return url.startIndex }
        for (offset, character) in url[..<colon].enumerated() {
            let alpha = character.isASCII && character.isLetter
            let other = character.isASCII && (character.isNumber || "+-.".contains(character))
            if !(alpha || ((offset > 0) && other)) {
                return url.startIndex
            }
        }
        return url.index(after: colon)
    }

    // the index of the first of the delimiters from a position, or the end
    private static func firstIndex(in url: Substring, from: Substring.Index, of delimiters: String) -> Substring.Index {
        return url[from...].firstIndex { delimiters.contains($0) } ?? url.endIndex
    }

    /**
     * Gets the scheme of a URL in lowercase.
     *
     * @param url is the URL string
     * @return the scheme or nil if the URL has none
     */
    static func scheme(_ url: String) -> String? {
        let wire = withoutFragment(url)
        let end = schemeEnd(wire)
        guard end > wire.startIndex else { return nil }
        return wire[wire.startIndex..<wire.index(before: end)].lowercased()
    }

    // where the authority starts, or nil if the URL has none
    private static func authorityStart(_ url: Substring) -> Substring.Index? {
        let start = schemeEnd(url)
        guard url[start...].hasPrefix("//") else { return nil }
        return url.index(start, offsetBy: 2)
    }

    // the host and port as sent, which is the authority without any user information
    private static func hostAndPort(_ url: Substring) -> Substring? {
        guard let start = authorityStart(url) else { return nil }
        let authority = url[start..<firstIndex(in: url, from: start, of: "/?#")]
        if let at = authority.lastIndex(of: "@") {
            return authority[authority.index(after: at)...]
        }
        return authority
    }

    // the index of the ":" that starts the port, or nil if there is none
    private static func portColon(_ hostAndPort: Substring) -> Substring.Index? {
        if hostAndPort.hasPrefix("[") {
            guard let close = hostAndPort.firstIndex(of: "]") else { return nil }
            let next = hostAndPort.index(after: close)
            return ((next < hostAndPort.endIndex) && (hostAndPort[next] == ":")) ? next : nil
        }
        return hostAndPort.lastIndex(of: ":")
    }

    /**
     * Gets the host of a URL in lowercase, without user information or port. An IPv6 literal
     * keeps its brackets.
     *
     * @param url is the URL string
     * @return the host or nil if the URL has no authority
     */
    static func host(_ url: String) -> String? {
        guard let hostAndPort = hostAndPort(withoutFragment(url)) else { return nil }
        let end = portColon(hostAndPort) ?? hostAndPort.endIndex
        return hostAndPort[..<end].lowercased()
    }

    /**
     * Gets the port of a URL as sent, which may not be a number.
     *
     * @param url is the URL string
     * @return the port text or nil if there is none or it is empty
     */
    static func portText(_ url: String) -> String? {
        guard let hostAndPort = hostAndPort(withoutFragment(url)),
              let colon = portColon(hostAndPort) else { return nil }
        let text = hostAndPort[hostAndPort.index(after: colon)...]
        return text.isEmpty ? nil : String(text)
    }

    // where the path starts
    private static func pathStart(_ url: Substring) -> Substring.Index {
        guard let start = authorityStart(url) else { return schemeEnd(url) }
        return firstIndex(in: url, from: start, of: "/?#")
    }

    /**
     * Gets the path of a URL as sent, still percent-encoded.
     *
     * @param url is the URL string
     * @return the path or an empty string if the URL has none
     */
    static func path(_ url: String) -> String {
        let wire = withoutFragment(url)
        let start = pathStart(wire)
        return String(wire[start..<firstIndex(in: wire, from: start, of: "?")])
    }

    /**
     * Gets the query of a URL as sent, still percent-encoded and without the leading "?".
     *
     * @param url is the URL string
     * @return the query, an empty string for a bare "?", or nil if the URL has none
     */
    static func query(_ url: String) -> String? {
        let wire = withoutFragment(url)
        let mark = firstIndex(in: wire, from: pathStart(wire), of: "?")
        guard mark < wire.endIndex else { return nil }
        return String(wire[wire.index(after: mark)...])
    }

    /**
     * Gets the path and query as written in the request line, with "/" for an empty path.
     *
     * @param url is the URL string
     * @return the request target
     */
    static func requestTarget(_ url: String) -> String {
        let path = path(url)
        let target = path.isEmpty ? "/" : path
        guard let query = query(url) else { return target }
        return target + "?" + query
    }

    /**
     * Gets the target URI as URLSession sends it: the scheme, the host as the Host header carries
     * it, and the request target. A URL without an authority is only stripped of its fragment.
     *
     * @param url is the URL string
     * @return the target URI
     */
    static func targetURI(_ url: String) -> String {
        guard let scheme = scheme(url), let host = host(url) else {
            return String(withoutFragment(url))
        }
        let port = portText(url).map { ":" + $0 } ?? ""
        return scheme + "://" + host + port + requestTarget(url)
    }

    /**
     * Gets the authority of a URL: the lowercase host, followed by the port only if it is not the
     * default for the scheme.
     *
     * @param url is the URL string
     * @return the authority or nil if the URL has none
     */
    static func authority(_ url: String) -> String? {
        guard let host = host(url) else { return nil }
        guard let port = portText(url) else { return host }
        switch (scheme(url), port) {
        case ("https", "443"), ("http", "80"):
            return host
        default:
            return host + ":" + port
        }
    }

    /**
     * Gets the host as a message signing host factory is keyed: lowercase, without a port, and an
     * IPv6 address without its brackets.
     *
     * @param url is the URL string
     * @return the host or nil if the URL has no authority
     */
    static func factoryHost(_ url: String) -> String? {
        guard var host = host(url) else { return nil }
        if host.count >= 2, host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    /**
     * Gets the value of a query parameter for the @query-param component. It is looked up by its
     * decoded name, and its value is decoded and encoded again with the form percent-encode set.
     *
     * @param url is the URL string
     * @param name is the name of the query parameter
     * @return the encoded value, or nil if the name is absent or occurs more than once
     */
    static func queryParam(_ url: String, name: String) -> String? {
        guard let query = query(url) else { return nil }
        let decodedName = formDecode(name)
        var values: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let key: Substring
            let value: Substring
            if let equals = pair.firstIndex(of: "=") {
                key = pair[..<equals]
                value = pair[pair.index(after: equals)...]
            } else {
                key = pair
                value = ""
            }
            if formDecode(key) == decodedName {
                values.append(formDecode(value))
            }
        }
        guard values.count == 1 else { return nil }
        return formEncode(values[0])
    }

    /**
     * Decodes application/x-www-form-urlencoded text, where "+" is a space and %XX a byte of UTF-8.
     * A malformed escape is kept as it is.
     *
     * @param text is the text to be decoded
     * @return the decoded text
     */
    static func formDecode<S: StringProtocol>(_ text: S) -> String {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
            } else if byte == UInt8(ascii: "%"), index + 2 < utf8.count,
                      let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
                continue
            } else {
                bytes.append(byte)
            }
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /**
     * Decodes %XX escapes as UTF-8, leaving "+" as it is.
     *
     * @param text is the text to be decoded
     * @return the decoded text, or nil for a malformed escape or bytes that are not UTF-8
     */
    static func percentDecode(_ text: String) -> String? {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "%") {
                guard index + 2 < utf8.count,
                      let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) else {
                    return nil
                }
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    // the value of a hexadecimal digit, or nil if it is not one
    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /**
     * Percent-encodes UTF-8 text with the application/x-www-form-urlencoded percent-encode set,
     * which leaves only ASCII letters, digits and "*-._".
     *
     * @param text is the text to be encoded
     * @return the encoded text
     */
    static func formEncode(_ text: String) -> String {
        let hex = Array("0123456789ABCDEF")
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                out.append(Character(Unicode.Scalar(byte)))
            default:
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0f)])
            }
        }
        return out
    }
}
