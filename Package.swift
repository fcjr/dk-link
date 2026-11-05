// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DKLink",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DKCore", targets: ["DKCore"]),
        .library(name: "Syphon", targets: ["Syphon"]),
        .library(name: "DKKit", targets: ["DKKit"]),
        .library(name: "DKLinkTD", type: .dynamic, targets: ["DKLinkTD"]),
        .executable(name: "dklink", targets: ["dklink"]),
        .executable(name: "DKLinkApp", targets: ["DKLinkApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "CLibusb",
            path: "Sources/CLibusb",
            exclude: ["LICENSE.libusb"],
            sources: [
                "core.c", "descriptor.c", "hotplug.c", "io.c", "strerror.c", "sync.c",
                "os/darwin_usb.c", "os/events_posix.c", "os/threads_posix.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags(["-Wno-shorten-64-to-32", "-Wno-unused-parameter"]),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "DKCore",
            dependencies: ["CLibusb"],
            path: "Sources/DKCore",
            exclude: ["openk4a/LICENSE.OpenK4A"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/openk4a"),
                .headerSearchPath("openk4a"),
                .define("K4A_STATIC_DEFINE"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .target(
            name: "Syphon",
            path: "Sources/Syphon",
            exclude: ["LICENSE.Syphon"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include"),
                .headerSearchPath("include/Syphon"),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .target(
            name: "DKKit",
            dependencies: ["DKCore", "Syphon"],
            path: "Sources/DKKit",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .target(
            name: "CDKLinkTD",
            path: "Sources/CDKLinkTD",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DKLinkTD",
            dependencies: ["DKKit", "DKCore", "CDKLinkTD"],
            path: "Sources/DKLinkTD",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(
            name: "DKLinkApp",
            dependencies: ["DKKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DKLinkApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "dklink",
            dependencies: ["DKCore", "Syphon"],
            path: "Sources/dklink"
        ),
        .testTarget(
            name: "DKLinkTDTests",
            dependencies: ["DKLinkTD", "CDKLinkTD"],
            path: "Tests/DKLinkTDTests"
        ),
        .testTarget(
            name: "DKKitTests",
            dependencies: ["DKKit"],
            path: "Tests/DKKitTests"
        ),
        .testTarget(
            name: "DKCoreTests",
            dependencies: ["DKCore"],
            path: "Tests/DKCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    cLanguageStandard: .gnu11
)
