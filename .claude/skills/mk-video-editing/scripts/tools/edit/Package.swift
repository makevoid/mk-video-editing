// swift-tools-version:5.9
// medit: footage editor for camera recordings (talks, interviews, events). Decodes HDR/SDR sources to Rec.709, analyzes
// shake, flicker, exposure and people (Vision), and renders an edit decision list (edl.json) with a virtual camera
// (stabilized reframing, subject follow, zooms and pans), deflicker, grading, dissolves, fades and alpha overlays.
import PackageDescription

let package = Package(
    name: "medit",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../graphics")],
    targets: [
        .executableTarget(name: "medit", dependencies: [.product(name: "MotionGraphics", package: "graphics")], path: "Sources/medit")
    ]
)
