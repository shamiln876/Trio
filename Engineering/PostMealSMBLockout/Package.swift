// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PostMealSMBLockout",
    products: [.library(name: "PostMealSMBLockout", targets: ["PostMealSMBLockout"])],
    targets: [
        .target(name: "PostMealSMBLockout"),
        .testTarget(name: "PostMealSMBLockoutTests", dependencies: ["PostMealSMBLockout"])
    ]
)
