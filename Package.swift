// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "Lifelog",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "lifelog", targets: ["Lifelog"])],
    targets: [
        .target(name: "LifelogCore", resources: [.process("Resources/notes.js"), .copy("Resources/viewer")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Lifelog", dependencies: ["LifelogCore"], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", root + "/Support/Info.plist"])
        ]),
        .testTarget(name: "LifelogCoreTests", dependencies: ["LifelogCore"], exclude: ["Golden"], linkerSettings: [.linkedLibrary("sqlite3")])
    ]
)
