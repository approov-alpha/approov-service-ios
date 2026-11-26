# Approov Package for iOS

![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-15%2B-000000?logo=apple&logoColor=white)
![SwiftPM](https://img.shields.io/github/v/tag/approov/approov-service-ios?logo=swift&logoColor=white&label=SwiftPM)
![CocoaPods](https://img.shields.io/badge/CocoaPods-git%20tag-EE3322?logo=cocoapods&logoColor=white)
![Approov SDK](https://img.shields.io/badge/Approov%20SDK-3.7.0-1f6feb)
![Message Signing](https://img.shields.io/badge/Message%20Signing-RFC%209421-1f6feb)

This package is the client API of [Approov](https://www.approov.io) for iOS apps. After you initialize it, every API call that your app makes through URLSession carries an Approov token that your backend can verify. This includes clients built on URLSession, such as Alamofire, AFNetworking or a generated API client. Each call that carries a token is also signed. Your backend then knows that each request came from a genuine, unmodified copy of your app.

The package intercepts every URLSession that your app creates after initialization, so you do not adopt a wrapper.

The package also validates the TLS connection to each of your API domains. It uses the Managed Trust Roots that Approov maintains for your account, or the certificate public keys configured for the domain.

## BEFORE YOU START

You need:

* an Approov account, trial or paid, and its [account ID](#your-account-id)
* your API domains [added to Approov](https://approov.io/docs/latest/approov-usage-documentation/#managing-api-domains). The package adds a token only to requests to these domains.

Then follow these steps:

1. [Add the dependency](#adding-the-dependency).
2. [Initialize](#initializing) `ApproovService` with your account ID.
3. [Make your requests](#making-requests).
4. [Look in the debug log](ADVANCED.md#diagnostics) for the result of each token fetch.
5. [Register your app and verify tokens on your backend](#next-steps). Until your backend verifies the token, your API is not protected.

[ADVANCED.md](ADVANCED.md) describes the optional features and the known limitations. [REFERENCE.md](REFERENCE.md) lists every public method.

## ADDING THE DEPENDENCY

The package supports iOS 15 and later. It builds with Swift 6, and supports the Swift 6 and Swift 5 language modes. Its public API is Swift only.

It depends on the Approov SDK through the shared `approov-ios-sdk` package, version 3.7.0, as `approov-service-urlsession`, `approov-service-alamofire` and `approov-service-react-native` do. An app that uses this package with one of them links only one Approov SDK.

### Swift Package Manager

Add the package and the `ApproovService` product:

```swift
.package(url: "https://github.com/approov-alpha/approov-service-ios.git", exact: "3.7.0"),
// in the app target:
.product(name: "ApproovService", package: "approov-service-ios"),
```

In Xcode, choose File > Add Package Dependencies, enter the URL and choose the `ApproovService` library. SwiftPM fetches `approov-ios-sdk` with it.

### CocoaPods

In your Podfile, reference both pods from their GitHub repositories at a tag:

```ruby
pod 'approov-ios-sdk', :git => 'https://github.com/approov/approov-ios-sdk.git', :tag => '3.7.0'
pod 'approov-service-ios', :git => 'https://github.com/approov-alpha/approov-service-ios.git', :tag => '3.7.0'
```

The podspec of the package requires `approov-ios-sdk` version `3.7.0` exactly, but a podspec cannot say where to fetch a dependency from. So your Podfile must list `approov-ios-sdk` with `:git` itself. The pod also depends on `swift-http-structured-headers` (`~> 1.4`).

With either package manager the module is `ApproovService`:

```swift
import ApproovService
```

## INITIALIZING

Initialize `ApproovService` once, when your app starts, with your Approov account ID. Do this first in `application(_:didFinishLaunchingWithOptions:)`. The package covers only the sessions that your app creates after initialization, or after a call to [installInterception](REFERENCE.md#installinterception). A request made before initialization has no Approov protection.

```swift
import ApproovService
import os

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let log = Logger(subsystem: "com.example.app", category: "approov")
    // an identifier of your own for this launch, to tie app and backend logs together (not an Approov secret)
    let sessionID = UUID().uuidString
    do {
        // your Approov account ID, from your onboarding email or "approov sdk -getConfigString"
        try ApproovService.initialize("<your-approov-account-id>")
        if ApproovService.isApproovServiceEnabled() && ApproovService.isApproovProtectionEnabled() {
            let deviceID = (try? ApproovService.getDeviceID()) ?? "unavailable"
            log.info("Approov initialized; session=\(sessionID, privacy: .public) deviceID=\(deviceID, privacy: .public)")
        }
    } catch {
        // the value passed was not a valid account ID; run without Approov rather than not at all
        log.error("Approov account ID rejected; session=\(sessionID, privacy: .public); starting in bypass mode: \(error.localizedDescription, privacy: .public)")
        try? ApproovService.initialize("")
    }
    // then configure, straight after initialize and before the app issues protected
    // requests; only the settings your app uses, for example:
    // ApproovService.setTokenHeader("Authorization", prefix: "Bearer ")
    return true
}
```

About this example:

* `initialize` throws if the value it receives is not a complete, unaltered account ID. The `catch` block then initializes with `""` to start the package in **bypass mode**, so your app still starts. In bypass mode the package sends requests without a token or a signature, and iOS trust alone validates the connections. Your backend rejects them as any request without a valid token.
* Logging the device ID is optional. Approov identifies an installation only by its device ID, so log it next to your own session or user ID.
* Make your configuration calls immediately after `initialize`, which is synchronous, and before the app sends protected requests. A setting applies only to requests processed after the call. See [initialize, then configure](ADVANCED.md#initialize-then-configure).

### Your account ID

Your account ID is in your onboarding email. The Approov CLI also shows it at any time, and calls it the SDK config string:

```sh
approov sdk -getConfigString
```

The account ID is the same for every app in your account. It is not a secret and not an API key. You can keep it in your source code or deliver it with your app's configuration. The whole value must reach the app unchanged, including its punctuation.

If the account ID is not available when the app starts, initialize with `""` first. Call `initialize` again when you have the account ID. See [bypass initialization](ADVANCED.md#bypass-initialization).

### From a bundled approov.config

You can supply the account ID, and optionally your configuration, in a file named `approov.config`. Then call `initialize()` without arguments. A plugin or a one-line native bootstrap that initializes Approov for you uses this form.

```json
{
  "config": "<your-approov-account-id>",
  "comment": null,
  "tokenHeader": {"name": "Authorization", "prefix": "Bearer "},
  "exclusionURLRegexes": ["^https://static\\.example\\.com/"]
}
```

```swift
try ApproovService.initialize()
```

* Add the file to your app target (Target Membership). Give each target its own `approov.config` for a different file for each build variant.
* If one target has several build configurations, copy the correct file into the app with a Run Script build phase, for example `cp "${SRCROOT}/approov/${CONFIGURATION}/approov.config" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/"`. Do not include these files in Copy Bundle Resources.
* `initialize()` throws `ApproovServiceError.initializationError` if the file is missing or unreadable, if it is not one valid JSON object, or if it has no `config`. `"config": ""` starts bypass mode. A 3.5.x file that holds only the account ID still works.
* The package applies the other keys once, in the `initialize()` call that first enables the package or turns on protection after bypass mode. Your configuration calls after `initialize()` still apply. [REFERENCE.md](REFERENCE.md#initialize-from-approovconfig) lists the keys.
* Put `devKey` only in the file of a debug build, never in a release build.

To change these options without a new store release, see [persistent configuration](ADVANCED.md#persistent-configuration).

## MAKING REQUESTS

The package gives you no network object. Make requests as you do now, through any URLSession that your app creates after `initialize`, or through a library built on URLSession.

```swift
let session = URLSession(configuration: .default)   // created after initialize
let (data, response) = try await session.data(from: URL(string: "https://api.example.com/v1/items")!)
```

The package also covers `URLSession.shared`, and a client such as Alamofire if the app first uses its session after `initialize`. The package cannot intercept background sessions and WKWebView, and it does not support WebSockets. See [known limitations](ADVANCED.md#known-limitations).

For each request to an API domain that you added to Approov, the package:

* adds the Approov token, which proves that the app passed attestation
* adds the `Approov-Status` header, which gives the result of the token fetch, for example `SUCCESS` or `NO_NETWORK`
* signs the request with the install signature and the account signature
* puts your [secure strings](ADVANCED.md#secure-strings) in place of their placeholders
* validates the connection, and refuses it with `NSURLErrorServerCertificateUntrusted` if the validation fails

By default, a request goes out also when the token fetch fails. The request then carries only the `Approov-Status` header, which gives the reason, and your backend decides. A [secrets-only API](ADVANCED.md#secrets-only-apis) receives only its secure strings and the connection validation. The package sends requests to other domains without changes. [What each request carries](ADVANCED.md#what-each-request-carries) has the details.

## CUSTOMIZING THE BEHAVIOUR

[ADVANCED.md](ADVANCED.md) explains how to customize the package:

* [What happens by default](ADVANCED.md#what-happens-by-default), and the [service mutators](ADVANCED.md#service-mutators) that change it, for example to fail a request in the app when it has no token
* [Message signing](ADVANCED.md#message-signing): which signatures to make, and how to turn signing off
* [Header names](ADVANCED.md#header-names), [secure strings](ADVANCED.md#secure-strings), [token binding](ADVANCED.md#token-binding) and [excluded URLs](ADVANCED.md#excluding-urls)
* the [challenge handler](ADVANCED.md#challenge-handler), [other networking SDKs](ADVANCED.md#coexistence-with-other-networking-sdks) and [third-party SDKs](ADVANCED.md#third-party-sdks)
* [Diagnostics](ADVANCED.md#diagnostics), which show the result of each token fetch in the log

## NEXT STEPS

1. [Register your app](https://approov.io/docs/latest/approov-usage-documentation/#registering-apps), so that your release builds pass attestation. A [development key](https://approov.io/docs/latest/approov-usage-documentation/#using-a-development-key) lets debug builds and simulators pass attestation.
2. Set up your backend to [verify tokens](https://approov.io/docs/latest/approov-usage-documentation/#approov-tokens) and signatures. This is the step that protects your API.
3. Watch the [live metrics](https://approov.io/docs/latest/approov-usage-documentation/#metrics-graphs) of your account. Then let your backend reject requests without a valid token.

## UPGRADING FROM 3.5.x

This is the first release of this package. It replaces `approov-service-urlsession` and `approov-service-alamofire` 3.5.x. Initialize `ApproovService` in place of the per-library service, and use plain `URLSession` and Alamofire sessions in place of the Approov wrappers. Read the [changelog](CHANGELOG.md) and the [removed and renamed methods](REFERENCE.md#removed-in-370). Test your app and backend together.

### What your backend receives

* Every protected request also carries the `Approov-Status` header.
* Every request that carries a token is signed with both the install and the account signature. The package leaves out a signature that it cannot produce. Your backend verifies the signatures it is configured for.
* By default, a request goes out also when the token fetch fails, for example with no network or after a rejection. It then carries only the `Approov-Status` header, with no token, secure strings or signatures. Your backend must be ready for such a request. To keep the 3.5.x decisions, which fail such a request in the app, install `.CLOSE_FAILURE` (see [service mutators](ADVANCED.md#service-mutators)).
* A secure string never fails a request. If a secure string fetch does not succeed, the package puts the fetch status (`REJECTED`, `UNKNOWN_KEY`, ...) in place of the placeholder, and the request continues.
* A request to a secrets-only API (`UNPROTECTED_URL`) receives its secure strings again, as before urlsession 3.5.6.

### Code changes

* Message signing is on by default. Remove the code that installed `ApproovDefaultMessageSigning` as a mutator. To make one signature only, pass a factory to `enableMessageSigning(_:)`. To turn signing off, call `disableMessageSigning()`.
* `isApproovServiceEnabled()` and `isApproovProtectionEnabled()` replace `isInitialized()` and `isApproovEnabled()`.
* `setUseApproovStatusIfNoToken`, `setProceedOnNetworkFail` and `prefetch` no longer exist.
* `setBindingHeader` and `addSubstitutionHeader` now throw for a header that would be both the binding header and a substitution header.
* `getMessageSignature(message:)` is deprecated. Use `getAccountMessageSignature(message:)`, which throws while Approov protection is not enabled.

### Behaviour changes

* `initialize` never resets your configuration.
* The package also protects the URLSession traffic of a third-party SDK, but the SDK's own trust logic does not run. See [third-party SDKs](ADVANCED.md#third-party-sdks).

## LICENSE

This package is licensed under the [MIT License](LICENSE). It uses the Approov SDK, which is proprietary software of Approov Ltd and is not covered by the MIT License. See [NOTICE](NOTICE).
