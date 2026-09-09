// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StitchKit",
    platforms: [.macOS(.v14)],
    products: [
        // Static on purpose: app extensions that link an embedded .framework/.dylib
        // hit signing and @rpath problems. Static linking into each target avoids all of it.
        .library(name: "StitchKit", type: .static, targets: ["StitchKit"]),
        // Diagnostics only. The app targets never link this.
        .executable(name: "stitchdump", targets: ["stitchdump"])
    ],
    targets: [
        .target(name: "StitchKit"),
        .executableTarget(name: "stitchdump", dependencies: ["StitchKit"]),
        .testTarget(
            name: "StitchKitTests",
            dependencies: ["StitchKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
