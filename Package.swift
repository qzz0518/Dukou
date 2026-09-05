// swift-tools-version: 6.0
import PackageDescription

// Dukou ships two signed Mach-O binaries in one bundle: the resident menu bar
// app and the `com.apple.share-services` extension inside it. SwiftPM has no
// notion of an `.appex`, so both are plain executables here and
// `Scripts/make-app.sh` assembles and signs the bundle around them.
let package = Package(
    name: "Dukou",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dukou", targets: ["DukouApp"]),
        .executable(name: "DukouShare", targets: ["DukouShare"]),
        .library(name: "DukouCore", targets: ["DukouCore"]),
    ],
    dependencies: [
        // Only the app links it. The extensions never update anything, and a
        // framework inside an appex would be a second copy to sign and notarise.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6"),
    ],
    targets: [
        // Built with `-application-extension` on purpose: the shared inbox code
        // runs inside the share extension, and the compiler is the only thing
        // that reliably catches an API that is unavailable there.
        .target(
            name: "DukouCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-application-extension"]),
            ]
        ),
        .executableTarget(
            name: "DukouApp",
            dependencies: [
                "DukouCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // An app extension has no `main`: dyld enters at `NSExtensionMain`,
        // which reads `NSExtensionPrincipalClass` from the appex Info.plist.
        // Xcode expresses this as `-e _NSExtensionMain`; SwiftPM needs the same
        // flag spelled out, plus an (empty) main.swift so the target still
        // satisfies SwiftPM's executable rule.
        .executableTarget(
            name: "DukouShare",
            dependencies: ["DukouCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-application-extension"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                    "-Xlinker", "-application_extension",
                ])
            ]
        ),
        .testTarget(
            name: "DukouCoreTests",
            dependencies: ["DukouCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
