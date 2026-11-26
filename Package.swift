// swift-tools-version:6.0
// ApproovService: a drop-in Approov service layer that intercepts ALL URLSession-based
// networking (URLSession, Alamofire, AFNetworking, ...) via a URLProtocol subclass plus a
// swizzle of the URLSessionConfiguration factory getters: one layer instead of the per-library
// service layers (approov-service-urlsession / approov-service-alamofire).
import Foundation
import PackageDescription

// Approov SDK package version. The SDK is consumed as the shared approov-ios-sdk package (the
// same `.package(url:exact:)` declaration approov-service-urlsession and
// approov-service-alamofire use) and never as a private binary target: SwiftPM requires target
// names to be unique across the package graph, so a private `Approov` binary target cannot
// coexist with another Approov service layer in the same app. With the shared package an app
// can depend on this layer alongside the per-library layers and resolves ONE approov-ios-sdk.
// Keep in step with the podspec `approov-ios-sdk` dependency (the same exact version).
let sdkVersion: Version = "3.7.0"

// Development only: APPROOV_IOS_SDK_PATH names a local folder holding a Package.swift with a binaryTarget
// `Approov` (product `Approov`) over an Approov.xcframework, used in place of the published approov-ios-sdk,
// such as an SDK release candidate. The folder must be named approov-ios-sdk, since SwiftPM names a local
// package after its folder. Unset, the published SDK above is used. SwiftPM and Xcode read it when the package is resolved, so reset the package caches after a change.
let localSDKPath = ProcessInfo.processInfo.environment["APPROOV_IOS_SDK_PATH"].flatMap { $0.isEmpty ? nil : $0 }

// the Approov SDK package, published or local
let sdkPackage: Package.Dependency = localSDKPath.map { .package(path: $0) }
    ?? .package(url: "https://github.com/approov/approov-ios-sdk.git", exact: sdkVersion)

// The version main is at. The SwiftPM version is the git tag, so this, the podspec s.version,
// ApproovService.serviceVersion and the top CHANGELOG entry must all match; bump them together.
let releaseTAG = "3.7.0"

let package = Package(
    name: "ApproovService",
    platforms: [
        // floor is iOS 15 / macOS 12 so SecTrustCopyCertificateChain can be used directly
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // SDK-free interception core: URLProtocol + swizzle + pinning + request decoration +
        // service mutator + message signing. Compiles and tests on macOS so the mechanism is
        // verifiable without a device.
        .library(name: "ApproovServiceCore", targets: ["ApproovServiceCore"]),
        // The real product: core + Approov SDK binding. iOS only (binary SDK has no macOS slice).
        .library(name: "ApproovService", targets: ["ApproovService"]),
    ],
    dependencies: [
        // HTTP structured field values (RFC 8941/9651) used by message signing (RFC 9421),
        // the same dependency approov-service-urlsession uses. Same floor as the podspec's
        // `~> 1.4` (1.4.0 is the oldest release on CocoaPods trunk).
        .package(url: "https://github.com/apple/swift-http-structured-headers.git", from: "1.4.0"),
        // The Approov SDK, shared with the other Approov iOS service layers.
        sdkPackage,
    ],
    targets: [
        .target(
            name: "ApproovServiceCore",
            dependencies: [
                .product(name: "RawStructuredFieldValues", package: "swift-http-structured-headers"),
            ]
        ),
        .target(
            name: "ApproovService",
            dependencies: [
                "ApproovServiceCore",
                // the binary SDK has no macOS slice; on macOS this module compiles empty
                // (see the canImport guard in its sources) so `swift test` works host-side
                .product(name: "Approov", package: "approov-ios-sdk", condition: .when(platforms: [.iOS])),
            ]
        ),
    ],
    // The package and its sources support both language modes: SwiftPM builds the production
    // targets in Swift 6 (the first listed mode the compiler supports), and the sources compile
    // warning-free in Swift 5 mode too, for apps and toolchains that build dependencies in it.
    // Keep in step with the podspec `s.swift_versions`.
    swiftLanguageModes: [.v6, .v5]
)
