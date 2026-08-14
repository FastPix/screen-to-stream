// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "screen-to-stream",
    platforms: [.macOS(.v14)],
    targets: [
        // The embedded __info_plist section makes the bare binary (what Xcode's Run button
        // executes) a proper TCC client: camera/mic usage strings resolve and it stays a
        // menu-bar app. The assembled .app uses Contents/Info.plist, which takes precedence.
        .executableTarget(
            name: "App",
            path: "Sources/App",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "AppTests", dependencies: ["App"], path: "Tests/AppTests"),
        // Read-only MCP server — Foundation only, never links the App target (AppKit/AVFoundation).
        .target(name: "MCPCore", path: "Sources/MCPCore"),
        .executableTarget(name: "mcp-server", dependencies: ["MCPCore"], path: "Sources/MCP"),
        .testTarget(name: "MCPTests", dependencies: ["MCPCore"], path: "Tests/MCPTests"),
    ]
)
