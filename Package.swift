// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "bar-tasker-core",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "BarTaskerCore", targets: ["BarTaskerCore"])
  ],
  targets: [
    .target(
      name: "BarTaskerCore",
      path: "Bar Tasker/CoreLogic"
    ),
    .testTarget(
      name: "BarTaskerCoreTests",
      dependencies: ["BarTaskerCore"],
      path: "corelogic-tests"
    ),
  ]
)
