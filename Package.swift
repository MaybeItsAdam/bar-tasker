// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "checkvist-focus-corelogic",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "CheckvistFocusCore", targets: ["CheckvistFocusCore"])
  ],
  targets: [
    .target(
      name: "CheckvistFocusCore",
      path: "checkvist focus/CoreLogic"
    ),
    .testTarget(
      name: "CheckvistFocusCoreTests",
      dependencies: ["CheckvistFocusCore"],
      path: "corelogic-tests"
    ),
  ]
)
