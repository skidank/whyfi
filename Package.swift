// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhyFi",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "WhyFiCore"),
        .target(name: "WhyFiScan", dependencies: ["WhyFiCore"],
                linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("CoreLocation")]),
        .executableTarget(name: "WhyFiApp", dependencies: ["WhyFiCore", "WhyFiScan"],
                         resources: [.copy("Resources/oui.tsv")]),
        .testTarget(name: "WhyFiCoreTests", dependencies: ["WhyFiCore"]),
    ]
)
