# Reference

This page is a reference for the public API of the Approov Package for iOS. It lists the static methods of `ApproovService`, the entry point, and the types they use. Everything is available with:

```swift
import ApproovService
```

The API is Swift only. Method names follow the other Approov packages, with `approov-service-okhttp` as the reference. Where a Swift idiom differs, this page says so.

The rest of this introduction explains what happens to requests, and which errors your app can see. The methods follow it.

The package cannot protect some requests, for example when it cannot fetch a token. The installed service mutator, an `ApproovServiceMutator`, decides whether the package still sends such a request. A service mutator is the object that holds the package's request decisions. See [setServiceMutator](#setservicemutator) and [what happens by default](ADVANCED.md#what-happens-by-default).

* The default, `.DEFAULT`, is `.ALWAYS_PROCEED`. The request always proceeds. If it could not be protected, it carries no token header, and the fetch status is on the `Approov-Status` header.
* With `.CLOSE_FAILURE` the package makes the 3.5.x decisions. A request proceeds on `SUCCESS` and `NO_APPROOV_SERVICE`. Otherwise it fails, as listed under [errors](#errors).

With any mutator, these other errors can reach your completion handler from the request path:

* your own configuration errors, as a `URLError` (see [errors](#errors))
* errors your service mutator throws, also as a `URLError`
* TLS connections to your protected domains that fail validation. A protected domain is one of your API domains added to Approov. The error is `NSURLErrorServerCertificateUntrusted`, as for any certificate that iOS cannot trust.

Before `initialize`, and in bypass mode, a request goes out without any Approov processing and without Approov connection validation. The package does not fail or hold it. Bypass mode is the state after you initialize with an empty string (see [initialize](#initialize)).

What a request carries depends on its token fetch status. Some requests get secure strings. A secure string is a secret, such as an API key, that Approov delivers only to attested apps. The package puts it in place of a placeholder in your request.

* `SUCCESS`, for an API added to Approov, gets the token, status and trace headers, secure strings and signatures.
* `UNPROTECTED_URL`, for an API added with `-noApproovToken` (a secrets-only API), gets its secure strings and nothing else.
* `UNKNOWN_URL`, for a host not added to Approov, gets nothing.
* Any other status is a failure. When the host is a protected domain, the mutator decides whether to abort or proceed. The SDK keeps the list of protected domains, with the keys that the package validates their connections against. A request that proceeds gets the status header only.
* After a failure on any other host, the request goes out unchanged. The standard mutators never abort it. Only a throw from a custom mutator can abort it. It gets no token header, trace header, secure strings or signatures.

The list of protected domains plays no part on `SUCCESS`. Connection validation applies with every status. The package logs requests that do not get what Approov would give them at `.debug` only (see [diagnostics](ADVANCED.md#diagnostics)). See [what each request carries](ADVANCED.md#what-each-request-carries).

For each connection, connection validation looks up the exact host in the list of protected domains, as [protected domains](ADVANCED.md#protected-domains) describes. A protected domain with no public keys of its own is validated against the Managed Trust Roots that Approov maintains for your account.

Every method that calls the Approov SDK is declared `throws`. These are `fetchToken`, `fetchSecureString`, `fetchCustomJWT`, `getDeviceID`, `getServerAdjustedCurrentTimeMS`, `setDevKey`, `setDataHashInToken`, `setInstallAttributes`, `getInstallMessageSignature` and `getAccountMessageSignature`. While [isApproovProtectionEnabled](#isapproovprotectionenabled) is `false`, each throws `ApproovServiceError.permanentError` with the message `<method>: Approov protection not enabled`, and does not call the SDK.

The deprecated [getMessageSignature](#getmessagesignature-deprecated) keeps a non-throwing signature, and returns `nil` instead.

Do not call blocking methods on the main thread.

## Initialization and state

### initialize

```swift
static func initialize(_ config: String, comment: String? = nil) throws
```

Initializes the Approov SDK and installs interception.

`config` is your Approov account ID. It is the string from your onboarding email. The CLI also gives it with `approov sdk -getConfigString`. The CLI and the SDK call it the SDK config string. It identifies your account to the SDK. It is not a secret, and it is the same for every app in the account. See [where to find it](https://approov.io/docs/latest/approov-usage-documentation/#getting-the-initial-sdk-configuration).

The package passes every non-empty account ID to the SDK, with `comment` exactly as you passed it, and the SDK decides. The package does not store or compare the account ID.

* The first initialization succeeds.
* For a call with the same account ID and comment, the SDK reports that it is already initialized, and `initialize` returns at once. So every place in the process that uses Approov may call it.
* For any other call that the SDK rejects, `initialize` throws `ApproovServiceError.initializationError`. That includes a different account ID or comment, and an account ID that did not reach the app intact. The error carries the SDK's message unchanged, and the SDK's own `NSError` as `underlyingError`. The package state does not change.

`initialize` never resets your configuration. These settings keep the values set before or after it, by any caller:

* the token, trace, status and binding headers
* substitutions and exclusions
* the service mutator
* message signing and its host factories
* the challenge handler
* the logging level

`initialize` changes only what [isApproovServiceEnabled](#isapproovserviceenabled) and [isApproovProtectionEnabled](#isapproovprotectionenabled) report.

Call `initialize` before the first request, as the first step in `application(_:didFinishLaunchingWithOptions:)`. The package does not cover sessions created before the call, unless [installInterception](#installinterception) ran before the app created them.

An empty `config` starts bypass mode:

* `isApproovServiceEnabled()` is `true` and `isApproovProtectionEnabled()` is `false`.
* The package does not call the SDK.
* Requests go out with no Approov token, message signing, secure strings or Approov connection validation.

The package passes a later `initialize` with the account ID to the SDK. If the SDK accepts it, protection starts. After protection is on, the package ignores an empty string and does not pass it to the SDK. See [bypass initialization](ADVANCED.md#bypass-initialization).

### initialize (from approov.config)

```swift
static func initialize() throws
```

Initializes as [initialize](#initialize) does, with the `config` and `comment` of the `approov.config` file in the app's main bundle. Then it applies the other keys of the file.

It throws `ApproovServiceError.initializationError` when the file:

* is missing or cannot be read
* is larger than 1 MiB
* is not valid UTF-8
* is not one strict JSON object
* has no string `config`

Strict JSON means RFC 8259 with these limits:

* no trailing commas, comments or single quotes
* nesting up to 128 levels
* no duplicate key at any level
* no number that is not finite as a double

The error message names the cause and never the content. The package ignores a leading UTF-8 byte order mark.

The package reads the content as a 3.5.x file when both of these are true:

* The first non-whitespace character (Unicode whitespace included) is not `{` or `[`.
* The content is not a JSON string, number, `true`, `false` or `null`.

In a 3.5.x file, the first non-blank line is the `config`, and there are no options. If that line holds `{` or `"`, the file is invalid JSON.

On iOS, the package also rejects an integer of several hundred digits as invalid JSON, because `JSONSerialization` cannot hold it.

The package applies the keys other than `config` and `comment` once per process. The call that first enables the package applies them. That call is the first initialization (bypass mode included) or the upgrade from bypass mode to protection. This is also true when another layer in the app already initialized the SDK with the same `config`. The package applies the keys after the SDK accepts the `config`, and before the package reports itself enabled. It applies `logLevel` first.

* A call that finds the package already enabled in the state it asks for applies, logs and resets nothing from the file.
* The package never applies a `devKey` from a bypass-mode file later.
* A missing key changes nothing.
* The package skips an unknown key, with an `.info` line that names it.
* The package skips a key with a wrong type or value, with an `.error` line that names it. The other keys still apply.
* In a list, the package skips a bad element, and the other elements apply.

The package logs nothing from the file except key names. It quotes key names, escapes them as JSON strings and cuts them after 40 characters, for example `unknown key "futureKey" ignored`. [initialize](#initialize) never reads the file.

| Key | Value | Applied with |
|---|---|---|
| `config` | string, required. `""` is bypass mode, with a warning | `initialize` |
| `comment` | string, or `null` for none. The package passes `""` as an empty comment | `initialize` |
| `devKey` | non-empty string. Use it in debug builds only. Not applied in bypass mode | [setDevKey](#setdevkey) |
| `tokenHeader` | `{"name": non-empty string, "prefix": string}`, prefix default `""` | [setTokenHeader](#settokenheader) |
| `traceIDHeader` | non-empty string, or `null` to disable | [setTraceIDHeader](#settraceidheader) |
| `statusHeader` | non-empty string, or `null` to disable | [setStatusHeader](#setstatusheader) |
| `mutator` | `"CLOSE_FAILURE"` or `"ALWAYS_PROCEED"` | [setServiceMutator](#setservicemutator) |
| `messageSigning` | `true` or `false` (a JSON boolean, not a number). Message signing is on by default | `false` is `disableMessageSigning()`. `true` is `enableMessageSigning()` with the default factory, which replaces a default factory that your app set before. Host factories stay |
| `logLevel` | `"OFF"`, `"ERROR"`, `"WARNING"`, `"INFO"` or `"DEBUG"` | [setLoggingLevel](#setlogginglevel) |
| `substitutionHeaders` | object of header name to required prefix (`""` for none) | [addSubstitutionHeader](#addsubstitutionheader) |
| `substitutionQueryParams` | array of non-empty strings | [addSubstitutionQueryParam](#addsubstitutionqueryparam) |
| `exclusionURLRegexes` | array of non-empty strings in JSON escaping, so `"^https://a\\.b/"` is the regular expression `^https://a\.b/` | [addExclusionURLRegex](#addexclusionurlregex) |
| `bindingHeader` | non-empty string, or `null` for none. Applied after `substitutionHeaders`, and skipped if it is a substitution header | [setBindingHeader](#setbindingheader) |

The package accepts `null` only where the table says so. On any other key, `null` is a wrong type.

### setPersistentConfiguration

```swift
static func setPersistentConfiguration(_ json: String, source: String?) throws
```

Stores options that [initialize (from approov.config)](#initialize-from-approovconfig) applies over the file, from the next launch. The method applies nothing in the running process. Each process uses the options that were stored before it first looked at them. A process first looks at them at the first of these events:

* its first `initialize()` that applies the file
* a call to this method or to [clearPersistentConfiguration](#clearpersistentconfiguration)

So options stored before that `initialize()` also wait for the next launch.

`json` is a JSON object of at most 64 KiB with the keys of the file. The method parses it as strictly as the file, with nesting up to 127 levels. That is one level less than the file, because the stored record holds the options one level deeper. The method ignores a leading byte order mark.

The method throws `ApproovServiceError.permanentError` and stores nothing if the options:

* are not valid JSON or not an object
* are larger than 64 KiB
* hold `config`, `comment` or `devKey`
* hold a known key with a wrong type or value. This includes a bad list element, an exclusion pattern that does not compile, or a `bindingHeader` that is also one of its `substitutionHeaders`. The method also checks these against the keys of the bundled file that the options leave in place. For the reverse clash, the message is `substitutionHeaders: element is the binding header`.

The error names the cause, never a value. The method also throws if the bundled `approov.config` is present but cannot be read.

The method stores an unknown key. `source` is any tag of at most 1024 UTF-8 bytes, such as an update ID.

If the options and the source are the same as those stored, the method writes nothing. Otherwise the options replace those stored, and the method logs one `.info` line: `persistent configuration stored, applies at the next launch`.

The package keeps the options in `Application Support/approov/override.json`. This file is:

* written atomically
* readable from the first unlock after a restart
* excluded from backups

The file also holds the SHA-256 of the bundled `approov.config` (null if the app has none, which never matches), and the app version, `CFBundleVersion` + `/` + `CFBundleShortVersionString`.

The `initialize()` call that applies the file applies the stored options in the same pass:

* Each stored key replaces the whole key of the file. So `tokenHeader` and the lists replace the bundled value.
* The call sets the logging level first.
* The call logs a bad value or an unknown key as it does for the file. The line starts with `approov.config (persistent):` for a key the options hold (a `tokenHeader` member included), and with `approov.config:` for a key of the file.
* One `.info` line reads `initialize: persistent configuration applied (source "<source>")`, or `(source none)`. The line quotes and escapes the source as it does key names, and cuts it after 128 characters.

The package deletes the stored options in these cases, and the file alone then applies:

* The options were stored with a bundled `approov.config` whose content differs from the current one.
* Another app version (a different build number or version name) stored them.
* The options were stored without an app version. The package treats them as stored by another version, and deletes them once.
* The options cannot be read, are not valid, or are of an unknown version. This includes a stored file over 128 KiB, which the package does not read.

Because of the first two cases, a store release never inherits the options.

The `initialize()` call that applies the file reports each deletion, after it sets its logging level. This method and `clearPersistentConfiguration` never report it. The call logs one of these lines:

* `.info`: `persistent configuration deleted: store release changed the bundled approov.config`. The call also uses this line when the app version changed too.
* `.info`: `persistent configuration deleted: app version changed`
* `.warning`: `persistent configuration deleted: <cause>`

The package keeps a file that the device does not yet let the app read, before the first unlock after a restart. It does not apply that file. [initialize](#initialize) never reads or deletes the stored options.

### clearPersistentConfiguration

```swift
static func clearPersistentConfiguration() throws
```

Deletes the options stored by [setPersistentConfiguration](#setpersistentconfiguration), so the bundled file alone applies from the next launch. Nothing changes in the running process. Options in force for this launch stay in force. The method does not read the bundled file. If no options are stored, that is not an error.

### persistentConfigurationSource

```swift
static func persistentConfigurationSource() -> String?
```

Returns the `source` of the options that are stored now. It returns nil if no valid options are stored, or if they have no source.

This is what is stored, not what is in force. It includes:

* options stored in this launch, which apply from the next launch
* options that the next launch may still delete, because the bundled `approov.config` changed

It deletes nothing.

### isApproovServiceEnabled

```swift
static func isApproovServiceEnabled() -> Bool
```

Returns whether the package is installed and processing requests. It is `true` after any `initialize` succeeds, bypass mode included.

### isApproovProtectionEnabled

```swift
static func isApproovProtectionEnabled() -> Bool
```

Returns whether Approov protection is active. It is `true` once the SDK is initialized with the account ID. It is `false` before `initialize` and in bypass mode.

### installInterception

```swift
static func installInterception()
```

Installs interception without initialization. After this call, every `URLSessionConfiguration.default` and `.ephemeral` that is created carries the Approov `URLProtocol`. Interception also covers `URLSession.shared`.

Until `initialize` succeeds, requests go out unchanged. The package does not fail or hold them. After that, the package protects them like any other request.

Use it for frameworks that create sessions before your app can call `initialize`. An example is React Native, whose package calls it at load. A second call changes nothing. `initialize` installs interception itself, so apps do not need to call this method.

### verifyInterceptionInstalled

```swift
@discardableResult static func verifyInterceptionInstalled() -> Bool
```

Checks that a newly created `URLSessionConfiguration` carries the Approov `URLProtocol` first.

It returns `false`, and logs at error level, when:

* neither `installInterception` nor `initialize` installed interception
* the configuration swizzle is absent
* the `URLProtocol` of another SDK is ahead of Approov. The log names it.

Call it after every other networking SDK initializes.

In a Debug build of an Expo development client, it returns `false` after a project loads. The cause is that the protocol of the network inspector is ahead of Approov. Requests are still protected, and release builds return `true`. In Debug builds, do not make app behaviour depend on its result. See [coexistence](ADVANCED.md#coexistence-with-other-networking-sdks).

### getInterceptionDiagnostics

```swift
static func getInterceptionDiagnostics() -> ApproovInterceptionDiagnostics
```

Returns counters that show that interception operates:

* `requestsForwarded`
* `pinnedChallengesAllowed` and `pinnedChallengesBlocked`, the TLS checks that Approov made, by outcome
* `delegatedChallenges`, the challenges that the challenge handler or default handling answered

### serviceVersion

```swift
static let serviceVersion: String   // "approov-service-ios/3.7.0"
```

The name and version the package reports to the Approov platform.

## Header configuration

### setTokenHeader

```swift
static func setTokenHeader(_ header: String, prefix: String? = nil)
```

Sets the header that carries the Approov token, and an optional prefix.

* The default is `Approov-Token`, with no prefix.
* Use `prefix: "Bearer "` for an `Authorization`-style API.
* A `nil` prefix means no prefix.
* The package adds the header only when the token fetch returned `SUCCESS`. A request sent after a failed fetch carries no token header, not an empty one. The reason is on the status header instead.

### getTokenHeader

```swift
static func getTokenHeader() -> String
```

Returns the name of the header that carries the Approov token.

### getTokenPrefix

```swift
static func getTokenPrefix() -> String
```

Returns the prefix added before the Approov token, or `""` for none.

### setStatusHeader

```swift
static func setStatusHeader(_ header: String?)
```

Sets the header that reports the token fetch status to your backend. The default is `Approov-Status`. Passing `nil` turns it off.

The value is the status name, never converted, such as `SUCCESS`, `NO_NETWORK`, `MITM_DETECTED`, `NO_APPROOV_SERVICE` or `REJECTED`. It describes the token fetch only, never the result of a secure string fetch.

The package sends the header on every request that the token decision lets proceed with Approov headers. That includes a request after a failed fetch when the host is a protected domain. The package never sends it to a host not added to Approov (`UNKNOWN_URL`), or to a secrets-only API (`UNPROTECTED_URL`).

### getStatusHeader

```swift
static func getStatusHeader() -> String?
```

Returns the name of the status header, or `nil` if it is turned off.

### setTraceIDHeader

```swift
static func setTraceIDHeader(_ header: String?)
```

Sets the optional debug header that carries the SDK trace ID. The default is `Approov-TraceID`. Passing `nil` turns it off. The package sends the header only when the SDK supplies a trace ID.

### getTraceIDHeader

```swift
static func getTraceIDHeader() -> String?
```

Returns the name of the trace ID header, or `nil` if it is turned off.

### setApproovHeader (deprecated)

```swift
@available(*, deprecated, renamed: "setTokenHeader(_:prefix:)")
static func setApproovHeader(_ header: String, prefix: String = "")
```

Deprecated: use [setTokenHeader](#settokenheader) instead. This older name still works, and calls `setTokenHeader`. Here an empty `prefix` means no prefix.

### setApproovTraceIDHeader (deprecated)

```swift
@available(*, deprecated, renamed: "setTraceIDHeader(_:)")
static func setApproovTraceIDHeader(_ header: String?)
```

Deprecated: use [setTraceIDHeader](#settraceidheader) instead. This older name still works, and calls `setTraceIDHeader`.

## Request decisions

### setServiceMutator

```swift
static func setServiceMutator(_ mutator: ApproovServiceMutator?)
```

Installs the service mutator that makes the request decisions. A service mutator has one method for each decision, such as whether a failed token fetch fails the request.

* Pass `.CLOSE_FAILURE`, `.ALWAYS_PROCEED` or your own mutator.
* `nil` restores `.DEFAULT`. `.DEFAULT` points to the default behaviour of the release, which is `.ALWAYS_PROCEED`.
* Name `.CLOSE_FAILURE` or `.ALWAYS_PROCEED` for a behaviour that stays fixed.

The mutator in force when a request is processed decides everything about that request.

Under `.ALWAYS_PROCEED`, the default, a cleartext `http://` request to a protected domain proceeds. The SDK answers `BAD_URL` for it. It carries `Approov-Status: BAD_URL` and no token header. The package never substitutes a secure string into it.

See [ApproovServiceMutator](#approovservicemutator).

### getServiceMutator

```swift
static func getServiceMutator() -> ApproovServiceMutator
```

Returns the service mutator that is currently installed.

### setChallengeHandler

```swift
static func setChallengeHandler(_ handler: ApproovChallengeHandler?)
```

Installs a handler for the challenges the package cannot deliver to your session's delegate. Passing `nil` removes it.

The handler receives:

* every challenge that is not server trust: Basic, Digest, NTLM and client certificates
* server-trust challenges for hosts without Approov validation. The handler decides these on its own, as in bypass mode.
* server-trust challenges for hosts with Approov validation, after the Approov check passes. So your own trust logic can narrow trust further.

The package never offers the handler a connection that Approov refuses. Without a handler, these challenges get default handling. See [challenge handler](ADVANCED.md#challenge-handler).

### addExclusionURLRegex

```swift
static func addExclusionURLRegex(_ pattern: String) throws
```

Excludes URLs that match the regular expression from Approov processing. An excluded request gets no token fetch, no headers and no substitutions.

Connection validation still applies to excluded requests to protected domains.

An invalid pattern throws `ApproovServiceError.permanentError`, with no `status`, and changes nothing. The message is `addExclusionURLRegex: invalid regular expression <pattern>: <reason>`. Every Approov package throws for an invalid pattern, and does not ignore it.

### removeExclusionURLRegex

```swift
static func removeExclusionURLRegex(_ pattern: String)
```

Removes an exclusion regular expression you added with `addExclusionURLRegex`.

### getExclusionURLRegexs

```swift
static func getExclusionURLRegexs() -> [String: NSRegularExpression]
```

Returns a snapshot of the exclusions. Each pattern, as you added it, maps to its compiled expression.

### setBindingHeader

```swift
static func setBindingHeader(_ header: String?) throws
```

Binds the value of the named request header into the token's `pay` claim. This is [token binding](ADVANCED.md#token-binding).

* A request without the header sets no new binding.
* The package binds a header that is present but empty as the empty string.
* `nil` stops binding.
* A header that is registered with `addSubstitutionHeader`, in any letter case, throws `ApproovServiceError.permanentError` and changes nothing. The message is `setBindingHeader <header>: already a substitution header`.

### getBindingHeader

```swift
static func getBindingHeader() -> String?
```

Returns the binding header, or `nil` when none is set.

### addSubstitutionHeader

```swift
static func addSubstitutionHeader(_ header: String, requiredPrefix: String = "") throws
```

Marks a header for [secure string](ADVANCED.md#secure-strings) substitution.

The package replaces a header value of the form `<requiredPrefix><key>` with `<requiredPrefix><secure string>`. This occurs only on `https` requests whose token fetch returned `SUCCESS`, or `UNPROTECTED_URL` (a [secrets-only API](ADVANCED.md#secrets-only-apis)).

* A cleartext request keeps the placeholder, with any mutator. So does a request whose token fetch returned `UNKNOWN_URL`, `BAD_URL` or any failure status.
* A secure string fetch may return a status other than `SUCCESS`. If the mutator lets the request continue, the package sends the status after the prefix instead. The standard mutators always let it continue. The status has the same form as in `Approov-Status`. Examples are `Bearer REJECTED`, and `Bearer UNKNOWN_KEY` for a key that is not defined.
* Header names match in any letter case. If you register a name again, in any letter case, the new entry replaces the old entry and its prefix.
* The binding header, in any letter case, throws `ApproovServiceError.permanentError` and changes nothing. The message is `addSubstitutionHeader <header>: already the binding header`.

### removeSubstitutionHeader

```swift
static func removeSubstitutionHeader(_ header: String)
```

Removes a header you added with `addSubstitutionHeader`. The name matches in any letter case.

### getSubstitutionHeaders

```swift
static func getSubstitutionHeaders() -> [String: String]
```

Returns a snapshot of the substitution headers. Each name maps to its required prefix, or `""` for none. The name is in the letter case that you last registered it with.

### addSubstitutionQueryParam

```swift
static func addSubstitutionQueryParam(_ key: String)
```

Marks a query parameter for secure string substitution. The package substitutes every occurrence of the parameter.

* Substitution occurs only on `https` requests whose token fetch returned `SUCCESS` or `UNPROTECTED_URL`.
* A cleartext request or redirect hop keeps the placeholder, with any mutator. So does a request whose token fetch returned `UNKNOWN_URL`, `BAD_URL` or any failure status.
* The secure string fetch for an occurrence can return another status. If the mutator lets the request continue, the occurrence gets that status as its value. The status has the same form as in `Approov-Status`. A key that is not defined gives `UNKNOWN_KEY`.

The package uses a redirect target URL exactly as the server sent it. It never looks up the query values of that URL, even under a substitution query parameter. It does not change a secure string that the server echoes into that URL back to the placeholder. See [secure strings](ADVANCED.md#secure-strings).

### removeSubstitutionQueryParam

```swift
static func removeSubstitutionQueryParam(_ key: String)
```

Removes a query parameter key you added with `addSubstitutionQueryParam`.

### getSubstitutionQueryParams

```swift
static func getSubstitutionQueryParams() -> Set<String>
```

Returns a snapshot of the substitution query parameter keys.

Android maps each key to the `Pattern` it matches with. This package matches the key as a literal string, so the keys are the whole configuration.

### setLoggingLevel

```swift
static func setLoggingLevel(_ level: ApproovLogLevel)
```

Sets the level of the package's own logging. The levels are `.off`, `.error`, `.warning`, `.info` (the default) and `.debug`.

Every configuration setter logs one `.debug` line. The text is the same as the text that the same setter of the Android package logs. Examples are `setTokenHeader Authorization, Bearer `, `setServiceMutator ApproovServiceMutator.CLOSE_FAILURE`, `addExclusionURLRegex ^https://a\.b/` and `setLoggingLevel DEBUG`. A nil value is written `null`.

* The line names a mutator of your own by its type. The package does not run any code of the mutator to log it.
* The package logs a host name and an exclusion pattern as private.
* `setDevKey`, `setDataHashInToken` and `setInstallAttributes` log their name only, never the value.
* Your calls and [initialize (from approov.config)](#initialize-from-approovconfig) log these lines alike.
* `setLoggingLevel` logs its line at the level it sets.

## Message signing

### enableMessageSigning

```swift
static func enableMessageSigning(_ defaultFactory: SignatureParametersFactory? = nil)
```

Turns message signing (RFC 9421) on, or sets the default factory. [Message signing](ADVANCED.md#message-signing) is on by default, with both signatures, so call this method only to turn signing on again after `disableMessageSigning()`, or to pass a factory.

When it is on, the package signs every request that carries the Approov token header. That is a request whose token fetch returned `SUCCESS`. The package never signs a request to a secrets-only API, or a request sent after a failed fetch.

By default each request gets two signatures: install (`ecdsa-p256-sha256`) and account (`hmac-sha256`). Pass `defaultFactory` to configure them differently. Passing `nil` selects `ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory()`.

Signing is independent of the service mutator, and `initialize` does not change it.

Signing fails open. If the package cannot produce a signature, it leaves that signature out. The first time in the process that one signature is missing, it logs a warning. The first time a request goes unsigned, it logs an error. After that, it logs these at `.debug`. If there is no usable algorithm, the package sends the request unsigned and logs an error.

### disableMessageSigning

```swift
static func disableMessageSigning()
```

Turns message signing off. The factories are kept for a later `enableMessageSigning`.

### isMessageSigningEnabled

```swift
static func isMessageSigningEnabled() -> Bool
```

Returns whether message signing is on. It is `true` by default.

### putMessageSigningHostFactory

```swift
static func putMessageSigningHostFactory(hostName: String, factory: SignatureParametersFactory?)
```

Signs requests to one host with `factory`, instead of the default factory. The host matches in any letter case, with no port. Passing `nil` removes the host's factory.

## Direct SDK methods

### fetchToken

```swift
static func fetchToken(url: String) throws -> String
```

Fetches an Approov token for the URL. Use it for a transport the package does not intercept. It blocks.

It throws `networkingError` or `permanentError`, as `handleFetchTokenResult` decides. Before `initialize` and in bypass mode, it throws `permanentError` with the message `fetchToken: Approov protection not enabled`.

### fetchSecureString

```swift
static func fetchSecureString(key: String, newDef: String? = nil) throws -> String?
```

Fetches or defines a [secure string](https://approov.io/docs/latest/approov-usage-documentation/#secure-strings). It blocks.

* With `newDef` set to `nil`, it looks up the secure string. It returns `nil` for an unknown key.
* With `newDef` set, it may define a secure string for this app instance.

It throws as `handleFetchSecureStringResult` decides. Before `initialize` and in bypass mode, it throws `permanentError` with the message `fetchSecureString: Approov protection not enabled`.

### fetchCustomJWT

```swift
static func fetchCustomJWT(payload: String) throws -> String?
```

Fetches a [custom JWT](https://approov.io/docs/latest/approov-usage-documentation/#custom-jwts) with the given payload, which is a marshaled JSON string. It blocks.

It throws as `handleFetchCustomJWTResult` decides. Before `initialize` and in bypass mode, it throws `permanentError` with the message `fetchCustomJWT: Approov protection not enabled`.

### getDeviceID

```swift
static func getDeviceID() throws -> String
```

Returns the Approov device ID.

It throws `permanentError("getDeviceID: device ID unavailable")` when the SDK has none. Before `initialize` and in bypass mode, it throws `permanentError` with the message `getDeviceID: Approov protection not enabled`.

### getServerAdjustedCurrentTimeMS

```swift
static func getServerAdjustedCurrentTimeMS() throws -> Int64
```

Returns the current time in milliseconds since the epoch, adjusted by the offset between the device clock and the clock of the Approov servers. The SDK learns this offset at each attestation. Before the first attestation of the installation, the value is the device clock.

Message signatures take their `created` and `expires` times from it. So a device with a wrong clock still signs within the time window of your backend. Use it for your own timestamps that your backend compares with its clock.

It throws `permanentError("getServerAdjustedCurrentTimeMS: time unavailable")` when the SDK cannot give the time. Before `initialize` and in bypass mode, it throws `permanentError` with the message `getServerAdjustedCurrentTimeMS: Approov protection not enabled`.

### getLastARC

```swift
static func getLastARC() -> String
```

Returns the [Attestation Response Code](https://approov.io/docs/latest/approov-usage-documentation/#attestation-response-code) (ARC) of the most recent fetch the package performed. The ARC is a code that tells Approov support why attestation gave its result.

The fetch can be a token, secure string or custom JWT fetch, from a request or a direct method.

It performs no fetch, and never throws. It returns `""` when:

* no fetch occurred after initialization
* the last fetch carried no ARC
* ARC is not enabled

### setDataHashInToken

```swift
static func setDataHashInToken(_ data: String) throws
```

Binds arbitrary data into the token's `pay` claim. Do not use it together with `setBindingHeader`.

Before `initialize` and in bypass mode, it throws `permanentError` with the message `setDataHashInToken: Approov protection not enabled`.

### setDevKey

```swift
static func setDevKey(_ devKey: String) throws
```

Sets a [development key](https://approov.io/docs/latest/approov-usage-documentation/#using-a-development-key), so a development build passes attestation.

Before `initialize` and in bypass mode, it throws `permanentError` with the message `setDevKey: Approov protection not enabled`.

### setInstallAttributes

```swift
static func setInstallAttributes(_ attrs: String) throws
```

Sets the [install attributes](https://approov.io/docs/latest/approov-usage-documentation/#application-installation-attributes) for this app installation.

* `attrs` is the signed JWT that holds the new attributes.
* The SDK sends them with future token fetches. The next fetch does not use a cached token.
* The server accepts them only if they are signed, unexpired and bound to this device ID.

Before `initialize` and in bypass mode, it throws `permanentError` with the message `setInstallAttributes: Approov protection not enabled`.

### getInstallMessageSignature

```swift
static func getInstallMessageSignature(message: String) throws -> String?
```

Returns the install signature of `message`, in base64. It is an ECDSA P-256 signature in ASN.1 DER form. It returns `nil` when the SDK cannot produce one.

Before `initialize` and in bypass mode, it throws `permanentError` with the message `getInstallMessageSignature: Approov protection not enabled`.

### getAccountMessageSignature

```swift
static func getAccountMessageSignature(message: String) throws -> String?
```

Returns the account signature of `message`, in base64. It is an HMAC-SHA256 signature. It returns `nil` when the SDK cannot produce one, for example when there is no account key yet.

Before `initialize` and in bypass mode, it throws `permanentError` with the message `getAccountMessageSignature: Approov protection not enabled`.

### getMessageSignature (deprecated)

```swift
@available(*, deprecated)
static func getMessageSignature(message: String) -> String?
```

Deprecated: use [`getAccountMessageSignature`](#getaccountmessagesignature) instead.

It is an alias with the non-throwing signature that `approov-service-urlsession` uses, so a migrating app compiles unchanged.

* It returns the same account signature.
* Where `getAccountMessageSignature` throws, because Approov protection is not enabled, it returns `nil` instead.
* It logs a deprecation warning that names `getAccountMessageSignature`, once per process.

## Types

### ApproovServiceMutator

```swift
protocol ApproovServiceMutator: Sendable
```

The protocol for the request decisions. Every method has a default implementation, which makes the `.CLOSE_FAILURE` decisions, not the decisions of `.DEFAULT`. So a conforming type overrides only what it needs. A conforming type that should never abort a request delegates `handleInterceptorFetchTokenResult` to `.ALWAYS_PROCEED`.

* The interceptor hooks may throw a `URLError` to abort a request, as your app's own policy. This includes the substitution hooks.
* The token decision controls the token, status and trace headers and the signatures.
* Whether secure strings may apply follows the token fetch status (`SUCCESS` or `UNPROTECTED_URL`), and then the substitution hooks.
* An `ApproovServiceError` that the `.CLOSE_FAILURE` token decision throws keeps its type, whether your mutator inherits the decision or calls it.
* Any other error your hook throws fails the request as your hook's failure. That includes an `ApproovServiceError` your code builds, or rethrows from a direct method (see [Errors](#errors)).

| Method | Called | Default implementation |
| :--- | :--- | :--- |
| `handleInterceptorShouldProcessRequest(_ request: URLRequest) throws -> Bool` | first, for every intercepted request | `false` (send untouched) when an exclusion regex matches. Throws `permanentError` for a request with no URL |
| `handleInterceptorFetchTokenResult(_ result: ApproovTokenResult, url: String) throws -> Bool` | after the token fetch. For a failure status on a host that is not a protected domain, only a throw from your own code counts. That throw aborts the request. The package ignores a standard decision thrown there, and a return value adds nothing | `true` on `SUCCESS` and `NO_APPROOV_SERVICE`. `false` on `UNKNOWN_URL` and `UNPROTECTED_URL`. Throws otherwise: `networkingError` for `NO_NETWORK`, `POOR_NETWORK` and `MITM_DETECTED`, `rejectionError` for `REJECTED`, and `permanentError` for any other status. `true` adds the token, status and trace headers and the signatures on `SUCCESS`. On any other status it adds the status header only, and only to a protected domain |
| `handleInterceptorHeaderSubstitutionResult(_ result: ApproovTokenResult, header: String) throws -> Bool` | per substitution header, on an `https` request whose token fetch returned `SUCCESS` or `UNPROTECTED_URL` | `true` on `SUCCESS`, `false` on every other status. Never throws. Unless the hook throws, the package sends any status other than `SUCCESS` in place of the placeholder, whatever the hook returns. `false` on `SUCCESS` leaves the placeholder |
| `handleInterceptorQueryParamSubstitutionResult(_ result: ApproovTokenResult, queryKey: String) throws -> Bool` | per query occurrence | as for headers |
| `handleInterceptorProcessedRequest(_ request: URLRequest, changes: ApproovRequestMutations) throws -> URLRequest` | last, before signing. Called on a request that the token decision let proceed with Approov headers, or that received a secure string | returns the request unchanged |
| `handlePinningShouldProcessRequest(_ request: URLRequest) -> Bool` | once per request, before the package forwards it | `true` |
| `handleFetchTokenResult(_ result: ApproovTokenResult) throws` | `fetchToken(url:)` | throws for anything but `SUCCESS` |
| `handleFetchSecureStringResult(_ result: ApproovTokenResult, operation: String, key: String) throws` | `fetchSecureString(key:newDef:)` | throws for anything but `SUCCESS` and `UNKNOWN_KEY` |
| `handleFetchCustomJWTResult(_ result: ApproovTokenResult) throws` | `fetchCustomJWT(payload:)` | throws for anything but `SUCCESS` |

The standard decision sets are static members. You can use them wherever the code expects an `ApproovServiceMutator`:

| Name | Type | Decisions |
| :--- | :--- | :--- |
| `.CLOSE_FAILURE` | `ApproovCloseFailureMutator` | the 3.5.x token decisions above. Substitutes a secure string on `SUCCESS` only. A secure string never fails the request |
| `.ALWAYS_PROCEED` | `ApproovAlwaysProceedMutator` | never throws. Every token status except `UNKNOWN_URL` and `UNPROTECTED_URL` proceeds. Substitutes a secure string on `SUCCESS` only |
| `.DEFAULT` | `ApproovServiceMutator` | points to the release's default behaviour, which is `.ALWAYS_PROCEED` |

The declared type of `.DEFAULT` is the protocol, never a mutator class. Write it as `.DEFAULT` where the code expects an `ApproovServiceMutator`. `ApproovCloseFailureMutator.DEFAULT` does not compile. Name `.CLOSE_FAILURE` or `.ALWAYS_PROCEED` explicitly for a behaviour that stays fixed.

### ApproovTokenResult

```swift
struct ApproovTokenResult: Sendable
```

The SDK fetch result passed to the mutator. Its properties are:

* `status: ApproovTokenStatus`
* `token: String`, `""` when there is none
* `secureString: String?`
* `traceID: String`, `""` when there is none
* `arc: String`
* `rejectionReasons: String`
* `isConfigChanged: Bool`

Its initializer takes the same names. All but `status` have defaults.

### ApproovTokenStatus

```swift
enum ApproovTokenStatus: String, Sendable
```

The status of an SDK fetch. The cases are `success`, `noNetwork`, `poorNetwork`, `mitmDetected`, `noApproovService`, `badURL`, `unknownURL`, `unprotectedURL`, `notInitialized`, `rejected`, `disabled`, `unknownKey`, `badKey`, `badPayload` and `internalError`.

The raw value is the name that the Android SDK uses for the same status, such as `"NO_NETWORK"`. It is also the `Approov-Status` value, never converted. The iOS SDK does not supply these names, so the package defines them.

`isNetworkFailure` is `true` for `noNetwork`, `poorNetwork` and `mitmDetected`.

`mitmDetected` (`"MITM_DETECTED"`) is what the SDK reports for an untrusted network or a captive portal.

### ApproovRequestMutations

```swift
class ApproovRequestMutations
```

Records what the package changed on a request. The package passes it to `handleInterceptorProcessedRequest`, and to a signature parameters factory. Its methods are:

* `getTokenHeaderKey()`
* `getTraceIDHeaderKey()`
* `getStatusHeaderKey()`
* `getSubstitutionHeaderKeys()`
* `getOriginalURL()`, the URL before the package replaced any query parameter with a secure string or a status. It is `nil` if the package replaced none.
* `getSubstitutionQueryParamKeys()`

The substitution keys list only headers and parameters that received a secure string. Those that received a status in its place are not listed.

### ApproovChallengeHandler

```swift
typealias ApproovChallengeHandler =
    @Sendable (URLAuthenticationChallenge,
               @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void
```

The type of the handler you pass to [setChallengeHandler](#setchallengehandler). It matches URLSession's `didReceive challenge` delegate method.

### ApproovLogLevel

```swift
enum ApproovLogLevel: Int, Comparable { case off, error, warning, info, debug }
```

The logging levels you pass to [setLoggingLevel](#setlogginglevel).

### ApproovInterceptionDiagnostics

```swift
struct ApproovInterceptionDiagnostics: Sendable
```

The counters [getInterceptionDiagnostics](#getinterceptiondiagnostics) returns: `requestsForwarded`, `pinnedChallengesAllowed`, `pinnedChallengesBlocked` and `delegatedChallenges`. All are `Int`.

### ApproovDefaultMessageSigning and SignatureParametersFactory

`ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory(baseParametersOverride: SignatureParameters? = nil) -> SignatureParametersFactory` returns the default factory.

The default factory makes both signatures. It covers:

* `@method` and `@target-uri`
* the token header
* the trace and status headers, when present
* `Authorization`, `Content-Length` and `Content-Type`, when present
* a SHA-256 `Content-Digest`, which is not required
* `created`, and an `expires` 15 seconds later, from the server adjusted time ([getServerAdjustedCurrentTimeMS](#getserveradjustedcurrenttimems))

The factory never adds a component that is already covered (RFC 9421 section 2). So a token header named `Authorization` is covered once.

The constants are:

* `DIGEST_SHA256` (`"sha-256"`) and `DIGEST_SHA512` (`"sha-512"`)
* `ALG_ES256` (`"ecdsa-p256-sha256"`) and `ALG_HS256` (`"hmac-sha256"`)
* `SIG_ID_INSTALL` (`"install"`) and `SIG_ID_ACCOUNT` (`"account"`)

```swift
open class SignatureParametersFactory: @unchecked Sendable
```

A `SignatureParametersFactory` builds the signature parameters for each request. Configure a factory completely before you pass it to the package. Each setter returns the factory, so you can chain them.

| Method | Effect |
| :--- | :--- |
| `init()` | a bare factory, which makes both signatures |
| `setBaseParameters(_:)` | sets the base signature parameters (see `SignatureParameters` below) |
| `setBodyDigestConfig(_ algorithm: String?, required: Bool) throws` | sets the body digest: `DIGEST_SHA256` or `DIGEST_SHA512`, or `nil` for none. Any other algorithm throws `ApproovServiceError.permanentError`. If the digest is required and the factory cannot generate it, the request fails. This occurs for a GET or HEAD, which carries no body, and for a streamed body over 10 MB or without `Content-Length`. The factory digests an empty body |
| `setUseInstallMessageSigning()`, `setUseAccountMessageSigning()`, `setUseInstallAndAccountMessageSigning()` | choose which signatures are made |
| `open func getAlgs() -> [String]` | returns the configured algorithms, in the order that the package adds the signatures. They apply to every request that the factory is installed for, when the request parameters carry no `alg` |
| `setAddCreated(_:)`, `setExpiresLifetime(_ seconds: Int64)` | set the timestamps. `<= 0` gives no `expires` |
| `setAddApproovTokenHeader(_:)`, `setAddApproovTraceIDHeader(_:)`, `setAddApproovStatusHeader(_:)` | choose which Approov headers are covered |
| `addOptionalHeaders(_ headers: [String])` | covers these headers when present |
| `open func buildSignatureParameters(provider: ApproovURLSessionComponentProvider, changes: ApproovRequestMutations) throws -> SignatureParameters?` | builds the parameters for one request from the configuration above. `nil` leaves the request unsigned |
| `open func generateBodyDigest(provider: ApproovURLSessionComponentProvider, requestParameters: SignatureParameters) throws -> Bool` | `buildSignatureParameters` calls it when a body digest is configured. It adds the `Content-Digest` header and covers it. It returns `false` when the body cannot be digested |

The factory is open. A subclass may override `buildSignatureParameters` to decide the signature of each request (see [choosing the signatures](ADVANCED.md#choosing-the-signatures)). It may also override the other two `open` methods.

#### What an override returns

An override returns the parameters to sign with. It may build them itself, take them from `super`, or take them from another factory's `buildSignatureParameters`. A factory from `generateDefaultSignatureParametersFactory` is one example.

It may also return `nil` to leave the request unsigned. The package then sends the request with its token and status headers, and no `Signature`, `Signature-Input` or `Content-Digest` header. The package does not log this.

An `alg` set on the returned parameters gives that single signature. Otherwise the signatures come from `getAlgs()` of the installed factory, whichever factory built the parameters.

#### Threads

One factory serves every request it applies to. So the package calls an override for many requests at the same time, on different threads. It must be thread-safe, and must not block or wait for another request. A subclass restates `@unchecked Sendable`, as the compiler asks.

#### Errors an override throws

An error that an override throws never fails the request. The package sends the request unsigned. It logs `Message signing: failed to build signature parameters, proceeding unsigned` at error level, with the error as private detail.

Only a body digest that is configured as required, and that the factory cannot generate, fails the request. This is also true when the call reaches the standard implementation through `super` or another factory. A `generateBodyDigest` override that returns `false` while the digest is required also fails the request.

#### SignatureParameters

`SignatureParameters` builds the base parameters a factory starts every request from. The factory copies them for each request, and adds its own components and parameters to the copy. So configure the base before you give it to the factory:

```swift
let base = SignatureParameters()
    .addComponentIdentifier("@method")
    .addComponentIdentifier("@target-uri")
    .addComponentIdentifier("X-Request-ID")
base.setTag("my-app")
ApproovService.enableMessageSigning(
    ApproovDefaultMessageSigning.generateDefaultSignatureParametersFactory(baseParametersOverride: base))
```

| Member | Effect |
| :--- | :--- |
| `init()`, `init(base:)` | empty parameters, or a copy of `base` |
| `addComponentIdentifier(_ identifier: String)` | covers a component. The method uses a derived component, such as `"@method"`, `"@target-uri"` or `"@authority"`, as given. It uses a header field by its lowercase name. It does not add a component that is already covered |
| `containsComponentIdentifier(_ identifier: String) -> Bool` | whether the component is covered. Field names match in any letter case |
| `setAlg(_:)`, `setKeyid(_:)`, `setNonce(_:)`, `setTag(_:)`, `setCreated(_:)`, `setExpires(_:)` and their getters | the signature metadata. An explicit `alg` makes that single signature. The factory replaces `created` and `expires` when it adds them |
| `setDebugMode(_:)`, `isDebugMode()` | adds a `Signature-Base-Digest` header with the SHA-256 of each signature base, one member per signature (`install` and `account`). Use it for server-side debugging only. The factory keeps it on the parameters it builds from yours |

The setters return the parameters. You can also call them on their own, because they are `@discardableResult`.

### ApproovURLSessionComponentProvider

```swift
final class ApproovURLSessionComponentProvider
```

The request that a factory builds parameters for, in the form that the package sends it. The package creates one for each signed request. You can only read it.

| Method | Returns |
| :--- | :--- |
| `getRequest() -> URLRequest` | the request as Approov and your mutator left it, with any `Content-Digest` already added. `httpBody` is the body when the package holds it in memory |
| `getMethod() -> String` | the method, or `GET` if the request sets none |
| `getScheme() -> String` | the scheme in lowercase |
| `getAuthority() -> String` | the host in lowercase, with the port only when it is not the scheme's default |
| `getTargetUri() -> String` | the target URI as URLSession sends it, without a fragment |
| `getPath() -> String` | the path, still percent-encoded, or `/` when empty |
| `getQuery() -> String` | `?` and the query, still percent-encoded, or `?` alone when there is none |
| `getRequestTarget() -> String` | the path and any query, as in the request line |
| `getQueryParam(name: String) -> String?` | the value of one query parameter, decoded and encoded again with the form set, so a space becomes `%20`. `nil` when it is absent or repeated |
| `hasField(name: String) -> Bool`, `getField(name: String) -> String?` | whether the request has a header (the name matches in any letter case), and its value |
| `hasBody() -> Bool` | whether the request has a body, in memory or as a stream |

### Errors

```swift
enum ApproovServiceError: LocalizedError
```

The error the direct methods throw.

| Case | Raised for |
| :--- | :--- |
| `networkingError(message: String, status: ApproovTokenStatus?)` | `NO_NETWORK`, `POOR_NETWORK` or `MITM_DETECTED`, from a token fetch or a direct method. A retry is reasonable. The package never raises it for a secure string that it substitutes into a request |
| `rejectionError(message: String, arc: String, rejectionReasons: String)` | `REJECTED`, with the ARC and the [rejection reasons](https://approov.io/docs/latest/approov-usage-documentation/#rejection-reasons) where enabled |
| `permanentError(message: String, status: ApproovTokenStatus?)` | every other failing status, the "Approov protection not enabled" guard, and an unavailable device ID. Also an invalid exclusion pattern, a binding and substitution header conflict, and an unsupported body digest algorithm |
| `pinningError(message: String)` | not raised by this release |
| `initializationError(message: String, underlying: NSError?)` | `initialize` rejected by the SDK |

`status` returns the SDK status that the error is for. It is `.rejected` for `rejectionError`, and `nil` where no status applies. `underlyingError` returns the SDK's `NSError` for `initializationError`.

On the request path, errors reach your completion handler as `NSError`s, made by `asNSError()`. URLSession rebuilds relayed errors from their domain, code and `userInfo`.

| Error | Domain | Code | `userInfo` |
| :--- | :--- | :--- | :--- |
| `networkingError` | `NSURLErrorDomain` | `NSURLErrorNetworkConnectionLost` | `type: "network"`, `status` |
| `rejectionError` | `io.approov.ApproovService` (`ApproovServiceError.errorDomain`) | 499 (`ApproovServiceError.errorCode`) | `type: "rejection"`, `rejectionARC`, `rejectionReasons`, `status` |
| `permanentError` | `io.approov.ApproovService` | 499 | `type: "general"`, and `status` when one applies |
| your configuration error, or an error other than a `URLError` or a `.CLOSE_FAILURE` decision thrown by your mutator (an `ApproovServiceError` your code throws included) | `NSURLErrorDomain` | `NSURLErrorUnknown` | a description naming the problem or the hook. Your error is the `NSUnderlyingErrorKey`, with an `ApproovServiceError` in its `asNSError()` form |
| a token or trace ID the SDK issued that a header cannot carry (not seen with current SDKs, whose values are base64url) | `NSURLErrorDomain` | `NSURLErrorUnknown` | a description naming the header and the SDK value, as in `Approov header Approov-Token: invalid character in SDK token`. It never quotes the value |
| a `URLError` your mutator throws | as thrown | as thrown | as thrown |
| a connection that does not validate | `NSURLErrorDomain` | `NSURLErrorServerCertificateUntrusted` | your app's URL as the failing URL |

The failing URL of every relayed error is your request's URL. So is the URL of every relayed response. It is never a URL with a secure string substituted into its query.

## Core API used by the package itself

`ApproovInterceptor`, `ApproovBackend` and `ApproovURLProtocol` are public because the SwiftPM package splits the core into its own module, which does not need the SDK.

* `ApproovInterceptor`'s `shared` instance mirrors the methods above.
* `ApproovBackend` is the SDK abstraction the core is written against.

They are not part of the integration API. Use `ApproovService`.

## Removed in 3.7.0

Some names from the 3.5.x iOS packages (`approov-service-urlsession`, `approov-service-alamofire`) are gone. This table gives each replacement:

| Name | Replacement |
| :--- | :--- |
| `isInitialized()` | `isApproovServiceEnabled()` |
| `isApproovEnabled()` | `isApproovProtectionEnabled()` |
| `prefetch()` | none. The SDK manages prefetching |
| `setUseApproovStatusIfNoToken(_:)` | none. The status has its own header, and a request sent after a failed token fetch carries no token header |
| `setProceedOnNetworkFail(_:)` | none. The default mutator, `.ALWAYS_PROCEED`, proceeds on network failures |
| `setFailureCacheTTL(_:)` | none. There is no failure cache. The SDK manages retries |
| `ApproovServiceMutatorDefault` | `.CLOSE_FAILURE` for the same decisions |
| `ApproovDefaultMessageSigning` as a mutator (`setServiceMutator(ApproovDefaultMessageSigning()...)`) | none for the default signatures, because message signing is on by default. `enableMessageSigning(_:)` and `putMessageSigningHostFactory(hostName:factory:)` take a factory |
| `setApproovHeader(_:prefix:)`, `setApproovTraceIDHeader(_:)` | deprecated for one release, not removed: `setTokenHeader(_:prefix:)`, `setTraceIDHeader(_:)` |
