// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DeskBar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Sensors", path: "Sources/Sensors",
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .executableTarget(name: "DeskBar", dependencies: ["Sensors"], path: "Sources/DeskBar",
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("IOKit"), .linkedFramework("CoreMediaIO")])
    ]
)
