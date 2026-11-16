// swift-tools-version: 6.1
import PackageDescription

// The binary carries its own Info.plist in a __TEXT,__info_plist section.
// macOS reads the usage strings from it when it shows a privacy prompt.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"

let package = Package(
    name: "applesauce",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "applesauce", targets: ["applesauce"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "AppleSauceCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModCalendar",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModReminders",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModMail",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModNotes",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModContacts",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModShortcuts",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModSpotlight",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .target(
            name: "ModSystem",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(
            name: "applesauce",
            dependencies: [
                "AppleSauceCore", "ModCalendar", "ModReminders", "ModMail", "ModNotes", "ModContacts",
                "ModShortcuts", "ModSpotlight", "ModSystem",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", infoPlist,
                    ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "AppleSauceCoreTests",
            dependencies: ["AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModCalendarTests",
            dependencies: ["ModCalendar", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModRemindersTests",
            dependencies: ["ModReminders", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModMailTests",
            dependencies: ["ModMail", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModNotesTests",
            dependencies: ["ModNotes", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModContactsTests",
            dependencies: ["ModContacts", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModShortcutsTests",
            dependencies: ["ModShortcuts", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModSpotlightTests",
            dependencies: ["ModSpotlight", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "ModSystemTests",
            dependencies: ["ModSystem", "AppleSauceCore", .product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
