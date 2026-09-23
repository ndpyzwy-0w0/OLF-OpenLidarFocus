// swift-tools-version: 5.9
import PackageDescription

/// 跟焦器功能层（纯逻辑，只有一个 Foundation 依赖）。
///
/// 这里**不允许** import Flutter/UIKit：UI 层通过 `FollowFocusCorePlugin` 的
/// channel 调用它，两层靠编译器强制分开。macOS 平台声明是为了能直接
/// `swift test` 跑逻辑测试，不必等模拟器构建。
let package = Package(
  name: "FollowFocusCore",
  platforms: [.iOS("15.4"), .macOS(.v13)],
  products: [
    .library(name: "FollowFocusCore", targets: ["FollowFocusCore"])
  ],
  targets: [
    .target(name: "FollowFocusCore"),
    .testTarget(
      name: "FollowFocusCoreTests",
      dependencies: ["FollowFocusCore"]
    ),
  ]
)
