// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "ICloudExporter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "icloud-exporter", targets: ["ICloudExporter"])],
    targets: [
        .target(name: "ICloudExporterCore", resources: [.process("Resources/notes.js"), .copy("Resources/viewer")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ICloudExporter", dependencies: ["ICloudExporterCore"], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", root + "/Support/Info.plist"])
        ]),
        .testTarget(name: "ICloudExporterCoreTests", dependencies: ["ICloudExporterCore"], exclude: ["Golden"], linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
