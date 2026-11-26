# The published Approov SDK pod version this pod requires. Development only: APPROOV_IOS_SDK_VERSION, when set
# and not empty, requires that version instead, so a local approov-ios-sdk pod (Podfile `:path`) of an SDK not
# published yet can be used, as APPROOV_IOS_SDK_PATH does for SwiftPM.
approov_sdk_version = "3.7.0"
approov_sdk_requirement = ENV["APPROOV_IOS_SDK_VERSION"].to_s.empty? ? approov_sdk_version : ENV["APPROOV_IOS_SDK_VERSION"]

Pod::Spec.new do |s|
  s.name         = "approov-service-ios"
  # The version main is at. Must match the top CHANGELOG entry, Package.swift releaseTAG (the
  # SwiftPM version is the git tag) and ApproovService.serviceVersion. Bump all of them together.
  s.version      = "3.7.0"
  s.summary      = "Drop-in Approov service layer that protects all URLSession-based networking"
  s.description  = <<-DESC
    One initialize call adds Approov token injection, Approov-managed pinning, secure strings
    and message signing to every URLSession-based client (URLSession, Alamofire, AFNetworking,
    generated API clients) through a URLProtocol and a URLSessionConfiguration swizzle.
  DESC
  s.homepage     = "https://github.com/approov-alpha/approov-service-ios"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.authors      = { "CriticalBlue, Ltd." => "support@approov.io" }
  s.source       = { :git => "https://github.com/approov-alpha/approov-service-ios.git", :tag => s.version.to_s }

  # One Swift module, named like the SwiftPM product apps import (`import ApproovService`). The
  # SwiftPM ApproovServiceCore target (SDK-free, kept separate so it tests on macOS) is compiled
  # into this module; ApproovService.swift only imports ApproovServiceCore when it exists.
  s.module_name  = "ApproovService"
  # Both language modes are supported, as Package.swift `swiftLanguageModes: [.v6, .v5]`
  # declares; CocoaPods builds the pod in the newest one the app's toolchain supports.
  s.swift_versions = ["5.0", "6.0"]

  # Same floor as Package.swift (SecTrustCopyCertificateChain needs iOS 15).
  s.ios.deployment_target = "15.0"

  s.source_files = "Sources/ApproovServiceCore/**/*.swift", "Sources/ApproovService/**/*.swift"

  # The shared Approov SDK pod, as ApproovURLSession and approov-service-react-native depend on
  # it, so the app links one SDK whichever Approov layers it combines. Exactly the version
  # Package.swift pins (sdkVersion, exact:), so both package managers build against one SDK.
  s.dependency "approov-ios-sdk", approov_sdk_requirement
  # The same range as Package.swift (from: "1.4.0", up to the next major); 1.4.0 is the oldest
  # release published to CocoaPods trunk.
  s.dependency "swift-http-structured-headers", "~> 1.4"
  s.frameworks = "Approov"

  # The sources use the Swift `package` access level between the SwiftPM targets; outside SwiftPM
  # the compiler needs an explicit package name for it.
  s.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -package-name approov_service_ios"
  }
end
