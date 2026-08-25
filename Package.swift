// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GuavaSureSDK",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "GuavaSureSDK", targets: ["GuavaSureSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/razorpay/razorpay-pod.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "GuavaSureSDK",
            dependencies: [
                .product(name: "RazorpayCheckout", package: "razorpay-pod"),
            ],
            path: "Sources/GuavaSureSDK"
        ),
    ]
)
