// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Scanner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Scanner",
            path: "Sources/Scanner",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreLocation"),
            ]
        )
    ]
)
