// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KinectMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KinectCore", targets: ["KinectCore"]),
        .library(name: "Syphon", targets: ["Syphon"]),
        .library(name: "KinectKit", targets: ["KinectKit"]),
        .executable(name: "kinectctl", targets: ["kinectctl"]),
        .executable(name: "KinectApp", targets: ["KinectApp"]),
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
            name: "KinectCore",
            dependencies: ["CLibusb"],
            path: "Sources/KinectCore",
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
            name: "KinectKit",
            dependencies: ["KinectCore", "Syphon"],
            path: "Sources/KinectKit",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .executableTarget(
            name: "KinectApp",
            dependencies: ["KinectKit"],
            path: "Sources/KinectApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .executableTarget(
            name: "kinectctl",
            dependencies: ["KinectCore", "Syphon"],
            path: "Sources/kinectctl"
        ),
        .testTarget(
            name: "KinectKitTests",
            dependencies: ["KinectKit"],
            path: "Tests/KinectKitTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "KinectCoreTests",
            dependencies: ["KinectCore"],
            path: "Tests/KinectCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    cLanguageStandard: .gnu11
)
