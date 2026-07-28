// swift-tools-version:5.10
import PackageDescription

// pace — a calm menu-bar break reminder. Pomodoro-inspired eye + movement
// breaks that get out of the way during calls. No dependencies: AppKit +
// SwiftUI (overlay only) + CoreAudio (mic-in-use) + IOKit (idle). Same
// self-contained-.app pattern as netty (see make-app.sh).
let package = Package(
    name: "pace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "pace",
            path: "Sources/pace"
        )
    ]
)
