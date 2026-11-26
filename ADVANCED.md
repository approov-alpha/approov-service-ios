# Advanced Options

A standard integration of the Approov Package for iOS needs nothing in this document. The options below change the defaults, for apps with specific needs. Every public method is in [REFERENCE.md](REFERENCE.md).

The package registers its own `URLProtocol`, the Foundation hook that lets code handle a request in place of the system. This registration covers `URLSession.shared`. The package also swizzles the `URLSessionConfiguration.default` and `.ephemeral` getters, so each configuration that the app gets from them puts `ApproovURLProtocol` first. The package installs both when `initialize` first succeeds, bypass mode included, or earlier when your app or a framework calls [installInterception](REFERENCE.md#installinterception). The package covers any other session only if the app created its configuration after that point (see [known limitations](#known-limitations)).

| What you need | Read |
| :--- | :--- |
| Understand what reaches your backend | [What each request carries](#what-each-request-carries), then [What happens by default](#what-happens-by-default) |
| Fail a request in the app when it has no token | [Service mutators](#service-mutators) |
| Choose the signatures, or turn signing off | [Message signing](#message-signing) |
| Replace an embedded API secret | [Secure strings](#secure-strings) |
| Keep your own trust or authentication logic | [Challenge handler](#challenge-handler), then [Third-party SDKs](#third-party-sdks) |
| Investigate an unexpected result | [Diagnostics](#diagnostics), then [Known limitations](#known-limitations) |

## What each request carries

What the package adds to a request depends on the token fetch status that the SDK gives for its URL. With the default mutator:

| Token fetch status | The request goes to | What the package adds |
| :--- | :--- | :--- |
| `SUCCESS` | an API domain that you added to Approov | the token header, `Approov-Status: SUCCESS`, the trace header when the SDK supplies a trace ID, your secure strings (`https` only) and both signatures |
| `UNPROTECTED_URL` | a [secrets-only API](#secrets-only-apis) | your secure strings (`https` only), and nothing else |
| `UNKNOWN_URL` | a host not added to Approov | nothing |
| any other status (`NO_APPROOV_SERVICE`, `NO_NETWORK`, `REJECTED`, `BAD_URL`, ...) | a [protected domain](#protected-domains) | the `Approov-Status` header only. There is no token header (absent, not empty), no trace header and no signature, and the secure string placeholders go out unchanged |
| any other status | any other host | nothing |

Whatever the status, the package validates the TLS connection to each protected domain (see [connection validation](#connection-validation)). None of these headers reaches an [excluded URL](#excluding-urls), or a request in [bypass mode](#bypass-initialization) or before `initialize`.

The headers your backend can receive:

* `Approov-Token` carries the Approov token, a short-lived signed JWT that proves the app passed attestation. Your backend verifies it, and rejects a request whose token is missing or invalid. The token also carries the public key of the app installation, for the `install` signature.
* `Approov-Status` carries the token fetch status as the SDK names it, such as `SUCCESS` or `NO_NETWORK`, never converted. It replaces any value your app set. It tells your backend why a request carries no proof of attestation. It never describes a secure string outcome.
* `Signature` and `Signature-Input` carry the [message signatures](#message-signing).
* `Approov-TraceID` is an optional debug header. Your backend passes it through unchanged.

## What happens by default

The installed [service mutator](#service-mutators) decides what happens when the package cannot protect a request. The default, `.DEFAULT`, is `.ALWAYS_PROCEED`. It never fails a request because of a token fetch or a secure string fetch. Every request goes out, and your backend decides:

* After a failed token fetch, a request to a protected domain carries the `Approov-Status` header only.
* After a failed secure string fetch, the fetch status takes the place of the placeholder (see [secure strings](#secure-strings)).
* A cleartext (`http`) request to a host that is not a protected domain goes out untouched at once, without a token fetch. So a development server request, such as Metro on `http://127.0.0.1:8081`, is not held.

A request can still fail in the app for these reasons:

* a TLS connection that does not validate
* a configuration error in your app (see [values a header or URL cannot carry](#values-a-header-or-url-cannot-carry) and [message signing](#when-a-signature-cannot-be-produced))
* an abort that a mutator of your own asks for

To fail a request in the app when the token fetch fails, as the 3.5.x packages did, install `.CLOSE_FAILURE` (see [service mutators](#service-mutators)). The direct methods (`fetchToken`, `fetchSecureString`, `fetchCustomJWT`) throw an `ApproovServiceError` on failure, whichever mutator is installed. See the [reference](REFERENCE.md#errors).

## Message signing

Message signing is on by default. The package signs every request that carries the Approov token header with two RFC 9421 signatures. Your backend verifies the signature or signatures that it is configured for, as [installation message signing](https://approov.io/docs/latest/approov-usage-documentation/#installation-message-signing) and [account message signing](https://approov.io/docs/latest/approov-usage-documentation/#account-message-signing) describe.

```swift
ApproovService.disableMessageSigning()          // no Signature / Signature-Input headers
ApproovService.isMessageSigningEnabled()        // false
ApproovService.enableMessageSigning()           // on again, both signatures, default covered components
```

Signing is a switch, not a mutator, and `initialize` leaves it as it is. It runs last, after the mutator decisions, the substitutions and `handleInterceptorProcessedRequest`, so the signature covers what is sent. Only a `SUCCESS` request carries the token header. So the package never signs a request sent after a failed fetch, or a request to a secrets-only API.

The two signatures are members of the same `Signature` and `Signature-Input` dictionaries, as Byte Sequences (`install=:<base64>:, account=:<base64>:`):

* `install` uses `ecdsa-p256-sha256` with a key unique to the app installation, held in the device's secure hardware, sent as the raw 64-byte r||s value.
* `account` uses `hmac-sha256` with the account key, which the app receives when it passes attestation.

Both cover the same components, by default:

* `@method` and `@target-uri`
* the token header, and the trace and status headers when present
* `Authorization`, `Content-Length` and `Content-Type`, when present
* a SHA-256 `Content-Digest`, when the body can be digested. A POST, PUT, PATCH or DELETE without a body is sent with an empty one, and digested as such. GET and HEAD carry no body.
* `created`, and `expires` fifteen seconds later

Each component is covered once, as RFC 9421 requires, so a token on `Authorization` is covered once. The times come from `getServerAdjustedCurrentTimeMS()`, the device clock adjusted by the offset that the SDK learns at each attestation. So a device with a wrong clock still signs within the time window of your backend.

### When a signature cannot be produced

Signing fails open. The package leaves out a signature that it cannot produce, for example with no install key or no account key yet. The request proceeds with the other signature, or unsigned. The package logs each condition once per process. It logs a warning the first time one signature is missing, and an error the first time a request goes unsigned. After that, it logs at `.debug`, so an account without a signing key does not log on every request.

Signing fails closed only on your own configuration errors. A body digest configured as required that cannot be generated, or an unsupported algorithm, fails the request with a `URLError`.

### Choosing the signatures

A `SignatureParametersFactory` decides which signatures a request gets, and what they cover. It selects install only (`setUseInstallMessageSigning()`), account only (`setUseAccountMessageSigning()`) or both (the default), and the covered headers, body digest and timestamps. Pass a factory to `enableMessageSigning` for every host, or to `putMessageSigningHostFactory` for one host, matched without regard to case or port.

```swift
ApproovService.enableMessageSigning(
    ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory().setUseAccountMessageSigning())
ApproovService.putMessageSigningHostFactory(
    hostName: "api.example.com",
    factory: ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory().setUseInstallMessageSigning())
```

Configure a factory completely before you pass it in. The package reads it afterwards, but never changes it.

To decide the signature of each request, subclass the open class `SignatureParametersFactory` and override `buildSignatureParameters(provider:changes:)`. Return `nil` to send a request unsigned. The package calls the override on many threads at the same time. So make it thread-safe, declare the subclass `@unchecked Sendable`, and never block or wait for another request in it. See [the reference](REFERENCE.md#approovdefaultmessagesigning-and-signatureparametersfactory).

### What is signed as the target URI

`@target-uri` is the request URL's `absoluteString` as URLSession sends it. It has no fragment and no user information, the host in lowercase, an explicit port kept (a default `:443` included), and `/` for an empty path. Two cautions:

* Cloudflare's `request.url` drops a default `:443` that URLSession sends. So do not write default ports in URLs.
* From iOS 17, Foundation percent-encodes the whole URL string when it contains a character it considers invalid, such as `|`. Existing escapes are encoded again, so your backend receives `%2520` for `%20`. Build such URLs with `URLComponents`, or pre-encode the `|`.

The package reads a body into memory for its digest, up to 10 MB, using `Content-Length`. It forwards a larger body, or a body without `Content-Length`, intact, with no digest.

## Header names

You can change the name of each header that the package adds. Passing `nil` turns the trace or status header off:

```swift
ApproovService.setTokenHeader("Authorization", prefix: "Bearer ")  // default "Approov-Token", no prefix
ApproovService.setTraceIDHeader(nil)                                // default "Approov-TraceID"; nil disables
ApproovService.setStatusHeader("X-Approov-Fetch-Status")            // default "Approov-Status"; nil disables
```

A `nil` prefix means no prefix. The package sends the trace header only when the SDK supplies a non-empty trace ID. With the status header off, a request sent after a failed token fetch carries no Approov header at all, and so no reason.

## Bypass initialization

Initialize with an empty string instead of the account ID to put the package in bypass mode. The package is then enabled but protects nothing: `isApproovServiceEnabled()` is `true` and `isApproovProtectionEnabled()` is `false`. Requests go out with no token, signature, secure strings or Approov connection validation, only iOS trust and your [challenge handler](#challenge-handler). The methods that call the SDK throw `ApproovServiceError.permanentError("<method>: Approov protection not enabled")`. A request made before any `initialize` goes out in the same way. The package does not fail or hold it.

```swift
try? ApproovService.initialize("")
```

Use bypass mode while your app fetches the account ID, or as a guard, as in the README. A later `initialize` with the account ID turns Approov on, if the SDK accepts it. The package keeps the configuration set before then. When protection is on, the package ignores an `initialize` with an empty string. The SDK rejects a second initialization with a different account ID, as `ApproovServiceError.initializationError`, and the package state does not change.

## Initialize, then configure

Call `initialize`, which is synchronous, and handle any error that it throws. Then make every configuration call that your app needs, before the app sends protected requests. These include headers, substitutions, exclusions, the service mutator, signature factories, the challenge handler and the logging level.

`initialize` never resets your configuration. A configuration change applies only to requests processed after the call. Until then, requests use the defaults: `.ALWAYS_PROCEED`, the `Approov-Token` header with no prefix, no binding header, exclusions or substitutions, both signatures, and logging at `.info`. Connection validation does not depend on this order.

Native code at startup (for example expo-updates), [third-party SDKs](#third-party-sdks) and JavaScript modules that fetch when imported can send requests before your configuration calls. Delay such requests to protected hosts until after them.

Every caller of `initialize` in the process drives the same state, and a repeat call with the same account ID and comment returns at once. Configure the package in one place, natively, because the last write wins.

A one-line native bootstrap in a React Native app, or the Expo config plugin, calls only `initialize()`, which applies the options in your [approov.config](README.md#from-a-bundled-approovconfig). Your app makes any other configuration calls afterwards.

### Persistent configuration

An over-the-air update of your app's JavaScript cannot change the bundled `approov.config`. To change its options from an update, store them with `setPersistentConfiguration`:

```swift
try ApproovService.setPersistentConfiguration(#"{"exclusionURLRegexes": ["^https://cdn\\.example\\.com/"]}"#, source: updateID)
```

The stored options apply from the next launch, and each key replaces the same key of the file. The package discards them when the bundled `approov.config` or the app version changes, so a new store release has none. See [setPersistentConfiguration](REFERENCE.md#setpersistentconfiguration).

## Token binding

[Token binding](https://approov.io/docs/latest/approov-usage-documentation/#token-binding) ties the Approov token to the value of a header on the request, typically an OAuth `Authorization` header. A token then cannot be replayed with different credentials. Only a hash of the value reaches Approov, as the `pay` claim of the token, which your backend verifies.

```swift
try ApproovService.setBindingHeader("Authorization")
```

Each token is bound to the value of its own request. A request without the header sets no new binding. `setDataHashInToken` binds arbitrary data instead. Do not use both.

A header cannot be both the binding header and a substitution header. The call made second throws `ApproovServiceError.permanentError` and changes nothing.

## Secure strings

[Secure strings](https://approov.io/docs/latest/approov-usage-documentation/#secure-strings) let you take API keys and other secrets out of your app. Approov delivers them only to attested installations. Put a secure string key in your request where the secret goes, and register the headers and query parameters that carry keys:

```swift
try ApproovService.addSubstitutionHeader("X-Api-Key")                           // whole value is the key
try ApproovService.addSubstitutionHeader("Authorization", requiredPrefix: "Bearer ")  // value after the prefix
ApproovService.addSubstitutionQueryParam("api_key")
```

Header names match without regard to case. If a secure string fetch fails, the package puts the fetch status in place of the key, after any required prefix, and the request proceeds. For example, `Authorization: Bearer REJECTED` or `?api_key=UNKNOWN_KEY`, where `UNKNOWN_KEY` means no secure string is defined for that key.

The package substitutes only on an `https` request whose token fetch returned `SUCCESS` or `UNPROTECTED_URL`. Any other request keeps its placeholders, and the package logs the header or query parameter, never the value.

### Secrets-only APIs

An API that you added with `approov api -add <domain> -noApproovToken` needs no Approov token, for example a third-party service whose API key you take out of your app. The SDK reports it as `UNPROTECTED_URL`. A request to it gets its secure strings over `https`, and connection validation, but no Approov header and no signature. A secrets-only request that got a substituted secure string is never stored in the URL cache of your session.

### Values a header or URL cannot carry

The package substitutes a secret only where URLSession carries it unchanged. Otherwise the placeholder stays, the request proceeds, and a warning names the header or query parameter.

* A header carries only tab and printable ASCII.
* In a query, the package looks at each occurrence of the parameter separately. A secret with `&`, `;`, `#`, CR, LF or tab keeps the placeholder. A `+` is carried unchanged, but a backend that form-decodes the query reads it as a space.

A value of your own that a header cannot carry fails the request, for example a token prefix or a header that your mutator sets. The `URLError` names the header, never the value.

## Excluding URLs

Requests whose URL matches an exclusion regular expression are sent untouched, without a token fetch:

```swift
try ApproovService.addExclusionURLRegex("https://api\\.example\\.com/health.*")
```

Connection validation still applies to excluded requests on protected domains. An invalid pattern throws `ApproovServiceError.permanentError` that names the pattern, and changes nothing.

## Connection validation

Whatever the attestation outcome, the package validates the TLS connection to each protected domain. It uses the certificate public keys configured for the domain. If there are none, it uses the [Managed Trust Roots](https://approov.io/docs/latest/approov-usage-documentation/#managed-trust-roots) that Approov maintains for your account.

A connection that fails validation is refused with `NSURLErrorServerCertificateUntrusted` (-1202), the error iOS gives for any certificate it cannot trust. Its description says whether the certificate failed iOS trust evaluation or matched none of the public keys. A cleartext `http://` request to a protected domain fails with the same error before anything is sent.

The package validates a connection when it opens, and for every host coalesced onto an HTTP/2 connection. Requests that reuse an open connection get no new validation.

### Protected domains

A protected domain is an API domain that you added to Approov, with or without `-noApproovToken`. The SDK holds the list, with the keys for each domain.

* The package looks up the exact host of the connection, ignoring case and one trailing dot. API domains never contain wildcards, so a domain never covers its subdomains. The `*` entry of the list holds the Managed Trust Roots, and is not a protected domain.
* If a domain is protected but the SDK holds no Managed Trust Roots, only iOS trust evaluation validates its connections. The package logs a warning once for each host.
* After a failed token fetch, the package uses the list to tell your API domains from other hosts. The list is empty before the first configuration arrives, and on a device in unpin mode.

## Challenge handler

The package forwards each request through a URLSession of its own, so TLS and authentication challenges cannot reach the delegate of your session. Install a handler for them, with the signature of the URLSession `didReceive challenge` delegate method:

```swift
ApproovService.setChallengeHandler { challenge, completion in
    // your own trust or credential logic
    completion(.performDefaultHandling, nil)
}
```

The handler receives:

* every challenge that is not server trust: HTTP Basic, Digest, NTLM and client certificates. Without a handler, default handling uses the shared credential storage, and a client certificate from your delegate is not sent.
* server-trust challenges for hosts without Approov validation: hosts not added to Approov, requests that your mutator excludes, and every host in bypass mode
* server-trust challenges for hosts with Approov validation, only after the Approov validation passed

A connection that Approov refuses never reaches the handler. The handler can narrow trust, never widen it.

## Redirects

Your delegate's `willPerformHTTPRedirection` decides each redirect as usual. The package builds a followed redirect from the request that your app made. It takes only the new URL and any change of method and body from the redirect. So:

* no header that Approov or your mutator added for the first destination reaches the redirect target
* a secure string goes back to its placeholder, and is substituted again only if the new target is protected and `https`
* the target gets its own token fetch and fresh signatures. On a change of origin, the package also removes your `Authorization` header.

The package uses the redirect target URL exactly as the server sent it, and never looks up its query. **Do not let a server echo a secret into a redirect**, because the next hop receives what the server sent. The responses and errors that your app sees name the URL of your request, never a URL with a secure string in its query.

## Coexistence with other networking SDKs

Observability SDKs such as New Relic, Datadog, Instabug, Firebase Performance and Sentry also install a `URLProtocol` with a swizzle. URLSession uses the first `URLProtocol` that claims a request, and the last SDK that installs its swizzle becomes first.

So initialize Approov after any other networking SDK that uses interception, but before the app creates its sessions. Then call `ApproovService.verifyInterceptionInstalled()`. It returns `false`, and logs an error, if the swizzle is absent or if another `URLProtocol` sits ahead of Approov. The log names that SDK. Add it to a startup assertion and to your QA smoke test. If you cannot resolve a conflict by ordering, use the explicit `approov-service-urlsession` layer for the affected sessions.

### Expo development builds

In a Debug build of an Expo development client, the network inspector puts its `EXRequestInterceptorProtocol` ahead of Approov each time a project loads, and `verifyInterceptionInstalled()` returns `false`. Requests are still protected, because the inspector sends each request again through a session that carries `ApproovURLProtocol`. Release builds have no inspector, and report `true`. Assert on the result in release builds only (`#if !DEBUG`), or set `EX_DEV_CLIENT_NETWORK_INSPECTOR` to `false` in `ios/Podfile.properties.json`.

## Third-party SDKs

The package intercepts the URLSession requests of a third-party SDK, such as a payments, analytics or chat SDK, as it intercepts your own. Requests to protected domains get the token, the status header, the signatures and connection validation.

But the trust logic of the SDK does not run. The request goes on the forwarding session of the package. So the challenge method of the SDK's session delegate is never called, also for hosts not added to Approov. Make any such trust decision in your [challenge handler](#challenge-handler). Initialize such an SDK after you initialize and configure Approov.

## Service mutators

A service mutator, an `ApproovServiceMutator`, holds the request decisions of the package, one method for each decision. The mutator in force when a request is processed decides everything about that request.

* `.ALWAYS_PROCEED` never fails a request. It is the default.
* `.CLOSE_FAILURE` keeps the 3.5.x token decisions. A failed token fetch for a protected domain fails the request in the app, except `NO_APPROOV_SERVICE`, which proceeds with the status header only. A secure string never fails a request.
* `.DEFAULT` points to the default behaviour of the release, which is `.ALWAYS_PROCEED`. `setServiceMutator(nil)` puts it back. Name `.CLOSE_FAILURE` or `.ALWAYS_PROCEED` for a behaviour that stays fixed.

```swift
ApproovService.setServiceMutator(.CLOSE_FAILURE)
ApproovService.setServiceMutator(nil)               // back to .DEFAULT
```

Under `.CLOSE_FAILURE`, a request that fails never reaches the network. Your app receives one of these errors, and decides what to do:

| Token fetch status | Error |
| :--- | :--- |
| `NO_NETWORK`, `POOR_NETWORK`, `MITM_DETECTED` | `NSURLErrorDomain`, `NSURLErrorNetworkConnectionLost`, which can be retried |
| `REJECTED` | domain `io.approov.ApproovService`, code 499, `userInfo["type"] == "rejection"`, with `rejectionARC` and `rejectionReasons` |
| any other status | domain `io.approov.ApproovService`, code 499, `userInfo["type"] == "general"` |

Each error carries the status as `userInfo["status"]`, and as `ApproovServiceError.status` where you hold the Swift error.

### Your own mutator

Write your own mutator, a `Sendable` type that conforms to `ApproovServiceMutator`, when your app needs another decision. Every method has a default implementation, so override only what you need. **The default implementations make the `.CLOSE_FAILURE` decisions.** So a mutator of your own that should never abort a request delegates its token decision to `.ALWAYS_PROCEED`, as the example below does.

| Hook | Decides |
| :--- | :--- |
| `handleInterceptorShouldProcessRequest(_:)` | whether a request is processed at all. By default, not when an exclusion matches |
| `handleInterceptorFetchTokenResult(_:url:)` | `true` adds the Approov headers for the status, `false` adds none, and a throw aborts the request |
| `handleInterceptorHeaderSubstitutionResult(_:header:)`, `handleInterceptorQueryParamSubstitutionResult(_:queryKey:)` | whether a `SUCCESS` secret is substituted. Any other status goes in place of the placeholder, unless the hook throws |
| `handleInterceptorProcessedRequest(_:changes:)` | final changes to the request, before message signing |
| `handlePinningShouldProcessRequest(_:)` | whether Approov connection validation applies. An excluded request goes on separate connections, and its challenges go to your [challenge handler](#challenge-handler) |
| `handleFetchTokenResult`, `handleFetchSecureStringResult`, `handleFetchCustomJWTResult` | which results the direct methods turn into errors |

### Aborting a request in the app

To abort a request for an outcome that your app does not accept, override the hook and throw a `URLError`, never an Approov type. The package relays it unchanged and sends nothing, so the abort reaches your error handling as an ordinary network failure:

```swift
final class PaymentsMutator: ApproovServiceMutator {
    func handleInterceptorFetchTokenResult(_ result: ApproovTokenResult, url: String) throws -> Bool {
        // the payments host must only ever receive a request carrying a token
        if result.status != .success && url.hasPrefix("https://payments.example.com/") {
            throw URLError(.userAuthenticationRequired)
        }
        return try ApproovAlwaysProceedMutator.ALWAYS_PROCEED.handleInterceptorFetchTokenResult(result, url: url)
    }
}
ApproovService.setServiceMutator(PaymentsMutator())
```

For a failed token fetch on a host that is not a protected domain, only a throw of your own aborts the request. The package ignores a standard decision thrown there, and a `true` or `false` answer adds nothing.

Any other error that a hook throws, an `ApproovServiceError` from your own code included, fails the request with a `URLError` (`NSURLErrorUnknown`). The error names the hook, and its `NSUnderlyingErrorKey` is your error. Only the `.CLOSE_FAILURE` token decisions keep their Approov errors. A Swift runtime trap in a hook, such as a failed force unwrap, still ends the process.

## Diagnostics

The package never logs a token, a secure string value, a device ID or the account ID. Its messages go to the unified log, with the `ApproovService:` prefix, at the level that you set with `setLoggingLevel(_:)` (default `.info`). Hosts and error descriptions are private, so a release log shows `<private>` in place of the host.

Each configuration setter logs one `.debug` line, such as `setTokenHeader Authorization, Bearer `, whether the setting comes from your calls, `approov.config` or the persistent configuration.

The package logs a request that does not get full Approov protection at `.debug` only, so turn on `.debug` while you investigate:

* a failed token fetch, for example `Approov token fetch for api.example.com: NO_NETWORK, proceeding with the status header only`, with the ARC and rejection reasons when present
* each header or query parameter that did not get its secure string, with the status, and whether the status or the placeholder was sent

These go to higher levels:

* a placeholder left on an `http` request or after `BAD_URL`, and a secret that a header or URL cannot carry, as warnings
* a missing message signature, once per process (see [when a signature cannot be produced](#when-a-signature-cannot-be-produced))
* a connection that matches none of the public keys, as an error: `Approov pinning: no pin matches for api.example.com`

### The Attestation Response Code

`ApproovService.getLastARC()` returns the [Attestation Response Code](https://approov.io/docs/latest/approov-usage-documentation/#attestation-response-code) (ARC) of the most recent fetch, which tells why attestation gave its result. Prefer the `arc` claim of the token that your backend received, because it belongs to the request in question.

To decode an ARC, run this once. The CLI prints a `curl` command with the API key of your account and an `<arc>` placeholder:

```sh
approov token -showArcInfoCurl
```

Run that command with the ARC in place of `<arc>`. The response lists the flags behind the result, for example `app-not-registered`. The [live metrics](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs) of your account show the same reasons in aggregate, within a minute.

`ApproovService.getInterceptionDiagnostics()` returns counters that show that interception is in use: `requestsForwarded`, `pinnedChallengesAllowed`, `pinnedChallengesBlocked` and `delegatedChallenges`. Any blocked challenge means that a certificate failed validation.

## Known limitations

Where one of these limits matters to your app, use the explicit `approov-service-urlsession` layer for the affected sessions.

* **Background sessions and WKWebView.** Apple forbids custom protocols in background sessions, and WKWebView traffic runs out of process. The package cannot see either.
* **WebSockets.** A `URLSessionWebSocketTask`, GraphQL subscriptions over WebSocket included, never goes through the package. Its connection is not validated, and its upgrade request carries nothing from Approov.
* **Sessions created before interception is installed.** The package covers a session only if the app got its configuration from `URLSessionConfiguration.default` or `.ephemeral` after `initialize` or [installInterception](REFERENCE.md#installinterception). It does not cover a session created earlier, or a session built from a configuration that the app got earlier. If your app sets `protocolClasses` to a list without `ApproovURLProtocol`, the package does not cover the sessions built from that configuration.
* **Your session's configuration.** Forwarded requests use a default configuration. So `tlsMinimumSupportedProtocolVersion`, `allowsCellularAccess`, `allowsExpensiveNetworkAccess`, `allowsConstrainedNetworkAccess`, `connectionProxyDictionary`, `waitsForConnectivity`, `httpMaximumConnectionsPerHost` and the credential storage of your session do not apply. The shared cookie storage is used, so cookies from an ephemeral session may be stored persistently. Headers from `httpAdditionalHeaders` are sent. Upload progress and `URLSessionTaskMetrics` are not relayed.
* **Redirect decisions** must arrive within one second. After that, the package delivers the `3xx` as the final response.
* **Concurrent requests.** The package processes at most 8 requests at the same time, because each blocks a thread in an SDK fetch. Other requests wait in arrival order, without a thread. Mutator hooks and factory overrides run on these slots, so they must not wait synchronously for another intercepted request.
* **No stale protection refresh.** URLSession may hold a request after the package protected it, for example behind other transfers to the same host. It can then go out after its token or its signatures expired. A `401` that URLSession answers with credentials from your handler or the credential storage is retried with no new protection or signatures.
* **Objective-C exceptions** that the SDK raises on the request path end the process.
